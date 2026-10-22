import Foundation
import Testing
@testable import LibFx

private actor HandoffTool {
    private(set) var calls = 0
    private(set) var cancelled = false
    func run() async throws -> FxToolResult {
        calls += 1
        do { try await Task.sleep(for: .seconds(30)) }
        catch { cancelled = true; throw error }
        return "stored"
    }
    func waitUntilStarted() async { while calls == 0 { await Task.yield() } }
}

private actor HandoffHTTP: FxHTTPClient {
    private(set) var requests: [String] = []
    func send(_ request: URLRequest) async throws -> FxHTTPResponse {
        let text: String
        if request.httpMethod == "GET" {
            text = #"{"data":[{"id":"swift/handoff","type":"language","tags":["tool-use"]}]}"#
        } else {
            requests.append(String(decoding: request.httpBody ?? Data(), as: UTF8.self))
            let frames: [JSONValue] = requests.count == 1 ? [
                .object(["type": .string("tool-call"), "toolCallId": .string("write-1"), "toolName": .string("write"), "input": .object([:])]),
                .object(["type": .string("finish"), "finishReason": .object(["unified": .string("tool-calls"), "raw": .string("tool-calls")])]),
            ] : [
                .object(["type": .string("text-delta"), "delta": .string("resumed")]),
                .object(["type": .string("finish"), "finishReason": .object(["unified": .string("stop"), "raw": .string("stop")])]),
            ]
            text = try frames.map { "data: \(String(decoding: try JSONEncoder().encode($0), as: UTF8.self))\n\n" }.joined() + "data: [DONE]\n\n"
        }
        return FxHTTPResponse(statusCode: 200, body: AsyncThrowingStream { continuation in
            continuation.yield(Data(text.utf8)); continuation.finish()
        })
    }
}

@Test func handoffPreservesInterruptedTurnAndPreventsLaterWrites() async throws {
    let gateway = HandoffHTTP(), tool = HandoffTool(), store = FxMemoryPersistence()
    let configuration = FxConfiguration(
        apiKey: "test-key", model: "swift/handoff",
        tools: [FxTool(name: "write", description: "Write a record", inputSchema: .object(["type": .string("object")]), isIdempotent: false, writes: true) { _, _ in
            try await tool.run()
        }], httpClient: gateway, checkpointAfterBytes: 0
    )
    let engine = try await FxEngine.open(configuration: configuration, persistence: store)
    let turn = try await engine.prompt("original handoff input", id: "handoff-1")
    await tool.waitUntilStarted()
    _ = try await turn.steer("preserve pending steer", id: "steer-1")
    let before = await store.load()
    try await turn.handoff()
    for try await _ in turn {}
    #expect(try await turn.result.stopReason == .cancelled)
    #expect(await tool.cancelled)
    try await turn.handoff()
    await #expect(throws: FxError.handedOff) { try await engine.prompt("must not run") }
    await #expect(throws: FxError.handedOff) { try await engine.resume() }
    await #expect(throws: FxError.handedOff) { try await engine.saveCheckpoint() }
    try await engine.close()
    let after = await store.load()
    #expect(after.journal == before.journal)
    #expect(after.checkpoint == nil)
    let next = try await FxEngine.open(configuration: configuration, persistence: store)
    let recovery = try #require(await next.recoveryState)
    #expect(recovery.turnID == "handoff-1")
    #expect(recovery.runningCalls.map(\.executionID) == ["write-1"])
    let resumed = try #require(try await next.resume())
    for try await _ in resumed {}
    #expect(try await resumed.result.stopReason == .endTurn)
    #expect(await tool.calls == 1)
    let requests = await gateway.requests
    #expect(requests.count == 2)
    #expect(requests.last?.contains("original handoff input") == true)
    #expect(requests.last?.contains("preserve pending steer") == true)
    #expect(requests.last?.contains("may have partly run") == true)
    try await next.close()
}

@Test func handoffWithoutPersistenceLeavesTurnRunning() async throws {
    let gateway = HandoffHTTP(), tool = HandoffTool()
    let engine = try await FxEngine.open(configuration: FxConfiguration(
        apiKey: "test-key", model: "swift/handoff",
        tools: [FxTool(name: "write", description: "Write", inputSchema: .object(["type": .string("object")]), isIdempotent: false) { _, _ in
            try await tool.run()
        }], httpClient: gateway
    ))
    let turn = try await engine.prompt("write")
    await tool.waitUntilStarted()
    await #expect(throws: FxError.self) { try await turn.handoff() }
    #expect(await tool.cancelled == false)
    await turn.cancel()
    for try await _ in turn {}
    #expect(try await turn.result.stopReason == .cancelled)
    try await engine.close()
}

@Test func staleHandoffCannotStopANewerTurn() async throws {
    let gateway = HandoffHTTP()
    let engine = try await FxEngine.open(configuration: FxConfiguration(
        apiKey: "test-key", model: "swift/handoff", httpClient: gateway
    ), persistence: FxMemoryPersistence())
    let old = try await engine.prompt("first")
    for try await _ in old {}
    _ = try await old.result
    let next = try await engine.prompt("second")
    try await old.handoff()
    for try await _ in next {}
    #expect(try await next.result.stopReason == .endTurn)
    let final = try await engine.prompt("still usable")
    for try await _ in final {}
    #expect(try await final.result.stopReason == .endTurn)
    try await engine.close()
}
