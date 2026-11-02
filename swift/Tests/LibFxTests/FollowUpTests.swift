import Foundation
import Testing
@testable import LibFx

private actor FollowUpGate {
    private let stream: AsyncStream<Void>
    private let release: AsyncStream<Void>.Continuation
    private var blocked = false
    private(set) var turnIDs: [String] = []
    init() { (stream, release) = AsyncStream.makeStream() }
    func wait(turnID: String) async throws {
        turnIDs.append(turnID)
        blocked = true
        for await _ in stream { break }
        try Task.checkCancellation()
    }
    func waitUntilBlocked() async { while !blocked { await Task.yield() } }
    func open() { release.yield(()); release.finish() }
}

private actor FollowUpGateway: FxHTTPClient {
    private(set) var inputs: [String] = []
    func send(_ request: URLRequest) async throws -> FxHTTPResponse {
        let text: String
        if request.httpMethod == "GET" {
            text = #"{"data":[{"id":"swift/follow-up","type":"language","tags":["tool-use"]}]}"#
        } else {
            let body = try JSONDecoder().decode(JSONValue.self, from: request.httpBody ?? Data())
            var input = ""
            if case .array(let messages) = body["prompt"] {
                for message in messages where message["role"] == .string("user") {
                    if case .array(let blocks) = message["content"] { input = blocks.compactMap { $0["text"]?.string }.joined() }
                    else { input = message["content"]?.string ?? "" }
                }
            }
            inputs.append(input)
            let frames: [JSONValue]
            if inputs.count == 1 && input == "hold" {
                frames = [
                    .object(["type": .string("tool-call"), "toolCallId": .string("hold-1"), "toolName": .string("hold"), "input": .object([:])]),
                    .object(["type": .string("finish"), "finishReason": .object(["unified": .string("tool-calls"), "raw": .string("tool-calls")])]),
                ]
            } else {
                frames = [
                    .object(["type": .string("text-delta"), "delta": .string(input)]),
                    .object(["type": .string("finish"), "finishReason": .object(["unified": .string("stop"), "raw": .string("stop")])]),
                ]
            }
            text = try frames.map { "data: \(String(decoding: try JSONEncoder().encode($0), as: UTF8.self))\n\n" }.joined() + "data: [DONE]\n\n"
        }
        return FxHTTPResponse(statusCode: 200, body: AsyncThrowingStream { continuation in
            continuation.yield(Data(text.utf8)); continuation.finish()
        })
    }
}

private final class FollowUpObservations: @unchecked Sendable {
    private let lock = NSLock()
    private var failures = 0
    var errorCount: Int { lock.withLock { failures } }
    func record(_ event: FxObservation) {
        if event.kind == .checkpointError { lock.withLock { failures += 1 } }
    }
}

private func followUpConfiguration(_ gateway: FollowUpGateway, gate: FollowUpGate? = nil) -> FxConfiguration {
    FxConfiguration(apiKey: "test-key", model: "swift/follow-up", tools: gate.map { gate in [
        FxTool(name: "hold", description: "Wait", inputSchema: .object(["type": .string("object")]), isIdempotent: true) { _, context in
            try await gate.wait(turnID: context.turnID)
            return "released"
        },
    ] } ?? [], httpClient: gateway)
}

private func finish(_ turn: FxTurn) async throws {
    for try await _ in turn {}
    #expect(try await turn.result.stopReason == .endTurn)
}

private func journalEvents(_ store: FxMemoryPersistence) async throws -> [JSONValue] {
    try await store.load().journal.flatMap { record in
        guard case .array(let events) = try JSONDecoder().decode(JSONValue.self, from: record.data)["events"] else { return [JSONValue]() }
        return events
    }
}

@Test func idleFollowUpStartsAndRecordsAcceptanceOnce() async throws {
    let gateway = FollowUpGateway(), store = FxMemoryPersistence()
    let engine = try await FxEngine.open(configuration: followUpConfiguration(gateway), persistence: store)
    let queued = try await engine.followUp("right away")
    try await queued.accepted
    let turn = try await queued.turn
    #expect(turn.id == queued.id)
    try await finish(turn)
    let events = try await journalEvents(store)
    #expect(events.filter { $0["type"] == .string("input_accepted") && $0["data"]?["id"] == .string(queued.id) }.count == 1)
    #expect(await gateway.inputs == ["right away"])
    try await engine.close()
}

@Test func queuedFollowUpsAreDurableAndRunInOrder() async throws {
    let gateway = FollowUpGateway(), gate = FollowUpGate(), store = FxMemoryPersistence()
    let observed = FollowUpObservations()
    var config = followUpConfiguration(gateway, gate: gate)
    config.checkpointAfterBytes = 0
    config.observation = FxObservationOptions(onEvent: observed.record)
    let engine = try await FxEngine.open(configuration: config, persistence: store)
    let first = try await engine.prompt("hold", id: "initial-turn")
    await gate.waitUntilBlocked()
    #expect(await gate.turnIDs == [first.id])
    let one = try await engine.followUp("one"), two = try await engine.followUp("two")
    try await one.accepted
    try await two.accepted
    #expect(await gateway.inputs == ["hold"])
    let accepted = try await journalEvents(store).filter { $0["type"] == .string("input_accepted") }
    #expect(accepted.compactMap { $0["data"]?["id"]?.string } == [one.id, two.id])
    await gate.open()
    try await finish(first)
    try await finish(one.turn)
    try await finish(two.turn)
    #expect(await gateway.inputs == ["hold", "hold", "one", "two"])
    let saved = await store.load()
    #expect(saved.checkpoint != nil && saved.journal.isEmpty)
    #expect(observed.errorCount == 0)
    #expect(try await engine.resume() == nil)
    try await engine.close()
}

@Test func handoffLeavesHeldFollowUpsForExplicitResume() async throws {
    let gateway = FollowUpGateway(), gate = FollowUpGate(), store = FxMemoryPersistence()
    let config = followUpConfiguration(gateway, gate: gate)
    let engine = try await FxEngine.open(configuration: config, persistence: store)
    let first = try await engine.prompt("hold")
    await gate.waitUntilBlocked()
    let queued = try await engine.followUp("held input")
    try await queued.accepted
    try await first.handoff()
    _ = try await first.result
    await #expect(throws: FxError.handedOff) { try await queued.turn }
    try await engine.close()
    let restored = try await FxEngine.open(configuration: config, persistence: store)
    try await finish(try #require(try await restored.resume()))
    let own = try await restored.followUp("own input")
    try await finish(own.turn)
    let held = try #require(try await restored.resume())
    #expect(held.id == queued.id)
    try await finish(held)
    #expect(try await restored.resume() == nil)
    #expect(await gateway.inputs.suffix(2) == ["own input", "held input"])
    try await restored.close()
}

@Test func cancellingFollowUpWaiterDoesNotRemoveInput() async throws {
    let gateway = FollowUpGateway(), gate = FollowUpGate()
    let engine = try await FxEngine.open(configuration: followUpConfiguration(gateway, gate: gate))
    let first = try await engine.prompt("hold")
    await gate.waitUntilBlocked()
    let queued = try await engine.followUp("keep queued")
    let waiter = Task { try await queued.turn }
    waiter.cancel()
    await #expect(throws: CancellationError.self) { try await waiter.value }
    await gate.open()
    try await finish(first)
    try await finish(queued.turn)
    try await queued.accepted
    #expect(await gateway.inputs.last == "keep queued")
    try await engine.close()
}

@Test func closeRejectsQueuedFollowUpWaiters() async throws {
    let gateway = FollowUpGateway(), gate = FollowUpGate()
    let engine = try await FxEngine.open(configuration: followUpConfiguration(gateway, gate: gate))
    let first = try await engine.prompt("hold")
    await gate.waitUntilBlocked()
    let queued = try await engine.followUp("never started")
    try await engine.close()
    await #expect(throws: FxError.closed) { try await first.result }
    await #expect(throws: FxError.closed) { try await queued.turn }
    await #expect(throws: FxError.closed) { try await queued.accepted }
    await #expect(throws: FxError.closed) { try await engine.followUp("closed") }
}

private actor FailingFollowUpStore: FxPersistence {
    private let memory = FxMemoryPersistence()
    private var rejecting = false
    func load() async -> FxPersistenceSnapshot { await memory.load() }
    func rejectWrites() { rejecting = true }
    func append(expected: String?, idempotencyKey: String, data: Data, barrier: Bool) async throws -> String {
        guard !rejecting else { throw FxPersistenceError.fenced }
        return try await memory.append(expected: expected, idempotencyKey: idempotencyKey, data: data, barrier: barrier)
    }
}

@Test func failedFollowUpAcceptanceRejectsBothWaiters() async throws {
    let gateway = FollowUpGateway(), gate = FollowUpGate(), store = FailingFollowUpStore()
    let engine = try await FxEngine.open(configuration: followUpConfiguration(gateway, gate: gate), persistence: store)
    let first = try await engine.prompt("hold")
    await gate.waitUntilBlocked()
    await store.rejectWrites()
    let queued = try await engine.followUp("must not run")
    await #expect(throws: FxPersistenceError.fenced) { try await queued.accepted }
    await #expect(throws: FxPersistenceError.fenced) { try await queued.turn }
    await #expect(throws: FxPersistenceError.fenced) { try await first.result }
    #expect(await gateway.inputs == ["hold"])
    await #expect(throws: FxPersistenceError.fenced) { try await engine.close() }
}
