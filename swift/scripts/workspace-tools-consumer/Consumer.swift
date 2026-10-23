import Foundation
import LibFx
import FxAgentKit

private func require(_ condition: Bool, _ message: String) throws {
    if !condition { throw ConsumerFailure(message: message) }
}
private struct ConsumerFailure: Error { let message: String }

private actor FixtureHTTP: FxHTTPClient {
    let calls: [(String, JSONValue)]
    private var step = 0
    private(set) var bodies: [JSONValue] = []
    init(_ calls: [(String, JSONValue)]) { self.calls = calls }
    func send(_ request: URLRequest) async throws -> FxHTTPResponse {
        let text: String
        if request.httpMethod == "GET" {
            text = #"{"data":[{"id":"fixture/workspace","type":"language","tags":["tool-use"]}]}"#
        } else {
            bodies.append(try JSONDecoder().decode(JSONValue.self, from: request.httpBody ?? Data()))
            var frames: [JSONValue] = []
            if step < calls.count {
                let (name, args) = calls[step]
                frames.append(.object(["type": .string("tool-call"), "toolCallId": .string("call-\(step)"),
                                       "toolName": .string(name), "input": args]))
            } else {
                frames.append(.object(["type": .string("text-delta"), "delta": .string("fixture finished")]))
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
    var results: [JSONValue] {
        guard case .array(let messages) = bodies.last?["prompt"] else { return [] }
        return messages.flatMap { message -> [JSONValue] in
            guard case .array(let content) = message["content"] else { return [] }
            return content.filter { $0["type"] == .string("tool-result") }
        }
    }
}

private actor ApprovalProbe {
    private(set) var effects: [FxToolEffect] = []
    func allow(_ request: FxToolApproval.Request) -> FxToolApproval.Decision {
        effects.append(request.effect)
        return .allowOnce
    }
}

@main struct Consumer {
    static func main() async throws {
        let workspace = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }
        func args(_ values: [String: String]) -> JSONValue { .object(values.mapValues(JSONValue.string)) }
        let probe = ApprovalProbe()
        let approval = FxToolApproval { await probe.allow($0) }
        let tools = FxWorkspaceTools(workspace: workspace, approval: approval, pluginID: "consumer")
            .tools([.readFile, .writeFile, .editFile, .shell])
        let plugin = FxTool(name: "plugin_echo", description: "Echo a plugin result", inputSchema: .object(["type": .string("object")]),
                            isIdempotent: true, writes: false) { _, _ in "PLUGIN_OK" }
        let http = FixtureHTTP([
            ("write_file", args(["path": "note.txt", "content": "before\n"])),
            ("read_file", args(["path": "note.txt"])),
            ("edit_file", args(["path": "note.txt", "old_string": "before", "new_string": "after"])),
            ("read_file", args(["path": "note.txt"])),
            ("shell", args(["command": "pwd; printf SHELL_OK; printf err >&2; printf shell > shell.txt"])),
            ("plugin_echo", .object([:])),
        ])
        let configuration = FxConfiguration(apiKey: "fixture", model: "fixture/workspace", tools: tools + [plugin], workspace: workspace, httpClient: http)
        let engine = try await FxEngine.open(configuration: configuration)
        do {
            let turn = try await engine.prompt("Run the fixture tools")
            for try await _ in turn {}
            _ = try await turn.result
            try await engine.close()
        } catch { try? await engine.close(); throw error }
        try require(try String(contentsOf: workspace.appendingPathComponent("note.txt"), encoding: .utf8) == "after\n", "File edit did not run")
        try require(try String(contentsOf: workspace.appendingPathComponent("shell.txt"), encoding: .utf8) == "shell", "Shell did not run in workspace")
        let results = await http.results
        try require(results.count == 6 && results.allSatisfy { $0["output"]?["type"] == .string("text") }, "Tools did not return successful results to the model")
        let outputs = String(describing: results)
        try require(outputs.contains("before") && outputs.contains("after") && outputs.contains("SHELL_OK") && outputs.contains("PLUGIN_OK"), "Tool outputs were not consumed by the model fixture")
        try require(await probe.effects == [.write, .write, .dangerous], "Approval effects mismatch")

        let deniedHTTP = FixtureHTTP([("shell", args(["command": "printf forbidden > denied.txt"]))])
        let deniedTools = FxWorkspaceTools(workspace: workspace, approval: FxToolApproval { _ in .deny }, pluginID: "denied").tools([.shell])
        let denied = try await FxEngine.open(configuration: FxConfiguration(apiKey: "fixture", model: "fixture/workspace", tools: deniedTools, workspace: workspace, httpClient: deniedHTTP))
        do {
            let turn = try await denied.prompt("Try denied shell")
            for try await _ in turn {}
            _ = try await turn.result
            try await denied.close()
        }
        catch { try? await denied.close(); throw error }
        try require(!FileManager.default.fileExists(atPath: workspace.appendingPathComponent("denied.txt").path), "Denied command had a side effect")
        try require(await deniedHTTP.results.first?["output"]?["type"] == .string("error-text"), "Denial was not returned to the model")
        let cancelledHTTP = FixtureHTTP([("shell", args(["command": "echo $$ > cancel-pid; trap '' TERM; while :; do :; done"]))])
        let cancelledTools = FxWorkspaceTools(workspace: workspace, approval: approval, pluginID: "cancel").tools([.shell])
        let cancelled = try await FxEngine.open(configuration: FxConfiguration(apiKey: "fixture", model: "fixture/workspace", tools: cancelledTools, workspace: workspace, httpClient: cancelledHTTP))
        do {
            let turn = try await cancelled.prompt("Start then cancel shell")
            let file = workspace.appendingPathComponent("cancel-pid")
            let deadline = ContinuousClock.now.advanced(by: .seconds(5))
            while !FileManager.default.fileExists(atPath: file.path) {
                guard ContinuousClock.now < deadline else { await turn.cancel(); throw ConsumerFailure(message: "Shell did not start") }
                try await Task.sleep(for: .milliseconds(10))
            }
            let pid = Int32(try String(contentsOf: file, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines))!
            await turn.cancel()
            for try await _ in turn {}
            let result = try await turn.result
            try require(result.stopReason == .cancelled, "Turn did not cancel")
            try await cancelled.close()
            try require(kill(pid, 0) == -1 && errno == ESRCH, "Cancelled shell survived SDK shutdown")
        } catch { try? await cancelled.close(); throw error }
        print("PASS: public SDK native instance consumed read/write/edit/shell and plugin tool results; shell denial had no side effects; cancellation joined its process")
    }
}
