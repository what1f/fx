import Foundation
import Testing
@_spi(Conformance) @testable import LibFx

private actor CatalogCalls {
    var inputs: [JSONValue] = []
    func record(_ value: JSONValue) { inputs.append(value) }
}

private actor CatalogHTTP: FxHTTPClient {
    var posts: [JSONValue] = []
    let actions: [(String, JSONValue)?]
    let codex: Bool
    init(actions: [(String, JSONValue)?], codex: Bool = false) { self.actions = actions; self.codex = codex }
    func send(_ request: URLRequest) async throws -> FxHTTPResponse {
        let payload: String
        if request.httpMethod == "GET" {
            if codex {
                payload = request.url!.path.hasSuffix("/models") ? #"{"models":[{"slug":"gpt-6.1-sol","visibility":"list","supported_in_api":true,"priority":1,"supported_reasoning_levels":[{"effort":"low"}],"additional_speed_tiers":[],"input_modalities":["text"],"context_window":272000}]}"# : #"{"version":"0.162.1"}"#
            } else { payload = #"{"data":[{"id":"swift/catalog","type":"language","tags":["tool-use"]}]}"# }
        } else {
            let body = try JSONDecoder().decode(JSONValue.self, from: request.httpBody ?? Data())
            posts.append(body)
            let action = posts.count <= actions.count ? actions[posts.count - 1] : nil
            var events: [JSONValue] = []
            if let (name, input) = action {
                events.append(.object(["type": .string("tool-call"), "toolCallId": .string("call-\(posts.count)"), "toolName": .string(name), "input": input]))
            } else {
                events.append(.object(["type": .string("text-delta"), "delta": .string("done")]))
            }
            events.append(.object(["type": .string("finish"), "finishReason": .object(["unified": .string(action == nil ? "stop" : "tool-calls"), "raw": .string(action == nil ? "stop" : "tool-calls")])]))
            if codex {
                if let (name, input) = action {
                    let arguments = String(decoding: try JSONEncoder().encode(input), as: UTF8.self)
                    var item: JSONValue = .object(["type": .string("function_call"), "id": .string("fc_\(posts.count)"), "call_id": .string("call-\(posts.count)"), "name": .string(name), "arguments": .string(arguments)])
                    if name == "tool_search" {
                        item = .object(["type": .string("tool_search_call"), "id": .string("ts_\(posts.count)"), "call_id": .string("call-\(posts.count)"), "execution": .string("client"), "arguments": input])
                    }
                    events = [
                        .object(["type": .string("response.output_item.added"), "output_index": .number(0), "item": item]),
                        .object(["type": .string("response.function_call_arguments.done"), "output_index": .number(0), "arguments": .string(arguments)]),
                        .object(["type": .string("response.output_item.done"), "output_index": .number(0), "item": item]),
                        .object(["type": .string("response.completed"), "response": .object(["status": .string("completed"), "output": .array([item])])]),
                    ]
                    if name == "tool_search" { events.remove(at: 1) }
                } else {
                    events = [
                        .object(["type": .string("response.output_item.added"), "output_index": .number(0), "item": .object(["type": .string("message")])]),
                        .object(["type": .string("response.output_text.delta"), "output_index": .number(0), "delta": .string("done")]),
                        .object(["type": .string("response.completed"), "response": .object(["status": .string("completed")])]),
                    ]
                }
            }
            payload = try events.map { "data: \(String(decoding: try JSONEncoder().encode($0), as: UTF8.self))\n\n" }.joined() + "data: [DONE]\n\n"
        }
        return FxHTTPResponse(statusCode: 200, body: AsyncThrowingStream { $0.yield(Data(payload.utf8)); $0.finish() })
    }
}

private func catalogTool(_ name: String, key: String = "value", calls: CatalogCalls) -> FxTool {
    FxTool(name: name, description: "Perform \(name)", inputSchema: .object([
        "type": .string("object"), "properties": .object([key: .object(["type": .string("string")])]),
        "required": .array([.string(key)]), "additionalProperties": .bool(false),
    ]), isIdempotent: true, deferred: true) { input, _ in
        await calls.record(input)
        return "called"
    }
}

private func drainCatalogTurn(_ turn: FxTurn) async throws {
    for try await _ in turn {}
    #expect(try await turn.result.stopReason == .endTurn)
}

@Test func runtimeCatalogSearchesTwoHundredToolsAndRejectsStaleArguments() async throws {
    let calls = CatalogCalls()
    let http = CatalogHTTP(actions: [
        ("tool_search", .object(["query": .string("action_42")])),
        ("action_42", .object(["value": .string("old")])), nil,
        ("action_42", .object(["value": .string("stale")])),
        ("action_42", .object(["updated": .string("new")])), nil,
        ("action_42", .object(["updated": .string("removed")])), nil,
    ])
    let tools = (0..<200).map { catalogTool("action_\($0)", calls: calls) }
    let engine = try await FxEngine.open(configuration: FxConfiguration(apiKey: "fixture", model: "swift/catalog", tools: tools, httpClient: http))
    let first = try await engine.prompt("run action 42")
    do { try await engine.upsertTools([catalogTool("other", calls: calls)]); Issue.record("Busy update was accepted") }
    catch FxError.busy {}
    try await drainCatalogTurn(first)
    let posts = await http.posts
    guard case .array(let initial) = posts.first?["tools"] else { Issue.record("Missing initial tools"); try await engine.close(); return }
    #expect(initial.count == 2)
    #expect(initial.contains { $0["name"] == .string("tool_search") })
    #expect(await calls.inputs == [.object(["value": .string("old")])])
    try await engine.upsertTools([catalogTool("action_42", key: "updated", calls: calls)])
    try await drainCatalogTurn(try await engine.prompt("run updated action"))
    #expect(await calls.inputs == [.object(["value": .string("old")]), .object(["updated": .string("new")])])
    let checkpoint = try await engine.checkpoint()
    #expect(String(decoding: checkpoint, as: UTF8.self).contains("loaded_tools_json"))
    try await engine.removeTools(named: ["action_42"])
    try await drainCatalogTurn(try await engine.prompt("call removed action"))
    #expect(await calls.inputs.count == 2)
    try await engine.close()
}

@Test func runtimeCatalogCodexUsesInlineDefinitionsAndRestoresLoadedTools() async throws {
    let calls = CatalogCalls()
    let http = CatalogHTTP(actions: [
        ("tool_search", .object(["query": .string("action_42")])),
        ("action_42", .object(["value": .string("first")])), nil,
        ("tool_search", .object(["query": .string("action_42")])), nil,
        ("action_42", .object(["value": .string("restored")])), nil,
    ], codex: true)
    let credentials = try FxSubscriptionCredentials(accessToken: "fixture-token", accountID: "fixture-account", expiresAt: Date().addingTimeInterval(3600))
    let auth = FxSubscription(provider: .codex, credentials: { _ in credentials })
    let config = FxConfiguration(provider: .subscription(auth), model: FxModel(id: "gpt-6.1-sol"), tools: [catalogTool("action_42", calls: calls)], httpClient: http)
    let engine = try await FxEngine.open(configuration: config)
    try await drainCatalogTurn(try await engine.prompt("search and call"))
    try await drainCatalogTurn(try await engine.prompt("search again"))
    let before = await http.posts
    #expect(before.count == 5)
    guard case .array(let initial) = before[0]["tools"], case .array(let loaded) = before[1]["tools"] else {
        Issue.record("Missing ordinary function tools"); try await engine.close(); return
    }
    #expect(initial.count == 1)
    #expect(loaded == initial)
    #expect(!loaded.contains { $0["name"] == .string("action_42") })
    #expect(String(describing: before).contains("tool_search_output"))
    let checkpoint = try await engine.checkpoint()
    try await engine.close()
    let restored = try await FxEngine.open(configuration: config, checkpoint: checkpoint)
    try await drainCatalogTurn(try await restored.prompt("use loaded action"))
    #expect(await calls.inputs.count == 2)
    let final = await http.posts
    #expect(final[5]["tools"] == before[1]["tools"])
    try await restored.close()
}

@Test func runtimeCatalogSurvivesAutomaticCompactionAndSQLiteReopen() async throws {
    #expect(try await runRuntimeCatalogProbe() > 0)
}

@Test func runtimeCatalogRejectsInvalidBatchWithoutPartialUpdates() async throws {
    let calls = CatalogCalls()
    let http = CatalogHTTP(actions: [("tool_search", .object(["query": .string("action_42")])), ("action_42", .object(["value": .string("kept")])), nil])
    let engine = try await FxEngine.open(configuration: FxConfiguration(apiKey: "fixture", model: "swift/catalog", tools: [catalogTool("action_42", calls: calls)], httpClient: http))
    do {
        try await engine.upsertTools([catalogTool("action_42", key: "updated", calls: calls), catalogTool("invalid name", calls: calls)])
        Issue.record("Invalid batch accepted")
    } catch {}
    try await drainCatalogTurn(try await engine.prompt("call original action"))
    #expect(await calls.inputs == [.object(["value": .string("kept")])])
    try await engine.close()
}

private actor CatalogUpdateGate {
    private var blocked = false
    private var release: CheckedContinuation<Void, Never>?
    func block() async { blocked = true; await withCheckedContinuation { release = $0 } }
    func wait() async { while !blocked { await Task.yield() } }
    func open() { release?.resume(); release = nil }
}

@Test func runtimeCatalogUpdateBlocksCheckpointAndCloseJoinsIt() async throws {
    let calls = CatalogCalls()
    let gate = CatalogUpdateGate()
    var configuration = FxConfiguration(apiKey: "fixture", model: "swift/catalog", tools: [catalogTool("action_42", calls: calls)], httpClient: CatalogHTTP(actions: []))
    configuration.wireObserver = { direction, message in
        if direction == .sent, message["method"] == .string("libfx/catalog") { await gate.block() }
    }
    let engine = try await FxEngine.open(configuration: configuration)
    let update = Task { try await engine.upsertTools([catalogTool("other", calls: calls)]) }
    await gate.wait()
    await #expect(throws: FxError.busy) { try await engine.checkpoint() }
    await #expect(throws: FxError.busy) { try await engine.prompt("busy") }
    let closing = Task { try await engine.close() }
    // Observe close admission before allowing the catalog response to return.
    while true {
        do { _ = try await engine.prompt("closing"); Issue.record("Prompt admitted during update"); break }
        catch FxError.closed { break }
        catch FxError.busy { await Task.yield() }
    }
    await gate.open()
    try await update.value
    try await closing.value
    await #expect(throws: FxError.closed) { try await engine.upsertTools([]) }
}

@Test func runtimeCatalogSearchSharesTheResidentCapacityAtOpen() async throws {
    let calls = CatalogCalls()
    let tools = (0..<64).map { index in
        FxTool(name: "resident_\(index)", description: "Resident", inputSchema: .object(["type": .string("object")]), isIdempotent: true) { input, _ in
            await calls.record(input); return "called"
        }
    }
    var configuration = FxConfiguration(apiKey: "fixture", model: "swift/catalog", tools: tools, httpClient: CatalogHTTP(actions: []))
    configuration.toolSearchEnabled = true
    do { let engine = try await FxEngine.open(configuration: configuration); try await engine.close(); Issue.record("Resident capacity ignored search tool") }
    catch {}
}

private actor MessagesCatalogHTTP: FxHTTPClient {
    var requests: [Data] = []
    var step = 0
    func send(_ request: URLRequest) async throws -> FxHTTPResponse {
        #expect(request.url?.path == "/v1/messages")
        #expect(request.value(forHTTPHeaderField: "anthropic-beta") == "inline-tools-2026-09-15")
        requests.append(request.httpBody!)
        let phase = step % 3
        step += 1
        var events: [JSONValue] = []
        if phase < 2 {
            let name = phase == 0 ? "tool_search" : "action_42"
            let args: JSONValue = phase == 0 ? .object(["query": .string("select:action_42")]) : .object(["value": .string("native")])
            let arguments = String(decoding: try JSONEncoder().encode(args), as: UTF8.self)
            events = [
                .object(["type": .string("content_block_start"), "index": .number(0), "content_block": .object(["type": .string("tool_use"), "id": .string("call-\(step)"), "name": .string(name), "input": .object([:])])]),
                .object(["type": .string("content_block_delta"), "index": .number(0), "delta": .object(["type": .string("input_json_delta"), "partial_json": .string(arguments)])]),
                .object(["type": .string("content_block_stop"), "index": .number(0)]),
            ]
        } else {
            events = [
                .object(["type": .string("content_block_start"), "index": .number(0), "content_block": .object(["type": .string("text"), "text": .string("")])]),
                .object(["type": .string("content_block_delta"), "index": .number(0), "delta": .object(["type": .string("text_delta"), "text": .string("done")])]),
                .object(["type": .string("content_block_stop"), "index": .number(0)]),
            ]
        }
        events.append(.object(["type": .string("message_delta"), "delta": .object(["stop_reason": .string(phase < 2 ? "tool_use" : "end_turn")]), "usage": .object(["output_tokens": .number(10)])]))
        events.append(.object(["type": .string("message_stop")]))
        let stream = try events.map { "data: " + String(decoding: try JSONEncoder().encode($0), as: UTF8.self) + "\n\n" }.joined()
        return FxHTTPResponse(statusCode: 200, body: AsyncThrowingStream { $0.yield(Data(stream.utf8)); $0.finish() })
    }
}

@Test func runtimeCatalogAnthropicLoadsDefinitionsWithoutChangingPrefix() async throws {
    let calls = CatalogCalls()
    let http = MessagesCatalogHTTP()
    let provider = try FxCustomProvider(name: "messagesfixture", baseURL: URL(string: "https://messages.example/v1")!, models: ["claude-fixture": .init(contextWindow: 100000, maxOutputTokens: 1024)], apiProtocol: .anthropicMessages)
    let engine = try await FxEngine.open(configuration: FxConfiguration(provider: .custom(provider), model: "claude-fixture", tools: [catalogTool("action_42", calls: calls)], httpClient: http))
    try await drainCatalogTurn(try await engine.prompt("Find and run action"))
    #expect(await calls.inputs == [.object(["value": .string("native")])])
    try await engine.upsertTools([catalogTool("added", calls: calls)])
    try await drainCatalogTurn(try await engine.prompt("Run again"))
    try await engine.removeTools(named: ["added"])
    let checkpoint = try await engine.checkpoint()
    try await engine.close()
    let restored = try await FxEngine.open(configuration: FxConfiguration(provider: .custom(provider), model: "claude-fixture", tools: [catalogTool("action_42", calls: calls)], httpClient: http), checkpoint: checkpoint)
    try await drainCatalogTurn(try await restored.prompt("Run after restore"))
    try await restored.close()
    let requests = await http.requests
    let tools = try catalogRawArray("tools", in: requests[0])
    for body in requests { #expect(try catalogRawArray("tools", in: body) == tools) }
    let initial = try catalogRawArray("messages", in: requests[0])
    #expect(try catalogRawArray("messages", in: requests[2]).starts(with: initial.dropLast()))
    #expect(String(decoding: requests[1], as: UTF8.self).contains("tool_addition"))
}
