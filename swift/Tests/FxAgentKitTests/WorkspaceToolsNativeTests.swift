import Foundation
import Testing
import LibFx
import FxAgentKit

private actor WorkspaceHTTP: FxHTTPClient {
    private let calls: [(String, JSONValue)]
    private var step = 0
    private(set) var results: [JSONValue] = []
    init(_ calls: [(String, JSONValue)]) { self.calls = calls }
    func send(_ request: URLRequest) throws -> FxHTTPResponse {
        let text: String
        if request.httpMethod == "GET" {
            text = #"{"data":[{"id":"fixture/workspace","type":"language","tags":["tool-use"]}]}"#
        } else {
            let body = try JSONDecoder().decode(JSONValue.self, from: request.httpBody ?? Data())
            if case .array(let messages) = body["prompt"] {
                results = messages.flatMap { message -> [JSONValue] in
                    guard case .array(let content) = message["content"] else { return [] }
                    return content.filter { $0["type"] == .string("tool-result") }
                }
            }
            var frames: [JSONValue] = []
            if step < calls.count {
                let (name, args) = calls[step]
                frames.append(.object(["type": .string("tool-call"), "toolCallId": .string("call-\(step)"),
                                       "toolName": .string(name), "input": args]))
            }
            frames.append(.object(["type": .string("finish"), "finishReason": .object([
                "unified": .string(step < calls.count ? "tool-calls" : "stop"),
                "raw": .string(step < calls.count ? "tool-calls" : "stop"),
            ])]))
            step += 1
            text = try frames.map { "data: \(String(decoding: try JSONEncoder().encode($0), as: UTF8.self))\n\n" }.joined() + "data: [DONE]\n\n"
        }
        return FxHTTPResponse(statusCode: 200, body: AsyncThrowingStream { $0.yield(Data(text.utf8)); $0.finish() })
    }
}

@Suite(.serialized, .timeLimit(.minutes(1))) struct WorkspaceToolsNativeTests {
    @Test(arguments: [false, true])
    func nativeSDKConsumesWorkspaceAndPluginToolsWithApproval(allow: Bool) async throws {
        let workspace = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }
        func args(_ values: [String: String]) -> JSONValue { .object(values.mapValues(JSONValue.string)) }
        try Data("before".utf8).write(to: workspace.appendingPathComponent("existing"))
        let http = WorkspaceHTTP([
            ("read_file", args(["path": "existing"])),
            ("write_file", args(["path": "new", "content": "created"])),
            ("edit_file", args(["path": "existing", "old_string": "before", "new_string": "after"])),
            ("shell", args(["command": "printf SHELL_NATIVE; printf created > from-shell"])),
            ("plugin", .object([:])),
        ])
        let approval = FxToolApproval { _ in allow ? .allowOnce : .deny }
        let workspaceTools = FxWorkspaceTools(workspace: workspace, approval: approval, pluginID: "fixture")
        let plugin = FxTool(name: "plugin", description: "Plugin fixture", inputSchema: .object(["type": .string("object")]),
                            isIdempotent: true, writes: false) { _, _ in "PLUGIN_NATIVE" }
        let engine = try await FxEngine.open(configuration: FxConfiguration(apiKey: "fixture", model: "fixture/workspace",
            tools: workspaceTools.tools([.readFile, .writeFile, .editFile, .shell]) + [plugin], workspace: workspace, httpClient: http))
        do {
            let turn = try await engine.prompt("Exercise workspace tools")
            for try await _ in turn {}
            #expect(try await turn.result.stopReason == .endTurn)
            try await engine.close()
        } catch { try? await engine.close(); throw error }
        let results = await http.results
        #expect(results.count == 5)
        #expect(results.map { $0["output"]?["type"] } == ["text", allow ? "text" : "error-text", allow ? "text" : "error-text", allow ? "text" : "error-text", "text"].map { .string($0) })
        #expect(String(describing: results).contains("PLUGIN_NATIVE"))
        #expect(try String(contentsOf: workspace.appendingPathComponent("existing"), encoding: .utf8) == (allow ? "after" : "before"))
        #expect(FileManager.default.fileExists(atPath: workspace.appendingPathComponent("new").path) == allow)
        #expect(FileManager.default.fileExists(atPath: workspace.appendingPathComponent("from-shell").path) == allow)
        if allow { #expect(String(describing: results).contains("SHELL_NATIVE")) }
    }
}

extension WorkspaceToolsNativeTests {
    @Test func nativeTurnCancellationStopsTheWorkspaceShell() async throws {
        let workspace = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }
        let http = WorkspaceHTTP([("shell", .object(["command": .string("echo $$ > pid; trap '' TERM; while :; do :; done")]))])
        let tools = FxWorkspaceTools(workspace: workspace, approval: FxToolApproval { _ in .allowOnce }, pluginID: "fixture").tools([.shell])
        let engine = try await FxEngine.open(configuration: FxConfiguration(apiKey: "fixture", model: "fixture/workspace", tools: tools,
                                                                           workspace: workspace, httpClient: http))
        do {
            let turn = try await engine.prompt("Start a shell")
            let pidFile = workspace.appendingPathComponent("pid")
            let deadline = ContinuousClock.now.advanced(by: .seconds(5))
            while !FileManager.default.fileExists(atPath: pidFile.path) {
                guard ContinuousClock.now < deadline else { await turn.cancel(); throw FxError.transport("Shell did not start") }
                try await Task.sleep(for: .milliseconds(10))
            }
            let pid = try #require(Int32(String(contentsOf: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
            await turn.cancel()
            for try await _ in turn {}
            #expect(try await turn.result.stopReason == .cancelled)
            try await engine.close()
            #expect(kill(pid, 0) == -1 && errno == ESRCH)
        } catch { try? await engine.close(); throw error }
    }
}
