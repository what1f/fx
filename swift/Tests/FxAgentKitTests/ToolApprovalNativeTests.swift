import Foundation
import Testing
import LibFx
import FxAgentKit

private actor ApprovalNativeHTTP: FxHTTPClient {
    private var posts = 0
    private(set) var outputs: [JSONValue] = []

    func send(_ request: URLRequest) throws -> FxHTTPResponse {
        posts += 1
        let events: [JSONValue]
        if posts == 1 {
            events = [
                .object(["type": .string("tool-call"), "toolCallId": .string("approval-call"),
                         "toolName": .string("save"), "input": .object(["value": .string("fixture")])]),
                .object(["type": .string("finish"), "finishReason": .object([
                    "unified": .string("tool-calls"), "raw": .string("tool-calls"),
                ])]),
            ]
        } else {
            let body = try JSONDecoder().decode(JSONValue.self, from: request.httpBody ?? Data())
            if case .array(let messages) = body["prompt"] {
                outputs = messages.flatMap { message -> [JSONValue] in
                    guard case .array(let content) = message["content"] else { return [] }
                    return content.filter { $0["type"] == .string("tool-result") }
                }
            }
            events = [
                .object(["type": .string("text-delta"), "delta": .string("handled")]),
                .object(["type": .string("finish"), "finishReason": .object([
                    "unified": .string("stop"), "raw": .string("stop"),
                ])]),
            ]
        }
        let payload = try events.map { "data: \(String(decoding: try JSONEncoder().encode($0), as: UTF8.self))\n\n" }.joined() + "data: [DONE]\n\n"
        return FxHTTPResponse(statusCode: 200, body: AsyncThrowingStream {
            $0.yield(Data(payload.utf8)); $0.finish()
        })
    }
}

private actor ApprovalNativeCalls {
    private(set) var requests: [FxToolApproval.Request] = []
    private(set) var executions = 0
    private(set) var observations: [FxObservation] = []
    func approve(_ request: FxToolApproval.Request, allow: Bool) -> FxToolApproval.Decision {
        requests.append(request)
        return allow ? .allowOnce : .deny
    }
    func execute(at url: URL, context: FxToolContext) throws -> FxToolResult {
        executions += 1
        if let observation = context.observation { observations.append(observation.scope) }
        try Data("saved".utf8).write(to: url)
        return "saved"
    }
}

@Suite(.serialized, .timeLimit(.minutes(1))) struct ToolApprovalNativeTests {
    @Test(arguments: [false, true])
    func nativeEngineUsesApprovalBeforeFileEffect(allow: Bool) async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("tool-approval-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: file) }
        let http = ApprovalNativeHTTP(), calls = ApprovalNativeCalls()
        let approval = FxToolApproval { await calls.approve($0, allow: allow) }
        let original = FxTool(name: "save", description: "Save a value", inputSchema: .object([
            "type": .string("object"), "properties": .object(["value": .object(["type": .string("string")])]),
        ]), isIdempotent: false, writes: true) { _, context in try await calls.execute(at: file, context: context) }
        let tool = approval.wrap(tool: original, pluginID: "notes", effect: .write)
        var configuration = FxConfiguration(apiKey: "fixture", model: "swift/tool-approval", tools: [tool], httpClient: http)
        configuration.modelCatalog = try FxModelCatalog(response: Data(#"{"data":[{"id":"swift/tool-approval","type":"language","tags":["tool-use"]}]}"#.utf8))
        configuration.observation = FxObservationOptions(onEvent: { _ in })
        let engine = try await FxEngine.open(configuration: configuration)
        do {
            let turn = try await engine.prompt("save the fixture", id: "approval-turn")
            var text = "", toolResults = 0
            for try await event in turn {
                if case .text(let delta) = event { text += delta }
                if case .toolFinished("approval-call", "save", _, let isError) = event {
                    toolResults += 1
                    #expect(isError == !allow)
                }
            }
            #expect(try await turn.result.stopReason == .endTurn)
            #expect(text == "handled" && toolResults == 1)
            try await engine.close()
        } catch {
            try? await engine.close()
            throw error
        }
        let request = try #require(await calls.requests.first)
        #expect(await calls.requests.count == 1)
        #expect(request.pluginID == "notes" && request.toolName == "save" && request.effect == .write)
        #expect(request.input == .object(["value": .string("fixture")]))
        #expect(request.context.executionID == "approval-call")
        #expect(request.context.turnID == "approval-turn")
        #expect(request.context.sessionID == engine.sessionID)
        let observation = try #require(request.context.observation)
        #expect(await calls.observations == (allow ? [observation.scope] : []))
        #expect(await calls.executions == (allow ? 1 : 0))
        #expect(FileManager.default.fileExists(atPath: file.path) == allow)
        if allow { #expect(try String(contentsOf: file, encoding: .utf8) == "saved") }
        let outputs = await http.outputs
        #expect(outputs.count == 1)
        #expect(outputs.first?["output"]?["type"] == .string(allow ? "text" : "error-text"))
        #expect(await approval.allowedPlugins.isEmpty)
    }
}
