import Foundation
import Testing
@testable import LibFx

private actor NegotiationCalls {
    var names: [String] = []
    func call(_ name: String) -> FxToolResult { names.append(name); return FxToolResult(text: "RESULT_" + name) }
}

private actor NegotiationHTTP: FxHTTPClient {
    let fallback: Int
    var requests: [URLRequest] = []
    var step = 0
    init(fallback: Int) { self.fallback = fallback }
    func send(_ request: URLRequest) throws -> FxHTTPResponse {
        requests.append(request)
        let body = String(decoding: request.httpBody!, as: UTF8.self)
        let native = body.contains("tool_addition")
        let reference = body.contains("tool_reference")
        if (fallback > 0 && native) || (fallback > 1 && reference) {
            let status = native ? 422 : 400
            return FxHTTPResponse(statusCode: status, body: AsyncThrowingStream { $0.yield(Data("unrelated error text".utf8)); $0.finish() })
        }
        defer { step += 1 }
        var blocks: [[String: Any]] = []
        if step == 0 || step == 3 {
            let name = step == 0 ? "first" : "second"
            blocks = [["type": "tool_use", "id": "s-\(step)", "name": "tool_search", "input": ["query": "select:" + name]]]
        } else if step == 1 || step == 4 {
            let name = step == 1 ? "first" : "second"
            let wrapper = fallback == 2
            blocks = [["type": "tool_use", "id": "c-\(step)", "name": wrapper ? "call_tool" : name,
                       "input": wrapper ? ["name": name, "args": [:]] : [:]]]
        } else { blocks = [["type": "text", "text": "ok"]] }
        return try messagesReply(blocks)
    }
}

private func messagesReply(_ blocks: [[String: Any]]) throws -> FxHTTPResponse {
    var events: [[String: Any]] = []
    for (i, block) in blocks.enumerated() {
        var start = block
        if block["type"] as? String == "tool_use" { start["input"] = [:] }
        events.append(["type": "content_block_start", "index": i, "content_block": start])
        if let input = block["input"] {
            events.append(["type": "content_block_delta", "index": i, "delta": ["type": "input_json_delta", "partial_json": String(decoding: try JSONSerialization.data(withJSONObject: input), as: UTF8.self)]])
        }
        events.append(["type": "content_block_stop", "index": i])
    }
    events += [["type": "message_delta", "delta": ["stop_reason": blocks.contains { $0["type"] as? String == "tool_use" } ? "tool_use" : "end_turn"]], ["type": "message_stop"]]
    let data = try events.map { "data: " + String(decoding: try JSONSerialization.data(withJSONObject: $0), as: UTF8.self) + "\n\n" }.joined()
    return FxHTTPResponse(statusCode: 200, body: AsyncThrowingStream { $0.yield(Data(data.utf8)); $0.finish() })
}

@Suite(.serialized) struct DeferredNegotiationTests {
    @Test(arguments: [0, 1, 2]) func persistenceAndCheckpoint(fallback: Int) async throws {
        let http = NegotiationHTTP(fallback: fallback), calls = NegotiationCalls()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("fx6-modes-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = directory.appendingPathComponent("session.sqlite")
        let store = try FxSQLitePersistence(url: database)
        func tool(_ name: String) -> FxTool {
            FxTool(name: name, description: "Run " + name, inputSchema: .object(["type": .string("object"), "properties": .object([:])]), isIdempotent: true, deferred: true) { _, _ in await calls.call(name) }
        }
        let provider = try FxCustomProvider(name: "negotiation", baseURL: URL(string: "https://messages.example/v1")!, models: ["fixture": .init(contextWindow: 100000, maxOutputTokens: 1024)], apiProtocol: .anthropicMessages)
        let config = FxConfiguration(provider: .custom(provider), model: "fixture", tools: [tool("first"), tool("second")], httpClient: http)
        let engine = try await FxEngine.open(configuration: config, persistence: store)
        let sessionID = engine.sessionID
        try await drainCatalogTurn(try await engine.prompt("First"))
        #expect(await calls.names == ["first"])
        let checkpoint = try await engine.checkpoint()
        try await engine.close()
        // The store replays negotiation independently of checkpoint restoration.
        let reopenedStore = try FxSQLitePersistence(url: database)
        let reopened = try await FxEngine.open(configuration: config, sessionID: sessionID, persistence: reopenedStore)
        try await drainCatalogTurn(try await reopened.prompt("Second"))
        try await reopened.removeTools(named: ["first"])
        try await drainCatalogTurn(try await reopened.prompt("After removal"))
        try await reopened.close()
        #expect(await calls.names == ["first", "second"])
        let restored = try await FxEngine.open(configuration: config, checkpoint: checkpoint)
        try await drainCatalogTurn(try await restored.prompt("Checkpoint"))
        try await restored.close()
        let requests = await http.requests
        let bodies = requests.map { String(decoding: $0.httpBody!, as: UTF8.self) }
        #expect(bodies.filter { $0.contains("tool_addition") && $0.contains("s-0") }.count == (fallback == 0 ? bodies.filter { $0.contains("tool_addition") }.count : 1))
        if fallback == 1 {
            let references = requests.filter { String(decoding: $0.httpBody!, as: UTF8.self).contains("tool_reference") }
            #expect(references.count >= 6)
            for request in references { #expect(request.value(forHTTPHeaderField: "anthropic-beta") == nil) }
            let firstTools = try catalogRawArray("tools", in: references[0].httpBody!)
            for request in references { #expect(try catalogRawArray("tools", in: request.httpBody!).starts(with: firstTools.dropLast())) }
            let last = try JSONDecoder().decode(JSONValue.self, from: references[references.count - 2].httpBody!)
            guard case .array(let tools) = last["tools"] else { Issue.record("Missing tools"); return }
            #expect(tools.contains { $0["name"] == .string("first") && $0["defer_loading"] == .bool(true) })
        }
        for request in requests {
            let body = try JSONDecoder().decode(JSONValue.self, from: request.httpBody!)
            guard case .array(let tools) = body["tools"] else { Issue.record("Missing tools"); return }
            #expect(tools.contains { $0["name"] == .string("call_tool") })
        }
    }
}
