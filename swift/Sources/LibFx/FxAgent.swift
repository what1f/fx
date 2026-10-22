import Foundation

/// Owns workers for durable conversations. The caller owns the session store.
public actor FxAgent {
    public nonisolated let name: String
    let store: any FxSessionStorage
    private let harness: any FxSessionHarness
    private let onLifecycleEvent: (@Sendable (FxLifecycleEvent) async -> Void)?
    private let initialCheckpoint: Data?
    private let checkpointAfterBytes: Int?
    private let deliveryPolicy: FxDeliveryPolicy?
    private let queue: (any FxSessionQueue)?
    private var deliveries: [String: AsyncResult<FxDeliveryOutcome>] = [:]
    private typealias Deadlines = (yield: Date, stop: ContinuousClock.Instant?)
    private var workers: [String: Task<Void, Never>] = [:]
    private var failures: [String: any Error] = [:]
    private struct ControlCheck {
        let inputID: String
        var pause: Task<Void, Never>?
        var waiters: [CheckedContinuation<Void, Never>] = []
    }
    private var controlChecks: [String: ControlCheck] = [:]
    private var intakes = 0
    private var closed = false

    public init(configuration: FxConfiguration, name: String = "default", store: any FxSessionStorage, checkpoint: Data? = nil, checkpointAfterBytes: Int? = 64 * 1024, deliveryPolicy: FxDeliveryPolicy? = nil, queue: (any FxSessionQueue)? = nil) throws {
        try configuration.validateInstructions()
        try self.init(harness: KernelSessionHarness(configuration: configuration), name: name, store: store,
                  checkpoint: checkpoint, checkpointAfterBytes: checkpointAfterBytes,
                  deliveryPolicy: deliveryPolicy, queue: queue, onLifecycleEvent: { event in
            await configuration.onLifecycleEvent?(event)
            if case .deliveryDeadline(let sessionID, let epoch, let cutoffs) = event {
                configuration.observation?.deliver(FxObservation(journal: .sessionDeadline, sessionID: sessionID,
                    data: .object(["epoch": .number(Double(epoch)), "cutoffs": .number(Double(cutoffs))])))
            }
        })
    }

    public init(harness: any FxSessionHarness, name: String = "default", store: any FxSessionStorage,
                checkpoint: Data? = nil, checkpointAfterBytes: Int? = 64 * 1024,
                deliveryPolicy: FxDeliveryPolicy? = nil, queue: (any FxSessionQueue)? = nil,
                onLifecycleEvent: (@Sendable (FxLifecycleEvent) async -> Void)? = nil) throws {
        guard validSessionIdentifier(name), name.utf8.count <= 64,
              let first = name.utf8.first, (48...57).contains(first) || (65...90).contains(first) || (97...122).contains(first) else { throw FxError.invalidInput("Invalid agent name") }
        if let checkpointAfterBytes, checkpointAfterBytes < 0 { throw FxError.invalidInput("Checkpoint interval must not be negative") }
        self.harness = harness
        self.onLifecycleEvent = onLifecycleEvent
        self.initialCheckpoint = checkpoint
        self.checkpointAfterBytes = checkpointAfterBytes
        self.deliveryPolicy = deliveryPolicy
        self.queue = queue
        self.name = name
        self.store = store
    }

    /// Creates a view. Data is stored when the first input is accepted.
    public func session(id: String = UUID().uuidString, options: FxSessionOptions = .init()) throws -> FxSession {
        guard !closed else { throw FxError.closed }
        try harness.validate(options: options)
        guard validSessionIdentifier(id) else { throw FxError.invalidInput("Invalid session ID") }
        return FxSession(id: id, options: options, agent: self)
    }

    func accept(session: String, options: FxSessionOptions, content: [FxPromptContent], id: String, steering: Bool = false) async throws -> FxSessionTurn {
        guard !closed else { throw FxError.closed }
        guard validSessionIdentifier(id) else { throw FxError.invalidInput("Invalid session or message ID") }
        try harness.validate(options: options)
        try harness.validate(input: content, options: options)
        guard try JSONEncoder().encode(options).count <= 1024 * 1024 else { throw FxError.invalidInput("Session settings exceed the size limit") }
        if steering, content.allSatisfy({ if case .text = $0 { return true }; return false }) {
            let text = content.compactMap { if case .text(let text) = $0 { return text }; return nil }.joined(separator: "\n")
            guard text.utf8.count <= 64 * 1024 else { throw FxError.invalidInput("Steering text exceeds the size limit") }
        }
        intakes += 1
        defer { intakes -= 1 }
        try Task.checkCancellation()
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
    }

    func resume(_ session: String) async throws -> FxSessionTurn? {
        guard !closed else { throw FxError.closed }
        intakes += 1
        defer { intakes -= 1 }
        let point: (id: String, cursor: Int64)?
        do { point = try await store.resumePoint(session: session, agent: name) }
        catch FxSessionError.notFound { return nil }
        guard let point else { return nil }
        try await schedule(session)
        return FxSessionTurn(id: point.id, sessionID: session, isRepeated: false, eventCursor: point.cursor, agent: self)
    }

    func checkpoint(_ session: String, options: FxSessionOptions) async throws -> Data {
        guard !closed else { throw FxError.closed }
        intakes += 1
        defer { intakes -= 1 }
        let snapshot: FxPersistenceSnapshot
        do { snapshot = try await store.snapshot(session: session, agent: name) }
        catch FxSessionError.notFound {
            if let initialCheckpoint {
                let seed = try await harness.prepareCheckpoint(initialCheckpoint, options: options)
                snapshot = FxPersistenceSnapshot(checkpoint: FxStoredCheckpoint(through: "1", data: seed), head: "1")
            } else { snapshot = FxPersistenceSnapshot() }
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

    func failure(_ session: String) throws {
        if let failure = failures[session] { throw failure }
    }

    func cancel(_ session: String, id: String? = nil) async throws {
        try await store.cancel(session: session, agent: name, id: id)
        if let queue, try await store.hasWork(session: session, agent: name) {
            try await queue.enqueue(FxSessionWakeup(agent: name, sessionID: session))
        }
        if id == nil || controlChecks[session]?.inputID == id { await synchronizeControls(session) }
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
        while true {
            let pending: Bool
            do { pending = try await store.hasWork(session: session, agent: name) }
            catch FxSessionError.notFound { return .complete }
            guard pending else { return .complete }
            if external, let stop = deadlines?.stop, ContinuousClock.now >= stop { return .retry(after: .zero) }
            guard let lease = try await store.claim(session: session, agent: name) else {
                if external { return .retry(after: .seconds(1)) }
                try await Task.sleep(for: .milliseconds(20))
                continue
            }
            do {
                var started = false
                while let input = try await store.next(lease) {
                    if external, started, let yield = deadlines?.yield, Date() >= yield { break }
                    started = true
                    if try await execute(input, lease: lease, deadlines: deadlines) { break }
                }
                try await store.release(lease)
            } catch {
                try? await store.release(lease)
                throw error
            }
            if external {
                return try await store.hasWork(session: session, agent: name) ? .retry(after: .zero) : .complete
            }
        }
    }

    private func execute(_ input: FxSessionInput, lease: FxSessionLease, deadlines suppliedDeadlines: Deadlines? = nil) async throws -> Bool {
        let deadlines = suppliedDeadlines ?? deliveryPolicy?.deadlines()
        try await store.start(lease, input: input)
        if input.cancelRequested && !input.wasStarted {
            try await finish(input, lease: lease, reason: .cancelled)
            return false
        }
        let store = self.store
        let context = FxHarnessContext(sessionID: lease.sessionID, inputID: input.id, options: input.options,
            persistence: SessionPersistence(store: store, lease: lease), checkpointAfterBytes: checkpointAfterBytes,
            ownership: { try await store.checkLease(lease) })
        let engine: any FxHarnessSession
        do {
            engine = try await prepareSession(deadline: deadlines?.stop, open: { try await self.harness.open(context) },
                                              close: { try await $0.close() })
        } catch let error as SessionStorageFailure { throw error }
        catch let error as FxSessionError { throw error }
        catch let error as FxPersistenceError { throw error }
        catch let error as FxSQLiteError { throw error }
        catch FxError.invalidInput(let message) {
            try await finish(input, lease: lease, reason: .error, error: message)
            return false
        } catch {
            try await finish(input, lease: lease, reason: .error, error: "Could not open conversation")
            return false
        }
        do {
            controlChecks[lease.sessionID] = ControlCheck(inputID: input.id)
            defer { finishControlChecks(lease.sessionID) }
            let turnID = sessionCoreInputID(input.id)
            let recovery = await engine.recoveryState
            let spent = try await sessionStorageOperation { try await store.deliveryCutoffs(lease, id: input.id) } >= 3
            let turn: any FxHarnessTurn
            if let recovery {
                guard input.wasStarted, recovery.turnID == turnID else { throw FxPersistenceError.invalidJournal }
                guard let resumed = try await engine.resume(rerunning: !spent && !input.cancelRequested, yieldAt: deadlines?.yield) else { throw FxPersistenceError.invalidJournal }
                turn = resumed
            } else if input.wasStarted, await engine.completedTurnID == turnID {
                // The core committed completion, but the host result was not committed.
                // Usage and final outcome cannot be inferred safely from an empty replay.
                try await finish(input, lease: lease, reason: .unknown)
                try await engine.close()
                return false
            } else { turn = try await engine.prompt(input.content, id: turnID, yieldAt: deadlines?.yield) }
            if input.cancelRequested || spent && recovery?.runningCalls.isEmpty == true { await turn.cancel() }
            let controls = Task { () throws -> Bool in
                var ending = false
                defer { finishControlChecks(lease.sessionID) }
                do {
                    while !Task.isCancelled {
                        // Acknowledge only updates present before this storage read.
                        let waiters = controlChecks[lease.sessionID]?.waiters ?? []
                        controlChecks[lease.sessionID]?.waiters.removeAll()
                        defer { for waiter in waiters { waiter.resume() } }
                        if try await sessionStorageOperation({ try await store.cancelled(lease, id: input.id) }) {
                            await turn.cancel()
                            return false
                        }
                        if let stop = deadlines?.stop, ContinuousClock.now >= stop {
                            let cutoffs = try await sessionStorageOperation { try await store.cutOffDelivery(lease, id: input.id) }
                            await self.onLifecycleEvent?(.deliveryDeadline(sessionID: lease.sessionID, epoch: Int64(lease.epoch), cutoffs: cutoffs))
                            try await turn.handoff()
                            return true
                        }
                        let steering = try await sessionStorageOperation { try await store.steering(lease, owner: input.id) }
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
                try await publishEvents(turn, input: input, lease: lease)
                let result = try await turn.result
                controls.cancel()
                let interrupted = try await controls.value
                if result.stopReason == .yielded || interrupted && result.stopReason == .cancelled {
                    try await sessionStorageOperation { try await store.appendEvent(lease, .yielded(id: input.id)) }
                    if !interrupted { try await engine.saveCheckpoint() }
                    try await engine.close()
                    return true
                }
                try await finish(input, lease: lease, reason: result.stopReason, usage: result.usage)
            } catch {
                controls.cancel()
                _ = await controls.result
                await turn.cancel()
                throw error
            }
            try await engine.close()
        } catch {
            try? await engine.close()
            if error is SessionStorageFailure || error is FxPersistenceError || error is FxSQLiteError { throw error }
            try await finish(input, lease: lease, reason: .error, error: "Conversation failed")
        }
        return false
    }

    private func publishEvents(_ turn: any FxHarnessTurn, input: FxSessionInput, lease: FxSessionLease) async throws {
        let store = self.store
        for try await event in turn.events {
            var event = event
            if case .userMessage(let text, let id?) = event {
                event = .userMessage(text, id: try await sessionStorageOperation { try await store.publicInputID(id, session: lease.sessionID) } ?? id)
            }
            try await sessionStorageOperation { try await store.appendEvent(lease, .update(id: input.id, event)) }
        }
    }

    private func finish(_ input: FxSessionInput, lease: FxSessionLease, reason: FxTurnResult.StopReason,
                        usage: FxUsage? = nil, error: String? = nil) async throws {
        try await sessionStorageOperation { try await store.finish(lease, id: input.id, result: FxSessionResult(id: input.id, stopReason: reason,
            usage: usage, error: error, epoch: lease.epoch, isRepeated: false)) }
    }

    /// Stops intake and waits for active work. Queued inputs remain in the store for delivery.
    public func close() async throws {
        closed = true
        while intakes > 0 || !workers.isEmpty {
            let pending = Array(workers.values)
            for task in pending { await task.value }
            if intakes > 0 { try await Task.sleep(for: .milliseconds(1)) }
        }
        if let error = failures.values.first { throw error }
    }
}
