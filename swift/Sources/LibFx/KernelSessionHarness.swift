import Foundation

struct KernelSessionHarness: FxSessionHarness {
    let configuration: FxConfiguration
    var defersImageLimits: Bool { configuration.prepareImage != nil }

    func configured(for options: FxSessionOptions) -> FxConfiguration {
        var config = configuration
        if let model = options.model { config.model = model }
        if let instructions = options.instructions { config.instructions = instructions }
        return config
    }
    func validate(options: FxSessionOptions) throws { try configured(for: options).validateInstructions() }
    func validate(input: [FxPromptContent], options: FxSessionOptions) throws {
        _ = try PreparedPrompt(input, deferringImageLimits: defersImageLimits)
    }
    func prepareCheckpoint(_ data: Data, options: FxSessionOptions) async throws -> Data {
        var config = configured(for: options)
        config.observation = nil
        config.onLifecycleEvent = nil
        let engine = try await FxEngine.open(configuration: config, checkpoint: data)
        try await engine.close()
        return sessionSeed(data)
    }
    func open(_ context: FxHarnessContext) async throws -> any FxHarnessSession {
        var config = configured(for: context.options)
        config.checkpointAfterBytes = context.checkpointAfterBytes
        if context.leaseGuard != nil {
            config.httpClient = OwnedSessionHTTPClient(base: config.httpClient, context: context)
        }
        config.validatePermission = { try await context.checkOwnership() }
        if let onLifecycleEvent = configuration.onLifecycleEvent {
            let publicTurnID = context.inputID
            config.onLifecycleEvent = { event in
                switch event {
                case .permissionRequested(_, _, let toolID):
                    await onLifecycleEvent(.permissionRequested(sessionID: context.sessionID, turnID: publicTurnID ?? "", toolID: toolID))
                case .permissionResolved(_, _, let toolID, let decision):
                    await onLifecycleEvent(.permissionResolved(sessionID: context.sessionID, turnID: publicTurnID ?? "", toolID: toolID, decision: decision))
                default: await onLifecycleEvent(event)
                }
            }
        }
        if let onPermission = configuration.onPermission {
            config.onPermission = { request in
                try await context.checkOwnership()
                let decision = try await onPermission(request.scoped(sessionID: context.sessionID, turnID: context.inputID ?? ""))
                try await context.checkOwnership()
                return decision
            }
        }
        config.tools = configuration.tools.map { tool in
            FxTool(name: tool.name, description: tool.description, inputSchema: tool.inputSchema,
                   isIdempotent: tool.isIdempotent, writes: tool.writes) { value, toolContext in
                try await context.checkOwnership()
                let scoped = FxToolContext(executionID: toolContext.executionID, sessionID: context.sessionID,
                                          turnID: context.inputID ?? "", context: context.options.context, observation: toolContext.observation)
                return try await tool.execute(value, scoped)
            }
        }
        if context.inputID == nil {
            config.observation = nil
            config.onLifecycleEvent = nil
        }
        let engine = try await FxEngine.open(configuration: config, sessionID: context.sessionID, persistence: context.persistence)
        return KernelHarnessSession(engine: engine, idempotent: Set(config.tools.filter(\.isIdempotent).map(\.name)))
    }
}

private struct OwnedSessionHTTPClient: FxHTTPClient {
    let base: any FxHTTPClient
    let context: FxHarnessContext

    func send(_ request: URLRequest) async throws -> FxHTTPResponse {
        try await context.checkOwnership()
        let response = try await base.send(request)
        do { try await context.checkOwnership() }
        catch { response.cancel(); throw error }
        return response
    }
}

private struct KernelHarnessSession: FxHarnessSession {
    let engine: FxEngine
    let idempotent: Set<String>
    var recoveryState: FxRecoveryState? { get async { await engine.recoveryState } }
    var completedTurnID: String? { get async { await engine.completedTurnID } }
    func prompt(_ content: [FxPromptContent], id: String, yieldAt: Date?) async throws -> any FxHarnessTurn {
        try await engine.prompt(content, id: id, yieldAt: yieldAt)
    }
    func resume(rerunning: Bool, yieldAt: Date?) async throws -> (any FxHarnessTurn)? {
        let calls = await engine.recoveryState?.runningCalls ?? []
        let ids = Set(calls.filter { rerunning && idempotent.contains($0.name) }.map(\.executionID))
        return try await engine.resume(replayingOutput: false, rerunning: ids, yieldAt: yieldAt)
    }
    func flushPersistence() async throws { try await engine.flushPersistence() }
    func saveCheckpoint() async throws { try await engine.saveCheckpoint() }
    func checkpoint() async throws -> Data { try await engine.checkpoint() }
    func close() async throws { try await engine.close() }
}
