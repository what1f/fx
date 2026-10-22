import Foundation
import LibFx
import LibFxPostgres
import Logging
import PostgresNIO
import Testing

private actor CancellationLockGate {
  private(set) var isOpen = false
  private(set) var failure: (any Error)?
  private var waiters: [CheckedContinuation<Void, Never>] = []
  func wait() async {
    if isOpen { return }
    await withCheckedContinuation { waiters.append($0) }
  }
  func fail(_ error: any Error) { failure = error; open() }
  func open() {
    isOpen = true
    let pending = waiters
    waiters.removeAll()
    for waiter in pending { waiter.resume() }
  }
}

private enum CancellationTestFailure: Error { case missingEnvironment, lockNotObserved }

private func withCancellationClients(
  _ body: @escaping @Sendable (PostgresClient, PostgresClient, FxPostgresStore) async throws -> Void
) async throws {
    let environment = ProcessInfo.processInfo.environment
    guard let host = environment["LIBFX_POSTGRES_TEST_HOST"], host == "127.0.0.1",
      let rawPort = environment["LIBFX_POSTGRES_TEST_PORT"], let port = Int(rawPort),
      let username = environment["LIBFX_POSTGRES_TEST_USER"],
      let database = environment["LIBFX_POSTGRES_TEST_DATABASE"]
    else { throw CancellationTestFailure.missingEnvironment }
    var configuration = PostgresClient.Configuration(host: host, port: port, username: username,
      password: nil, database: database, tls: .disable)
    configuration.options.maximumConnections = 1
    let client = PostgresClient(configuration: configuration)
    configuration.options.maximumConnections = 3
    let observer = PostgresClient(configuration: configuration)
    let namespace = UUID().uuidString
    let policy = try FxSessionLeasePolicy(duration: .seconds(10), renewalInterval: .seconds(2))
    let store = try FxPostgresStore(client: client, namespace: namespace, leasePolicy: policy)
    try await withThrowingTaskGroup(of: Void.self) { group in
      group.addTask { await client.run() }
      group.addTask { await observer.run() }
      defer { group.cancelAll() }
      try await store.migrate()
      try await body(client, observer, store)
    }
}

private func waitForCancellationLock(_ observer: PostgresClient) async throws {
  let deadline = ContinuousClock.now.advanced(by: .seconds(5))
  while ContinuousClock.now < deadline {
    let rows = try await observer.query(
      "SELECT count(*) FROM pg_stat_activity WHERE datname=current_database() AND pid<>pg_backend_pid() AND wait_event_type='Lock' AND query LIKE '%fx_pg_wakes%'")
    for try await count in rows.decode(Int64.self) { if count > 0 { return } }
    await Task.yield()
  }
  throw CancellationTestFailure.lockNotObserved
}

@Suite(.serialized, .timeLimit(.minutes(1)),
  .enabled(if: ProcessInfo.processInfo.environment["LIBFX_POSTGRES_TEST_PORT"] != nil))
struct PostgresCancellationTests {
  @Test func cancelledIntakeInterruptsItsLockedQueryAndReturnsItsOnlyPoolConnection() async throws {
    try await withCancellationClients { client, observer, store in
      let namespace = store.namespace
      let locked = CancellationLockGate(), release = CancellationLockGate()
      _ = try await store.accept(session: "cancel-lock", agent: "owner", id: "seed",
        content: [.text("seed")], options: .init())
      let holding = Task {
        do {
        try await observer.withTransaction(logger: Logger(label: "PostgresCancellationTests")) { connection in
          for try await _ in try await connection.query(
            "SELECT generation FROM fx_pg_wakes WHERE namespace=\(namespace) AND session_id='cancel-lock' FOR UPDATE",
            logger: Logger(label: "PostgresCancellationTests")) {}
          await locked.open()
          await release.wait()
        }
        } catch { await locked.fail(error); throw error }
      }
      // The watchdog only releases the test's lock on failure. Successful
      // synchronization uses pg_stat_activity and task completion, not a delay.
      let watchdog = Task {
        do {
          try await Task.sleep(for: .seconds(8))
          Issue.record("Cancellation did not complete while the conflicting row lock remained held")
          await release.open()
        } catch {}
      }
      defer { watchdog.cancel(); Task { await release.open() } }
      await locked.wait()
      if let error = await locked.failure { throw error }
      let accepting = Task {
        try await store.accept(session: "cancel-lock", agent: "owner", id: "cancelled",
          content: [.text("must not commit")], options: .init())
      }
      do { try await waitForCancellationLock(observer) }
      catch {
        accepting.cancel()
        await release.open()
        _ = await accepting.result
        try await holding.value
        throw error
      }
      accepting.cancel()
      await #expect(throws: CancellationError.self) { try await accepting.value }
      #expect(await release.isOpen == false)
      // With maximumConnections=1 this cannot finish if the interrupted task
      // retained its pool lease. It must use a healthy replacement connection.
      let probe = try await client.query("SELECT 1")
      for try await value in probe.decode(Int.self) { #expect(value == 1) }
      #expect(await release.isOpen == false)
      watchdog.cancel()
      await watchdog.value
      await release.open()
      try await holding.value
      let lease = try #require(try await store.claim(session: "cancel-lock", agent: "owner"))
      #expect(try await store.input(lease, id: "cancelled") == nil)
      try await store.release(lease)
      let wakes = try await observer.query(
        "SELECT generation FROM fx_pg_wakes WHERE namespace=\(namespace) AND session_id='cancel-lock'")
      var generations: [Int64] = []
      for try await generation in wakes.decode(Int64.self) { generations.append(generation) }
      #expect(generations == [1])
      #expect(try await store.accept(session: "cancel-lock", agent: "owner", id: "cancelled",
        content: [.text("accepted after rollback")], options: .init()) == false)
    }
  }

  @Test(arguments: ["renew", "enqueue", "receive"])
  func cancelledQueueOperationInterruptsItsLockedQueryAndLeavesReceiptUsable(operation: String) async throws {
    try await withCancellationClients { client, observer, store in
      let namespace = store.namespace
      let queue = try FxPostgresQueue(client: client, namespace: namespace)
      _ = try await store.accept(session: "queue-cancel", agent: "owner", id: "seed",
        content: [.text("seed")], options: .init())
      let delivery = try #require(try await queue.receive())
      let locked = CancellationLockGate(), release = CancellationLockGate()
      let holding = Task {
        do {
        try await observer.withTransaction(logger: Logger(label: "PostgresCancellationTests")) { connection in
          let query: PostgresQuery = operation == "receive"
            ? "LOCK TABLE fx_pg_wakes IN ACCESS EXCLUSIVE MODE"
            : "SELECT generation FROM fx_pg_wakes WHERE namespace=\(namespace) AND session_id='queue-cancel' FOR UPDATE"
          for try await _ in try await connection.query(query,
            logger: Logger(label: "PostgresCancellationTests")) {}
          await locked.open()
          await release.wait()
        }
        } catch { await locked.fail(error); throw error }
      }
      let watchdog = Task {
        do {
          try await Task.sleep(for: .seconds(8))
          Issue.record("Cancelled queue operation did not return while its conflicting lock remained held")
          await release.open()
        } catch {}
      }
      defer { watchdog.cancel(); Task { await release.open() } }
      await locked.wait()
      if let error = await locked.failure { throw error }
      let renewing = Task {
        switch operation {
        case "enqueue": try await queue.enqueue(delivery.wakeup)
        case "receive": _ = try await queue.receive()
        default: try await queue.renew(delivery)
        }
      }
      do { try await waitForCancellationLock(observer) }
      catch {
        renewing.cancel()
        await release.open()
        _ = await renewing.result
        try await holding.value
        throw error
      }
      renewing.cancel()
      await #expect(throws: CancellationError.self) { try await renewing.value }
      #expect(await release.isOpen == false)
      for try await value in try await client.query("SELECT 1").decode(Int.self) { #expect(value == 1) }
      #expect(await release.isOpen == false)
      watchdog.cancel()
      await watchdog.value
      await release.open()
      try await holding.value
      try await queue.complete(delivery)
      #expect(try await queue.receive() == nil)
    }
  }
}
