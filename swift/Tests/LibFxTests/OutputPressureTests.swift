import Foundation
import CryptoKit
import Testing
@testable import LibFx

private actor PressureProbe {
    let reached = PromptDispatch()
    var samples: [(bytes: Int, events: Int)] = []
    var effects = 0
    func record(_ event: FxLifecycleEvent) async {
        guard case .outputBackpressure(let bytes, let events) = event else { return }
        samples.append((bytes, events))
        await reached.resolve(sent: true)
    }
    func effect() { effects += 1 }
}

private actor PressureTurn {
    var turn: FxTurn?
    var waiter: CheckedContinuation<FxTurn, Never>?
    func set(_ turn: FxTurn) { self.turn = turn; waiter?.resume(returning: turn); waiter = nil }
    func value() async -> FxTurn {
        if let turn { return turn }
        return await withCheckedContinuation { waiter = $0 }
    }
}

private final class PressureFailure: Error {}
private actor PressureReaderCancellation {
    var queue: TurnOutput?
    let finished = PromptDispatch()
    func set(_ queue: TurnOutput) { self.queue = queue }
    func cancel(with failure: PressureFailure) async {
        await queue?.finish(throwing: failure, discarding: true)
        await finished.resolve(sent: true)
    }
}

private actor PressureHTTP: FxHTTPClient {
    let response: String
    let keepOpen: Bool
    let cancelled = PromptDispatch()
    private var requests = 0
    init(response: String, keepOpen: Bool = false) { self.response = response; self.keepOpen = keepOpen }
    func send(_ request: URLRequest) async throws -> FxHTTPResponse {
        let text: String
        if request.httpMethod == "GET" {
            text = #"{"data":[{"id":"fixture/output","type":"language"}]}"#
        } else {
            requests += 1
            text = requests == 1 ? response : pressureDelta("after cancel") + pressureFinish
        }
        let (body, continuation) = AsyncThrowingStream<Data, any Error>.makeStream()
        continuation.yield(Data(text.utf8))
        if request.httpMethod == "GET" || requests > 1 || !keepOpen { continuation.finish() }
        return FxHTTPResponse(statusCode: 200, body: body, cancel: { [cancelled] in
            continuation.finish(throwing: CancellationError())
            Task { await cancelled.resolve(sent: true) }
        })
    }
}

private let pressureFinish = "data: {\"type\":\"finish\",\"finishReason\":{\"unified\":\"stop\",\"raw\":\"stop\"}}\n\ndata: [DONE]\n\n"
private func pressureDelta(_ text: String) -> String {
    let value = JSONValue.object(["type": .string("text-delta"), "delta": .string(text)])
    return "data: \(String(decoding: try! JSONEncoder().encode(value), as: UTF8.self))\n\n"
}
private func pressureConfiguration(_ http: PressureHTTP, probe: PressureProbe? = nil, tools: [FxTool] = []) -> FxConfiguration {
    FxConfiguration(apiKey: "pressure-fixture", model: "fixture/output", tools: tools, httpClient: http,
        onLifecycleEvent: { event in await probe?.record(event) })
}
private func pressureDigest(_ turn: FxTurn) async throws -> (Int, SHA256.Digest) {
    var digest = SHA256(), bytes = 0
    for try await event in turn {
        if case .text(let text) = event { let data = Data(text.utf8); bytes += data.count; digest.update(data: data) }
    }
    return (bytes, digest.finalize())
}

@Suite(.serialized, .timeLimit(.minutes(1))) struct OutputPressureTests {
    @Test func readerCancellationDoesNotReplaceAKnownFailureWithEOF() async throws {
        let failure = PressureFailure(), cancellation = PressureReaderCancellation()
        let queue = TurnOutput(onCancel: { await cancellation.cancel(with: failure) })
        await cancellation.set(queue)
        let reader = Task { try await queue.next() }
        reader.cancel()
        _ = await reader.result
        _ = await cancellation.finished.wait()
        do { _ = try await queue.next(); Issue.record("Expected the original output failure") }
        catch { #expect(error as? PressureFailure === failure) }
    }

    @Test(arguments: [false, true])
    func largeUnicodeOutputSurvivesOneOrManyProviderFrames(fragmented: Bool) async throws {
        let source = String(repeating: "\u{1F600}界", count: 1_200_000) + " tail\n"
        let wire: String
        if fragmented { wire = String(repeating: pressureDelta(String(repeating: "\u{1F600}界", count: 1_000)), count: 1_200) + pressureDelta(" tail\n") }
        else { wire = pressureDelta(source) }
        let engine = try await FxEngine.open(configuration: pressureConfiguration(PressureHTTP(response: wire + pressureFinish)))
        let turn = try await engine.prompt("large output")
        let (bytes, digest) = try await pressureDigest(turn)
        #expect(bytes == source.utf8.count)
        #expect(digest == SHA256.hash(data: Data(source.utf8)))
        #expect(try await turn.result.stopReason == .endTurn)
        try await engine.close()
    }

    @Test(arguments: [false, true])
    func queuesWaitAtTheirByteAndEventBudgets(events: Bool) async throws {
        let reached = PromptDispatch()
        let queue = TurnOutput(onCancel: {}, onPressure: { _ in await reached.resolve(sent: true) })
        let part = events ? "" : String(repeating: "x", count: 16 * 1024)
        let producer = Task {
            for _ in 0..<512 { _ = try await queue.send(.text(part)) }
            await queue.finish()
        }
        _ = await reached.wait()
        let state = await queue.state
        #expect(state.bufferedBytes <= TurnOutput.byteLimit)
        #expect(state.bufferedEvents <= TurnOutput.eventLimit)
        if events { #expect(state.bufferedEvents == TurnOutput.eventLimit) }
        var count = 0
        while let event = try await queue.next() { #expect(event == .text(part)); count += 1 }
        try await producer.value
        #expect(count == 512)
    }

    @Test func oneLargeMetadataEventRemainsLosslessAndBlocksFollowingOutput() async throws {
        let reached = PromptDispatch(), queue = TurnOutput(onCancel: {})
        let event = FxEvent.toolFinished(id: "large", name: "tool", content: String(repeating: "界", count: 400_000), isError: false)
        #expect(try await queue.send(event))
        let state = await queue.state
        #expect(state.bufferedEvents == 1 && state.bufferedBytes > TurnOutput.byteLimit)
        let second = TurnOutput(onCancel: {}, onPressure: { _ in await reached.resolve(sent: true) })
        #expect(try await second.send(event))
        let producer = Task { _ = try await second.send(.text("tail")); await second.finish() }
        _ = await reached.wait()
        #expect(try await second.next() == event)
        #expect(try await second.next() == .text("tail"))
        #expect(try await second.next() == nil)
        try await producer.value
        #expect(try await queue.next() == event)
        await queue.finish()
    }

    @Test(arguments: [false, true])
    func unreadPressureCancelsWithoutReadingAndPreventsQueuedToolEffects(withTool: Bool) async throws {
        let probe = PressureProbe()
        let toolWire = "data: {\"type\":\"tool-call\",\"toolCallId\":\"queued\",\"toolName\":\"effect\",\"input\":{}}\n\ndata: {\"type\":\"finish\",\"finishReason\":{\"unified\":\"tool-calls\",\"raw\":\"tool-calls\"}}\n\ndata: [DONE]\n\n"
        let http = PressureHTTP(response: String(repeating: pressureDelta(String(repeating: "x", count: 16 * 1024)), count: 128)
            + (withTool ? toolWire : ""), keepOpen: !withTool)
        let tools = [FxTool(name: "effect", description: "Record effect", inputSchema: .object(["type": .string("object")]), isIdempotent: false) { _, _ in
            await probe.effect(); return "effect"
        }]
        let engine = try await FxEngine.open(configuration: pressureConfiguration(http, probe: probe, tools: tools))
        let turn = try await engine.prompt("pause output")
        _ = await probe.reached.wait()
        #expect(await probe.samples.allSatisfy { $0.bytes <= 1024 * 1024 && $0.events <= 256 })
        await turn.cancel()
        #expect(try await turn.result.stopReason == .cancelled)
        if !withTool { _ = await http.cancelled.wait() }
        #expect(await probe.effects == 0)
        let next = try await engine.prompt("reuse")
        let (bytes, digest) = try await pressureDigest(next)
        #expect(bytes == 12 && digest == SHA256.hash(data: Data("after cancel".utf8)))
        #expect(try await next.result.stopReason == .endTurn)
        try await engine.close()
    }

    @Test func pressureCallbackCanAwaitCancellation() async throws {
        let holder = PressureTurn(), probe = PressureProbe()
        let http = PressureHTTP(response: String(repeating: pressureDelta(String(repeating: "x", count: 16 * 1024)), count: 128), keepOpen: true)
        var configuration = pressureConfiguration(http)
        configuration.onLifecycleEvent = { event in
            guard case .outputBackpressure = event else { return }
            await probe.record(event)
            await holder.value().cancel()
        }
        let engine = try await FxEngine.open(configuration: configuration)
        let turn = try await engine.prompt("cancel in callback")
        await holder.set(turn)
        #expect(try await turn.result.stopReason == .cancelled)
        #expect(await probe.samples.count == 1)
        try await engine.close()
    }

    @Test func closingUnreadOutputLeavesAnIndependentEngineUsable() async throws {
        let probe = PressureProbe()
        let first = try await FxEngine.open(configuration: pressureConfiguration(PressureHTTP(
            response: String(repeating: pressureDelta(String(repeating: "x", count: 16 * 1024)), count: 128) + pressureFinish), probe: probe))
        let unread = try await first.prompt("unread")
        _ = await probe.reached.wait()
        let independent = try await FxEngine.open(configuration: pressureConfiguration(PressureHTTP(response: pressureDelta("independent") + pressureFinish)))
        let other = try await independent.prompt("separate owner")
        #expect(try await pressureDigest(other).0 == 11)
        #expect(try await other.result.stopReason == .endTurn)
        try await independent.close()
        try await first.close()
        await #expect(throws: FxError.closed) { try await unread.result }
    }
}
