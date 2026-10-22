import Foundation
import LibFx
import Logging
import PostgresNIO

/// Network-backed durable storage. The application owns and runs the client pool.
public struct FxPostgresStore: FxRenewableSessionStorage {
  public let client: PostgresClient
  public let namespace: String
  public let leasePolicy: FxSessionLeasePolicy?
  let logger = Logger(label: "LibFxPostgres.Store")
  let leaseSeconds: Double

  public init(
    client: PostgresClient, namespace: String = "default", leasePolicy: FxSessionLeasePolicy
  ) throws {
    guard !namespace.isEmpty, namespace.utf8.count <= 255, !namespace.utf8.contains(0) else {
      throw FxError.invalidInput("Invalid storage namespace")
    }
    self.client = client
    self.namespace = namespace
    self.leasePolicy = leasePolicy
    let parts = leasePolicy.duration.components
    self.leaseSeconds = Double(parts.seconds) + Double(parts.attoseconds) / 1e18
  }

  func rows(_ connection: PostgresConnection, _ query: PostgresQuery) async throws -> [PostgresRow]
  {
    try await postgresRows(connection, query, logger: logger)
  }
  func execute(_ connection: PostgresConnection, _ query: PostgresQuery) async throws {
    _ = try await postgresRows(connection, query, logger: logger)
  }
  func transaction<T: Sendable>(_ body: @escaping @Sendable (PostgresConnection) async throws -> T)
    async throws -> T
  {
    try await postgresTransaction(client: client, logger: logger, body)
  }
  func lockSession(_ connection: PostgresConnection, session: String) async throws -> PostgresRow {
    guard
      let row = try await rows(
        connection,
        "SELECT agent FROM fx_pg_sessions WHERE namespace=\(namespace) AND session_id=\(session) FOR UPDATE"
      ).first
    else { throw FxSessionError.notFound }
    return row
  }
  func checkAgent(_ connection: PostgresConnection, session: String, agent: String) async throws {
    let row = try await lockSession(connection, session: session)
    guard try row.decode(String.self) == agent else { throw FxSessionError.wrongAgent }
  }
  func check(_ connection: PostgresConnection, lease: FxSessionLease) async throws {
    do {
      _ = try await lockSession(connection, session: lease.sessionID)
    } catch FxSessionError.notFound {
      throw FxPersistenceError.fenced
    }
    let result = try await rows(
      connection,
      "SELECT 1 FROM fx_pg_sessions WHERE namespace=\(namespace) AND session_id=\(lease.sessionID) AND owner=\(lease.owner) AND epoch=\(lease.epoch) AND lease_until>clock_timestamp()"
    )
    guard !result.isEmpty else { throw FxPersistenceError.fenced }
  }
  func leased<T: Sendable>(
    _ lease: FxSessionLease, _ body: @escaping @Sendable (PostgresConnection) async throws -> T
  ) async throws -> T {
    try await transaction { connection in
      try await check(connection, lease: lease)
      let value = try await body(connection)
      try await check(connection, lease: lease)
      return value
    }
  }
  public func owner(session: String) async throws -> String? {
    try await transaction { c in
      try await rows(
        c, "SELECT agent FROM fx_pg_sessions WHERE namespace=\(namespace) AND session_id=\(session)"
      ).first?.decode(String.self)
    }
  }
  public func claim(session: String, agent: String) async throws -> FxSessionLease? {
    try await transaction { c in
      try await checkAgent(c, session: session, agent: agent)
      let owner = UUID().uuidString
      let result = try await rows(
        c,
        "UPDATE fx_pg_sessions SET epoch=epoch+1,owner=\(owner),lease_until=clock_timestamp()+make_interval(secs=>\(leaseSeconds)) WHERE namespace=\(namespace) AND session_id=\(session) AND (owner IS NULL OR lease_until<=clock_timestamp()) AND epoch<9223372036854775807 RETURNING epoch"
      )
      guard let row = result.first else {
        let exhausted = try await rows(
          c,
          "SELECT 1 FROM fx_pg_sessions WHERE namespace=\(namespace) AND session_id=\(session) AND epoch=9223372036854775807 AND (owner IS NULL OR lease_until<=clock_timestamp())"
        )
        guard exhausted.isEmpty else { throw FxPersistenceError.sizeLimit }
        return nil
      }
      return FxSessionLease(sessionID: session, owner: owner, epoch: try row.decode(Int64.self))
    }
  }
  public func renew(_ lease: FxSessionLease) async throws {
    try await transaction { c in
      do {
        _ = try await lockSession(c, session: lease.sessionID)
      } catch FxSessionError.notFound {
        throw FxPersistenceError.fenced
      }
      let changed = try await rows(
        c,
        "UPDATE fx_pg_sessions SET lease_until=clock_timestamp()+make_interval(secs=>\(leaseSeconds)) WHERE namespace=\(namespace) AND session_id=\(lease.sessionID) AND owner=\(lease.owner) AND epoch=\(lease.epoch) AND lease_until>clock_timestamp() RETURNING epoch"
      )
      guard !changed.isEmpty else { throw FxPersistenceError.fenced }
    }
  }
  public func release(_ lease: FxSessionLease) async throws {
    try await transaction { c in
      _ = try await lockSession(c, session: lease.sessionID)
      try await execute(
        c,
        "UPDATE fx_pg_sessions SET owner=NULL,lease_until=NULL WHERE namespace=\(namespace) AND session_id=\(lease.sessionID) AND owner=\(lease.owner) AND epoch=\(lease.epoch)"
      )
    }
  }
  public func checkLease(_ lease: FxSessionLease) async throws { try await leased(lease) { _ in } }
}

// Query admission and connection close run on the same event loop. Checking
// before this turn would race a close: PostgresNIO 1.33's query context promise
// is not failed when its write reaches an already closed channel.
func postgresRows(_ connection: PostgresConnection, _ query: PostgresQuery,
                  logger: Logger) async throws -> [PostgresRow] {
  try Task.checkCancellation()
  return try await connection.eventLoop.flatSubmit {
    guard !connection.isClosed else {
      return connection.eventLoop.makeFailedFuture(FxError.closed)
    }
    return connection.query(query, logger: logger).map(\.rows)
  }.get()
}

private struct PostgresRollbackFailure: Error {
  let cause: any Error
  let rollbackError: any Error
}

// Both store and queue transactions need the same cancellation/commit boundary.
func postgresTransaction<Value: Sendable>(
  client: PostgresClient, logger: Logger,
  _ body: @escaping @Sendable (PostgresConnection) async throws -> Value
) async throws -> Value {
  try Task.checkCancellation()
  let decision = PostgresCommitDecision()
  let task = Task {
    do {
      return try await client.withConnection { connection in
        let outcome: Result<Value, any Error>
        do {
          guard decision.register(connection) else { throw CancellationError() }
          do { _ = try await postgresRows(connection, "BEGIN", logger: logger) }
          catch {
            try? await connection.close().get()
            throw error
          }
          let value: Value
          do {
            value = try await body(connection)
            try decision.beginCommit()
          } catch {
            // A cancelled precommit transaction is already being disconnected;
            // PostgreSQL rolls it back on disconnect. Never query it again.
            if !decision.isCancelled {
              do { _ = try await postgresRows(connection, "ROLLBACK", logger: logger) }
              catch let rollbackError {
                try? await connection.close().get()
                throw PostgresRollbackFailure(cause: error, rollbackError: rollbackError)
              }
            }
            throw error
          }
          do { _ = try await postgresRows(connection, "COMMIT", logger: logger) }
          catch {
            // A failed commit has an uncertain outcome. Retire this connection
            // before returning its lease; preserve the actual server error.
            try? await connection.close().get()
            throw error
          }
          outcome = .success(value)
        } catch { outcome = .failure(error) }
        if decision.finish() {
          try? await connection.closeFuture.get()
          throw CancellationError()
        }
        return try outcome.get()
      }
    } catch {
      if decision.finish() { throw CancellationError() }
      throw error
    }
  }
  return try await withTaskCancellationHandler {
    try await task.value
  } onCancel: {
    if decision.cancel() { task.cancel() }
  }
}

private final class PostgresCommitDecision: @unchecked Sendable {
  private let lock = NSLock()
  private var cancelled = false
  private var committing = false
  private var finished = false
  private var connection: PostgresConnection?

  var isCancelled: Bool { lock.withLock { cancelled && !committing } }

  func register(_ connection: PostgresConnection) -> Bool {
    lock.withLock {
      guard !cancelled else {
        // Cancellation can win before pool acquisition completes. Do not begin
        // a transaction on that connection; close and join it before release.
        connection.close().whenFailure { _ in }
        return false
      }
      self.connection = connection
      return true
    }
  }

  /// Returns true only when cancellation won before commit admission.
  func cancel() -> Bool {
    lock.withLock {
      guard !committing, !finished else { return false }
      cancelled = true
      // PostgresNIO's query await does not cancel a running server statement.
      // Only this borrowed connection is interrupted, never the shared client.
      connection?.close().whenFailure { _ in }
      return true
    }
  }

  /// Clearing ownership and ending cancellation admission are one operation.
  func finish() -> Bool {
    lock.withLock {
      connection = nil
      finished = true
      return cancelled && !committing
    }
  }

  func beginCommit() throws {
    try lock.withLock {
      guard !cancelled else { throw CancellationError() }
      committing = true
    }
  }
}
