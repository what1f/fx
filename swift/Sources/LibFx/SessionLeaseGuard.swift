import Foundation

struct SessionLeaseClock: Sendable {
    let now: @Sendable () -> ContinuousClock.Instant
    let sleep: @Sendable (ContinuousClock.Instant) async throws -> Void
    static let continuous = Self(now: { ContinuousClock.now }, sleep: { deadline in
        try await ContinuousClock().sleep(until: deadline)
    })
}

/// Local authority is deliberately shorter than the backend's grant: time starts
/// before sending claim/renew, never when its potentially delayed reply arrives.
actor SessionLeaseGuard {
    private let lease: FxSessionLease
    private let policy: FxSessionLeasePolicy
    private let clock: SessionLeaseClock
    private let renew: @Sendable (FxSessionLease) async throws -> Void
    private var deadline: ContinuousClock.Instant
    private var lastRequest: ContinuousClock.Instant
    private var lost = false
    private var stopped = false
    private var renewal: Task<Void, Never>?
    private var expiry: Task<Void, Never>?
    private var onLoss: (@Sendable () async -> Void)?
    private let loss = AsyncResult<Void>()

    init(lease: FxSessionLease, policy: FxSessionLeasePolicy, claimedAt: ContinuousClock.Instant,
         clock: SessionLeaseClock = .continuous,
         renew: @escaping @Sendable (FxSessionLease) async throws -> Void) {
        self.lease = lease; self.policy = policy; self.clock = clock; self.renew = renew
        self.lastRequest = claimedAt
        self.deadline = claimedAt.advanced(by: policy.duration)
    }

    func start(onLoss: @escaping @Sendable () async -> Void = {}) async {
        guard renewal == nil, expiry == nil, !stopped, !lost else { return }
        self.onLoss = onLoss
        guard clock.now() < deadline else { await invalidate(); return }
        renewal = Task { await self.renewLoop() }
        expiry = Task { await self.expiryLoop() }
    }

    func waitForLoss() async throws { try await loss.wait() }

    func check() async throws {
        if !stopped, !lost, clock.now() >= deadline { await invalidate() }
        guard !lost, !stopped else { throw FxPersistenceError.fenced }
        try Task.checkCancellation()
    }

    /// Recheck after the await: a delayed successful storage read is not authority.
    func checkOwnership(_ check: @Sendable () async throws -> Void) async throws {
        try await self.check()
        do { try await check() }
        catch {
            if case FxPersistenceError.fenced = error { await invalidate() }
            throw error
        }
        try await self.check()
    }

    /// Does not join a host callback that ignores cancellation.
    func stop() async {
        stopped = true
        renewal?.cancel(); expiry?.cancel()
        renewal = nil; expiry = nil; onLoss = nil
        await loss.resolve(.failure(CancellationError()))
    }

    private func invalidate() async {
        guard !lost, !stopped else { return }
        lost = true
        renewal?.cancel(); expiry?.cancel()
        let notify = onLoss
        onLoss = nil
        await loss.resolve(.success(()))
        // Notification must not delay the guard's state transition or waiters.
        if let notify { Task { await notify() } }
    }

    private func renewLoop() async {
        while !lost, !stopped, !Task.isCancelled {
            do { try await clock.sleep(lastRequest.advanced(by: policy.renewalInterval)) }
            catch { return }
            guard !lost, !stopped, !Task.isCancelled else { return }
            let started = clock.now()
            guard started < deadline else { await invalidate(); return }
            do { try await renew(lease) }
            catch {
                if !stopped, !lost { await invalidate() }
                return
            }
            guard !lost, !stopped else { return }
            // Never authorize again after even a conservative local expiry.
            guard clock.now() < deadline else { await invalidate(); return }
            lastRequest = started
            deadline = started.advanced(by: policy.duration)
        }
    }

    private func expiryLoop() async {
        while !lost, !stopped, !Task.isCancelled {
            do { try await clock.sleep(deadline) }
            catch { return }
            if clock.now() >= deadline { await invalidate(); return }
        }
    }
}
