import Foundation
import LibFx
import PostgresNIO

extension FxPostgresStore {
  public func deliveryCutoffs(_ lease: FxSessionLease, id: String) async throws -> Int {
    try await leased(lease) { c in
      guard
        let row = try await rows(
          c,
          "SELECT CASE WHEN step IS NOT DISTINCT FROM cut_step THEN cutoffs ELSE 0 END FROM fx_pg_inputs WHERE namespace=\(namespace) AND session_id=\(lease.sessionID) AND id=\(id)"
        ).first
      else { throw FxSessionError.notFound }
      return try row.decode(Int.self)
    }
  }
  public func cutOffDelivery(_ lease: FxSessionLease, id: String) async throws -> Int {
    try await leased(lease) { c in
      guard
        let row = try await rows(
          c,
          "UPDATE fx_pg_inputs SET cutoffs=CASE WHEN step IS NOT DISTINCT FROM cut_step THEN cutoffs+1 ELSE 1 END,cut_step=step WHERE namespace=\(namespace) AND session_id=\(lease.sessionID) AND id=\(id) AND result IS NULL RETURNING cutoffs"
        ).first
      else { throw FxSessionError.notFound }
      return try row.decode(Int.self)
    }
  }
  func failureState(_ c: PostgresConnection, lease: FxSessionLease, id: String) async throws
    -> FxHarnessFailureState
  {
    guard
      let row = try await rows(
        c,
        "SELECT i.stops,s.halted FROM fx_pg_inputs i JOIN fx_pg_sessions s USING(namespace,session_id) WHERE i.namespace=\(namespace) AND i.session_id=\(lease.sessionID) AND i.id=\(id)"
      ).first
    else { throw FxSessionError.notFound }
    let (stops, halted) = try row.decode((Int, Bool).self)
    return FxHarnessFailureState(stops: stops, halted: halted)
  }
  public func harnessFailureState(_ lease: FxSessionLease, id: String) async throws
    -> FxHarnessFailureState
  { try await leased(lease) { c in try await failureState(c, lease: lease, id: id) } }
  public func recordHarnessStop(_ lease: FxSessionLease, id: String) async throws -> Int {
    try await leased(lease) { c in
      try await execute(
        c,
        "UPDATE fx_pg_inputs SET stops=LEAST(stops+1,5),stop_epoch=\(lease.epoch) WHERE namespace=\(namespace) AND session_id=\(lease.sessionID) AND id=\(id) AND stop_epoch<>\(lease.epoch)"
      )
      let state = try await failureState(c, lease: lease, id: id)
      try await execute(
        c,
        "UPDATE fx_pg_sessions SET recovery_input=\(id) WHERE namespace=\(namespace) AND session_id=\(lease.sessionID)"
      )
      return state.stops
    }
  }
  public func halt(_ lease: FxSessionLease) async throws {
    try await leased(lease) { c in
      try await execute(
        c,
        "UPDATE fx_pg_sessions SET halted=TRUE WHERE namespace=\(namespace) AND session_id=\(lease.sessionID)"
      )
    }
  }
  public func harnessRecoveryInput(_ lease: FxSessionLease) async throws -> FxSessionInput? {
    try await leased(lease) { c in
      guard
        let row = try await rows(
          c,
          "SELECT recovery_input FROM fx_pg_sessions WHERE namespace=\(namespace) AND session_id=\(lease.sessionID)"
        ).first, let id = try row.decode(String?.self)
      else { return nil }
      return try await readInput(c, session: lease.sessionID, id: id)
    }
  }
  public func setHarnessRecoveryInput(_ lease: FxSessionLease, id: String?) async throws {
    try await leased(lease) { c in
      if let id, try await readInput(c, session: lease.sessionID, id: id) == nil {
        throw FxSessionError.notFound
      }
      try await execute(
        c,
        "UPDATE fx_pg_sessions SET recovery_input=\(id) WHERE namespace=\(namespace) AND session_id=\(lease.sessionID)"
      )
    }
  }
}
