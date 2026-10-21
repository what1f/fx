import Foundation
import CryptoKit

/// Owns workers for durable conversations. The caller owns the session store.
public actor FxAgent {
    public nonisolated let name: String
    let store: FxSessionStore
    private let configuration: FxConfiguration
    private let initialCheckpoint: Data?
    private var workers: [String: Task<Void, Never>] = [:]
    private var failures: [String: any Error] = [:]
    private var intakes = 0
    private var closed = false

    public init(configuration: FxConfiguration, name: String = "default", store: FxSessionStore, checkpoint: Data? = nil) throws {
        guard validSessionIdentifier(name), name.utf8.count <= 64,
              let first = name.utf8.first, (48...57).contains(first) || (65...90).contains(first) || (97...122).contains(first) else { throw FxError.invalidInput("Invalid agent name") }
        self.configuration = configuration
        self.initialCheckpoint = checkpoint
        self.name = name
        self.store = store
    }

    /// Creates a view. Data is stored when the first input is accepted.
    public func session(id: String = UUID().uuidString, options: FxSessionOptions = .init()) throws -> FxSession {
        guard !closed else { throw FxError.closed }
        guard validSessionIdentifier(id) else { throw FxError.invalidInput("Invalid session ID") }
        return FxSession(id: id, options: options, agent: self)
    }

    func accept(session: String, options: FxSessionOptions, content: [FxPromptContent], id: String) async throws -> FxSessionTurn {
        guard !closed else { throw FxError.closed }
        intakes += 1
        defer { intakes -= 1 }
        try Task.checkCancellation()
        if let checkpoint = initialCheckpoint {
            do { _ = try await store.snapshot(session: session, agent: name) }
            catch FxSessionError.notFound {
                let temporary = try await FxEngine.open(configuration: configured(for: options), checkpoint: checkpoint)
                try await temporary.close()
            }
        }
        try Task.checkCancellation()
        let repeated = try await store.accept(session: session, agent: name, id: id, content: content, options: options, checkpoint: initialCheckpoint)
        kick(session)
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
        let temporary = try await FxEngine.open(configuration: config, sessionID: session,
                                                 persistence: ReadOnlySessionPersistence(snapshot: snapshot))
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
                    while let input = try await store.next(lease) { try await execute(input, lease: lease) }
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

    private func execute(_ input: SessionInput, lease: SessionLease) async throws {
        try await store.start(lease, input: input)
        if input.cancelRequested {
            try await finish(input, lease: lease, reason: .cancelled)
            return
        }
        var config = configured(for: input.options)
        let store = self.store
        config.tools = configuration.tools.map { tool in
            FxTool(name: tool.name, description: tool.description, inputSchema: tool.inputSchema,
                   isIdempotent: tool.isIdempotent, writes: tool.writes) { value, context in
                try await store.checkLease(lease)
                let context = FxToolContext(executionID: context.executionID, sessionID: lease.sessionID,
                                            turnID: input.id, context: input.options.context)
                return try await tool.execute(value, context)
            }
        }
        let engine: FxEngine
        do {
            engine = try await FxEngine.open(configuration: config, sessionID: lease.sessionID,
                                             persistence: SessionPersistence(store: store, lease: lease))
        } catch let error as FxPersistenceError { throw error }
        catch FxError.invalidInput(let message) {
            try await finish(input, lease: lease, reason: .error, error: message)
            return
        } catch {
            try await finish(input, lease: lease, reason: .error, error: "Could not open conversation")
            return
        }
        do {
            let turnID = "turn_" + SHA256.hash(data: Data(input.id.utf8)).map { String(format: "%02x", $0) }.joined()
            let recovery = await engine.recoveryState
            let turn: FxTurn
            if let recovery {
                guard input.wasStarted, recovery.turnID == turnID else { throw FxPersistenceError.invalidJournal }
                let idempotent = Set(config.tools.filter(\.isIdempotent).map(\.name))
                let rerun = Set(recovery.runningCalls.filter { idempotent.contains($0.name) }.map(\.executionID))
                guard let resumed = try await engine.resume(rerunning: rerun) else { throw FxPersistenceError.invalidJournal }
                turn = resumed
            } else if await engine.completedTurnID == turnID {
                // The core committed completion, but the host result was not committed.
                // Usage and final outcome cannot be inferred safely from an empty replay.
                try await finish(input, lease: lease, reason: .unknown)
                try await engine.close()
                return
            } else { turn = try await engine.prompt(input.content, id: turnID) }
            let cancellation = Task {
                while !Task.isCancelled {
                    if try await store.cancelled(lease, id: input.id) {
                        await turn.cancel()
                        return
                    }
                    try await Task.sleep(for: .milliseconds(20))
                }
            }
            do {
                for try await event in turn { try await store.appendEvent(lease, .update(id: input.id, event)) }
                let result = try await turn.result
                cancellation.cancel()
                _ = await cancellation.result
                try await finish(input, lease: lease, reason: result.stopReason, usage: result.usage)
            } catch {
                cancellation.cancel()
                _ = await cancellation.result
                await turn.cancel()
                throw error
            }
            try await engine.close()
        } catch {
            try? await engine.close()
            if error is FxPersistenceError || error is FxSQLiteError { throw error }
            try await finish(input, lease: lease, reason: .error, error: "Conversation failed")
        }
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
