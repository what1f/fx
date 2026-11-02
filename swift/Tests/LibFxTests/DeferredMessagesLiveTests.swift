import Foundation
import Testing
@testable import LibFx

private actor MessagesLiveCalls {
    var names: [String] = []
    func run(_ name: String) -> FxToolResult { names.append(name); return FxToolResult(text: "FX6_RESULT_" + name) }
}

private func isReferenceRequest(_ data: Data) -> Bool {
    guard let body = try? JSONDecoder().decode(JSONValue.self, from: data) else { return false }
    guard case .array(let tools) = body["tools"] else { return false }
    return tools.contains { $0["defer_loading"] == .bool(true) && $0["name"] != .string("__fx_deferred_placeholder__") }
}

private actor MessagesLiveHTTP: FxHTTPClient {
    private let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        return URLSession(configuration: configuration)
    }()
    var requests: [(Data, Int)] = []
    var rejectReferenceOnce = false
    func forceCallTool() { rejectReferenceOnce = true }
    func send(_ request: URLRequest) async throws -> FxHTTPResponse {
        let payload = request.httpBody!
        if rejectReferenceOnce && (isReferenceRequest(payload)) {
            rejectReferenceOnce = false
            requests.append((payload, 400))
            print("FX6 live request=\(requests.count) status=400 source=local-reference-rejection cache_read_input_tokens=NA")
            return FxHTTPResponse(statusCode: 400, body: AsyncThrowingStream { $0.yield(Data("local reference rejection".utf8)); $0.finish() })
        }
        let (data, response) = try await session.data(for: request)
        let status = (response as! HTTPURLResponse).statusCode
        let key = ProcessInfo.processInfo.environment["DORA_TEST_DEEPSEEK_KEY"]!
        guard !data.contains(Data(key.utf8)) else { throw FxError.invalidInput("Credential found in response") }
        requests.append((payload, status))
        var cached: Int?, input: Int?
        var toolNames: [String] = []
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") where line.hasPrefix("data:") {
            if let event = try? JSONDecoder().decode(JSONValue.self, from: Data(line.dropFirst(5).utf8)), event["type"] == .string("message_start") {
                if case .number(let n) = event["message"]?["usage"]?["cache_read_input_tokens"] { cached = Int(n) }
                if case .number(let n) = event["message"]?["usage"]?["input_tokens"] { input = Int(n) }
            }
            if let event = try? JSONDecoder().decode(JSONValue.self, from: Data(line.dropFirst(5).utf8)), event["type"] == .string("content_block_start"), let name = event["content_block"]?["name"]?.string { toolNames.append(name) }
        }
        print("FX6 live model_tools=" + toolNames.joined(separator: ","))
        print("FX6 live request=\(requests.count) status=\(status) source=deepseek input_tokens=\(input.map(String.init) ?? "NA") cache_read_input_tokens=\(cached.map(String.init) ?? "NA")")
        return FxHTTPResponse(statusCode: status, body: AsyncThrowingStream { $0.yield(data); $0.finish() })
    }
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["FX6_LIVE"] == "1"))
func deferredMessagesLiveDeepSeek() async throws {
    guard let key = ProcessInfo.processInfo.environment["DORA_TEST_DEEPSEEK_KEY"], !key.isEmpty else { throw FxError.invalidInput("DORA_TEST_DEEPSEEK_KEY is required") }
    let http = MessagesLiveHTTP(), calls = MessagesLiveCalls(), store = FxMemoryPersistence()
    func tool(_ name: String) -> FxTool {
        FxTool(name: name, description: "FX6 acceptance probe. Return the exact stored code for " + name, inputSchema: .object(["type": .string("object"), "properties": .object([:])]), isIdempotent: true, deferred: true) { _, _ in await calls.run(name) }
    }
    let provider = try FxCustomProvider(name: "deepseek", baseURL: URL(string: "https://api.deepseek.com/anthropic/v1")!, models: ["deepseek-flash": .init(contextWindow: 32768, maxOutputTokens: 2048, supportsToolUse: true)], apiProtocol: .anthropicMessages)
    let config = FxConfiguration(provider: .custom(provider, credentials: { _ in key }), model: FxModel(id: "deepseek-flash", reasoningEffort: "none"), instructions: "Follow the user's test procedure precisely. Use tool_search to discover tools. After discovery, invoke tools DIRECTLY using their exact names. NEVER use call_tool unless the user explicitly asks for call_tool. tool_reference blocks make the named tools available. Never invent results. Issue independent tool calls in parallel in one assistant response. Reply with only the result codes.", tools: [tool("fxsix_alpha"), tool("fxsix_beta")], httpClient: http)
    let engine = try await FxEngine.open(configuration: config, persistence: store)
    try await drainCatalogTurn(try await engine.prompt("Search for fxsix tools using query fxsix. Then call fxsix_alpha and fxsix_beta in parallel in ONE response. Both take {}. Do NOT use call_tool. Report both codes."))
    #expect(Set(await calls.names) == Set(["fxsix_alpha", "fxsix_beta"]))
    let id = engine.sessionID
    try await engine.close()
    let reopened = try await FxEngine.open(configuration: config, sessionID: id, persistence: store)
    try await reopened.upsertTools([tool("fxsix_gamma")])
    try await drainCatalogTurn(try await reopened.prompt("Use tool_search with query select:fxsix_gamma, then invoke fxsix_gamma DIRECTLY with {}. Do NOT use call_tool. Report its code."))
    #expect(await calls.names.contains("fxsix_gamma"))
    // Exercise the last tier against the real endpoint without pretending DeepSeek rejected reference.
    await http.forceCallTool()
    try await drainCatalogTurn(try await reopened.prompt("Call fxsix_alpha once using call_tool(name:fxsix_alpha,args:{}). Report its code."))
    try await reopened.close()
    let captured = await http.requests
    #expect(captured.contains { $0.1 == 422 && String(decoding: $0.0, as: UTF8.self).contains("tool_addition") })
    #expect(captured.contains { $0.1 == 200 && (isReferenceRequest($0.0)) })
    let accepted = try captured.filter { $0.1 == 200 }.map { try JSONDecoder().decode(JSONValue.self, from: $0.0) }
    func names(in body: JSONValue) -> [String] {
        guard case .array(let messages) = body["messages"] else { return [] }
        return messages.flatMap { message -> [String] in
            guard case .array(let content) = message["content"] else { return [] }
            return content.filter { $0["type"] == .string("tool_use") }.compactMap { $0["name"]?.string }
        }
    }
    let referenceBodies = try captured.filter { $0.1 == 200 && (isReferenceRequest($0.0)) }.map { try JSONDecoder().decode(JSONValue.self, from: $0.0) }
    #expect(referenceBodies.contains { Set(names(in: $0)).isSuperset(of: ["fxsix_alpha", "fxsix_beta", "fxsix_gamma"]) })
    #expect(referenceBodies.allSatisfy { !names(in: $0).contains("call_tool") })
    #expect(names(in: accepted.last!).contains("call_tool"))
    print("FX6 live direct_names_verified=\(referenceBodies.contains { Set(names(in: $0)).isSuperset(of: ["fxsix_alpha", "fxsix_beta", "fxsix_gamma"]) }) call_tool_verified=\(names(in: accepted.last!).contains("call_tool"))")
    let parallel = accepted.contains { request in
        guard case .array(let messages) = request["messages"] else { return false }
        return messages.contains { message in
            guard case .array(let content) = message["content"] else { return false }
            return content.filter { $0["type"] == .string("tool_result") && ($0["content"]?.string?.contains("FX6_RESULT_") ?? false) }.count >= 2
        }
    }
    #expect(parallel)
    #expect(accepted.last?["messages"] != nil)
    print("FX6 live model-driven parallel_results=\(parallel) executions=\(await calls.names.joined(separator: ","))")
    // Exact serialized array prefixes: reference tool declarations grow at their tail.
    let reference = captured.filter { $0.1 == 200 && (isReferenceRequest($0.0)) }
    for (old, new) in zip(reference, reference.dropFirst()) {
        let oldTools = try catalogRawArray("tools", in: old.0), newTools = try catalogRawArray("tools", in: new.0)
        #expect(newTools.starts(with: oldTools.dropLast()))
        let before = try catalogRawArray("messages", in: old.0), after = try catalogRawArray("messages", in: new.0)
        // A later user prompt may extend the last user content array.
        #expect(after.starts(with: before.dropLast()) || after.starts(with: before.dropLast(3)))
    }
    print("FX6 live local_reference_prefix=stable")
}
