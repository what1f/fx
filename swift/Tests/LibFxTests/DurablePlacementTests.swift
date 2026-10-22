import Foundation
import Testing
@testable import LibFx

private actor PlacementQueue: FxSessionQueue {
    private(set) var messages: [FxSessionWakeup] = []
    func enqueue(_ wakeup: FxSessionWakeup) { messages.append(wakeup) }
}

private actor PlacementHTTP: FxHTTPClient {
    enum Mode { case immediate, heldFirst, toolFirst }
    let mode: Mode
    let entered = AsyncResult<Void>()
    let release = AsyncResult<Void>()
    private(set) var bodies: [String] = []
    private(set) var cancellations = 0
    init(_ mode: Mode = .immediate) { self.mode = mode }
    func send(_ request: URLRequest) async throws -> FxHTTPResponse {
        #expect(request.httpMethod == "POST")
        bodies.append(String(decoding: request.httpBody ?? Data(), as: UTF8.self))
        await entered.resolve(.success(()))
        if bodies.count == 1 && mode == .heldFirst {
            do { try await release.wait() }
            catch { cancellations += 1; throw error }
        }
        let frames = bodies.count == 1 && mode == .toolFirst
            ? "data: {\"type\":\"tool-call\",\"toolCallId\":\"lookup-1\",\"toolName\":\"lookup\",\"input\":{}}\n\ndata: {\"type\":\"finish\",\"finishReason\":{\"unified\":\"tool-calls\",\"raw\":\"tool-calls\"}}\n\n"
            : "data: {\"type\":\"text-delta\",\"delta\":\"accepted\"}\n\ndata: {\"type\":\"finish\",\"finishReason\":{\"unified\":\"stop\",\"raw\":\"stop\"}}\n\n"
        return FxHTTPResponse(statusCode: 200, body: AsyncThrowingStream {
            $0.yield(Data((frames + "data: [DONE]\n\n").utf8)); $0.finish()
        })
    }
}

@Suite(.serialized, .timeLimit(.minutes(1))) struct DurablePlacementTests {
    private func configuration(_ http: PlacementHTTP, tools: [FxTool] = []) throws -> FxConfiguration {
        var configuration = FxConfiguration(apiKey: "fixture", model: "swift/placement", tools: tools, httpClient: http)
        configuration.modelCatalog = try FxModelCatalog(response: Data(#"{"data":[{"id":"swift/placement","type":"language","tags":["vision","tool-use"]}]}"#.utf8))
        return configuration
    }

    private func starts(_ entries: [FxSessionEntry]) -> [String] {
        entries.compactMap { if case .started(let id, _, _) = $0.event { return id }; return nil }
    }

    private func ends(_ entries: [FxSessionEntry]) -> [String] {
        entries.compactMap { if case .ended(let result) = $0.event { return result.id }; return nil }
    }

    @Test func twoWaitingPromptsPlaceLaterSteeringOnlyInTheSecondTurn() async throws {
        let store = try FxSessionStore(), queue = PlacementQueue(), http = PlacementHTTP(.heldFirst)
        let agent = try FxAgent(configuration: configuration(http), store: store, checkpointAfterBytes: nil, queue: queue)
        let session = try await agent.session(id: "two-waiting")
        let first = try await session.prompt("FIRST_PLACEMENT_TOKEN", id: "first")
        let second = try await session.prompt("SECOND_PLACEMENT_TOKEN", id: "second")
        _ = try await session.steer("LATE_GUIDANCE_TOKEN", id: "guide")
        #expect(await http.bodies.isEmpty)
        let wakeup = try #require(await queue.messages.first)
        let delivery = Task { try await agent.deliver(wakeup) }
        try await http.entered.wait()
        let firstBody = try #require(await http.bodies.first)
        #expect(firstBody.contains("FIRST_PLACEMENT_TOKEN"))
        #expect(!firstBody.contains("SECOND_PLACEMENT_TOKEN"))
        #expect(!firstBody.contains("LATE_GUIDANCE_TOKEN"))
        #expect(try await store.result(session: session.id, agent: "default", id: "first") == nil)
        await http.release.resolve(.success(()))
        #expect(try await delivery.value == .complete)
        #expect(try await first.result.stopReason == .endTurn)
        #expect(try await second.result.stopReason == .endTurn)
        let bodies = await http.bodies
        #expect(bodies.count == 2)
        let secondBody = try #require(bodies.last)
        #expect(secondBody.contains("SECOND_PLACEMENT_TOKEN"))
        #expect(secondBody.components(separatedBy: "LATE_GUIDANCE_TOKEN").count - 1 == 1)
        #expect(await http.cancellations == 0)
        let history = try await store.entries(session: session.id, agent: "default", after: 0)
        #expect(starts(history) == ["first", "second"])
        #expect(ends(history) == ["first", "second"])
        try await agent.close(); try await store.close()
    }

    @Test func idleSessionCancellationAndSteerCollisionLeaveTheWaitingPromptIntact() async throws {
        let store = try FxSessionStore(), queue = PlacementQueue(), http = PlacementHTTP()
        let agent = try FxAgent(configuration: configuration(http), store: store, checkpointAfterBytes: nil, queue: queue)
        let session = try await agent.session(id: "waiting-cancel")
        let turn = try await session.prompt("ORIGINAL_WAITING_TOKEN", id: "waiting")
        await #expect(throws: FxSessionError.messageIDInUse) {
            try await session.steer("COLLIDING_GUIDANCE_TOKEN", id: "waiting")
        }
        try await session.cancel()
        #expect(await http.bodies.isEmpty)
        #expect(try await store.result(session: session.id, agent: "default", id: "waiting") == nil)
        let wakeup = try #require(await queue.messages.first)
        #expect(try await agent.deliver(wakeup) == .complete)
        #expect(try await turn.result.stopReason == .endTurn)
        #expect(await http.bodies.count == 1)
        #expect(await http.bodies.first?.contains("ORIGINAL_WAITING_TOKEN") == true)
        #expect(await http.bodies.first?.contains("COLLIDING_GUIDANCE_TOKEN") == false)
        let history = try await store.entries(session: session.id, agent: "default", after: 0)
        #expect(starts(history) == ["waiting"] && ends(history) == ["waiting"])
        try await agent.close(); try await store.close()
    }

    @Test func idleTextSteerSurvivesProducerCloseAndDuplicateWakeups() async throws {
        let store = try FxSessionStore(), queue = PlacementQueue(), http = PlacementHTTP()
        let producer = try FxAgent(configuration: configuration(http), store: store, checkpointAfterBytes: nil, queue: queue)
        let session = try await producer.session(id: "idle-redelivery")
        _ = try await session.steer("IDLE_GUIDANCE_TOKEN", id: "guide")
        let wakeup = try #require(await queue.messages.first)
        #expect(await http.bodies.isEmpty)
        try await producer.close()
        let worker = try FxAgent(configuration: configuration(http), store: store, checkpointAfterBytes: nil, queue: queue)
        #expect(try await worker.deliver(wakeup) == .complete)
        #expect(try await worker.deliver(wakeup) == .complete)
        #expect(try await store.result(session: session.id, agent: "default", id: "guide")?.stopReason == .endTurn)
        #expect(await http.bodies.count == 1)
        #expect(await http.bodies.first?.components(separatedBy: "IDLE_GUIDANCE_TOKEN").count == 2)
        let history = try await store.entries(session: session.id, agent: "default", after: 0)
        #expect(starts(history) == ["guide"] && ends(history) == ["guide"])
        try await worker.close(); try await store.close()
    }

    @Test(arguments: [false, true])
    func rejectedPromptsNeverReachTheModelAndLeaveTheirIDReusable(durable: Bool) async throws {
        let http = PlacementHTTP()
        let png = Data([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a])
        let rejected: [[FxPromptContent]] = [
            [.text("")],
            [.text("look"), .image(FxImage(data: png, format: .jpeg))],
            [.text("look"), .image(FxImage(data: png, format: .gif))],
            [.text("look"), .image(FxImage(data: Data([1, 2, 3, 4]), format: .png))],
            Array(repeating: .image(FxImage(data: png, format: .png)), count: 9),
        ]
        if durable {
            let store = try FxSessionStore(), queue = PlacementQueue()
            let agent = try FxAgent(configuration: configuration(http), store: store, queue: queue)
            let session = try await agent.session(id: "admission")
            for content in rejected {
                await #expect(throws: FxError.self) { try await session.prompt(content, id: "refused") }
                #expect(try await store.owner(session: session.id) == nil)
                #expect(await queue.messages.isEmpty)
                #expect(await http.bodies.isEmpty)
            }
            let turn = try await session.prompt("valid replacement", id: "refused")
            #expect(!turn.isRepeated)
            let wakeup = try #require(await queue.messages.first)
            #expect(try await agent.deliver(wakeup) == .complete)
            #expect(try await turn.result.stopReason == .endTurn)
            try await agent.close(); try await store.close()
        } else {
            let engine = try await FxEngine.open(configuration: configuration(http))
            for content in rejected {
                await #expect(throws: FxError.self) { try await engine.prompt(content, id: "refused") }
                #expect(await http.bodies.isEmpty)
            }
            let turn = try await engine.prompt("valid replacement", id: "refused")
            #expect(try await turn.result.stopReason == .endTurn)
            try await engine.close()
        }
        #expect(await http.bodies.count == 1)
        #expect(await http.bodies.first?.contains("valid replacement") == true)
    }

    @Test func yieldedCheckpointKeepsPendingSteeringInTheOriginalTurn() async throws {
        let store = try FxSessionStore(), queue = PlacementQueue(), http = PlacementHTTP(.toolFirst)
        let toolEntered = AsyncResult<Void>(), releaseTool = AsyncResult<Void>()
        let tool = FxTool(name: "lookup", description: "Lookup", inputSchema: .object(["type": .string("object")]), isIdempotent: true) { _, _ in
            await toolEntered.resolve(.success(()))
            try await releaseTool.wait()
            return "found"
        }
        let agent = try FxAgent(configuration: configuration(http, tools: [tool]), store: store, checkpointAfterBytes: nil, queue: queue)
        let session = try await agent.session(id: "yielded-placement")
        let turn = try await session.prompt("lookup first", id: "original")
        let wakeup = try #require(await queue.messages.first)
        let policy = try FxDeliveryPolicy(maximumDuration: .zero, reserve: .zero)
        let firstDelivery = Task { try await agent.deliver(wakeup, policy: policy) }
        try await toolEntered.wait()
        _ = try await session.steer("RETAINED_GUIDANCE_TOKEN", id: "guide")
        await releaseTool.resolve(.success(()))
        #expect(try await firstDelivery.value == .retry(after: .zero))
        #expect(try await store.snapshot(session: session.id, agent: "default").checkpoint != nil)
        #expect(try await store.result(session: session.id, agent: "default", id: "original") == nil)
        #expect(try await agent.deliver(wakeup) == .complete)
        #expect(try await turn.result.stopReason == .endTurn)
        #expect(await http.bodies.count == 2)
        #expect(await http.bodies.last?.components(separatedBy: "RETAINED_GUIDANCE_TOKEN").count == 2)
        let history = try await store.entries(session: session.id, agent: "default", after: 0)
        #expect(starts(history) == ["original"] && ends(history) == ["original"])
        #expect(history.contains { if case .yielded(id: "original") = $0.event { return true }; return false })
        try await agent.close(); try await store.close()
    }
}
