import Foundation

/// Owns workers for durable conversations. The caller owns the session store.
public actor FxAgent {
    public nonisolated let name: String
    let store: FxSessionStore
    private let configuration: FxConfiguration
    private let initialCheckpoint: Data?
    private let checkpointAfterBytes: Int?
    private let deliveryPolicy: FxDeliveryPolicy?
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

    public init(configuration: FxConfiguration, name: String = "default", store: FxSessionStore, checkpoint: Data? = nil, checkpointAfterBytes: Int? = 64 * 1024, deliveryPolicy: FxDeliveryPolicy? = nil) throws {
        guard validSessionIdentifier(name), name.utf8.count <= 64,
              let first = name.utf8.first, (48...57).contains(first) || (65...90).contains(first) || (97...122).contains(first) else { throw FxError.invalidInput("Invalid agent name") }
        self.configuration = configuration
        self.initialCheckpoint = checkpoint
        if let checkpointAfterBytes, checkpointAfterBytes < 0 { throw FxError.invalidInput("Checkpoint interval must not be negative") }
        self.checkpointAfterBytes = checkpointAfterBytes
        self.deliveryPolicy = deliveryPolicy
        self.name = name
        self.store = store
    }

    /// Creates a view. Data is stored when the first input is accepted.
    public func session(id: String = UUID().uuidString, options: FxSessionOptions = .init()) throws -> FxSession {
        guard !closed else { throw FxError.closed }
        guard validSessionIdentifier(id) else { throw FxError.invalidInput("Invalid session ID") }
        return FxSession(id: id, options: options, agent: self)
    }

    func accept(session: String, options: FxSessionOptions, content: [FxPromptContent], id: String, steering: Bool = false) async throws -> FxSessionTurn {
        guard !closed else { throw FxError.closed }
        intakes += 1
        defer { intakes -= 1 }
        try Task.checkCancellation()
        if let checkpoint = initialCheckpoint {
            do { _ = try await store.snapshot(session: session, agent: name) }
            catch FxSessionError.notFound {
                var config = configured(for: options)
                config.observation = nil
                config.onLifecycleEvent = nil
                let temporary = try await FxEngine.open(configuration: config, checkpoint: checkpoint)
                try await temporary.close()
            }
        }
        try Task.checkCancellation()
        let repeated = try await store.accept(session: session, agent: name, id: id, content: content, options: options, checkpoint: initialCheckpoint, steering: steering)
        kick(session)
        if steering { await synchronizeControls(session) }
        return FxSessionTurn(id: id, sessionID: session, isRepeated: repeated, agent: self)
    }

    func resume(_ session: String) async throws -> FxSessionTurn? {
        guard !closed else { throw FxError.closed }
        intakes += 1
        defer { intakes -= 1 }
        let pendingID: String?
        do { pendingID = try await store.pendingID(session: session, agent: name) }
        catch FxSessionError.notFound { return nil }
        guard let id = pendingID else { return nil }
        kick(session)
        return FxSessionTurn(id: id, sessionID: session, isRepeated: false, agent: self)
    }

    func checkpoint(_ session: String, options: FxSessionOptions) async throws -> Data {
        guard !closed else { throw FxError.closed }
        intakes += 1
        defer { intakes -= 1 }
        let snapshot: FxPersistenceSnapshot
        do { snapshot = try await store.snapshot(session: session, agent: name) }
        catch FxSessionError.notFound {
            let temporary = try await FxEngine.open(configuration: configured(for: options), checkpoint: initialCheckpoint)
            do {
                let data = try await temporary.checkpoint()
                try await temporary.close()
                return data
            } catch { try? await temporary.close(); throw error }
        }
        var config = configured(for: options)
        config.checkpointAfterBytes = nil
        config.observation = nil
        config.onLifecycleEvent = nil
        let temporary = try await FxEngine.open(configuration: config, sessionID: session,
                                                 persistence: ReadOnlySessionPersistence(snapshot: snapshot, store: store, session: session, agent: name))
        do {
            let data = try await temporary.checkpoint()
            try await temporary.close()
            return data
        } catch { try? await temporary.close(); throw error }
    }

    private func configured(for options: FxSessionOptions) -> FxConfiguration {
        var config = configuration
        if let model = options.model { config.model = model }
        if let instructions = options.instructions { config.instructions = instructions }
        return config
    }

    func failure(_ session: String) throws {
        if let failure = failures[session] { throw failure }
    }

    func cancel(_ session: String, id: String? = nil) async throws {
        try await store.cancel(session: session, agent: name, id: id)
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

    private func kick(_ session: String) {
        guard workers[session] == nil else { return }
        failures[session] = nil
        workers[session] = Task { await self.run(session) }
    }

    private func run(_ session: String) async {
        do {
            // Another process may be draining the same inbox. Keep watching until it
            // finishes or releases ownership, including the intake/idle-release race.
            while try await store.hasWork(session: session, agent: name) {
                guard let lease = try await store.claim(session: session, agent: name) else {
                    try await Task.sleep(for: .milliseconds(20))
                    continue
                }
                do {
                    while let input = try await store.next(lease) {
                        if try await execute(input, lease: lease) { break }
                    }
                    try await store.release(lease)
                } catch {
                    try? await store.release(lease)
                    throw error
                }
            }
        } catch { failures[session] = error }
        workers[session] = nil
        // Acceptance can interleave with the final empty-inbox read.
        if failures[session] == nil {
            do { if try await store.hasWork(session: session, agent: name) { kick(session) } }
            catch { failures[session] = error }
        }
    }

    private func execute(_ input: SessionInput, lease: SessionLease) async throws -> Bool {
        let deadlines = deliveryPolicy?.deadlines()
        try await store.start(lease, input: input)
        if input.cancelRequested && !input.wasStarted {
            try await finish(input, lease: lease, reason: .cancelled)
            return false
        }
        var config = configured(for: input.options)
        config.checkpointAfterBytes = checkpointAfterBytes
        let store = self.store
        if let onPermission = configuration.onPermission {
            config.onPermission = { request in
                try await store.checkLease(lease)
                let decision = try await onPermission(request.scoped(sessionID: lease.sessionID, turnID: input.id))
                try await store.checkLease(lease)
                return decision
            }
        }
        config.tools = configuration.tools.map { tool in
            FxTool(name: tool.name, description: tool.description, inputSchema: tool.inputSchema,
                   isIdempotent: tool.isIdempotent, writes: tool.writes) { value, context in
                try await store.checkLease(lease)
                let context = FxToolContext(executionID: context.executionID, sessionID: lease.sessionID,
                                            turnID: input.id, context: input.options.context, observation: context.observation)
                return try await tool.execute(value, context)
            }
        }
        let engine: FxEngine
        do {
            engine = try await openSessionEngine(configuration: config, sessionID: lease.sessionID,
                                                 persistence: SessionPersistence(store: store, lease: lease), deadline: deadlines?.stop)
        } catch let error as FxSessionError { throw error }
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
            let spent = try await store.deliveryCutoffs(lease, id: input.id) >= 3
            let turn: FxTurn
            if let recovery {
                guard input.wasStarted, recovery.turnID == turnID else { throw FxPersistenceError.invalidJournal }
                let idempotent = Set(config.tools.filter(\.isIdempotent).map(\.name))
                let rerun = Set(recovery.runningCalls.filter { !spent && !input.cancelRequested && idempotent.contains($0.name) }.map(\.executionID))
                guard let resumed = try await engine.resume(replayingOutput: false, rerunning: rerun, yieldAt: deadlines?.yield) else { throw FxPersistenceError.invalidJournal }
                turn = resumed
            } else if await engine.completedTurnID == turnID {
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
                        if try await store.cancelled(lease, id: input.id) {
                            await turn.cancel()
                            return false
                        }
                        if let stop = deadlines?.stop, ContinuousClock.now >= stop {
                            let cutoffs = try await store.cutOffDelivery(lease, id: input.id)
                            self.configuration.onLifecycleEvent?(.deliveryDeadline(sessionID: lease.sessionID, epoch: Int64(lease.epoch), cutoffs: cutoffs))
                            self.configuration.observation?.deliver(FxObservation(journal: .sessionDeadline, sessionID: lease.sessionID,
                                data: .object(["epoch": .number(Double(lease.epoch)), "cutoffs": .number(Double(cutoffs))])))
                            try await turn.handoff()
                            return true
                        }
                        let steering = try await store.steering(lease, owner: input.id)
                        if !ending {
                            for steer in steering.pending {
                                do { _ = try await turn.steer(steer.text, id: sessionCoreInputID(steer.id)) }
                                catch FxError.noActiveTurn { return false }
                                catch FxError.rpc(_, "No prompt is running", _) { return false }
                                catch FxError.rpc(_, "Steering queue is full", _) { break }
                            }
                            if steering.ends {
                                ending = true
                                try await turn.endForSteeringAction()
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
                for try await event in turn {
                    var event = event
                    if case .userMessage(let text, let id?) = event {
                        event = .userMessage(text, id: try await store.publicInputID(id, session: lease.sessionID) ?? id)
                    }
                    try await store.appendEvent(lease, .update(id: input.id, event))
                }
                let result = try await turn.result
                controls.cancel()
                let interrupted = try await controls.value
                if result.stopReason == .yielded || interrupted && result.stopReason == .cancelled {
                    try await store.appendEvent(lease, .yielded(id: input.id))
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
            if error is FxPersistenceError || error is FxSQLiteError { throw error }
            try await finish(input, lease: lease, reason: .error, error: "Conversation failed")
        }
        return false
    }

    private func finish(_ input: SessionInput, lease: SessionLease, reason: FxTurnResult.StopReason,
                        usage: FxUsage? = nil, error: String? = nil) async throws {
        try await store.finish(lease, id: input.id, result: FxSessionResult(id: input.id, stopReason: reason,
            usage: usage, error: error, epoch: lease.epoch, isRepeated: false))
    }

    /// Stops intake, then waits for accepted work. The store remains open.
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
