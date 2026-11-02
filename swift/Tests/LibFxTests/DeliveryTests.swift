import Foundation
import Testing
@testable import LibFx

private actor DeliveryHTTP: FxHTTPClient {
    enum Mode { case loop, stall }
    let mode: Mode
    private(set) var requests = 0
    init(_ mode: Mode) { self.mode = mode }
    func send(_ request: URLRequest) async throws -> FxHTTPResponse {
        if request.httpMethod == "GET" {
            return response(#"{"data":[{"id":"swift/delivery","type":"language","tags":["tool-use"]}]}"#)
        }
        requests += 1
        let body = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
        if mode == .stall && !body.contains("fresh request") {
            try await Task.sleep(for: .seconds(60))
            throw CancellationError()
        }
        if mode == .loop && requests <= 3 {
            return response("data: {\"type\":\"tool-call\",\"toolCallId\":\"call-\(requests)\",\"toolName\":\"lookup\",\"input\":{}}\n\ndata: {\"type\":\"finish\",\"finishReason\":{\"unified\":\"tool-calls\",\"raw\":\"tool-calls\"}}\n\ndata: [DONE]\n\n")
        }
        return response("data: {\"type\":\"text-delta\",\"delta\":\"complete\"}\n\ndata: {\"type\":\"finish\",\"finishReason\":{\"unified\":\"stop\",\"raw\":\"stop\"}}\n\ndata: [DONE]\n\n")
    }
    private func response(_ text: String) -> FxHTTPResponse {
        FxHTTPResponse(statusCode: 200, body: AsyncThrowingStream { $0.yield(Data(text.utf8)); $0.finish() })
    }
}

private actor DeliveryCalls {
    private(set) var contexts: [FxToolContext] = []
    func append(_ context: FxToolContext) { contexts.append(context) }
}

@Suite(.serialized, .timeLimit(.minutes(1))) struct DeliveryTests {
    @Test func negativeDurationsAreRejected() throws {
        #expect(throws: FxError.self) { try FxDeliveryPolicy(maximumDuration: .milliseconds(-1)) }
        #expect(throws: FxError.self) { try FxDeliveryPolicy(maximumDuration: .seconds(1), reserve: .milliseconds(-1)) }
        _ = try FxDeliveryPolicy(maximumDuration: .zero, reserve: .zero)
    }

    @Test func cooperativeDeliveriesKeepOneTurnAndRunEachToolOnce() async throws {
        let http = DeliveryHTTP(.loop), calls = DeliveryCalls(), store = try FxSessionStore()
        let tool = FxTool(name: "lookup", description: "Look up", inputSchema: .object(["type": .string("object")]), isIdempotent: true) { _, context in
            await calls.append(context); return "looked up"
        }
        let agent = try FxAgent(configuration: FxConfiguration(apiKey: "test", model: "swift/delivery", tools: [tool], httpClient: http),
                                store: store, deliveryPolicy: FxDeliveryPolicy(maximumDuration: .zero, reserve: .zero))
        let session = try await agent.session(id: "conversation")
        let turn = try await session.prompt("loop", id: "public-turn")
        var text = ""
        for try await event in turn { if case .text(let delta) = event { text += delta } }
        #expect(text == "complete")
        #expect(try await turn.result.stopReason == .endTurn)
        try await agent.close()
        let entries = try await store.entries(session: "conversation", agent: "default", after: 0)
        #expect(entries.filter { if case .started = $0.event { return true }; return false }.count == 1)
        #expect(entries.filter { if case .yielded = $0.event { return true }; return false }.count == 3)
        #expect(entries.filter { if case .resumed = $0.event { return true }; return false }.count == 3)
        #expect(entries.filter { if case .ended = $0.event { return true }; return false }.count == 1)
        #expect(Set(entries.map(\.epoch)).count == 4)
        let contexts = await calls.contexts
        #expect(contexts.count == 3 && Set(contexts.map(\.executionID)).count == 3)
        #expect(contexts.allSatisfy { $0.turnID == "public-turn" && $0.sessionID == "conversation" })
        #expect(await http.requests == 4)
        try await store.close()
    }

    @Test func stalledModelStopsAfterThreeCutoffsAndSessionContinues() async throws {
        let http = DeliveryHTTP(.stall), store = try FxSessionStore()
        let agent = try FxAgent(configuration: FxConfiguration(apiKey: "test", model: "swift/delivery", httpClient: http),
                                store: store, deliveryPolicy: FxDeliveryPolicy(maximumDuration: .milliseconds(150), reserve: .milliseconds(100)))
        let session = try await agent.session(id: "conversation")
        let stalled = try await session.prompt("stall", id: "stalled")
        #expect(try await stalled.result.stopReason == .cancelled)
        #expect(await http.requests <= 4)
        let fresh = try await session.prompt("fresh request", id: "fresh")
        #expect(try await fresh.result.stopReason == .endTurn)
        try await agent.close()
        let entries = try await store.entries(session: "conversation", agent: "default", after: 0)
        #expect(entries.filter { if case .yielded(id: "stalled") = $0.event { return true }; return false }.count == 3)
        try await store.close()
    }

    @Test func cutoffCountsSurviveReopenAndResetOnlyWhenTheStepChanges() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("session.sqlite")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = try FxSessionStore(url: url)
        _ = try await store.accept(session: "s", agent: "a", id: "turn", content: [.text("run")], options: .init())
        let lease = try #require(try await store.claim(session: "s", agent: "a"))
        try await store.start(lease, input: #require(try await store.next(lease)))
        func progress(_ steps: Int) -> Data {
            Data("{\"events\":[{\"type\":\"turn_progress\",\"steps\":\(steps),\"data\":{\"tool_state\":\"running\"}}]}".utf8)
        }
        let first = try await store.appendJournal(lease, expected: nil, key: "one", data: progress(2))
        #expect(try await store.cutOffDelivery(lease, id: "turn") == 1)
        try await store.release(lease)
        try await store.close()
        let reopened = try FxSessionStore(url: url)
        let next = try #require(try await reopened.claim(session: "s", agent: "a"))
        #expect(try await reopened.deliveryCutoffs(next, id: "turn") == 1)
        let second = try await reopened.appendJournal(next, expected: first, key: "two", data: progress(2))
        #expect(try await reopened.cutOffDelivery(next, id: "turn") == 2)
        _ = try await reopened.appendJournal(next, expected: second, key: "three", data: progress(3))
        #expect(try await reopened.deliveryCutoffs(next, id: "turn") == 0)
        #expect(try await reopened.cutOffDelivery(next, id: "turn") == 1)
        await #expect(throws: FxPersistenceError.fenced) { try await reopened.cutOffDelivery(lease, id: "turn") }
        try await reopened.release(next)
        try await reopened.close()
    }

    @Test func cancellingAnOpenTurnBetweenDeliveriesLeavesTheSessionUsable() async throws {
        let http = DeliveryHTTP(.loop), store = try FxSessionStore()
        let configuration = FxConfiguration(apiKey: "test", model: "swift/delivery", tools: [
            FxTool(name: "lookup", description: "Look up", inputSchema: .object(["type": .string("object")]), isIdempotent: true) { _, _ in "looked up" },
        ], httpClient: http)
        _ = try await store.accept(session: "s", agent: "default", id: "open", content: [.text("loop")], options: .init())
        let lease = try #require(try await store.claim(session: "s", agent: "default"))
        try await store.start(lease, input: #require(try await store.next(lease)))
        let engine = try await FxEngine.open(configuration: configuration, sessionID: "s", persistence: SessionPersistence(store: store, lease: lease))
        let first = try await engine.prompt("loop", id: sessionCoreInputID("open"), yieldAt: Date(timeIntervalSince1970: 1))
        #expect(try await first.result.stopReason == .yielded)
        try await engine.close()
        try await store.release(lease)
        try await store.cancel(session: "s", agent: "default", id: "open")
        let agent = try FxAgent(configuration: configuration, store: store)
        let session = try await agent.session(id: "s")
        let resumed = try #require(try await session.resume())
        #expect(try await resumed.result.stopReason == .cancelled)
        let fresh = try await session.prompt("fresh request", id: "fresh")
        #expect(try await fresh.result.stopReason == .endTurn)
        try await agent.close()
        try await store.close()
    }
}
