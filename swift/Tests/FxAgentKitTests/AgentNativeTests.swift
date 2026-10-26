import Darwin
import Foundation
import Testing
import LibFx
import FxAgentKit

private actor AgentHTTP: FxHTTPClient {
    private let tool: String?
    private let input: JSONValue
    private(set) var requests: [JSONValue] = []
    init(tool: String? = nil, input: JSONValue = .object([:])) { self.tool = tool; self.input = input }

    func send(_ request: URLRequest) throws -> FxHTTPResponse {
        requests.append(try JSONDecoder().decode(JSONValue.self, from: request.httpBody ?? Data()))
        let events: [JSONValue]
        if requests.count == 1, let tool {
            events = [
                .object(["type": .string("tool-call"), "toolCallId": .string("kit-call"), "toolName": .string(tool), "input": input]),
                .object(["type": .string("finish"), "finishReason": .object(["unified": .string("tool-calls"), "raw": .string("tool-calls")])]),
            ]
        } else {
            events = [
                .object(["type": .string("text-delta"), "delta": .string("remembered reply")]),
                .object(["type": .string("finish"), "finishReason": .object(["unified": .string("stop"), "raw": .string("stop")])]),
            ]
        }
        let payload = try events.map { "data: \(String(decoding: try JSONEncoder().encode($0), as: UTF8.self))\n\n" }.joined() + "data: [DONE]\n\n"
        return FxHTTPResponse(statusCode: 200, body: AsyncThrowingStream { $0.yield(Data(payload.utf8)); $0.finish() })
    }
}

private func agentConfiguration(_ http: AgentHTTP, workspace: URL? = nil, tools: [FxTool] = []) throws -> FxConfiguration {
    var configuration = FxConfiguration(apiKey: "fixture", model: "swift/agent-kit", tools: tools, httpClient: http)
    configuration.modelCatalog = try FxModelCatalog(response: Data(#"{"data":[{"id":"swift/agent-kit","type":"language","tags":["tool-use"]}]}"#.utf8))
    if let workspace { configuration.workspace = workspace }
    return configuration
}

private func finishAgentTurn(_ turn: FxTurn) async throws -> String {
    var text = ""
    for try await event in turn { if case .text(let delta) = event { text += delta } }
    #expect(try await turn.result.stopReason == .endTurn)
    return text
}

private func databaseDescriptors(_ url: URL) -> [Int32] {
    var database = stat()
    guard lstat(url.path, &database) == 0 else { return [] }
    return (0..<getdtablesize()).filter { descriptor in
        var file = stat()
        return fstat(descriptor, &file) == 0 && file.st_dev == database.st_dev && file.st_ino == database.st_ino
    }
}

private actor AgentBlockingTool {
    private(set) var started = false
    private var cancelled = false
    private var cancellationWaiter: CheckedContinuation<Void, Never>?
    private var release: CheckedContinuation<Void, Never>?

    func run() async throws -> FxToolResult {
        started = true
        do { try await Task.sleep(for: .seconds(30)) }
        catch {
            cancelled = true
            cancellationWaiter?.resume()
            cancellationWaiter = nil
            await withCheckedContinuation { release = $0 }
            throw error
        }
        return "finished"
    }
    func waitUntilStarted() async { while !started { await Task.yield() } }
    func waitUntilCancelled() async {
        if !cancelled { await withCheckedContinuation { cancellationWaiter = $0 } }
    }
    func releaseCancellation() { release?.resume(); release = nil }
}

@Suite(.serialized, .timeLimit(.minutes(1))) struct AgentNativeTests {
    @Test func catalogAndContextUseAgentEntryPointAndPersistBeforeClose() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("agent-catalog-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = directory.appendingPathComponent("conversation.sqlite")
        let http = AgentHTTP()
        var configuration = try agentConfiguration(http, workspace: directory)
        configuration.toolSearchEnabled = true
        let agent = try await Agent.open(configuration: configuration, persistenceURL: database, builtInTools: [])
        let deferred = FxTool(name: "catalog_note", description: "Catalog note", inputSchema: .object(["type": .string("object")]), isIdempotent: true, deferred: true) { _, _ in "value" }
        try await agent.upsertTools([deferred])
        try await agent.removeTools(named: [deferred.name])
        try await agent.appendContext("PERSISTED_AGENT_REMINDER")
        try await agent.close()
        let restored = try await Agent.open(configuration: configuration, persistenceURL: database, builtInTools: [])
        _ = try await finishAgentTurn(try await restored.prompt("continue"))
        try await restored.close()
        let request = try #require(await http.requests.last)
        let encoded = String(decoding: try JSONEncoder().encode(request), as: UTF8.self)
        #expect(encoded.contains("PERSISTED_AGENT_REMINDER"))
        await #expect(throws: FxError.closed) { try await restored.appendContext("closed") }
        await #expect(throws: FxError.closed) { try await restored.upsertTools([deferred]) }
        await #expect(throws: FxError.closed) { try await restored.removeTools(named: [deferred.name]) }
    }

    @Test func sqliteReopenContinuesActualNativeConversation() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("conversation.sqlite"), http = AgentHTTP()
        let configuration = try agentConfiguration(http)
        let first = try await Agent.open(configuration: configuration, persistenceURL: url, builtInTools: [])
        #expect(try await finishAgentTurn(first.prompt("remember first instance", id: "first")) == "remembered reply")
        #expect(!databaseDescriptors(url).isEmpty)
        try await first.close()
        #expect(databaseDescriptors(url).isEmpty)
        let second = try await Agent.open(configuration: configuration, persistenceURL: url, builtInTools: [])
        #expect(try await second.resume() == nil)
        #expect(try await finishAgentTurn(second.prompt("continue second instance", id: "second")) == "remembered reply")
        let body = String(decoding: try JSONEncoder().encode(await http.requests.last), as: UTF8.self)
        #expect(body.contains("remember first instance") && body.contains("remembered reply") && body.contains("continue second instance"))
        try await second.close()
        #expect(databaseDescriptors(url).isEmpty)
    }

    @Test func noURLKeepsHistoryOnlyInCurrentAgent() async throws {
        let http = AgentHTTP(), configuration = try agentConfiguration(http)
        let first = try await Agent.open(configuration: configuration, builtInTools: [])
        _ = try await finishAgentTurn(first.prompt("ephemeral marker"))
        _ = try await finishAgentTurn(first.prompt("continue memory"))
        let continued = String(decoding: try JSONEncoder().encode(await http.requests.last), as: UTF8.self)
        #expect(continued.contains("ephemeral marker"))
        try await first.close()
        let second = try await Agent.open(configuration: configuration, builtInTools: [])
        _ = try await finishAgentTurn(second.prompt("fresh conversation"))
        let fresh = String(decoding: try JSONEncoder().encode(await http.requests.last), as: UTF8.self)
        #expect(!fresh.contains("ephemeral marker"))
        try await second.close()
    }

    @Test func concurrentCloseWaitsForEngineBeforeClosingStoreAndRejectsPrompts() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("conversation.sqlite"), blocking = AgentBlockingTool()
        let tool = FxTool(name: "block", description: "Block until cancellation", inputSchema: .object(["type": .string("object")]), isIdempotent: true) { _, _ in
            try await blocking.run()
        }
        let agent = try await Agent.open(configuration: agentConfiguration(AgentHTTP(tool: "block"), tools: [tool]), persistenceURL: url, builtInTools: [])
        _ = try await agent.prompt("run the blocker")
        await blocking.waitUntilStarted()
        let firstClose = Task { try await agent.close() }
        await blocking.waitUntilCancelled()
        let secondClose = Task { try await agent.close() }
        await #expect(throws: FxError.closed) { try await agent.prompt("closed") }
        await #expect(throws: FxError.closed) { try await agent.resume() }
        #expect(!databaseDescriptors(url).isEmpty)
        await blocking.releaseCancellation()
        try await firstClose.value
        try await secondClose.value
        try await agent.close()
        #expect(databaseDescriptors(url).isEmpty)
    }

    @Test func openFailureClosesOwnedStore() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("conversation.sqlite")
        var configuration = try agentConfiguration(AgentHTTP())
        configuration.provider = .gateway(apiKey: "")
        await #expect(throws: FxError.self) { try await Agent.open(configuration: configuration, persistenceURL: url) }
        #expect(databaseDescriptors(url).isEmpty)
        let recovered = try await Agent.open(configuration: agentConfiguration(AgentHTTP()), persistenceURL: url, builtInTools: [])
        _ = try await finishAgentTurn(recovered.prompt("open after failure"))
        try await recovered.close()
    }

    @Test func handoffCanResumeUnfinishedTurnAfterSQLiteReopen() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("conversation.sqlite"), http = AgentHTTP(tool: "block")
        let blocking = AgentBlockingTool()
        let tool = FxTool(name: "block", description: "Block until handoff", inputSchema: .object(["type": .string("object")]), isIdempotent: false, writes: true) { _, _ in
            try await blocking.run()
        }
        let configuration = try agentConfiguration(http, tools: [tool])
        let first = try await Agent.open(configuration: configuration, persistenceURL: url, builtInTools: [])
        let turn = try await first.prompt("unfinished marker", id: "unfinished")
        await blocking.waitUntilStarted()
        let handoff = Task { try await turn.handoff() }
        await blocking.waitUntilCancelled()
        await blocking.releaseCancellation()
        try await handoff.value
        try await first.close()
        let second = try await Agent.open(configuration: configuration, persistenceURL: url, builtInTools: [])
        let resumed = try #require(try await second.resume())
        #expect(resumed.id == "unfinished")
        #expect(try await finishAgentTurn(resumed) == "remembered reply")
        #expect(try await second.resume() == nil)
        let body = String(decoding: try JSONEncoder().encode(await http.requests.last), as: UTF8.self)
        #expect(body.contains("unfinished marker") && body.contains("may have partly run"))
        try await second.close()
    }

    @Test func defaultToolsDenyWritesWithoutApproval() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let http = AgentHTTP(tool: "write", input: .object(["path": .string("note.txt"), "content": .string("saved")]))
        let agent = try await Agent.open(configuration: agentConfiguration(http, workspace: directory))
        _ = try await finishAgentTurn(agent.prompt("save a note"))
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("note.txt").path))
        let body = String(decoding: try JSONEncoder().encode(await http.requests), as: UTF8.self)
        #expect(body.contains("read") && body.contains("edit") && body.contains("bash"))
        #expect(body.contains("error-text") && body.contains("denied"))
        try await agent.close()
    }

    @Test func selectedToolsShareHostApprovalAndKeepConfiguredPluginTools() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let approval = FxToolApproval { request in
            #expect(request.pluginID == "workspace" && request.toolName == "write" && request.effect == .write)
            return .allowPlugin
        }
        let plugin = FxTool(name: "plugin_tool", description: "Plugin fixture", inputSchema: .object(["type": .string("object")]), isIdempotent: true) { _, _ in "plugin" }
        let http = AgentHTTP(tool: "write", input: .object(["path": .string("note.txt"), "content": .string("saved")]))
        let agent = try await Agent.open(configuration: agentConfiguration(http, workspace: directory, tools: [plugin]), approval: approval, builtInTools: [.writeFile])
        #expect(agent.approval === approval)
        _ = try await finishAgentTurn(agent.prompt("save a note"))
        #expect(try String(contentsOf: directory.appendingPathComponent("note.txt"), encoding: .utf8) == "saved")
        #expect(await approval.allowedPlugins == ["workspace"])
        let body = String(decoding: try JSONEncoder().encode(await http.requests.first), as: UTF8.self)
        #expect(body.contains("plugin_tool") && body.contains("write") && !body.contains("read"))
        try await agent.close()
    }
}
