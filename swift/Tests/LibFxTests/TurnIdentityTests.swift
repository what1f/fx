import Foundation
import Testing
@testable import LibFx

private actor IdentityGateway: FxHTTPClient {
    var requests: [String] = []
    var holdRequest = false
    let toolRounds: Int
    private var started = false

    init(holdRequest: Bool = false, toolRounds: Int = 0) {
        self.holdRequest = holdRequest
        self.toolRounds = toolRounds
    }

    func send(_ request: URLRequest) async throws -> FxHTTPResponse {
        let text: String
        if request.httpMethod == "GET" {
            text = #"{"data":[{"id":"swift/identity","type":"language"}]}"#
        } else {
            requests.append(String(decoding: request.httpBody ?? Data(), as: UTF8.self))
            started = true
            if holdRequest { try await Task.sleep(for: .seconds(30)) }
            if requests.count <= toolRounds {
                text = "data: {\"type\":\"tool-call\",\"toolCallId\":\"step-\(requests.count)\",\"toolName\":\"identity_step\",\"input\":{}}\n\ndata: {\"type\":\"finish\",\"finishReason\":{\"unified\":\"tool-calls\",\"raw\":\"tool-calls\"}}\n\ndata: [DONE]\n\n"
            } else {
                text = "data: {\"type\":\"text-delta\",\"delta\":\"saved answer\"}\n\ndata: {\"type\":\"finish\",\"finishReason\":{\"unified\":\"stop\",\"raw\":\"stop\"}}\n\ndata: [DONE]\n\n"
            }
        }
        return FxHTTPResponse(statusCode: 200, body: AsyncThrowingStream { continuation in
            continuation.yield(Data(text.utf8)); continuation.finish()
        })
    }

    func waitUntilRequested() async { while !started { await Task.yield() } }
}

private let identityStep = FxTool(
    name: "identity_step", description: "Record a step", inputSchema: .object(["type": .string("object")]), isIdempotent: true
) { _, _ in "step completed" }

@Test func completedTurnIDDoesNotReplayAfterSnapshotRestore() async throws {
    let gateway = IdentityGateway(), store = FxMemoryPersistence()
    let config = FxConfiguration(apiKey: "test-key", model: "swift/identity", httpClient: gateway, checkpointAfterBytes: 0)
    let first = try await FxEngine.open(configuration: config, persistence: store)
    let turn = try await first.prompt("original input", id: "stable-1")
    #expect(turn.id == "stable-1")
    for try await _ in turn {}
    _ = try await turn.result
    let duplicate = try await first.prompt("ignored duplicate input", id: "stable-1")
    for try await _ in duplicate { Issue.record("A completed retry must have no events") }
    #expect(try await duplicate.result.stopReason == .endTurn)
    await #expect(throws: FxError.noActiveTurn) { try await duplicate.steer("ignored") }
    #expect(try await duplicate.withdraw("unused") == .alreadyPlaced)
    await duplicate.cancel()
    try await first.close()
    let reopened = try await FxEngine.open(configuration: config, persistence: store)
    let retried = try await reopened.prompt("ignored after restore", id: "stable-1")
    #expect(retried.id == "stable-1")
    #expect(try await retried.result.stopReason == .endTurn)
    #expect(await gateway.requests.count == 1)
    let next = try await reopened.prompt("a new turn", id: "stable-2")
    for try await _ in next {}
    _ = try await next.result
    #expect(await gateway.requests.count == 2)
    try await reopened.close()
}

@Test func yieldedTurnSurvivesDiskSnapshotAndRepeatedYield() async throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("conversation.sqlite")
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let gateway = IdentityGateway(toolRounds: 2)
    let config = FxConfiguration(apiKey: "test-key", model: "swift/identity", tools: [identityStep], httpClient: gateway, checkpointAfterBytes: 0)
    let store = try FxSQLitePersistence(url: url)
    let engine = try await FxEngine.open(configuration: config, persistence: store)
    let first = try await engine.prompt("original yielded input", id: "yield-1", yieldAt: Date().addingTimeInterval(-1))
    for try await _ in first {}
    #expect(try await first.result.stopReason == .yielded)
    #expect(await engine.recoveryState?.turnID == "yield-1")
    #expect(await gateway.requests.count == 1)
    let repeated = try await engine.prompt("ignored retry content", id: "yield-1", yieldAt: Date().addingTimeInterval(-1))
    #expect(try await repeated.result.stopReason == .yielded)
    #expect(await gateway.requests.count == 2)
    let saved = try await store.load()
    #expect(saved.checkpoint != nil && saved.journal.isEmpty)
    try await engine.close()
    try await store.close()

    let reopened = try FxSQLitePersistence(url: url)
    let restored = try await FxEngine.open(configuration: config, persistence: reopened)
    #expect(await restored.recoveryState?.turnID == "yield-1")
    let resumed = try #require(try await restored.resume())
    #expect(resumed.id == "yield-1")
    for try await _ in resumed {}
    #expect(try await resumed.result.stopReason == .endTurn)
    #expect(await restored.recoveryState == nil)
    let bodies = await gateway.requests
    #expect(bodies.count == 3)
    #expect(bodies.last!.components(separatedBy: "original yielded input").count - 1 == 1)
    #expect(!bodies.last!.contains("ignored retry content"))
    let done = try await restored.prompt("ignored completed retry", id: "yield-1")
    #expect(try await done.result.stopReason == .endTurn)
    #expect(await gateway.requests.count == 3)
    try await restored.close()
    try await reopened.close()
}

@Test func newTurnCanReplaceAnInterruptedTurn() async throws {
    let gateway = IdentityGateway(toolRounds: 1)
    let engine = try await FxEngine.open(configuration: FxConfiguration(
        apiKey: "test-key", model: "swift/identity", tools: [identityStep], httpClient: gateway
    ), persistence: FxMemoryPersistence())
    let yielded = try await engine.prompt("old input", id: "old", yieldAt: Date().addingTimeInterval(-1))
    #expect(try await yielded.result.stopReason == .yielded)
    let next = try await engine.prompt("new input", id: "new")
    for try await _ in next {}
    #expect(try await next.result.stopReason == .endTurn)
    #expect(await engine.recoveryState == nil)
    #expect(await gateway.requests.count == 2)
    try await engine.close()
}

@Test func invalidTurnIdentityAndYieldDeadlineDoNotReachModel() async throws {
    let gateway = IdentityGateway()
    let config = FxConfiguration(apiKey: "test-key", model: "swift/identity", httpClient: gateway)
    let engine = try await FxEngine.open(configuration: config, persistence: FxMemoryPersistence())
    for id in ["", "contains space", "path/id", "中文", String(repeating: "x", count: 129)] {
        await #expect(throws: FxError.self) { try await engine.prompt("hello", id: id) }
    }
    for date in [Date(timeIntervalSince1970: 0), Date(timeIntervalSince1970: .infinity), Date(timeIntervalSince1970: .nan)] {
        await #expect(throws: FxError.self) { try await engine.prompt("hello", yieldAt: date) }
    }
    #expect(await gateway.requests.isEmpty)
    try await engine.close()
    let withoutStore = try await FxEngine.open(configuration: config)
    await #expect(throws: FxError.self) { try await withoutStore.prompt("hello", yieldAt: Date()) }
    try await withoutStore.close()
}

@Test func cancellingResultWaiterThrowsCancellationError() async throws {
    // The core can settle cancellation as either a result or an RPC error.
    for _ in 0..<20 {
        let gateway = IdentityGateway(holdRequest: true)
        let engine = try await FxEngine.open(configuration: FxConfiguration(apiKey: "test-key", model: "swift/identity", httpClient: gateway))
        let turn = try await engine.prompt("wait for cancellation")
        let waiting = Task { try await turn.result }
        await gateway.waitUntilRequested()
        waiting.cancel()
        await #expect(throws: CancellationError.self) { try await waiting.value }
        try await engine.close()
        #expect(await gateway.requests.count == 1)
    }
}
