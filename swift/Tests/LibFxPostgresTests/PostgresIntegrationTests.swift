import CryptoKit
import Foundation
import LibFx
import LibFxPostgres
import Logging
import PostgresNIO
import Testing

private enum PostgresTestFailure: Error { case missingEnvironment, timedOut }
private struct PostgresTestStageFailure: Error {
  let stage: String
  let cause: String
}

private struct PostgresTestDatabase: Sendable {
  let first: PostgresClient
  let second: PostgresClient
  let namespace: String
  let policy: FxSessionLeasePolicy
  var store: FxPostgresStore {
    get throws { try FxPostgresStore(client: first, namespace: namespace, leasePolicy: policy) }
  }
  var otherStore: FxPostgresStore {
    get throws { try FxPostgresStore(client: second, namespace: namespace, leasePolicy: policy) }
  }
}

private func withPostgres(
  duration: Duration = .seconds(3),
  _ body: @escaping @Sendable (PostgresTestDatabase) async throws -> Void
) async throws {
  let environment = ProcessInfo.processInfo.environment
  guard let host = environment["LIBFX_POSTGRES_TEST_HOST"], host == "127.0.0.1",
    let rawPort = environment["LIBFX_POSTGRES_TEST_PORT"], let port = Int(rawPort),
    let username = environment["LIBFX_POSTGRES_TEST_USER"],
    let database = environment["LIBFX_POSTGRES_TEST_DATABASE"]
  else { throw PostgresTestFailure.missingEnvironment }
  let configuration = PostgresClient.Configuration(
    host: host, port: port, username: username,
    password: nil, database: database, tls: .disable)
  let first = PostgresClient(configuration: configuration)
  let second = PostgresClient(configuration: configuration)
  let policy = try FxSessionLeasePolicy(duration: duration, renewalInterval: duration / 5)
  let context = PostgresTestDatabase(
    first: first, second: second, namespace: UUID().uuidString, policy: policy)
  try await withThrowingTaskGroup(of: Void.self) { group in
    group.addTask { await first.run() }
    group.addTask { await second.run() }
    defer { group.cancelAll() }
    try await context.store.migrate()
    try await body(context)
  }
}

private func postgresPause(_ client: PostgresClient, seconds: Double) async throws {
  let rows = try await client.query("SELECT pg_sleep(\(seconds))")
  for try await _ in rows {}
}

private func waitForPostgresLock(_ client: PostgresClient, matching pattern: String) async throws {
  let deadline = ContinuousClock.now.advanced(by: .seconds(5))
  while ContinuousClock.now < deadline {
    let rows = try await client.query(
      "SELECT count(*) FROM pg_stat_activity WHERE datname=current_database() AND pid<>pg_backend_pid() AND wait_event_type='Lock' AND query LIKE \(pattern)"
    )
    for try await row in rows { if try row.decode(Int64.self) > 0 { return } }
    try await Task.sleep(for: .milliseconds(10))
  }
  throw PostgresTestFailure.timedOut
}

private actor PostgresTestGate {
  private var open = false
  private var waiters: [CheckedContinuation<Void, Never>] = []
  func wait() async {
    if open { return }
    await withCheckedContinuation { waiters.append($0) }
  }
  func release() {
    open = true
    let pending = waiters
    waiters = []
    for waiter in pending { waiter.resume() }
  }
}

private actor PostgresReadySignal {
  private var outcome: Result<Void, any Error>?
  private var waiters: [CheckedContinuation<Void, any Error>] = []
  func complete(_ outcome: Result<Void, any Error>) {
    guard self.outcome == nil else { return }
    self.outcome = outcome
    let pending = waiters
    waiters = []
    for waiter in pending { waiter.resume(with: outcome) }
  }
  func wait() async throws {
    if let outcome { return try outcome.get() }
    try await withCheckedThrowingContinuation { waiters.append($0) }
  }
}

private struct PostgresHeldRows: Sendable {
  let release: PostgresTestGate
  let task: Task<Void, any Error>
  func unlock() async throws {
    await release.release()
    try await task.value
  }
}

private func withPostgresHeldRows(
  _ client: PostgresClient, query: PostgresQuery,
  _ body: @escaping @Sendable (PostgresHeldRows) async throws -> Void
) async throws {
  let ready = PostgresReadySignal()
  let release = PostgresTestGate()
  let holding = Task {
    do {
      try await client.withTransaction(logger: Logger(label: "PostgresIntegrationTests")) {
        connection in
        for try await _ in try await connection.query(
          query, logger: Logger(label: "PostgresIntegrationTests"))
        {}
        await ready.complete(.success(()))
        await release.wait()
      }
    } catch {
      await ready.complete(.failure(error))
      throw error
    }
  }
  let lock = PostgresHeldRows(release: release, task: holding)
  do {
    try await withTaskCancellationHandler {
      try await ready.wait()
    } onCancel: {
      Task { await ready.complete(.failure(CancellationError())) }
    }
    try await body(lock)
    try await lock.unlock()
  } catch {
    await release.release()
    _ = await holding.result
    throw error
  }
}

private actor PostgresNativeHTTP: FxHTTPClient {
  let entered = PostgresReadySignal(), release = PostgresTestGate()
  let holdFirst: Bool
  private(set) var bodies: [String] = []
  init(holdFirst: Bool = false) { self.holdFirst = holdFirst }
  func send(_ request: URLRequest) async throws -> FxHTTPResponse {
    #expect(request.httpMethod == "POST")
    bodies.append(String(decoding: request.httpBody ?? Data(), as: UTF8.self))
    if bodies.count == 1 && holdFirst {
      await entered.complete(.success(()))
      await release.wait()
    }
    let text =
      "data: {\"type\":\"text-delta\",\"delta\":\"postgres reply\"}\n\ndata: {\"type\":\"finish\",\"finishReason\":{\"unified\":\"stop\",\"raw\":\"stop\"}}\n\ndata: [DONE]\n\n"
    return FxHTTPResponse(
      statusCode: 200,
      body: AsyncThrowingStream {
        $0.yield(Data(text.utf8))
        $0.finish()
      })
  }
}

@Suite(
  .serialized, .timeLimit(.minutes(2)),
  .enabled(if: ProcessInfo.processInfo.environment["LIBFX_POSTGRES_TEST_PORT"] != nil))
struct PostgresIntegrationTests {
  @Test func concurrentSameIDIntakeKeepsTheFirstCommittedInputAndOwner() async throws {
    try await withPostgres { database in
      let first = try database.store
      let second = try database.otherStore
      let results = try await withThrowingTaskGroup(of: (Int, Bool).self) { group in
        for index in 0..<16 {
          group.addTask {
            let store = index.isMultiple(of: 2) ? first : second
            return (
              index,
              try await store.accept(
                session: "atomic", agent: "owner", id: "same",
                content: [.text("candidate-\(index)")], options: .init())
            )
          }
        }
        var results: [(Int, Bool)] = []
        for try await result in group { results.append(result) }
        return results
      }
      let winner = try #require(results.filter { !$0.1 }.only?.0)
      let lease = try #require(try await second.claim(session: "atomic", agent: "owner"))
      let input = try #require(try await first.next(lease))
      #expect(input.id == "same" && input.content == [.text("candidate-\(winner)")])
      #expect(try await first.owner(session: "atomic") == "owner")
      await #expect(throws: FxSessionError.wrongAgent) {
        try await second.accept(
          session: "atomic", agent: "intruder", id: "other", content: [.text("wrong owner")],
          options: .init())
      }
      await #expect(throws: FxSessionError.messageIDInUse) {
        try await second.accept(
          session: "atomic", agent: "owner", id: "same", content: [.text("wrong kind")],
          options: .init(), steering: true)
      }
      try await first.release(lease)
      let queue = try FxPostgresQueue(client: database.second, namespace: database.namespace)
      let wake = try #require(try await queue.receive())
      #expect(wake.wakeup == FxSessionWakeup(agent: "owner", sessionID: "atomic"))
      try await queue.complete(wake)
      #expect(try await queue.receive() == nil)
    }
  }

  @Test func databaseClockRenewalAndExpiryFenceTheOldOwner() async throws {
    try await withPostgres(duration: .milliseconds(500)) { database in
      let first = try database.store
      let second = try database.otherStore
      _ = try await first.accept(
        session: "ttl", agent: "owner", id: "input", content: [.text("original")], options: .init())
      let old = try #require(try await first.claim(session: "ttl", agent: "owner"))
      try await first.start(old, input: #require(try await first.next(old)))
      try await postgresPause(database.second, seconds: 0.3)
      try await first.renew(old)
      try await postgresPause(database.second, seconds: 0.3)
      #expect(try await second.claim(session: "ttl", agent: "owner") == nil)
      try await first.checkLease(old)
      try await postgresPause(database.second, seconds: 0.25)
      await #expect(throws: FxPersistenceError.fenced) { try await first.renew(old) }
      let current = try #require(try await second.claim(session: "ttl", agent: "owner"))
      #expect(current.epoch == old.epoch + 1)
      await #expect(throws: FxPersistenceError.fenced) {
        try await first.appendEvent(old, .yielded(id: "input"))
      }
      await #expect(throws: FxPersistenceError.fenced) {
        try await first.appendJournal(
          old, expected: nil, key: "stale", data: Data([1]), barrier: true, marks: [])
      }
      await #expect(throws: FxPersistenceError.fenced) {
        try await first.saveJournalCheckpoint(old, .init(through: "1", data: Data([2])))
      }
      await #expect(throws: FxPersistenceError.fenced) {
        try await first.finish(
          old, id: "input", result: .init(id: "input", stopReason: .endTurn, epoch: old.epoch))
      }
      try await first.release(old)
      try await second.checkLease(current)
      #expect(try await second.next(current)?.wasStarted == true)
      try await second.release(current)
    }
  }

  @Test func journalCASMarksCheckpointAndImagesSurviveANewStore() async throws {
    try await withPostgres { database in
      let store = try database.store
      _ = try await store.accept(
        session: "journal", agent: "owner", id: "root", content: [.text("root")], options: .init())
      let lease = try #require(try await store.claim(session: "journal", agent: "owner"))
      try await store.start(lease, input: #require(try await store.next(lease)))
      _ = try await store.accept(
        session: "journal", agent: "owner", id: "guide", content: [.text("guide")],
        options: .init(), steering: true)
      let root = FxSessionInput.runtimeID(for: "root")
      let guide = FxSessionInput.runtimeID(for: "guide")
      let first = try await store.appendJournal(
        lease, expected: nil, key: "first", data: Data([1]), barrier: true,
        marks: [.accepted(guide)])
      #expect(try await store.steering(lease, owner: "root").pending.isEmpty)
      await #expect(throws: FxPersistenceError.fenced) {
        try await store.appendJournal(
          lease, expected: nil, key: "wrong-head", data: Data([2]), barrier: true,
          marks: [.withdrawn(guide), .completed(root)])
      }
      #expect(try await store.loadJournal(lease).completedTurnID == nil)
      #expect(try await store.steering(lease, owner: "root").pending.isEmpty)
      let withdrawn = try await store.appendJournal(
        lease, expected: first, key: "withdraw", data: Data([3]), barrier: true,
        marks: [.withdrawn(guide)])
      // Withdrawal makes this an independent queued input. A different
      // guide remains joined and is settled by the original root turn.
      #expect(try await store.steering(lease, owner: "root").pending.isEmpty)
      _ = try await store.accept(
        session: "journal", agent: "owner", id: "joined", content: [.text("joined")],
        options: .init(), steering: true)
      #expect(try await store.steering(lease, owner: "root").pending.map(\.id) == ["joined"])
      let joined = FxSessionInput.runtimeID(for: "joined")
      let finished = try await store.appendJournal(
        lease, expected: withdrawn, key: "finish", data: Data([4]), barrier: true,
        marks: [.accepted(joined), .placed(joined), .completed(root)])
      #expect(
        try await store.appendJournal(
          lease, expected: nil, key: "first", data: Data([1]), barrier: true,
          marks: [.accepted(guide)]) == first)
      let image = Data([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a])
      let imageName = SHA256.hash(data: image).map { String(format: "%02x", $0) }.joined()
      try await store.storeImage(image, named: imageName, lease: lease)
      let checkpoint = FxStoredCheckpoint(through: finished, data: Data([0xfe, 0x80, 0x00]))
      try await store.saveJournalCheckpoint(lease, checkpoint)
      let other = try database.otherStore
      let restored = try await other.snapshot(session: "journal", agent: "owner")
      #expect(
        restored.checkpoint == checkpoint && restored.journal.isEmpty && restored.head == finished)
      #expect(restored.completedTurnID == root)
      #expect(
        try await other.loadImage(named: imageName, session: "journal", agent: "owner") == image)
      #expect(try await other.publicInputID(root, session: "journal") == "root")
      try await store.finish(
        lease, id: "root", result: .init(id: "root", stopReason: .endTurn, epoch: lease.epoch))
      #expect(
        try await store.result(session: "journal", agent: "owner", id: "joined")?.stopReason
          == .endTurn)
      let independent = try #require(try await store.next(lease))
      #expect(independent.id == "guide" && independent.content == [.text("guide")])
      try await store.start(lease, input: independent)
      try await store.finish(
        lease, id: "guide", result: .init(id: "guide", stopReason: .endTurn, epoch: lease.epoch))
      #expect(try await store.next(lease) == nil)
      try await store.release(lease)
      let next = try #require(try await other.claim(session: "journal", agent: "owner"))
      #expect(try await other.loadJournal(next).completedTurnID == root)
      try await other.release(next)
    }
  }

  @Test func wakeDuringDeliverySurvivesCompletionAndOldReceiptCannotAcknowledgeIt() async throws {
    try await withPostgres { database in
      let queue = try FxPostgresQueue(client: database.first, namespace: database.namespace)
      let other = try FxPostgresQueue(client: database.second, namespace: database.namespace)
      let wake = FxSessionWakeup(agent: "owner", sessionID: "generation")
      try await queue.enqueue(wake)
      let first = try #require(try await queue.receive())
      #expect(try await other.receive() == nil)
      try await other.enqueue(wake)
      try await queue.complete(first)
      let second = try #require(try await other.receive())
      #expect(second.wakeup == wake && second.attempt == first.attempt + 1)
      await #expect(throws: FxPostgresQueueError.fenced) { try await queue.complete(first) }
      await #expect(throws: FxPostgresQueueError.fenced) {
        try await queue.retry(first, after: .zero)
      }
      await #expect(throws: FxPostgresQueueError.fenced) { try await queue.renew(first) }
      #expect(try await queue.receive() == nil)
      try await other.complete(second)
      #expect(try await queue.receive() == nil)
    }
  }

  @Test func queueRenewalWaitingOnARowLockCannotReviveAnExpiredReceipt() async throws {
    try await withPostgres { database in
      let queue = try FxPostgresQueue(
        client: database.first, namespace: database.namespace,
        visibilityDuration: .milliseconds(300), renewalInterval: .milliseconds(50))
      let wake = FxSessionWakeup(agent: "owner", sessionID: "locked-receipt")
      try await queue.enqueue(wake)
      let old = try #require(try await queue.receive())
      try await withPostgresHeldRows(
        database.second,
        query:
          "SELECT generation FROM fx_pg_wakes WHERE namespace = \(database.namespace) AND agent = \(wake.agent) AND session_id = \(wake.sessionID) FOR UPDATE"
      ) { lock in
        let renewing = Task { try await queue.renew(old) }
        defer { renewing.cancel() }
        try await waitForPostgresLock(database.first, matching: "%fx_pg_wakes%")
        try await postgresPause(database.second, seconds: 0.4)
        try await lock.unlock()
        await #expect(throws: FxPostgresQueueError.fenced) { try await renewing.value }
        let next = try #require(try await queue.receive())
        #expect(next.attempt == old.attempt + 1)
        await #expect(throws: FxPostgresQueueError.fenced) { try await queue.complete(old) }
        try await queue.complete(next)
      }
    }
  }

  @Test func storeRenewalWaitingOnARowLockCannotReviveAnExpiredOwner() async throws {
    try await withPostgres(duration: .milliseconds(300)) { database in
      let store = try database.store
      _ = try await store.accept(
        session: "locked-owner", agent: "owner", id: "input", content: [.text("original")],
        options: .init())
      let old = try #require(try await store.claim(session: "locked-owner", agent: "owner"))
      try await withPostgresHeldRows(
        database.second,
        query:
          "SELECT epoch FROM fx_pg_sessions WHERE namespace=\(database.namespace) AND session_id='locked-owner' FOR UPDATE"
      ) { lock in
        let renewing = Task { try await store.renew(old) }
        defer { renewing.cancel() }
        try await waitForPostgresLock(database.first, matching: "%fx_pg_sessions%")
        try await postgresPause(database.first, seconds: 0.4)
        try await lock.unlock()
        await #expect(throws: FxPersistenceError.fenced) { try await renewing.value }
        let successor = try #require(
          try await database.otherStore.claim(session: "locked-owner", agent: "owner"))
        #expect(successor.epoch == old.epoch + 1)
        try await database.otherStore.release(successor)
      }
    }
  }

  @Test func cancellationBeforeCommitRollsBackInputAndWakeGeneration() async throws {
    try await withPostgres { database in
      let store = try database.store
      _ = try await store.accept(
        session: "cancelled-intake", agent: "owner", id: "seed", content: [.text("seed")],
        options: .init())
      try await withPostgresHeldRows(
        database.second,
        query:
          "SELECT generation FROM fx_pg_wakes WHERE namespace=\(database.namespace) AND session_id='cancelled-intake' FOR UPDATE"
      ) { lock in

        let accepting = Task {
          try await store.accept(
            session: "cancelled-intake", agent: "owner", id: "cancelled",
            content: [.text("must roll back")], options: .init())
        }
        defer { accepting.cancel() }
        try await waitForPostgresLock(database.first, matching: "%fx_pg_wakes%")

        accepting.cancel()
        try await lock.unlock()

        await #expect(throws: CancellationError.self) { try await accepting.value }

        let lease = try #require(try await store.claim(session: "cancelled-intake", agent: "owner"))
        #expect(try await store.input(lease, id: "cancelled") == nil)
        try await store.release(lease)

        let rows = try await database.first.query(
          "SELECT generation FROM fx_pg_wakes WHERE namespace=\(database.namespace) AND session_id='cancelled-intake'"
        )
        var generations: [Int64] = []
        for try await row in rows { generations.append(try row.decode(Int64.self)) }
        #expect(generations == [1])
      }
    }
  }

  @Test func cancellationAfterCommitStartsPreservesTheAcceptedReceipt() async throws {
    try await withPostgres { database in
      // A deferred constraint trigger runs inside COMMIT. Holding its
      // advisory lock lets the test cancel after the store committed to
      // committing, without a production callback or a timing guess.
      for try await _ in try await database.first.query(
        "CREATE FUNCTION fx_test_hold_commit() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN PERFORM pg_advisory_xact_lock(93485701); RETURN NEW; END $$"
      ) {}
      for try await _ in try await database.first.query(
        "CREATE CONSTRAINT TRIGGER fx_test_hold_commit AFTER INSERT ON fx_pg_inputs DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION fx_test_hold_commit()"
      ) {}
      try await withPostgresHeldRows(
        database.second, query: "SELECT pg_advisory_xact_lock(93485701)"
      ) { lock in
        let accepting = Task {
          try await database.store.accept(
            session: "commit-wins", agent: "owner", id: "input", content: [.text("committed")],
            options: .init())
        }
        defer { accepting.cancel() }
        try await waitForPostgresLock(database.first, matching: "COMMIT%")
        accepting.cancel()
        try await lock.unlock()
        #expect(try await accepting.value == false)
        for try await _ in try await database.first.query(
          "DROP TRIGGER fx_test_hold_commit ON fx_pg_inputs")
        {}
        for try await _ in try await database.first.query("DROP FUNCTION fx_test_hold_commit()") {}
        let store = try database.otherStore
        let lease = try #require(try await store.claim(session: "commit-wins", agent: "owner"))
        #expect(try await store.next(lease)?.content == [.text("committed")])
        #expect(
          try await store.accept(
            session: "commit-wins", agent: "owner", id: "input", content: [.text("retry")],
            options: .init()))
        try await store.release(lease)
        let queue = try FxPostgresQueue(client: database.second, namespace: database.namespace)
        let wake = try #require(try await queue.receive())
        #expect(wake.wakeup.sessionID == "commit-wins")
        try await queue.complete(wake)
      }
    }
  }

  @Test func typedOpaqueExecutionRecoversAcrossFreshAgentsWithoutRepeatingUpdates() async throws {
    try await withPostgres { database in
      let counts = PostgresCalculationCounts()
      defer { Task { await counts.release.release() } }
      let input = PostgresCalculationInput(
        values: [2, -3, 8], label: "中文 café", attachment: Data([0, 255, 13, 10]))
      let queue = try FxPostgresQueue(client: database.first, namespace: database.namespace)
      let wake = FxSessionWakeup(agent: "typed", sessionID: "opaque")
      let first = try FxDurableAgent(
        harness: PostgresCalculationHarness(counts: counts, delay: .milliseconds(15)),
        name: "typed", store: database.store, queue: queue)
      let view = try await first.session(id: "opaque")
      _ = try await view.submit(input, id: "calculation")
      let cutoff = try FxDeliveryPolicy(maximumDuration: .milliseconds(1), reserve: .zero)
      #expect(try await first.deliver(wake, policy: cutoff) == .retry(after: .zero))
      #expect(
        try await database.store.result(session: "opaque", agent: "typed", id: "calculation") == nil
      )
      #expect(await counts.updates == 1)
      try await first.close()

      let second = try FxDurableAgent(
        harness: PostgresCalculationHarness(counts: counts), name: "typed",
        store: database.otherStore, queue: queue)
      #expect(try await second.deliver(wake) == .complete)
      try await second.close()
      let snapshot = try await database.otherStore.snapshot(session: "opaque", agent: "typed")
      #expect(snapshot.checkpoint != nil && snapshot.journal.isEmpty)
      #expect(snapshot.completedTurnID == FxSessionInput.runtimeID(for: "calculation"))

      let third = try FxDurableAgent(
        harness: PostgresCalculationHarness(counts: counts), name: "typed", store: database.store,
        queue: queue)
      let restored = try await third.session(id: "opaque")
      let repeated = try await restored.submit(
        PostgresCalculationInput(values: [999], label: "ignored", attachment: Data()),
        id: "calculation")
      #expect(try await repeated.result.isRepeated)
      var replay = restored.events().makeAsyncIterator()
      guard
        case .started("calculation", "opaque", let restoredInput) = try await replay.next()?.event
      else {
        Issue.record("Typed initial event was not restored")
        return
      }
      #expect(restoredInput == input)
      var updates: [PostgresCalculationUpdate] = []
      var resumes = 0
      replayLoop: while let entry = try await replay.next() {
        switch entry.event {
        case .update(_, let update): updates.append(update)
        case .resumed: resumes += 1
        case .ended(let result):
          #expect(result.stopReason == .endTurn)
          break replayLoop
        default: break
        }
      }
      #expect(updates.map(\.index) == [0, 1, 2])
      #expect(updates.map(\.total) == [2, -1, 7])
      #expect(updates.allSatisfy { $0.input == input })
      #expect(resumes == 1)
      #expect(await counts.submits == 1)
      #expect(await counts.resumes == 1)
      #expect(await counts.updates == 3)
      try await third.close()

      let fourth = try FxDurableAgent(
        harness: PostgresCalculationHarness(counts: counts, holdAfterFirst: true), name: "typed",
        store: database.otherStore, queue: queue)
      let cancelled = try await fourth.session(id: "opaque").submit(input, id: "cancelled")
      let delivering = Task { try await fourth.deliver(wake) }
      await counts.held.wait()
      try await cancelled.cancel()
      await counts.cancelled.wait()
      await counts.release.release()
      #expect(try await delivering.value == .complete)
      #expect(try await cancelled.result.stopReason == .cancelled)
      #expect(await counts.submits == 2)
      #expect(await counts.resumes == 1)
      #expect(await counts.updates == 4)
      #expect(await counts.cancellations == 1)
      try await fourth.close()
    }
  }

  @Test func realQueueConsumerRoutesNativeCompletionAndDrainsOnCancellation() async throws {
    try await withPostgres { database in
      var stage = "setup"
      do {
        let store = try database.store
        let router = FxAgentRouter(store: store)
        let queue = try FxPostgresQueue(
          client: database.first, namespace: database.namespace,
          visibilityDuration: .milliseconds(400), renewalInterval: .milliseconds(75))
        let http = PostgresNativeHTTP(holdFirst: true)
        let unused = PostgresNativeHTTP()
        defer { Task { await http.release.release() } }
        func configuration(_ http: PostgresNativeHTTP) throws -> FxConfiguration {
          var value = FxConfiguration(apiKey: "fixture", model: "swift/postgres", httpClient: http)
          value.modelCatalog = try FxModelCatalog(
            response: Data(#"{"data":[{"id":"swift/postgres","type":"language"}]}"#.utf8))
          return value
        }
        let alpha = try await router.makeAgent(
          configuration: configuration(http), name: "alpha", checkpointAfterBytes: 0, queue: queue)
        let beta = try await router.makeAgent(
          configuration: configuration(unused), name: "beta", checkpointAfterBytes: 0, queue: queue)
        let owned = try await alpha.session(id: "routed")
        let first = try await owned.prompt("FIRST_POSTGRES_TOKEN", id: "first")
        let consumer = Task {
          do {
            try await queue.run(router: router, concurrency: 2, pollInterval: .milliseconds(10))
          } catch {
            await http.entered.complete(.failure(error))
            throw error
          }
        }
        defer { consumer.cancel() }
        try await withTaskCancellationHandler {
          try await http.entered.wait()
        } onCancel: {
          Task { await http.entered.complete(.failure(CancellationError())) }
        }
        let second = try await beta.session(id: "routed").prompt(
          "FORWARDED_POSTGRES_TOKEN", id: "second")
        consumer.cancel()
        // Cancellation must keep active queue visibility renewed until the
        // actual native delivery finishes, beyond its initial receipt TTL.
        stage = "held delivery after consumer cancellation"
        try await postgresPause(database.second, seconds: 0.9)
        #expect(try await queue.receive() == nil)
        #expect(try await store.result(session: "routed", agent: "alpha", id: "first") == nil)
        await http.release.release()
        stage = "first result"
        #expect(try await first.result.stopReason == .endTurn)
        stage = "second result"
        do { #expect(try await second.result.stopReason == .endTurn) } catch {
          let stored = try await store.result(session: "routed", agent: "alpha", id: "second")
          let entries = try await store.entries(session: "routed", agent: "alpha", after: 0)
          let owner = try await store.owner(session: "routed")
          throw PostgresTestStageFailure(
            stage: stage,
            cause:
              "\(error); readerCancelled=\(Task.isCancelled); stored=\(String(reflecting: stored)); owner=\(String(reflecting: owner)); events=\(String(reflecting: entries.map(\.event)))"
          )
        }
        stage = "consumer join"
        do { try await consumer.value } catch is CancellationError {}
        #expect(await http.bodies.count == 2)
        #expect(await unused.bodies.isEmpty)
        #expect(await http.bodies.last?.contains("FORWARDED_POSTGRES_TOKEN") == true)
        stage = "post-delivery snapshot"
        let snapshot = try await store.snapshot(session: "routed", agent: "alpha")
        #expect(snapshot.checkpoint != nil && snapshot.journal.isEmpty)
        #expect(try await store.owner(session: "routed") == "alpha")
        // A generation accepted while delivery was active may remain as an
        // empty wakeup. It must be safely deliverable and then disappear.
        if let remaining = try await queue.receive() {
          stage = "new-generation delivery"
          #expect(try await router.deliver(remaining.wakeup) == .complete)
          try await queue.complete(remaining)
        }
        #expect(try await queue.receive() == nil)
        stage = "repeated input"
        let replay = try await owned.prompt("IGNORED_RETRY_TOKEN", id: "second")
        #expect(replay.isRepeated)
        #expect(try await replay.result.isRepeated)
        #expect(await http.bodies.count == 2)
        stage = "agent close"
        try await alpha.close()
        try await beta.close()
      } catch { throw PostgresTestStageFailure(stage: stage, cause: String(reflecting: error)) }
    }
  }
}

extension Array {
  fileprivate var only: Element? { count == 1 ? first : nil }
}
