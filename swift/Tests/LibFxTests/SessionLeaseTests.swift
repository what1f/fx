import Foundation
import Testing
@testable import LibFx

private final class LeaseTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var instant = ContinuousClock.now
    private var date = Date(timeIntervalSince1970: 1_000)
    private var sleepers: [UUID: (ContinuousClock.Instant, AsyncResult<Void>)] = [:]
    var now: ContinuousClock.Instant { lock.withLock { instant } }
    var wall: Date { lock.withLock { date } }
    var clock: SessionLeaseClock { SessionLeaseClock(now: { self.now }, sleep: { try await self.sleep($0) }) }
    func advance(_ duration: Duration) async {
        let ready = lock.withLock { () -> [AsyncResult<Void>] in
            instant = instant.advanced(by: duration)
            date = date.addingTimeInterval(Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18)
            let ready = sleepers.filter { $0.value.0 <= instant }
            for id in ready.keys { sleepers[id] = nil }
            return ready.values.map { $0.1 }
        }
        for value in ready { await value.resolve(.success(())) }
    }
    private func sleep(_ deadline: ContinuousClock.Instant) async throws {
        let id = UUID(), signal = AsyncResult<Void>()
        let pending = lock.withLock { () -> Bool in
            guard instant < deadline else { return false }
            sleepers[id] = (deadline, signal)
            return true
        }
        defer { _ = lock.withLock { sleepers.removeValue(forKey: id) } }
        if pending { try await signal.wait() }
        try Task.checkCancellation()
    }
}

/// Deliberately ignores cancellation until released by the test.
private actor HeldLeaseCallback {
    let started = AsyncResult<Void>()
    private var continuation: CheckedContinuation<Void, Never>?
    func call() async {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            Task { await self.started.resolve(.success(())) }
        }
    }
    func release() { continuation?.resume(); continuation = nil }
}

@Suite(.timeLimit(.minutes(1))) struct SessionLeaseTests {
    private func policy() throws -> FxSessionLeasePolicy {
        try FxSessionLeasePolicy(duration: .seconds(10), renewalInterval: .seconds(3))
    }
    private func lease() -> FxSessionLease { .init(sessionID: "s", owner: "old", epoch: 1) }
    private func location() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("lease.sqlite")
    }

    @Test func validatesTypedLeaseDurations() throws {
        let invalid: [(Duration, Duration)] = [(.zero, .seconds(1)), (.seconds(1), .zero), (.seconds(1), .seconds(1)), (.seconds(1), .seconds(2))]
        for (duration, interval) in invalid {
            #expect(throws: FxError.self) { try FxSessionLeasePolicy(duration: duration, renewalInterval: interval) }
        }
        #expect(try policy().duration == .seconds(10))
    }

    @Test func sqliteRenewalDefersTakeoverAndExpiryFencesEveryOldMutation() async throws {
        let time = LeaseTestClock(), url = location(), policy = try policy()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let first = try FxSessionStore(url: url, leasePolicy: policy, leaseNow: { time.wall })
        let second = try FxSessionStore(url: url, leasePolicy: policy, leaseNow: { time.wall })
        _ = try await first.accept(session: "s", agent: "a", id: "input", content: [.text("hello")], options: .init())
        let old = try #require(try await first.claim(session: "s", agent: "a"))
        let input = try #require(try await first.next(old))
        try await first.start(old, input: input)
        await time.advance(.seconds(9))
        try await first.renew(old)
        await time.advance(.seconds(9))
        #expect(try await second.claim(session: "s", agent: "a") == nil)
        try await first.checkLease(old)
        await time.advance(.seconds(2))
        // Expiry fences even before a successor changes the epoch.
        await #expect(throws: FxPersistenceError.fenced) { try await first.renew(old) }
        await #expect(throws: FxPersistenceError.fenced) { try await first.appendEvent(old, .update(id: "input", .text("stale"))) }
        let current = try #require(try await second.claim(session: "s", agent: "a"))
        #expect(current.epoch == old.epoch + 1)
        await #expect(throws: FxPersistenceError.fenced) { _ = try await first.appendJournal(old, expected: nil, key: "late", data: Data(), barrier: true, marks: []) }
        await #expect(throws: FxPersistenceError.fenced) { try await first.saveJournalCheckpoint(old, .init(through: "1", data: Data())) }
        let image = Data([1])
        await #expect(throws: FxPersistenceError.fenced) { try await first.storeImage(image, named: PersistedImages.name(for: image), lease: old) }
        let result = FxSessionResult(id: "input", stopReason: .endTurn, usage: nil, error: nil, epoch: old.epoch, isRepeated: false)
        await #expect(throws: FxPersistenceError.fenced) { try await first.finish(old, id: "input", result: result) }
        try await first.release(old)
        try await second.checkLease(current)
        #expect(try await second.next(current)?.wasStarted == true)
        try await second.release(current)
        try await first.close(); try await second.close()
    }

    @Test func sqliteOwnershipModeCannotBeMixedOrSilentlyConverted() async throws {
        for timed in [false, true] {
            let url = location(), policy = try policy()
            defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
            let first = try FxSessionStore(url: url, leasePolicy: timed ? policy : nil)
            #expect(throws: FxError.self) { _ = try FxSessionStore(url: url, leasePolicy: timed ? nil : policy) }
            try await first.close()
        }
    }

    @Test func stalledRenewalExpiresIndependentlyAndLateSuccessCannotRestoreAuthority() async throws {
        let time = LeaseTestClock(), held = HeldLeaseCallback(), notified = AsyncResult<Void>()
        let guarder = SessionLeaseGuard(lease: lease(), policy: try policy(), claimedAt: time.now, clock: time.clock, renew: { _ in await held.call() })
        await guarder.start { await notified.resolve(.success(())) }
        await time.advance(.seconds(3))
        try await held.started.wait()
        await time.advance(.seconds(7))
        try await guarder.waitForLoss()
        try await notified.wait()
        await #expect(throws: FxPersistenceError.fenced) { try await guarder.check() }
        await held.release()
        await #expect(throws: FxPersistenceError.fenced) { try await guarder.check() }
        await guarder.stop()
    }

    @Test func failedRenewalIrreversiblyFencesTheGuard() async throws {
        let time = LeaseTestClock()
        let guarder = SessionLeaseGuard(lease: lease(), policy: try policy(), claimedAt: time.now, clock: time.clock, renew: { _ in throw FxPersistenceError.fenced })
        await guarder.start()
        await time.advance(.seconds(3))
        try await guarder.waitForLoss()
        await #expect(throws: FxPersistenceError.fenced) { try await guarder.check() }
        await guarder.stop()
    }

    @Test func successfulOwnershipReadReturningAfterExpiryCannotAdmitAnEffect() async throws {
        let time = LeaseTestClock(), read = HeldLeaseCallback(), renewal = HeldLeaseCallback()
        let guarder = SessionLeaseGuard(lease: lease(), policy: try policy(), claimedAt: time.now, clock: time.clock, renew: { _ in await renewal.call() })
        await guarder.start()
        let check = Task { try await guarder.checkOwnership { await read.call() } }
        try await read.started.wait()
        await time.advance(.seconds(3))
        try await renewal.started.wait()
        await time.advance(.seconds(7))
        try await guarder.waitForLoss()
        await read.release()
        await #expect(throws: FxPersistenceError.fenced) { try await check.value }
        await renewal.release()
        await guarder.stop()
    }

    @Test func stoppingDoesNotJoinANoncooperativeRenewalOrReportLoss() async throws {
        let time = LeaseTestClock(), held = HeldLeaseCallback()
        let guarder = SessionLeaseGuard(lease: lease(), policy: try policy(), claimedAt: time.now, clock: time.clock, renew: { _ in await held.call() })
        await guarder.start()
        await time.advance(.seconds(3))
        try await held.started.wait()
        await guarder.stop()
        await #expect(throws: CancellationError.self) { try await guarder.waitForLoss() }
        await held.release()
    }
}
