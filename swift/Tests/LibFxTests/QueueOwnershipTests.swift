import Foundation
import Testing
@testable import LibFx

private final class QueueOwnershipClock: @unchecked Sendable {
    private let lock = NSLock()
    private var instant = Date(timeIntervalSince1970: 10_000)
    var now: Date { lock.withLock { instant } }
    func expire() { lock.withLock { instant = instant.addingTimeInterval(120) } }
}

private extension FxSessionStore {
    func rejectQueueRelease(_ reject: Bool) throws {
        if reject {
            try database.execute("CREATE TRIGGER reject_queue_release BEFORE UPDATE OF owner ON fx_sessions WHEN NEW.owner IS NULL BEGIN SELECT RAISE(ABORT,'held release'); END")
        } else { try database.execute("DROP TRIGGER reject_queue_release") }
    }
}

@Suite(.serialized, .timeLimit(.minutes(1))) struct QueueOwnershipTests {
    private func policy() throws -> FxSessionLeasePolicy {
        try FxSessionLeasePolicy(duration: .seconds(60), renewalInterval: .seconds(20))
    }
    private func location() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("queue.sqlite")
    }
    private func grant(message: String = "queue-message", attempt: Int64 = 1, equal: Bool = false,
                       source: String = "verified-queue", session: String = "session", input: String? = "input") async throws -> FxQueueClaim {
        let authority = try FxQueueDeliveryAuthority(source: source, allowsSameAttemptRedelivery: equal) {
            (_: FxSessionWakeup, receipt: FxQueueReceipt) in receipt
        }
        let context = FxQueueDeliveryContext(try FxQueueReceipt(messageID: message, attempt: attempt))
        return try await authority.prepare(context, for: FxSessionWakeup(agent: "agent", sessionID: session, inputID: input))
    }
    private func seed(_ store: FxSessionStore) async throws {
        _ = try await store.accept(session: "session", agent: "agent", id: "input", content: [.text("original")], options: .init())
    }

    @Test func queueModeRequiresTimedOwnershipAndCannotBeMixedOrConverted() async throws {
        #expect(throws: FxError.self) { _ = try FxSessionStore(queueSource: "queue") }
        for source in ["", String(repeating: "s", count: 257), "bad\0source"] {
            #expect(throws: FxError.self) { _ = try FxSessionStore(leasePolicy: policy(), queueSource: source) }
        }
        let url = location()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = try FxSessionStore(url: url, leasePolicy: policy(), queueSource: "verified-queue")
        #expect(throws: FxError.self) { _ = try FxSessionStore(url: url, leasePolicy: policy()) }
        #expect(throws: FxError.self) { _ = try FxSessionStore(url: url, leasePolicy: policy(), queueSource: "other-queue") }
        #expect(throws: FxError.self) { _ = try FxSessionStore(url: url) }
        try await store.close()
        let reopened = try FxSessionStore(url: url, leasePolicy: policy(), queueSource: "verified-queue")
        #expect(reopened.queueSource == "verified-queue")
        try await reopened.close()
        let timedURL = location()
        defer { try? FileManager.default.removeItem(at: timedURL.deletingLastPathComponent()) }
        let timed = try FxSessionStore(url: timedURL, leasePolicy: policy())
        #expect(throws: FxError.self) { _ = try FxSessionStore(url: timedURL, leasePolicy: policy(), queueSource: "verified-queue") }
        try await timed.close()
    }

    @Test(arguments: [false, true])
    func verifiedRedeliveryReplacesUnexpiredOwnerAndFencesEveryOldMutation(equalAttempt: Bool) async throws {
        let url = location()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let first = try FxSessionStore(url: url, leasePolicy: policy(), queueSource: "verified-queue")
        let second = try FxSessionStore(url: url, leasePolicy: policy(), queueSource: "verified-queue")
        try await seed(first)
        let original = try await grant()
        let old = try #require(try await first.claim(session: "session", agent: "agent", delivery: original))
        let input = try #require(try await first.next(old))
        try await first.start(old, input: input)
        let head = try await first.appendJournal(old, expected: nil, key: "committed", data: Data([1]), barrier: true, marks: [])
        let replacement = try await grant(attempt: equalAttempt ? 1 : 2, equal: equalAttempt)
        // The same process's genuinely live owner wins even over a new attempt.
        #expect(try await second.claim(session: "session", agent: "agent", delivery: replacement) == nil)
        await first.endExecution(old)
        let current = try #require(try await second.claim(session: "session", agent: "agent", delivery: replacement))
        #expect(current.epoch == old.epoch + 1)
        await #expect(throws: FxPersistenceError.fenced) { try await first.checkLease(old) }
        await #expect(throws: FxPersistenceError.fenced) { try await first.renew(old) }
        await #expect(throws: FxPersistenceError.fenced) { try await first.appendEvent(old, .update(id: "input", .text("late"))) }
        await #expect(throws: FxPersistenceError.fenced) { _ = try await first.appendJournal(old, expected: head, key: "late", data: Data([2]), barrier: true, marks: []) }
        await #expect(throws: FxPersistenceError.fenced) { try await first.saveJournalCheckpoint(old, .init(through: head, data: Data([3]))) }
        let image = Data([4])
        await #expect(throws: FxPersistenceError.fenced) { try await first.storeImage(image, named: PersistedImages.name(for: image), lease: old) }
        let result = FxSessionResult(id: "input", stopReason: .endTurn, usage: nil, error: nil, epoch: old.epoch, isRepeated: false)
        await #expect(throws: FxPersistenceError.fenced) { try await first.finish(old, id: "input", result: result) }
        try await first.release(old)
        try await second.checkLease(current)
        #expect(try await second.next(current)?.wasStarted == true)
        #expect(try await second.loadJournal(current).journal.count == 1)
        #expect(try await second.result(session: "session", agent: "agent", id: "input") == nil)
        try await second.release(current)
        original.finish(); replacement.finish()
        try await first.close(); try await second.close()
    }

    @Test func onlyTheSameMessageAndAllowedAttemptCanSupersedeOwnership() async throws {
        let store = try FxSessionStore(leasePolicy: policy(), queueSource: "verified-queue")
        try await seed(store)
        let original = try await grant(attempt: 4)
        let old = try #require(try await store.claim(session: "session", agent: "agent", delivery: original))
        await store.endExecution(old)
        for candidate in [try await grant(message: "unrelated", attempt: 5), try await grant(attempt: 3, equal: true), try await grant(attempt: 4)] {
            #expect(try await store.claim(session: "session", agent: "agent", delivery: candidate) == nil)
            candidate.finish()
        }
        try await store.checkLease(old)
        try await store.release(old)
        original.finish()
        try await store.close()
    }

    @Test func invocationLedgerAllowsOwnReopenButRejectsSupersededOrFinishedContexts() async throws {
        let store = try FxSessionStore(leasePolicy: policy(), queueSource: "verified-queue")
        try await seed(store)
        let original = try await grant()
        let first = try #require(try await store.claim(session: "session", agent: "agent", delivery: original))
        #expect(try await store.claim(session: "session", agent: "agent", delivery: original) == nil)
        try await store.release(first)
        let reopened = try #require(try await store.claim(session: "session", agent: "agent", delivery: original))
        #expect(reopened.epoch == first.epoch + 1)
        await store.endExecution(reopened)
        let next = try await grant(attempt: 2)
        let current = try #require(try await store.claim(session: "session", agent: "agent", delivery: next))
        try await store.release(current)
        await #expect(throws: FxPersistenceError.fenced) { _ = try await store.claim(session: "session", agent: "agent", delivery: original) }
        next.finish()
        await #expect(throws: FxPersistenceError.fenced) { _ = try await store.claim(session: "session", agent: "agent", delivery: next) }
        original.finish()
        try await store.close()
    }

    @Test func verifiedClaimsRequireTheStoredInputAndExactWakeupAndSource() async throws {
        let store = try FxSessionStore(leasePolicy: policy(), queueSource: "verified-queue")
        try await seed(store)
        for candidate in [try await grant(source: "another"), try await grant(input: nil), try await grant(input: "not-stored"), try await grant(session: "wrong-session")] {
            await #expect(throws: FxPersistenceError.fenced) { _ = try await store.claim(session: "session", agent: "agent", delivery: candidate) }
            candidate.finish()
        }
        #expect(try await store.owner(session: "wrong-session") == nil)
        let valid = try await grant()
        let lease = try #require(try await store.claim(session: "session", agent: "agent", delivery: valid))
        #expect(lease.epoch == 1)
        try await store.release(lease)
        valid.finish()
        try await store.close()
    }

    @Test func plainClaimsKeepTTLRulesAndEraseQueueReplacementAuthority() async throws {
        let clock = QueueOwnershipClock(), store = try FxSessionStore(leasePolicy: policy(), queueSource: "verified-queue", leaseNow: { clock.now })
        try await seed(store)
        let original = try await grant()
        let queued = try #require(try await store.claim(session: "session", agent: "agent", delivery: original))
        #expect(try await store.claim(session: "session", agent: "agent") == nil)
        clock.expire()
        let ordinary = try #require(try await store.claim(session: "session", agent: "agent"))
        #expect(!QueueDeliveryProcess.contains(owner: queued.owner))
        let next = try await grant(attempt: 2)
        #expect(try await store.claim(session: "session", agent: "agent", delivery: next) == nil)
        await #expect(throws: FxPersistenceError.fenced) { _ = try await store.claim(session: "session", agent: "agent", delivery: original) }
        try await store.release(ordinary)
        let acquired = try #require(try await store.claim(session: "session", agent: "agent", delivery: next))
        try await store.release(acquired)
        original.finish(); next.finish()
        try await store.close()
    }

    @Test func failedReleaseKeepsGrantUntilExecutionEndsAndRetryCannotReleaseSuccessor() async throws {
        let store = try FxSessionStore(leasePolicy: policy(), queueSource: "verified-queue")
        try await seed(store)
        let original = try await grant(), next = try await grant(attempt: 2)
        let old = try #require(try await store.claim(session: "session", agent: "agent", delivery: original))
        try await store.rejectQueueRelease(true)
        await #expect(throws: FxSQLiteError.self) { try await store.release(old) }
        #expect(QueueDeliveryProcess.contains(owner: old.owner))
        #expect(try await store.claim(session: "session", agent: "agent", delivery: next) == nil)
        await store.endExecution(old)
        let current = try #require(try await store.claim(session: "session", agent: "agent", delivery: next))
        try await store.rejectQueueRelease(false)
        try await store.release(old)
        try await store.checkLease(current)
        try await store.release(current)
        original.finish(); next.finish()
        try await store.close()
    }

    @Test func racingConnectionsCannotBothReplaceOneStoppedOwner() async throws {
        let url = location()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let first = try FxSessionStore(url: url, leasePolicy: policy(), queueSource: "verified-queue")
        let second = try FxSessionStore(url: url, leasePolicy: policy(), queueSource: "verified-queue")
        try await seed(first)
        let original = try await grant(), left = try await grant(attempt: 2), right = try await grant(attempt: 3)
        let old = try #require(try await first.claim(session: "session", agent: "agent", delivery: original))
        await first.endExecution(old)
        async let one = first.claim(session: "session", agent: "agent", delivery: left)
        async let two = second.claim(session: "session", agent: "agent", delivery: right)
        let results = try await [one, two].compactMap { $0 }
        #expect(results.count == 1)
        let winner = try #require(results.first)
        #expect(winner.epoch == old.epoch + 1)
        try await first.release(winner); try await second.release(winner)
        try await first.release(old)
        original.finish(); left.finish(); right.finish()
        try await first.close(); try await second.close()
    }

    @Test func droppingAStoreUnmarksItsOwnerAndTheInvocationLedgerSurvivesReopen() async throws {
        let url = location()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        var first: FxSessionStore? = try FxSessionStore(url: url, leasePolicy: policy(), queueSource: "verified-queue")
        try await seed(try #require(first))
        let original = try await grant()
        let old = try #require(try await first?.claim(session: "session", agent: "agent", delivery: original))
        #expect(QueueDeliveryProcess.contains(owner: old.owner))
        first = nil
        #expect(!QueueDeliveryProcess.contains(owner: old.owner))
        let second = try FxSessionStore(url: url, leasePolicy: policy(), queueSource: "verified-queue")
        let replacement = try await grant(equal: true)
        let current = try #require(try await second.claim(session: "session", agent: "agent", delivery: replacement))
        #expect(current.epoch == old.epoch + 1)
        try await second.release(current)
        try await second.close()
        let reopened = try FxSessionStore(url: url, leasePolicy: policy(), queueSource: "verified-queue")
        await #expect(throws: FxPersistenceError.fenced) { _ = try await reopened.claim(session: "session", agent: "agent", delivery: original) }
        // The current, still-active invocation remains usable after release and reopen.
        let continued = try #require(try await reopened.claim(session: "session", agent: "agent", delivery: replacement))
        #expect(continued.epoch == current.epoch + 1)
        try await reopened.release(continued)
        original.finish(); replacement.finish()
        try await reopened.close()
    }
}
