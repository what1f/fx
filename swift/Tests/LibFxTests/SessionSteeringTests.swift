import Foundation
import Testing
import CSQLite
@testable import LibFx

private actor SteeringHTTP: FxHTTPClient {
    enum Mode { case streaming, streamingTwice, tool, immediate }
    let mode: Mode
    private(set) var bodies: [String] = []
    private var streams: [Int: AsyncThrowingStream<Data, any Error>.Continuation] = [:]
    init(_ mode: Mode) { self.mode = mode }
    func send(_ request: URLRequest) async throws -> FxHTTPResponse {
        if request.httpMethod == "GET" {
            return response(#"{"data":[{"id":"swift/steer","type":"language","tags":["vision","tool-use"]}]}"#)
        }
        bodies.append(String(decoding: request.httpBody ?? Data(), as: UTF8.self))
        if bodies.count == 1 && mode == .streaming || bodies.count <= 2 && mode == .streamingTwice && bodies.last?.contains("keep it small") == false {
            let (body, continuation) = AsyncThrowingStream<Data, any Error>.makeStream()
            continuation.yield(Data("data: {\"type\":\"text-delta\",\"delta\":\"partial\"}\n\n".utf8))
            let id = bodies.count
            streams[id] = continuation
            return FxHTTPResponse(statusCode: 200, body: body, cancel: { Task { await self.stopStream(id) } })
        }
        let frames = bodies.count == 1 && mode == .tool
            ? "data: {\"type\":\"tool-call\",\"toolCallId\":\"lookup-1\",\"toolName\":\"lookup\",\"input\":{}}\n\ndata: {\"type\":\"finish\",\"finishReason\":{\"unified\":\"tool-calls\",\"raw\":\"tool-calls\"}}\n\n"
            : "data: {\"type\":\"text-delta\",\"delta\":\"complete\"}\n\ndata: {\"type\":\"finish\",\"finishReason\":{\"unified\":\"stop\",\"raw\":\"stop\"}}\n\n"
        return response(frames + "data: [DONE]\n\n")
    }
    private func response(_ text: String) -> FxHTTPResponse {
        FxHTTPResponse(statusCode: 200, body: AsyncThrowingStream { $0.yield(Data(text.utf8)); $0.finish() })
    }
    private func stopStream(_ id: Int) { streams.removeValue(forKey: id)?.finish() }
    func waitForRequest() async { while bodies.isEmpty { await Task.yield() } }
}

private actor SteeringGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var wasCancelled = false
    func enter() async { await withCheckedContinuation { continuation = $0 } }
    func waitForEntry() async { while continuation == nil { await Task.yield() } }
    func release() { continuation?.resume(); continuation = nil }
    func noteCancellation() { wasCancelled = true }
    func waitForCancellation() async { while !wasCancelled { await Task.yield() } }
}

@Suite(.serialized, .timeLimit(.minutes(1))) struct SessionSteeringTests {
    private func configuration(_ http: SteeringHTTP, tools: [FxTool] = []) -> FxConfiguration {
        FxConfiguration(apiKey: "test-key", model: "swift/steer", tools: tools, httpClient: http)
    }

    @Test func textInterruptsStreamingAndKeepsOnePublicTurn() async throws {
        let http = SteeringHTTP(.streaming), store = try FxSessionStore()
        let agent = try FxAgent(configuration: configuration(http), store: store)
        let session = try await agent.session(id: "s")
        let turn = try await session.prompt("start", id: "prompt")
        await http.waitForRequest()
        let receipt = try await session.steer("make it blue", id: "public-steer")
        #expect(receipt.id == "public-steer")
        #expect(try await turn.result.stopReason == .endTurn)
        try await agent.close()
        #expect(await http.bodies.count == 2)
        #expect(await http.bodies.last?.contains("make it blue") == true)
        let entries = try await store.entries(session: "s", agent: "default", after: 0)
        #expect(entries.filter { if case .started = $0.event { return true }; return false }.count == 1)
        #expect(entries.contains { if case .update(_, .userMessage(_, id: "public-steer")) = $0.event { return true }; return false })
        try await store.close()
    }

    @Test func idleSteerRunsOnceAndMessageKindsCannotReuseAnID() async throws {
        let http = SteeringHTTP(.immediate), store = try FxSessionStore()
        let agent = try FxAgent(configuration: configuration(http), store: store)
        let session = try await agent.session(id: "s")
        _ = try await session.steer("idle guidance", id: "guide")
        _ = try await session.steer("ignored retry", id: "guide")
        let after = try await session.prompt("after guidance", id: "prompt")
        #expect(try await after.result.stopReason == .endTurn)
        await #expect(throws: FxSessionError.messageIDInUse) { try await session.prompt("collision", id: "guide") }
        await #expect(throws: FxSessionError.messageIDInUse) { try await session.steer("collision", id: "prompt") }
        try await agent.close()
        #expect(await http.bodies.count == 2)
        #expect(await http.bodies.last?.contains("idle guidance") == true)
        #expect(await http.bodies.last?.contains("ignored retry") == false)
        try await store.close()
    }

    @Test func cancellationHandsUnplacedSteeringBackToTheQueue() async throws {
        let gate = SteeringGate(), http = SteeringHTTP(.tool), store = try FxSessionStore()
        let tool = FxTool(name: "lookup", description: "Look up", inputSchema: .object(["type": .string("object")]), isIdempotent: true) { _, _ in
            await withTaskCancellationHandler { await gate.enter() } onCancel: { Task { await gate.noteCancellation() } }
            return "looked up"
        }
        let agent = try FxAgent(configuration: configuration(http, tools: [tool]), store: store)
        let session = try await agent.session(id: "s")
        let turn = try await session.prompt("lookup", id: "prompt")
        await gate.waitForEntry()
        _ = try await session.steer("after cancellation", id: "guide")
        _ = try await session.steer("and keep the second guidance", id: "guide-2")
        #expect(try await store.databaseValueForSteeringTest(session: "s", id: "guide") == 1)
        #expect(try await store.databaseValueForSteeringTest(session: "s", id: "guide-2") == 1)
        try await session.cancel()
        await gate.waitForCancellation()
        await gate.release()
        #expect(try await turn.result.stopReason == .cancelled)
        let after = try await session.prompt("after everything", id: "after")
        #expect(try await after.result.stopReason == .endTurn)
        try await agent.close()
        #expect(await http.bodies.last?.contains("after cancellation") == true)
        #expect(await http.bodies.last?.contains("and keep the second guidance") == true)
        let entries = try await store.entries(session: "s", agent: "default", after: 0)
        #expect(entries.contains { if case .started(id: "guide", sessionID: _) = $0.event { return true }; return false })
        #expect(!entries.contains { if case .started(id: "guide-2", sessionID: _) = $0.event { return true }; return false })
        try await store.close()
    }

    @Test func imageSteeringEndsTheCurrentTurnAndOwnsLaterTextSteering() async throws {
        let http = SteeringHTTP(.streamingTwice), store = try FxSessionStore()
        let agent = try FxAgent(configuration: configuration(http), store: store)
        let session = try await agent.session(id: "s")
        let original = try await session.prompt("start", id: "prompt")
        await http.waitForRequest()
        let png = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jP0cAAAAASUVORK5CYII="
        let image = FxImage(data: try #require(Data(base64Encoded: png)), format: .png)
        _ = try await session.steer([.text("match this"), .image(image)], id: "image")
        _ = try await session.steer("keep it small", id: "guide")
        #expect(try await original.result.stopReason != .endTurn)
        try await agent.close()
        let bodies = await http.bodies
        #expect(bodies.last?.contains("match this") == true && bodies.last?.contains(png) == true)
        #expect(bodies.last?.contains("keep it small") == true)
        let entries = try await store.entries(session: "s", agent: "default", after: 0)
        let starts = entries.compactMap { if case .started(let id, _) = $0.event { return id }; return nil }
        #expect(starts == ["prompt", "image"])
        try await store.close()
    }

    @Test func localSteerReachesTheNextRequestWithoutAPollingDelay() async throws {
        let gate = SteeringGate(), http = SteeringHTTP(.tool), store = try FxSessionStore()
        let tool = FxTool(name: "lookup", description: "Look up", inputSchema: .object(["type": .string("object")]), isIdempotent: true) { _, _ in
            await gate.enter(); return "looked up"
        }
        let agent = try FxAgent(configuration: configuration(http, tools: [tool]), store: store)
        let session = try await agent.session(id: "s")
        let turn = try await session.prompt("lookup", id: "prompt")
        await gate.waitForEntry()
        _ = try await session.steer("immediate guidance", id: "guide")
        #expect(try await store.databaseValueForSteeringTest(session: "s", id: "guide") == 1)
        await gate.release()
        #expect(try await turn.result.stopReason == .endTurn)
        #expect(await http.bodies.count == 2)
        #expect(await http.bodies.last?.contains("immediate guidance") == true)
        try await agent.close()
        try await store.close()
    }

    @Test(arguments: [false, true]) func localCancellationPrecedesAnImmediatelyReleasedTool(wholeSession: Bool) async throws {
        let gate = SteeringGate(), http = SteeringHTTP(.tool), store = try FxSessionStore()
        let tool = FxTool(name: "lookup", description: "Look up", inputSchema: .object(["type": .string("object")]), isIdempotent: true) { _, _ in
            await gate.enter(); return "looked up"
        }
        let agent = try FxAgent(configuration: configuration(http, tools: [tool]), store: store)
        let session = try await agent.session(id: "s")
        let turn = try await session.prompt("lookup", id: "prompt")
        await gate.waitForEntry()
        if wholeSession { try await session.cancel() } else { try await turn.cancel() }
        await gate.release()
        #expect(try await turn.result.stopReason == .cancelled)
        let fresh = try await session.prompt("still usable", id: "fresh")
        #expect(try await fresh.result.stopReason == .endTurn)
        try await agent.close()
        try await store.close()
    }

    @Test func aSeparateStoreConnectionSteersTheCurrentWorker() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("sessions.sqlite")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let gate = SteeringGate(), http = SteeringHTTP(.tool)
        let firstStore = try FxSessionStore(url: url), secondStore = try FxSessionStore(url: url)
        let tool = FxTool(name: "lookup", description: "Look up", inputSchema: .object(["type": .string("object")]), isIdempotent: true) { _, _ in
            await gate.enter(); return "looked up"
        }
        let first = try FxAgent(configuration: configuration(http, tools: [tool]), store: firstStore)
        let second = try FxAgent(configuration: configuration(http, tools: [tool]), store: secondStore)
        let source = try await first.session(id: "s"), remote = try await second.session(id: "s")
        let turn = try await source.prompt("lookup", id: "prompt")
        await gate.waitForEntry()
        _ = try await remote.steer("from another connection", id: "guide")
        while try await secondStore.databaseValueForSteeringTest(session: "s", id: "guide") == 0 { await Task.yield() }
        await gate.release()
        #expect(try await turn.result.stopReason == .endTurn)
        try await first.close()
        try await second.close()
        #expect(await http.bodies.count == 2)
        #expect(await http.bodies.last?.contains("from another connection") == true)
        try await firstStore.close()
        try await secondStore.close()
    }
}

private extension FxSessionStore {
    func databaseValueForSteeringTest(session: String, id: String) throws -> Int {
        try database.statement("SELECT accepted FROM fx_inputs WHERE session=? AND id=?", [.text(session), .text(id)]) { statement in
            guard try database.step(statement) else { throw FxSessionError.notFound }
            return Int(sqlite3_column_int(statement, 0))
        }
    }
}
