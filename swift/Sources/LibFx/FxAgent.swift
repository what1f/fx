import Foundation

/// Owns workers for durable conversations. The caller owns the session store.
public actor FxAgent {
    public nonisolated let name: String
    let store: any FxSessionStorage
    private let harness: any FxSessionHarness
    private let onLifecycleEvent: (@Sendable (FxLifecycleEvent) async -> Void)?
    private let initialCheckpoint: Data?
    private let checkpointAfterBytes: Int?
    private let openingRetryPolicy: FxOpeningRetryPolicy?
    private let deliveryPolicy: FxDeliveryPolicy?
    private let queue: (any FxSessionQueue)?
    private var deliveries: [String: AsyncResult<FxDeliveryOutcome>] = [:]
    private typealias Deadlines = (yield: Date, stop: ContinuousClock.Instant?)
    private var workers: [String: Task<Void, Never>] = [:]
    private var cleanups: [UUID: Task<Void, Never>] = [:]
    private var cleanupFailure: (any Error)?
    private struct ActiveHarness {
        let id = UUID()
        let ready = AsyncResult<any FxHarnessSession>()
    }
    private var activeHarnesses: [String: ActiveHarness] = [:]
    private var leaseGuards: [String: (lease: FxSessionLease, guard: SessionLeaseGuard)] = [:]
    private var activeTurns: [String: (lease: FxSessionLease, turn: any FxHarnessTurn)] = [:]
    private var failures: [String: any Error] = [:]
    private struct ControlCheck {
        let inputID: String
        var pause: Task<Void, Never>?
        var waiters: [CheckedContinuation<Void, Never>] = []
    }
    private var controlChecks: [String: ControlCheck] = [:]
    private var intakes = 0
    private var closed = false
    private var router: FxAgentRouter?

    func attachRouter(_ router: FxAgentRouter) { self.router = router }
    var isClosed: Bool { closed }

    private func routedOwner(_ session: String) async throws -> FxAgent? {
        guard let router else { return nil }
        guard let owner = try await store.owner(session: session), owner != name else { return nil }
        return try await router.agent(named: owner)
    }

    public init(configuration: FxConfiguration, name: String = "default", store: any FxSessionStorage, checkpoint: Data? = nil, checkpointAfterBytes: Int? = 64 * 1024, deliveryPolicy: FxDeliveryPolicy? = nil, openingRetryPolicy: FxOpeningRetryPolicy? = nil, queue: (any FxSessionQueue)? = nil) throws {
        try configuration.validateInstructions()
        try self.init(harness: KernelSessionHarness(configuration: configuration), name: name, store: store,
                  checkpoint: checkpoint, checkpointAfterBytes: checkpointAfterBytes,
                  deliveryPolicy: deliveryPolicy, openingRetryPolicy: openingRetryPolicy, queue: queue, onLifecycleEvent: { event in
            await configuration.onLifecycleEvent?(event)
            if case .deliveryDeadline(let sessionID, let epoch, let cutoffs) = event {
                configuration.observation?.deliver(FxObservation(journal: .sessionDeadline, sessionID: sessionID,
                    data: .object(["epoch": .number(Double(epoch)), "cutoffs": .number(Double(cutoffs))])))
            }
        })
    }

    public init(harness: any FxSessionHarness, name: String = "default", store: any FxSessionStorage,
                checkpoint: Data? = nil, checkpointAfterBytes: Int? = 64 * 1024,
                deliveryPolicy: FxDeliveryPolicy? = nil, openingRetryPolicy: FxOpeningRetryPolicy? = nil, queue: (any FxSessionQueue)? = nil,
                onLifecycleEvent: (@Sendable (FxLifecycleEvent) async -> Void)? = nil) throws {
        guard validSessionIdentifier(name), name.utf8.count <= 64,
              let first = name.utf8.first, (48...57).contains(first) || (65...90).contains(first) || (97...122).contains(first) else { throw FxError.invalidInput("Invalid agent name") }
        if let checkpointAfterBytes, checkpointAfterBytes < 0 { throw FxError.invalidInput("Checkpoint interval must not be negative") }
        self.harness = harness
        self.onLifecycleEvent = onLifecycleEvent
        self.initialCheckpoint = checkpoint
        self.checkpointAfterBytes = checkpointAfterBytes
        self.openingRetryPolicy = openingRetryPolicy
        self.deliveryPolicy = deliveryPolicy
        self.queue = queue
        self.name = name
        self.store = store
    }

    /// Creates a view. Data is stored when the first input is accepted.
    public func session(id: String = UUID().uuidString, options: FxSessionOptions = .init()) async throws -> FxSession {
        guard !closed else { throw FxError.closed }
        guard validSessionIdentifier(id) else { throw FxError.invalidInput("Invalid session ID") }
        if router != nil, let owner = try await store.owner(session: id), owner != name {
            return FxSession(id: id, options: options, agent: self)
        }
        try harness.validate(options: options)
        return FxSession(id: id, options: options, agent: self)
    }

    func accept(session: String, options: FxSessionOptions, content: [FxPromptContent], id: String, steering: Bool = false) async throws -> FxSessionTurn {
        guard !closed else { throw FxError.closed }
        intakes += 1
        defer { intakes -= 1 }
        guard validSessionIdentifier(id) else { throw FxError.invalidInput("Invalid session or message ID") }
        if router != nil, let owner = try await store.owner(session: session), owner != name {
            return try await forwardAcceptance(to: owner, session: session, options: options, content: content, id: id, steering: steering)
        }
        try harness.validate(options: options)
        try harness.validate(input: content, options: options)
        try SessionInputAdmission.validate(content, options: options)
        if steering, content.allSatisfy({ if case .text = $0 { return true }; return false }) {
            let text = content.compactMap { if case .text(let text) = $0 { return text }; return nil }.joined(separator: "\n")
            guard text.utf8.count <= 64 * 1024 else { throw FxError.invalidInput("Steering text exceeds the size limit") }
        }
        try Task.checkCancellation()
        do {
            var seed: Data?
            if let checkpoint = initialCheckpoint {
                do { _ = try await store.snapshot(session: session, agent: name) }
                catch FxSessionError.notFound { seed = try await harness.prepareCheckpoint(checkpoint, options: options) }
            }
            try Task.checkCancellation()
            let repeated = try await store.accept(session: session, agent: name, id: id, content: content, options: options, checkpoint: seed, steering: steering, deferringImageLimits: harness.defersImageLimits)
            try await schedule(session)
            if steering { await synchronizeControls(session) }
            return FxSessionTurn(id: id, sessionID: session, isRepeated: repeated, eventCursor: 0, agent: self)
        } catch FxSessionError.wrongAgent {
            guard let owner = try await store.owner(session: session), owner != name else { throw FxSessionError.wrongAgent }
            return try await forwardAcceptance(to: owner, session: session, options: options, content: content, id: id, steering: steering)
        }
    }

    private func forwardAcceptance(to owner: String, session: String, options: FxSessionOptions,
        content: [FxPromptContent], id: String, steering: Bool) async throws -> FxSessionTurn {
        guard let router else { throw FxSessionError.wrongAgent }
        let target: FxAgent
        do { target = try await router.agent(named: owner) }
        catch FxAgentRoutingError.unavailableAgent {
            return try await retainForwardedInput(owner: owner, session: session, options: options, content: content, id: id, steering: steering)
        }
        let turn: FxSessionTurn
        do { turn = try await target.accept(session: session, options: options, content: content, id: id, steering: steering) }
        catch FxError.closed {
            guard await target.isClosed else { throw FxError.closed }
            return try await retainForwardedInput(owner: owner, session: session, options: options, content: content, id: id, steering: steering)
        }
        await onLifecycleEvent?(.sessionForwarded(sessionID: session, agent: owner))
        return turn
    }

    private func retainForwardedInput(owner: String, session: String, options: FxSessionOptions,
        content: [FxPromptContent], id: String, steering: Bool) async throws -> FxSessionTurn {
        // Retain accepted work while its executor is offline. No sender seed or harness is used.
        try SessionInputAdmission.validate(content, options: options)
        _ = try await store.accept(session: session, agent: owner, id: id, content: content, options: options,
            checkpoint: nil, steering: steering, deferringImageLimits: true)
        throw FxAgentRoutingError.unavailableAgent(owner)
    }

    /// Waits for the active executor's pending journal writes, without waiting for its turn.
    @_spi(Conformance) public func flushPersistence(sessionID: String) async throws {
        guard !closed else { throw FxError.closed }
        guard validSessionIdentifier(sessionID) else { throw FxError.invalidInput("Invalid session ID") }
        intakes += 1
        defer { intakes -= 1 }
        if let owner = try await routedOwner(sessionID) { return try await owner.flushPersistence(sessionID: sessionID) }
        while let active = activeHarnesses[sessionID] {
            let engine: any FxHarnessSession
            do { engine = try await active.ready.wait() }
            catch let failure as SessionStorageFailure { throw failure.cause }
            guard activeHarnesses[sessionID]?.id == active.id else { continue }
            do { try await engine.flushPersistence() }
            catch let failure as SessionStorageFailure { throw failure.cause }
            catch FxError.closed {
                guard activeHarnesses[sessionID]?.id != active.id else { throw FxError.closed }
                continue
            }
            if activeHarnesses[sessionID]?.id == active.id { return }
        }
        try await failure(sessionID)
    }

    func resume(_ session: String) async throws -> FxSessionTurn? {
        guard !closed else { throw FxError.closed }
        intakes += 1
        defer { intakes -= 1 }
        if let owner = try await routedOwner(session) { return try await owner.resume(session) }
        let point: (id: String, cursor: Int64)?
        do { point = try await store.resumePoint(session: session, agent: name) }
        catch FxSessionError.notFound { return nil }
        catch FxSessionError.wrongAgent {
            guard let owner = try await routedOwner(session) else { throw FxSessionError.wrongAgent }
            return try await owner.resume(session)
        }
        guard let point else { return nil }
        try await schedule(session)
        return FxSessionTurn(id: point.id, sessionID: session, isRepeated: false, eventCursor: point.cursor, agent: self)
    }

    func checkpoint(_ session: String, options: FxSessionOptions) async throws -> Data {
        guard !closed else { throw FxError.closed }
        intakes += 1
        defer { intakes -= 1 }
        if let owner = try await routedOwner(session) { return try await owner.checkpoint(session, options: options) }
        let snapshot: FxPersistenceSnapshot
        do { snapshot = try await store.snapshot(session: session, agent: name) }
        catch FxSessionError.notFound {
            if let initialCheckpoint {
                let seed = try await harness.prepareCheckpoint(initialCheckpoint, options: options)
                snapshot = FxPersistenceSnapshot(checkpoint: FxStoredCheckpoint(through: "1", data: seed), head: "1")
            } else { snapshot = FxPersistenceSnapshot() }
        } catch FxSessionError.wrongAgent {
            guard let owner = try await routedOwner(session) else { throw FxSessionError.wrongAgent }
            return try await owner.checkpoint(session, options: options)
        }
        let context = FxHarnessContext(sessionID: session, inputID: nil, options: options,
            persistence: ReadOnlySessionPersistence(snapshot: snapshot, store: store, session: session, agent: name),
            checkpointAfterBytes: nil, ownership: {})
        let engine = try await harness.open(context)
        do {
            let data = try await engine.checkpoint()
            try await engine.close()
            return data
        } catch { try? await engine.close(); throw error }
    }

    func failure(_ session: String) async throws {
        if let owner = try await routedOwner(session) { return try await owner.failure(session) }
        if let failure = failures[session] { throw failure }
    }

    func cancel(_ session: String, id: String? = nil) async throws {
        guard !closed else { throw FxError.closed }
        intakes += 1
        defer { intakes -= 1 }
        if let owner = try await routedOwner(session) { return try await owner.cancel(session, id: id) }
        do { try await store.cancel(session: session, agent: name, id: id) }
        catch FxSessionError.wrongAgent {
            guard let owner = try await routedOwner(session) else { throw FxSessionError.wrongAgent }
            return try await owner.cancel(session, id: id)
        }
        if let queue, try await store.hasWork(session: session, agent: name) {
            try await queue.enqueue(FxSessionWakeup(agent: name, sessionID: session))
        }
        if id == nil || controlChecks[session]?.inputID == id { await synchronizeControls(session) }
    }

    func entries(_ session: String, after cursor: Int64) async throws -> [FxSessionEntry] {
        let owner = router == nil ? name : try await store.owner(session: session) ?? name
        do { return try await store.entries(session: session, agent: owner, after: cursor) }
        catch FxSessionError.wrongAgent {
            guard router != nil, let canonical = try await store.owner(session: session), canonical != owner else { throw FxSessionError.wrongAgent }
            return try await store.entries(session: session, agent: canonical, after: cursor)
        }
    }

    func result(_ session: String, id: String) async throws -> FxSessionResult? {
        let owner = router == nil ? name : try await store.owner(session: session) ?? name
        do { return try await store.result(session: session, agent: owner, id: id) }
        catch FxSessionError.wrongAgent {
            guard router != nil, let canonical = try await store.owner(session: session), canonical != owner else { throw FxSessionError.wrongAgent }
            return try await store.result(session: session, agent: canonical, id: id)
        }
    }

    private func synchronizeControls(_ session: String) async {
        guard controlChecks[session] != nil else { return }
        await withCheckedContinuation { continuation in
            controlChecks[session]?.waiters.append(continuation)
            controlChecks[session]?.pause?.cancel()
        }
    }

    private func finishControlChecks(_ session: String) {
        guard let checks = controlChecks.removeValue(forKey: session) else { return }
        checks.pause?.cancel()
        for waiter in checks.waiters { waiter.resume() }
    }

    private func schedule(_ session: String) async throws {
        if let queue { try await queue.enqueue(FxSessionWakeup(agent: name, sessionID: session)) }
        else { kick(session) }
    }

    /// Runs one queue delivery. A retry result or thrown error must not acknowledge the message.
    /// Cancelling this waiter leaves durable work running; close() waits for active deliveries.
    public func deliver(_ wakeup: FxSessionWakeup, policy: FxDeliveryPolicy? = nil) async throws -> FxDeliveryOutcome {
        guard !closed else { throw FxError.closed }
        guard queue != nil else { throw FxError.invalidInput("Agent has no delivery queue") }
        guard wakeup.agent == name else { throw FxSessionError.wrongAgent }
        guard validSessionIdentifier(wakeup.sessionID) else { throw FxError.invalidInput("Invalid session ID") }
        try Task.checkCancellation()
        let session = wakeup.sessionID
        if let delivery = deliveries[session] { return try await delivery.wait() }
        let completion = AsyncResult<FxDeliveryOutcome>()
        deliveries[session] = completion
        failures[session] = nil
        let deadlines = (policy ?? deliveryPolicy)?.deadlines()
        workers[session] = Task {
            let result = await self.run(session, external: true, deadlines: deadlines)
            await completion.resolve(result)
        }
        return try await completion.wait()
    }

    private func kick(_ session: String) {
        guard workers[session] == nil else { return }
        failures[session] = nil
        workers[session] = Task { _ = await self.run(session) }
    }

    private func run(_ session: String, external: Bool = false, deadlines: Deadlines? = nil) async -> Result<FxDeliveryOutcome, any Error> {
        let result: Result<FxDeliveryOutcome, any Error>
        do {
            result = .success(try await drain(session, external: external, deadlines: deadlines))
        } catch {
            let cause = (error as? SessionStorageFailure)?.cause ?? error
            failures[session] = cause
            result = .failure(cause)
        }
        workers[session] = nil
        deliveries.removeValue(forKey: session)
        // Local intake can interleave with the final empty-inbox read. External
        // intake publishes its own wakeup and never starts another delivery here.
        if !external, failures[session] == nil {
            do { if try await store.hasWork(session: session, agent: name) { kick(session) } }
            catch { failures[session] = error }
        }
        return result
    }

    private func drain(_ session: String, external: Bool, deadlines: Deadlines?) async throws -> FxDeliveryOutcome {
        var openingRetries: UInt = 0
        var openingDeadline = deadlines?.stop ?? deliveryPolicy.map { ContinuousClock.now.advanced(by: $0.maximumDuration) }
        while true {
            let pending: Bool
            do { pending = try await store.hasWork(session: session, agent: name) }
            catch FxSessionError.notFound { return .complete }
            guard pending else { return .complete }
            if external, let stop = deadlines?.stop, ContinuousClock.now >= stop { return .retry(after: .zero) }
            let claimedAt = ContinuousClock.now
            guard let lease = try await store.claim(session: session, agent: name) else {
                if external { return .retry(after: .seconds(1)) }
                try await Task.sleep(for: .milliseconds(20))
                continue
            }
            let leaseGuard: SessionLeaseGuard?
            if let renewable = store as? any FxRenewableSessionStorage, let policy = renewable.leasePolicy {
                let guardState = SessionLeaseGuard(lease: lease, policy: policy, claimedAt: claimedAt,
                    renew: { try await renewable.renew($0) })
                leaseGuard = guardState
                leaseGuards[session] = (lease, guardState)
                await guardState.start { await self.ownershipLost(lease) }
            } else { leaseGuard = nil }
            do {
                try await leaseGuard?.check()
                var started = false
                while let input = try await store.next(lease) {
                    if external, started, let yield = deadlines?.yield, Date() >= yield { break }
                    started = true
                    let yielded = try await execute(input, lease: lease, deadlines: deadlines, leaseGuard: leaseGuard)
                    openingRetries = 0
                    openingDeadline = deadlines?.stop ?? deliveryPolicy.map { ContinuousClock.now.advanced(by: $0.maximumDuration) }
                    if yielded { break }
                }
                try await leaseGuard?.check()
                await stopOwnership(lease)
                try await store.release(lease)
            } catch let failure as OpeningStorageFailure {
                // Reopen only after ownership is released. Accepted input and its
                // journal remain authoritative across the next claim.
                do { try await leaseGuard?.check() }
                catch {
                    await stopOwnership(lease)
                    try? await store.release(lease)
                    throw FxPersistenceError.fenced
                }
                await stopOwnership(lease)
                try await store.release(lease)
                guard let policy = openingRetryPolicy, openingRetries < policy.maxRetries,
                      !(failure.cause is CancellationError), policy.shouldRetry(failure.cause) else {
                    throw failure.cause
                }
                if let openingDeadline, ContinuousClock.now.advanced(by: policy.delay) >= openingDeadline {
                    throw failure.cause
                }
                openingRetries += 1
                try await Task.sleep(for: policy.delay)
                continue
            } catch {
                var failure: any Error = error
                if let leaseGuard, leaseGuards[session]?.lease == lease {
                    do { try await leaseGuard.check() }
                    catch { failure = FxPersistenceError.fenced }
                }
                await stopOwnership(lease)
                try? await store.release(lease)
                throw failure
            }
            if external {
                return try await store.hasWork(session: session, agent: name) ? .retry(after: .zero) : .complete
            }
        }
    }

    private func leaseOperation<Value: Sendable>(_ lease: FxSessionLease,
        _ operation: @Sendable () async throws -> Value) async throws -> Value {
        let guardState = leaseGuards[lease.sessionID]?.guard
        try await guardState?.check()
        let value = try await sessionStorageOperation(operation)
        try await guardState?.check()
        return value
    }

    private func ownershipLost(_ lease: FxSessionLease) async {
        guard leaseGuards[lease.sessionID]?.lease == lease else { return }
        workers[lease.sessionID]?.cancel()
        if let active = activeTurns[lease.sessionID], active.lease == lease { await active.turn.cancel() }
    }

    private func stopOwnership(_ lease: FxSessionLease) async {
        guard let current = leaseGuards[lease.sessionID], current.lease == lease else { return }
        leaseGuards[lease.sessionID] = nil
        await current.guard.stop()
    }

    private func execute(_ input: FxSessionInput, lease: FxSessionLease, deadlines suppliedDeadlines: Deadlines? = nil, recoveringOnly: Bool = false, leaseGuard: SessionLeaseGuard? = nil) async throws -> Bool {
        try await leaseGuard?.check()
        let deadlines = suppliedDeadlines ?? deliveryPolicy?.deadlines()
        let store = self.store
        func settle(_ reason: FxTurnResult.StopReason, usage: FxUsage? = nil, error: FxSessionFailure? = nil) async throws {
            try await leaseGuard?.check()
            if !recoveringOnly { try await finish(input, lease: lease, reason: reason, usage: usage, error: error) }
        }
        if !input.wasStarted, !input.cancelRequested, !recoveringOnly {
            do {
                try SessionInputAdmission.validate(input.content, options: input.options)
                try harness.validate(options: input.options)
                try harness.validate(input: input.content, options: input.options)
            } catch {
                try await settle(.error, error: FxSessionFailure(error))
                await onLifecycleEvent?(.harnessFailed(sessionID: lease.sessionID, inputID: input.id, error: error))
                return false
            }
        }
        var failureState = try await leaseOperation(lease) { try await store.harnessFailureState(lease, id: input.id) }
        if !failureState.halted, !recoveringOnly,
           let previous = try await leaseOperation(lease, { try await store.harnessRecoveryInput(lease) }), previous.id != input.id {
            guard try await leaseOperation(lease, { try await store.result(session: lease.sessionID, agent: name, id: previous.id) }) != nil else {
                throw FxPersistenceError.invalidJournal
            }
            do {
                if try await execute(previous, lease: lease, deadlines: deadlines, recoveringOnly: true, leaseGuard: leaseGuard) { return true }
            } catch {
                if error is OpeningStorageFailure || error is SessionStorageFailure || error is FxPersistenceError || error is FxSQLiteError || error is FxSessionError { throw error }
                let cause = (error as? HarnessOpeningFailure)?.cause ?? error
                await onLifecycleEvent?(.harnessFailed(sessionID: lease.sessionID, inputID: input.id, error: cause))
                try await settle(.error, error: FxSessionFailure(cause))
                return false
            }
            failureState = try await leaseOperation(lease) { try await store.harnessFailureState(lease, id: input.id) }
        }
        if failureState.halted {
            try await settle(.error, error: FxSessionFailure(message: "The session's open turn cannot continue"))
            return false
        }
        if !recoveringOnly { try await leaseOperation(lease) { try await store.start(lease, input: input) } }
        if input.cancelRequested && !input.wasStarted {
            try await settle(.cancelled)
            return false
        }
        let context = FxHarnessContext(sessionID: lease.sessionID, inputID: input.id, options: input.options,
            persistence: SessionPersistence(store: store, lease: lease, leaseGuard: leaseGuard), checkpointAfterBytes: checkpointAfterBytes,
            leaseGuard: leaseGuard, ownership: {
                let check: @Sendable () async throws -> Void = { try await sessionStorageOperation { try await store.checkLease(lease) } }
                if let leaseGuard { try await leaseGuard.checkOwnership(check) }
                else { try await check() }
            })
        let active = ActiveHarness()
        activeHarnesses[lease.sessionID] = active
        defer {
            if activeHarnesses[lease.sessionID]?.id == active.id { activeHarnesses[lease.sessionID] = nil }
        }
        let engine: any FxHarnessSession
        do {
            engine = try await prepareSession(deadline: deadlines?.stop, open: { try await self.harness.open(context) },
                                              close: { try await $0.close() })
            do { try await leaseGuard?.check() }
            catch { try? await engine.close(); throw error }
            await active.ready.resolve(.success(engine))
        } catch {
            await active.ready.resolve(.failure(error))
            if let failure = error as? SessionStorageFailure { throw OpeningStorageFailure(cause: failure.cause) }
            if error is SessionStorageFailure || error is FxSessionError || error is FxPersistenceError || error is FxSQLiteError { throw error }
            if recoveringOnly { throw HarnessOpeningFailure(cause: error) }
            if input.wasStarted { try await leaseOperation(lease) { try await store.setHarnessRecoveryInput(lease, id: input.id) } }
            await onLifecycleEvent?(.harnessFailed(sessionID: lease.sessionID, inputID: input.id, error: error))
            try await settle(.error, error: FxSessionFailure(error))
            return false
        }
        do {
            controlChecks[lease.sessionID] = ControlCheck(inputID: input.id)
            defer { finishControlChecks(lease.sessionID) }
            let turnID = sessionCoreInputID(input.id)
            let recovery = await engine.recoveryState
            try await leaseGuard?.check()
            let spent = try await leaseOperation(lease) { try await store.deliveryCutoffs(lease, id: input.id) } >= 3
            let turn: any FxHarnessTurn
            if recoveringOnly, recovery == nil {
                try await leaseOperation(lease) { try await store.setHarnessRecoveryInput(lease, id: nil) }
                try await engine.close()
                return false
            }
            if let recovery {
                guard input.wasStarted, recovery.turnID == turnID else { throw FxPersistenceError.invalidJournal }
                guard let resumed = try await harnessTurnOperation({
                    try await engine.resume(rerunning: !spent && failureState.stops < 3 && !input.cancelRequested && !recoveringOnly, yieldAt: deadlines?.yield)
                }) else { throw FxPersistenceError.invalidJournal }
                turn = resumed
            } else if input.wasStarted, await engine.completedTurnID == turnID {
                try await settle(.unknown)
                try await leaseOperation(lease) { try await store.setHarnessRecoveryInput(lease, id: nil) }
                try await engine.close()
                return false
            } else if failureState.stops >= 3 {
                try await settle(.error, error: FxSessionFailure(message: "The executor stopped each of the 3 times it started this turn"))
                try await leaseOperation(lease) { try await store.setHarnessRecoveryInput(lease, id: nil) }
                try await engine.close()
                return false
            } else {
                try await leaseGuard?.check()
                turn = try await harnessTurnOperation { try await engine.prompt(input.content, id: turnID, yieldAt: deadlines?.yield) }
            }
            activeTurns[lease.sessionID] = (lease, turn)
            defer {
                if activeTurns[lease.sessionID]?.lease == lease { activeTurns[lease.sessionID] = nil }
            }
            do { try await leaseGuard?.check() }
            catch { await turn.cancel(); throw error }
            if recoveringOnly || input.cancelRequested || failureState.stops >= 3 || spent && recovery?.runningCalls.isEmpty == true { await turn.cancel() }
            let controls = Task { () throws -> Bool in
                var ending = false
                defer { finishControlChecks(lease.sessionID) }
                do {
                    while !Task.isCancelled {
                        try await leaseGuard?.check()
                        // Acknowledge only updates present before this storage read.
                        let waiters = controlChecks[lease.sessionID]?.waiters ?? []
                        controlChecks[lease.sessionID]?.waiters.removeAll()
                        defer { for waiter in waiters { waiter.resume() } }
                        if try await leaseOperation(lease, { try await store.cancelled(lease, id: input.id) }) {
                            await turn.cancel()
                            return false
                        }
                        if let stop = deadlines?.stop, ContinuousClock.now >= stop {
                            let cutoffs = try await leaseOperation(lease) { try await store.cutOffDelivery(lease, id: input.id) }
                            await self.onLifecycleEvent?(.deliveryDeadline(sessionID: lease.sessionID, epoch: Int64(lease.epoch), cutoffs: cutoffs))
                            try await turn.handoff()
                            return true
                        }
                        let steering = try await leaseOperation(lease) { try await store.steering(lease, owner: input.id) }
                        if !ending {
                            for steer in steering.pending {
                                do { _ = try await turn.steer(steer.text, id: sessionCoreInputID(steer.id)) }
                                catch FxError.noActiveTurn { return false }
                                catch FxError.rpc(_, "No prompt is running", _) { return false }
                                catch FxError.rpc(_, "Steering queue is full", _) { break }
                            }
                            if steering.ends {
                                ending = true
                                try await turn.endForSteering()
                            }
                        }
                        if controlChecks[lease.sessionID]?.waiters.isEmpty == false { continue }
                        let pause = Task<Void, Never> {
                            do { try await Task.sleep(for: .milliseconds(20)) } catch {}
                        }
                        controlChecks[lease.sessionID]?.pause = pause
                        await withTaskCancellationHandler {
                            _ = await pause.result
                        } onCancel: { pause.cancel() }
                        controlChecks[lease.sessionID]?.pause = nil
                    }
                } catch is CancellationError {} catch { await turn.cancel(); throw error }
                return false
            }
            do {
                if recoveringOnly {
                    for try await _ in turn.events {}
                } else { try await publishEvents(turn, input: input, lease: lease) }
                try await leaseGuard?.check()
                let result = try await turn.result
                controls.cancel()
                let interrupted = try await controls.value
                try await leaseGuard?.check()
                if result.stopReason == .yielded || interrupted && result.stopReason == .cancelled {
                    try await leaseOperation(lease) { try await store.appendEvent(lease, .yielded(id: input.id)) }
                    if !interrupted { try await engine.saveCheckpoint() }
                    try await engine.close()
                    return true
                }
                if await engine.recoveryState?.turnID == turnID { throw FxHarnessError.stopped("The turn ended but stayed open") }
                try await settle(result.stopReason, usage: result.usage, error: result.failure)
                try await leaseOperation(lease) { try await store.setHarnessRecoveryInput(lease, id: nil) }
            } catch {
                controls.cancel()
                if case .failure(let controlError) = await controls.result {
                    await turn.cancel()
                    throw controlError
                }
                if !(error is FxHarnessError) { await turn.cancel() }
                throw error
            }
            if recoveringOnly { try await engine.close() }
            else { retire(engine, session: lease.sessionID, inputID: input.id) }
        } catch {
            do { try await engine.close() }
            catch let closeError {
                if closeError is SessionStorageFailure || closeError is FxPersistenceError || closeError is FxSQLiteError || closeError is FxSessionError { throw closeError }
            }
            if error is SessionStorageFailure || error is FxPersistenceError || error is FxSQLiteError || error is FxSessionError { throw error }
            let stopped: (any Error)?
            if let error = error as? HarnessStopped { stopped = error.cause }
            else if error is FxHarnessError { stopped = error }
            else { stopped = nil }
            if let stopped {
                await onLifecycleEvent?(.harnessFailed(sessionID: lease.sessionID, inputID: input.id, error: stopped))
                if await engine.completedTurnID == sessionCoreInputID(input.id), await engine.recoveryState?.turnID != sessionCoreInputID(input.id) {
                    try await settle(.unknown)
                    try await leaseOperation(lease) { try await store.setHarnessRecoveryInput(lease, id: nil) }
                    return false
                }
                let count = try await leaseOperation(lease) { try await store.recordHarnessStop(lease, id: input.id) }
                let open = await engine.recoveryState?.turnID == sessionCoreInputID(input.id)
                if open && count >= 5 {
                    try await leaseOperation(lease) { try await store.halt(lease) }
                    try await settle(.error, error: FxSessionFailure(message: "The executor stopped each time it continued this turn, even to cancel it"))
                    return false
                }
                if !open && count >= 3 {
                    try await settle(.error, error: FxSessionFailure(message: "The executor stopped each of the 3 times it started this turn"))
                    try await leaseOperation(lease) { try await store.setHarnessRecoveryInput(lease, id: nil) }
                    return false
                }
                return true
            }
            if recoveringOnly { throw HarnessOpeningFailure(cause: error) }
            try await settle(.error, error: FxSessionFailure(error))
        }
        return false
    }

    private func retire(_ engine: any FxHarnessSession, session: String, inputID: String) {
        let id = UUID()
        cleanups[id] = Task {
            do { try await engine.close() }
            catch {
                let cause = (error as? SessionStorageFailure)?.cause ?? error
                if cleanupFailure == nil { cleanupFailure = cause }
                await onLifecycleEvent?(.harnessFailed(sessionID: session, inputID: inputID, error: cause))
            }
            cleanups[id] = nil
        }
    }

    private func publishEvents(_ turn: any FxHarnessTurn, input: FxSessionInput, lease: FxSessionLease) async throws {
        let store = self.store
        for try await event in turn.events {
            var event = event
            if case .userMessage(let text, let id?) = event {
                event = .userMessage(text, id: try await leaseOperation(lease) { try await store.publicInputID(id, session: lease.sessionID) } ?? id)
            }
            let published = event
            try await leaseOperation(lease) { try await store.appendEvent(lease, .update(id: input.id, published)) }
        }
    }

    private func finish(_ input: FxSessionInput, lease: FxSessionLease, reason: FxTurnResult.StopReason,
                        usage: FxUsage? = nil, error: FxSessionFailure? = nil) async throws {
        try await leaseOperation(lease) { try await store.finish(lease, id: input.id, result: FxSessionResult(id: input.id, stopReason: reason,
            usage: usage, failure: error, epoch: lease.epoch, isRepeated: false)) }
    }

    /// Stops intake and waits for active work. Queued inputs remain in the store for delivery.
    public func close() async throws {
        closed = true
        while intakes > 0 || !workers.isEmpty || !cleanups.isEmpty {
            let pending = Array(workers.values) + Array(cleanups.values)
            for task in pending { await task.value }
            if intakes > 0 { try await Task.sleep(for: .milliseconds(1)) }
        }
        await router?.remove(self)
        if let error = failures.values.first { throw error }
        if let cleanupFailure { throw cleanupFailure }
    }
}

private struct OpeningStorageFailure: Error {
    let cause: any Error
}
