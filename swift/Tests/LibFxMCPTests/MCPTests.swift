import Foundation
import Logging
import MCP
import Testing
@testable import LibFx
@testable import LibFxMCP

actor FixtureTransport: Transport {
    let logger: Logger = { var value = Logger(label: "libfx.mcp.test"); value.logLevel = .critical; return value }()
    let stream: AsyncThrowingStream<Data, Error>
    let continuation: AsyncThrowingStream<Data, Error>.Continuation
    var requests: [JSONValue] = []
    var disconnects = 0
    var catalog: [JSONValue]
    var callResult: JSONValue
    var holdCalls: Bool
    var holdInitialize: Bool
    var repeatCursor: Bool
    var resourceText: String

    init(catalog: [JSONValue] = [FixtureTransport.tool("echo")],
         result: JSONValue = .object(["content": .array([.object(["type": .string("text"), "text": .string("echoed")])])]),
         holdCalls: Bool = false, holdInitialize: Bool = false, repeatCursor: Bool = false, resourceText: String = "resource context") {
        let pair = AsyncThrowingStream<Data, Error>.makeStream()
        stream = pair.stream; continuation = pair.continuation
        self.catalog = catalog; callResult = result; self.holdCalls = holdCalls
        self.holdInitialize = holdInitialize; self.repeatCursor = repeatCursor
        self.resourceText = resourceText
    }
    static func tool(_ name: String) -> JSONValue {
        .object(["name": .string(name), "description": .string("Full description"), "inputSchema": .object(["type": .string("object")]),
                 "annotations": .object(["idempotentHint": .bool(true)])])
    }
    func connect() {}
    func disconnect() { disconnects += 1; continuation.finish() }
    func receive() -> AsyncThrowingStream<Data, Error> { stream }
    func send(_ data: Data) throws {
        let request = try JSONDecoder().decode(JSONValue.self, from: data)
        requests.append(request)
        guard let id = request["id"], let method = request["method"]?.string else { return }
        let result: JSONValue
        switch method {
        case "initialize":
            if holdInitialize { return }
            result = .object(["protocolVersion": request["params"]?["protocolVersion"] ?? .string("2025-11-25"),
                "capabilities": .object(["tools": .object([:]), "resources": .object([:]), "prompts": .object([:])]),
                "serverInfo": .object(["name": .string("fixture"), "version": .string("1")])])
        case "tools/list":
            result = repeatCursor ? .object(["tools": .array([]), "nextCursor": .string("same")]) : .object(["tools": .array(catalog)])
        case "tools/call": if holdCalls { return }; result = callResult
        case "resources/read": result = .object(["contents": .array([.object(["uri": .string("memory://fixture"), "text": .string(resourceText)])])])
        case "prompts/get": result = .object(["messages": .array([.object(["role": .string("user"), "content": .object(["type": .string("text"), "text": .string("prompt context")])])])])
        default: throw FxError.protocolViolation("Unexpected MCP fixture request")
        }
        try respond(id: id, result: result)
    }
    func respond(id: JSONValue, result: JSONValue) throws {
        continuation.yield(try JSONEncoder().encode(JSONValue.object(["jsonrpc": .string("2.0"), "id": id, "result": result])))
    }
    func hasRequest(_ method: String) -> Bool { requests.contains { $0["method"]?.string == method } }
    func calls() -> [JSONValue] { requests.filter { $0["method"]?.string == "tools/call" } }
}

private func waitForRequest(_ method: String, on transport: FixtureTransport) async throws {
    for _ in 0..<1000 {
        if await transport.hasRequest(method) { return }
        try await Task.sleep(for: .milliseconds(1))
    }
    throw FxError.protocolViolation("MCP fixture did not receive request")
}

@Test func mcpAdapterUsesAHostConfiguredClient() async throws {
    let transport = FixtureTransport()
    let client = Client(name: "host-app", version: "2")
    let adapter = try await FxMCPAdapter.connect(transport: transport, client: client)
    let initialize = try #require(await transport.requests.first { $0["method"] == .string("initialize") })
    #expect(initialize["params"]?["clientInfo"]?["name"] == .string("host-app"))
    #expect(initialize["params"]?["clientInfo"]?["version"] == .string("2"))
    await adapter.close()
    #expect(await transport.disconnects == 1)
}

@Test func mcpAdapterLoadsContextSanitizesNamesAndKeepsRemoteIdentity() async throws {
    let transport = FixtureTransport(catalog: [FixtureTransport.tool("a.b"), FixtureTransport.tool("a/b")])
    let adapter = try await FxMCPAdapter.connect(transport: transport, prefix: "mcp_", resources: ["memory://fixture"],
        prompts: [.init(name: "fixture", arguments: ["topic": "review"])], propagateCorrelation: true)
    #expect(adapter.tools.map(\.name) == ["mcp_a_b", "mcp_a_b_2"])
    #expect(adapter.tools.allSatisfy { !$0.isIdempotent && $0.description == "Full description" })
    #expect(adapter.instructions == "<mcp_resource>\nresource context\n</mcp_resource>\n\n<mcp_prompt>\nprompt context\n</mcp_prompt>")
    let result = try await adapter.tools[1].execute(.object(["value": .string("hello")]), FxToolContext(executionID: "call", sessionID: "session", turnID: "turn"))
    #expect(result.text == "echoed")
    let call = try #require(await transport.calls().first)
    #expect(call["params"]?["name"] == .string("a/b"))
    #expect(call["params"]?["_meta"]?["libfx/correlationId"]?.string.flatMap(UUID.init(uuidString:)) != nil)
    #expect(call["params"]?["_meta"]?["progressToken"] == nil)
    await adapter.close(); await adapter.close()
    #expect(await transport.disconnects == 1)
    await #expect(throws: FxMCPError.closed) {
        try await adapter.tools[0].execute(.object([:]), FxToolContext(executionID: "call", sessionID: "session", turnID: "turn"))
    }
}

@Test func mcpAdapterRejectsInvalidCatalogsPaginationAndPrefixes() async throws {
    let invalidPrefix = FixtureTransport()
    await #expect(throws: FxMCPError.invalidPrefix) { try await FxMCPAdapter.connect(transport: invalidPrefix, prefix: ".") }
    #expect(await invalidPrefix.requests.isEmpty)
    for catalog in [[FixtureTransport.tool("echo"), FixtureTransport.tool("echo")], (0..<65).map { FixtureTransport.tool(String($0)) }, [FixtureTransport.tool("")]] {
        let transport = FixtureTransport(catalog: catalog)
        await #expect(throws: FxMCPError.invalidCatalog) { try await FxMCPAdapter.connect(transport: transport) }
        #expect(await transport.disconnects == 1)
    }
    let looping = FixtureTransport(repeatCursor: true)
    await #expect(throws: FxMCPError.invalidPagination) { try await FxMCPAdapter.connect(transport: looping) }
    #expect(await looping.disconnects == 1)
}

@Test func mcpAdapterPreservesImagesStructuredContentAndErrorStatus() throws {
    let image = Data([1, 2, 3])
    let result = CallTool.Result(content: [
        .text(text: "caption", annotations: nil, _meta: nil),
        .image(data: image.base64EncodedString(), mimeType: "image/png", annotations: nil, _meta: nil),
        .resource(resource: .binary(image, uri: "memory://image", mimeType: "image/jpeg")),
    ], structuredContent: .object(["label": .string("screenshot")]), isError: true)
    let converted = try FxMCPAdapter.toolResult(result)
    #expect(converted.text == "caption\n{\"label\":\"screenshot\"}")
    #expect(converted.images == [FxImage(data: image, format: .png), FxImage(data: image, format: .jpeg)])
    #expect(converted.isError)
    #expect(throws: FxMCPError.invalidImage) {
        try FxMCPAdapter.toolResult(.init(content: [.image(data: "invalid", mimeType: "image/png", annotations: nil, _meta: nil)]))
    }
}

@Test func mcpCancellationStopsRemoteCallAndIgnoresItsLateReply() async throws {
    let transport = FixtureTransport(holdCalls: true)
    let adapter = try await FxMCPAdapter.connect(transport: transport)
    let task = Task { try await adapter.tools[0].execute(.object([:]), FxToolContext(executionID: "call", sessionID: "session", turnID: "turn")) }
    try await waitForRequest("tools/call", on: transport)
    task.cancel()
    await #expect(throws: CancellationError.self) { try await task.value }
    try await waitForRequest("notifications/cancelled", on: transport)
    let call = try #require(await transport.calls().first)
    try await transport.respond(id: try #require(call["id"]), result: .object(["content": .array([])]))
    await adapter.close()
    #expect(await transport.disconnects == 1)
}

@Test func mcpTransportSuppressesCancellationBeforeClientRegistration() async throws {
    let base = FixtureTransport()
    let transport = CancellableTransport(base, logger: base.logger)
    try await transport.connect()
    let id = ID.string("early")
    await transport.register(id)
    await transport.cancel(id)
    let data = Data(#"{"jsonrpc":"2.0","id":"early","method":"tools/call","params":{"name":"echo"}}"#.utf8)
    await #expect(throws: CancellationError.self) { try await transport.send(data) }
    #expect(await base.requests.isEmpty)
    await transport.disconnect()
}

@Test func mcpInstructionLimitIncludesFramingAndUTF8Bytes() async throws {
    let framing = "<mcp_resource>\n\n</mcp_resource>".utf8.count
    let transport = FixtureTransport(resourceText: String(repeating: "中", count: (64 * 1024 - framing) / 3))
    let adapter = try await FxMCPAdapter.connect(transport: transport, resources: ["memory://fixture"])
    #expect(adapter.instructions.utf8.count <= 64 * 1024)
    await adapter.close()
    let large = FixtureTransport(resourceText: String(repeating: "中", count: (64 * 1024 - framing) / 3 + 1))
    await #expect(throws: FxMCPError.instructionsTooLarge) { try await FxMCPAdapter.connect(transport: large, resources: ["memory://fixture"]) }
    #expect(await large.disconnects == 1)
}

@Test func mcpAlreadyCancelledToolDoesNotDispatchAndCloseStopsPendingCalls() async throws {
    let transport = FixtureTransport(holdCalls: true)
    let adapter = try await FxMCPAdapter.connect(transport: transport)
    let cancelled = Task {
        withUnsafeCurrentTask { $0?.cancel() }
        return try await adapter.tools[0].execute(.object([:]), FxToolContext(executionID: "early", sessionID: "session", turnID: "turn"))
    }
    await #expect(throws: CancellationError.self) { try await cancelled.value }
    #expect(await transport.calls().isEmpty)
    let pending = Task { try await adapter.tools[0].execute(.object([:]), FxToolContext(executionID: "pending", sessionID: "session", turnID: "turn")) }
    try await waitForRequest("tools/call", on: transport)
    await adapter.close()
    await #expect(throws: FxMCPError.closed) { try await pending.value }
    #expect(await transport.disconnects == 1)
}

@Test func mcpConnectCancellationClosesAWaitingHandshake() async throws {
    let transport = FixtureTransport(holdInitialize: true)
    let task = Task { try await FxMCPAdapter.connect(transport: transport) }
    try await waitForRequest("initialize", on: transport)
    task.cancel()
    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(await transport.disconnects == 1)
}

private actor MCPModelHTTP: FxHTTPClient {
    private(set) var posts = 0
    let toolName: String
    init(toolName: String = "mcp_echo") { self.toolName = toolName }
    func send(_ request: URLRequest) async throws -> FxHTTPResponse {
        let payload: String
        if request.httpMethod == "GET" {
            payload = #"{"data":[{"id":"swift/mcp","type":"language","tags":["tool-use"]}]}"#
        } else {
            posts += 1
            payload = "data: {\"type\":\"tool-call\",\"toolCallId\":\"mcp-call\",\"toolName\":\"\(toolName)\",\"input\":{\"value\":\"hello\"}}\n\ndata: {\"type\":\"finish\",\"finishReason\":{\"unified\":\"tool-calls\",\"raw\":\"tool-calls\"}}\n\ndata: [DONE]\n\n"
        }
        if posts > 1 {
            return FxHTTPResponse(statusCode: 200, body: AsyncThrowingStream {
                $0.yield(Data("data: {\"type\":\"text-delta\",\"delta\":\"done\"}\n\ndata: {\"type\":\"finish\",\"finishReason\":{\"unified\":\"stop\",\"raw\":\"stop\"}}\n\ndata: [DONE]\n\n".utf8))
                $0.finish()
            })
        }
        return FxHTTPResponse(statusCode: 200, body: AsyncThrowingStream { $0.yield(Data(payload.utf8)); $0.finish() })
    }
}

@Test func nativeEngineCancellationReachesTheMCPServer() async throws {
    let transport = FixtureTransport(holdCalls: true)
    let mcp = try await FxMCPAdapter.connect(transport: transport, prefix: "mcp_")
    let http = MCPModelHTTP()
    let events = MCPObservations()
    let engine = try await FxEngine.open(configuration: FxConfiguration(apiKey: "test", model: "swift/mcp", tools: mcp.tools, httpClient: http,
        observation: FxObservationOptions(onEvent: events.record)))
    let turn = try await engine.prompt("Use MCP")
    let reader = Task { for try await _ in turn {} }
    try await waitForRequest("tools/call", on: transport)
    await turn.cancel()
    #expect(try await turn.result.stopReason == .cancelled)
    _ = await reader.result
    try await waitForRequest("notifications/cancelled", on: transport)
    let spans = events.events.filter { [.mcpStarted, .mcpEnded].contains($0.kind) }
    #expect(spans.map(\.kind) == [.mcpStarted, .mcpEnded])
    #expect(spans.last?.data["status"] == .string("cancelled"))
    #expect(spans.first?.data["operationId"] == spans.last?.data["operationId"])
    #expect(await http.posts == 1)
    try await engine.close()
    await mcp.close()
    #expect(await transport.disconnects == 1)
}

private final class MCPObservations: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [FxObservation] = []
    var events: [FxObservation] { lock.withLock { stored } }
    func record(_ event: FxObservation) { lock.withLock { stored.append(event) } }
}

@Test func nativeMCPSpansRetainServerToolAndCorrelationIdentity() async throws {
    for isError in [false, true] {
        let transport = FixtureTransport(catalog: [FixtureTransport.tool("remote.echo")], result: .object([
            "content": .array([.object(["type": .string("text"), "text": .string("private-response")])]),
            "isError": .bool(isError),
        ]))
        let mcp = try await FxMCPAdapter.connect(transport: transport, prefix: "mcp_", propagateCorrelation: true,
                                                serverName: isError ? "named-server" : nil)
        let events = MCPObservations()
        let parent = try FxObservationParent(rootSessionID: "root", sessionID: "parent", turnID: "parent-turn", callID: "parent-call")
        let engine = try await FxEngine.open(configuration: FxConfiguration(apiKey: "test", model: "swift/mcp", tools: mcp.tools,
            httpClient: MCPModelHTTP(toolName: "mcp_remote_echo"),
            observation: FxObservationOptions(parent: parent, onEvent: events.record)))
        let turn = try await engine.prompt("Use MCP")
        for try await _ in turn {}
        #expect(try await turn.result.stopReason == .endTurn)
        try await engine.close()
        await mcp.close()
        let spans = events.events.filter { [.mcpStarted, .mcpRequest, .mcpEnded].contains($0.kind) }
        #expect(spans.map(\.kind) == [.mcpStarted, .mcpRequest, .mcpEnded])
        let start = try #require(spans.first), end = try #require(spans.last)
        #expect(start.data["server"] == .string(isError ? "named-server" : "fixture"))
        #expect(start.data["tool"] == .string("remote.echo"))
        #expect(start.data["callId"] == .string("mcp-call"))
        #expect(start.data["operationId"] == end.data["operationId"])
        #expect(end.data["status"] == .string(isError ? "failure" : "success"))
        let nativeStart = try #require(events.events.first { $0.kind == .toolStarted })
        #expect(start.executionID == nativeStart.executionID)
        #expect(start.turnID == nativeStart.turnID)
        #expect(spans.allSatisfy { $0.rootSessionID == "root" && $0.parentSessionID == "parent" && $0.parentCallID == "parent-call" && $0.parentTurnID == "parent-turn" })
        let calls = await transport.calls()
        #expect(calls.count == 1)
        let correlation = try #require(calls.first?["params"]?["_meta"]?["libfx/correlationId"]?.string)
        #expect(UUID(uuidString: correlation) != nil && correlation == correlation.lowercased())
        #expect(spans[1].data["requestId"] == .string(correlation))
        #expect(!String(decoding: try JSONEncoder().encode(spans), as: UTF8.self).contains("private-response"))
        let positions = events.events.map(\.kind)
        #expect(try #require(positions.firstIndex(of: .toolStarted)) < #require(positions.firstIndex(of: .mcpStarted)))
        #expect(try #require(positions.firstIndex(of: .mcpEnded)) < #require(positions.firstIndex(of: .toolEnded)))
    }
}
