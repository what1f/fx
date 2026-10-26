import Foundation
import LibFx

/// One conversation backed by the existing LibFx runtime and persistence journal.
public actor Agent {
    public nonisolated let approval: FxToolApproval
    private let engine: FxEngine
    private let store: FxSQLitePersistence?
    public nonisolated let skillCatalog: FxSkillCatalog?
    private var closingTask: Task<Void, any Error>?

    private init(engine: FxEngine, store: FxSQLitePersistence?, approval: FxToolApproval, skills: FxSkillCatalog?) {
        self.engine = engine
        self.store = store
        self.approval = approval
        self.skillCatalog = skills
    }

    /// Adds approved workspace tools while preserving configured provider and plugin tools.
    public static func open(
        configuration: FxConfiguration,
        persistenceURL: URL? = nil,
        approval: FxToolApproval = FxToolApproval(onApproval: { _ in .deny }),
        builtInTools: [FxWorkspaceTools.Tool] = [.readFile, .writeFile, .editFile, .shell],
        skillRoots: [URL] = []
    ) async throws -> Agent {
        try Task.checkCancellation()
        var configuration = configuration
        configuration.tools += FxWorkspaceTools(workspace: configuration.workspace, approval: approval,
                                                 pluginID: "workspace").tools(builtInTools)
        let store = try persistenceURL.map { try FxSQLitePersistence(url: $0) }
        let persistence: any FxPersistence
        if let store { persistence = store }
        else { persistence = FxMemoryPersistence() }
        do {
            let engine = try await FxEngine.open(configuration: configuration, persistence: persistence)
            do {
                let skills = skillRoots.isEmpty ? nil : try await FxSkillCatalog.open(roots: skillRoots)
                let agent = Agent(engine: engine, store: store, approval: approval, skills: skills)
                return agent
            } catch { try? await engine.close(); throw error }
        } catch {
            try? await store?.close()
            throw error
        }
    }

    public func prompt(_ text: String, id: String = UUID().uuidString) async throws -> FxTurn {
        try await prompt([.text(text)], id: id)
    }

    public func prompt(_ content: [FxPromptContent], id: String = UUID().uuidString) async throws -> FxTurn {
        guard closingTask == nil else { throw FxError.closed }
        try await refreshSkills()
        return try await engine.prompt(content, id: id)
    }

    public func setModel(_ id: String) async throws {
        guard closingTask == nil else { throw FxError.closed }
        try await engine.setModel(id)
    }

    public func setReasoningEffort(_ effort: String?) async throws {
        guard closingTask == nil else { throw FxError.closed }
        try await engine.setReasoningEffort(effort)
    }

    /// Adds or replaces deferred definitions while the conversation is idle.
    public func upsertTools(_ tools: [FxTool]) async throws {
        guard closingTask == nil else { throw FxError.closed }
        try await engine.upsertTools(tools)
    }

    public func removeTools(named names: [String]) async throws {
        guard closingTask == nil else { throw FxError.closed }
        try await engine.removeTools(named: names)
    }

    /// Persists a reminder at the end of the conversation.
    public func appendContext(_ text: String) async throws {
        guard closingTask == nil else { throw FxError.closed }
        try await engine.appendContext(text)
    }

    public func setContext(name: String, text: String) async throws {
        guard closingTask == nil else { throw FxError.closed }
        try await engine.setContext(name: name, text: text)
    }

    private func refreshSkills() async throws {
        // Unfinished native work must settle before context updates are accepted.
        guard await engine.recoveryState == nil else { return }
        if let skillCatalog { try await engine.setContext(name: "skills", text: await skillCatalog.current().prompt) }
    }

    /// Restores unfinished work using LibFx's existing recovery rules.
    public func resume() async throws -> FxTurn? {
        guard closingTask == nil else { throw FxError.closed }
        return try await engine.resume()
    }

    /// All callers await the same teardown. The engine closes before its owned store.
    public func close() async throws {
        if closingTask == nil {
            closingTask = Task { [engine, store, skillCatalog] in
                await skillCatalog?.close()
                do { try await engine.close() }
                catch {
                    try? await store?.close()
                    throw error
                }
                try await store?.close()
            }
        }
        try await closingTask!.value
    }
}
