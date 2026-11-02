import Foundation
import Testing
import LibFx
import FxAgentKit

enum DirectMode: String, CaseIterable, Sendable {
    case responses, messages, callTool
}

private actor DirectCalls {
    var executions = 0
    var approvals = 0
    func approve() -> FxToolApproval.Decision { approvals += 1; return .allowOnce }
    func execute() -> FxToolResult { executions += 1; return "DIRECT_RESULT" }
}

private actor DirectHTTP: FxHTTPClient {
    let mode: DirectMode
    let input: JSONValue
    let missing: Bool
    let loaded: Bool
    var requests: [Data] = []
    init(mode: DirectMode, input: JSONValue, missing: Bool, loaded: Bool) {
        self.mode = mode; self.input = input; self.missing = missing; self.loaded = loaded
    }
    func send(_ request: URLRequest) throws -> FxHTTPResponse {
        requests.append(request.httpBody!)
        let step = requests.count
        let search = loaded && step == 1
        let calling = search || step == (loaded ? 2 : 1)
        let target = missing ? "removed" : "direct_action"
        let name = search ? "tool_search" : mode == .callTool ? "call_tool" : target
        let args: JSONValue = search ? .object(["query": .string("select:direct_action")])
            : mode == .callTool ? .object(["name": .string(target), "args": input]) : input
        let arguments = String(decoding: try JSONEncoder().encode(args), as: UTF8.self)
        var events: [[String: Any]]
        if mode == .responses {
            if calling {
                let item: [String: Any] = search
                    ? ["type": "tool_search_call", "id": "ts-\(step)", "call_id": "call-\(step)", "execution": "client", "arguments": try JSONSerialization.jsonObject(with: JSONEncoder().encode(args))]
                    : ["type": "function_call", "id": "fc-\(step)", "call_id": "call-\(step)", "name": name, "arguments": arguments]
                events = [["type": "response.output_item.added", "output_index": 0, "item": item],
                          ["type": "response.output_item.done", "output_index": 0, "item": item],
                          ["type": "response.completed", "response": ["status": "completed", "output": [item]]]]
            } else {
                events = [["type": "response.output_item.added", "output_index": 0, "item": ["type": "message", "id": "msg"]],
                          ["type": "response.output_text.delta", "output_index": 0, "delta": "accepted"],
                          ["type": "response.completed", "response": ["status": "completed"]]]
            }
        } else {
            if calling {
                events = [["type": "content_block_start", "index": 0, "content_block": ["type": "tool_use", "id": "call-\(step)", "name": name, "input": [:]]],
                          ["type": "content_block_delta", "index": 0, "delta": ["type": "input_json_delta", "partial_json": arguments]],
                          ["type": "content_block_stop", "index": 0]]
            } else {
                events = [["type": "content_block_start", "index": 0, "content_block": ["type": "text", "text": ""]],
                          ["type": "content_block_delta", "index": 0, "delta": ["type": "text_delta", "text": "accepted"]],
                          ["type": "content_block_stop", "index": 0]]
            }
            events += [["type": "message_delta", "delta": ["stop_reason": calling ? "tool_use" : "end_turn"], "usage": ["output_tokens": 1]], ["type": "message_stop"]]
        }
        let data = try events.map { "data: " + String(decoding: try JSONSerialization.data(withJSONObject: $0), as: UTF8.self) + "\n\n" }.joined()
        return FxHTTPResponse(statusCode: 200, body: AsyncThrowingStream { $0.yield(Data(data.utf8)); $0.finish() })
    }
}

// Preserve exact array bytes rather than re-encoding parsed objects.
private func rawArray(_ key: String, _ data: Data) throws -> Data {
    let bytes = Array(data), marker = Array("\"\(key)\":[".utf8)
    var nesting = 0, inString = false, escape = false
    var found: Int?
    for index in bytes.indices {
        let byte = bytes[index]
        if inString {
            if escape { escape = false } else if byte == 92 { escape = true } else if byte == 34 { inString = false }
        } else {
            if nesting == 1 && index + marker.count <= bytes.count && Array(bytes[index..<(index + marker.count)]) == marker { found = index; break }
            if byte == 34 { inString = true }
            else if byte == 91 || byte == 123 { nesting += 1 }
            else if byte == 93 || byte == 125 { nesting -= 1 }
        }
    }
    guard let start = found else { throw FxError.invalidInput("Missing array") }
    let begin = start + marker.count - 1
    var depth = 0, quoted = false, escaped = false
    for index in begin..<bytes.count {
        let byte = bytes[index]
        if quoted {
            if escaped { escaped = false } else if byte == 92 { escaped = true } else if byte == 34 { quoted = false }
        } else if byte == 34 { quoted = true }
        else if byte == 91 || byte == 123 { depth += 1 }
        else if byte == 93 || byte == 125 { depth -= 1; if depth == 0 { return Data(bytes[begin...index]) } }
    }
    throw FxError.invalidInput("Unterminated array")
}

@Suite(.serialized) struct DeferredDirectCallTests {
    @Test(arguments: DirectMode.allCases, ["valid", "type", "required", "extra", "missing", "removed", "loaded"])
    func directCall(mode: DirectMode, scenario: String) async throws {
        let input: JSONValue = scenario == "required" ? .object([:]) : (scenario == "type" || scenario == "loaded") ? .object(["value": .number(42)])
            : scenario == "extra" ? .object(["value": .string("ok"), "extra": .bool(true)]) : .object(["value": .string("ok")])
        let calls = DirectCalls()
        let http = DirectHTTP(mode: mode, input: input, missing: scenario == "missing", loaded: scenario == "loaded")
        let provider = try FxCustomProvider(name: "directfixture", baseURL: URL(string: "https://direct.example/v1")!,
            models: ["fixture": .init(contextWindow: 100000, maxOutputTokens: 1024)],
            apiProtocol: mode == .responses ? .responses : .anthropicMessages)
        let tool = FxTool(name: "direct_action", description: "Current action", inputSchema: .object([
            "type": .string("object"), "properties": .object(["value": .object(["type": .string("string")])]),
            "required": .array([.string("value")]), "additionalProperties": .bool(false),
        ]), isIdempotent: false, deferred: true) { _, _ in await calls.execute() }
        let approval = FxToolApproval { _ in await calls.approve() }
        let config = FxConfiguration(provider: .custom(provider), model: "fixture", tools: [approval.wrap(tool: tool, pluginID: "fixture", effect: .write)], httpClient: http)
        let agent = try await Agent.open(configuration: config, approval: approval, builtInTools: [])
        if scenario == "removed" { try await agent.removeTools(named: ["direct_action"]) }
        let turn = try await agent.prompt("Call the action directly")
        for try await _ in turn {}
        #expect(try await turn.result.stopReason == .endTurn)
        try await agent.close()
        let succeeds = scenario == "valid"
        #expect(await calls.executions == (succeeds ? 1 : 0))
        #expect(await calls.approvals == (succeeds ? 1 : 0))
        let requests = await http.requests
        #expect(requests.count == (scenario == "loaded" ? 3 : 2))
        let firstTools = try rawArray("tools", requests[0])
        for body in requests { #expect(try rawArray("tools", body) == firstTools) }
        let key = mode == .responses ? "input" : "messages"
        for index in 1..<requests.count {
            #expect(try rawArray(key, requests[index]).starts(with: rawArray(key, requests[index - 1]).dropLast()))
        }
        let final = String(decoding: requests.last!, as: UTF8.self)
        if succeeds { #expect(final.contains("DIRECT_RESULT")) }
        else if scenario == "missing" || scenario == "removed" { #expect(final.contains("tool_not_found")); #expect(final.contains("tool_search")) }
        else {
            // Decode the output text to inspect the actual failure contract.
            let body = try JSONDecoder().decode(JSONValue.self, from: requests.last!)
            guard case .array(let history) = body[key] else { Issue.record("Missing history"); return }
            let text: String?
            if mode == .responses { text = history.last?["output"]?.string }
            else if case .array(let parts) = history.last?["content"] { text = parts.last?["content"]?.string }
            else { text = nil }
            let failure = try JSONDecoder().decode(JSONValue.self, from: Data(try #require(text).utf8))
            #expect(failure["error"]?["type"] == .string("invalid_tool_arguments"))
            #expect(failure["error"]?["tool_name"] == .string("direct_action"))
            #expect(failure["error"]?["definition"]?["parameters"] == tool.inputSchema)
            #expect(failure["error"]?["definition"]?["description"] == .string("Current action"))
            if case .array(let issues) = failure["error"]?["issues"] {
                #expect(!issues.isEmpty)
                #expect(issues.allSatisfy { $0["error"]?.string?.isEmpty == false && $0["instanceLocation"]?.string != nil })
            } else { Issue.record("Missing field errors") }
            #expect(!final.contains("InvalidToolArguments"))
            #expect(!final.contains("invalidInput"))
        }
    }
}
