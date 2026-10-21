import Foundation
import Testing
@testable import LibFx

private final class Observations: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [FxObservation] = []
    private var failures = 0
    var events: [FxObservation] { lock.withLock { values } }
    var errorCount: Int { lock.withLock { failures } }
    func record(_ event: FxObservation) { lock.withLock { values.append(event) } }
    func recordError() { lock.withLock { failures += 1 } }
}

private struct ObservationHTTP: FxHTTPClient {
    func send(_ request: URLRequest) async throws -> FxHTTPResponse {
        let text = request.httpMethod == "GET"
            ? #"{"data":[{"id":"swift/observe","type":"language"}]}"#
            : "data: {\"type\":\"text-delta\",\"delta\":\"private-answer\"}\n\ndata: {\"type\":\"finish\",\"finishReason\":{\"unified\":\"stop\",\"raw\":\"stop\"}}\n\ndata: [DONE]\n\n"
        return FxHTTPResponse(statusCode: 200, body: AsyncThrowingStream { continuation in
            continuation.yield(Data(text.utf8)); continuation.finish()
        })
    }
}

private struct FencedObservationStore: FxPersistence {
    func load() async throws -> FxPersistenceSnapshot { FxPersistenceSnapshot() }
    func append(expected: String?, idempotencyKey: String, data: Data, barrier: Bool) async throws -> String {
        throw FxPersistenceError.fenced
    }
}

private actor PausedCheckpointStore: FxCheckpointPersistence {
    private let memory = FxMemoryPersistence()
    private var release: CheckedContinuation<Void, Never>?
    private(set) var closeCompleted = false
    func load() async -> FxPersistenceSnapshot { await memory.load() }
    func append(expected: String?, idempotencyKey: String, data: Data, barrier: Bool) async throws -> String {
        try await memory.append(expected: expected, idempotencyKey: idempotencyKey, data: data, barrier: barrier)
    }
    func saveCheckpoint(_ checkpoint: FxStoredCheckpoint) async throws {
        await withCheckedContinuation { release = $0 }
        try await memory.saveCheckpoint(checkpoint)
    }
    func waitUntilSaving() async { while release == nil { await Task.yield() } }
    func resume() { release?.resume(); release = nil }
    func didClose() { closeCompleted = true }
}

@Test func observationScopesOrderAndContentOptIn() async throws {
    for capture in [false, true] {
        let collected = Observations()
        let engine = try await FxEngine.open(configuration: FxConfiguration(
            apiKey: "test-key", model: "swift/observe", httpClient: ObservationHTTP(),
            observation: FxObservationOptions(captureContent: capture, onEvent: collected.record)
        ))
        let turn = try await engine.prompt("private-prompt")
        for try await _ in turn {}
        #expect(try await turn.result.stopReason == .endTurn)
        try await engine.close()
        let events = collected.events
        #expect(events.first?.kind == .turnStarted)
        #expect(events.last?.kind == .turnEnded)
        #expect(events.contains { $0.kind == .modelStarted })
        #expect(events.contains { $0.kind == .modelEnded })
        #expect(Set(events.compactMap(\.executionID)).count == 1)
        #expect(Set(events.compactMap(\.turnID)).count == 1)
        #expect(events.allSatisfy { $0.sessionID == engine.sessionID && $0.rootSessionID == engine.sessionID })
        #expect(events.allSatisfy { $0.contentCaptured == capture && $0.timestamp.timeIntervalSince1970 > 1_000_000_000 })
        let payloads = String(decoding: try JSONEncoder().encode(events), as: UTF8.self)
        #expect(payloads.contains("private-prompt") == capture)
        #expect(payloads.contains("private-answer") == capture)
    }
}

@Test func throwingObserverDoesNotChangeTurnOrJournal() async throws {
    enum ObserverFailure: Error { case expected }
    let collected = Observations()
    let store = FxMemoryPersistence()
    let engine = try await FxEngine.open(configuration: FxConfiguration(
        apiKey: "test-key", model: "swift/observe", httpClient: ObservationHTTP(),
        observation: FxObservationOptions(onEvent: { event in
            collected.record(event)
            throw ObserverFailure.expected
        }, onError: { _ in collected.recordError() })
    ), persistence: store)
    for _ in 0..<2 {
        let turn = try await engine.prompt("hello")
        for try await _ in turn {}
        #expect(try await turn.result.stopReason == .endTurn)
    }
    #expect(collected.errorCount == collected.events.count)
    let snapshot = await store.load()
    #expect(!snapshot.journal.isEmpty)
    #expect(collected.events.contains { $0.kind == .journalRestored })
    let commits = collected.events.filter { $0.kind == .journalCommitted }
    #expect(commits.count == snapshot.journal.count)
    #expect(commits.last?.data["cursor"]?.string == snapshot.head)
    let lastRecord = try #require(snapshot.journal.last)
    let record = try JSONDecoder().decode(JSONValue.self, from: lastRecord.data)
    guard case .array(let entries) = record["events"] else { Issue.record("Missing journal entries"); return }
    let lastSequence = try #require(entries.last?["seq"])
    try await engine.saveCheckpoint()
    try await engine.close()
    let reopened = try await FxEngine.open(configuration: FxConfiguration(
        apiKey: "test-key", model: "swift/observe", httpClient: ObservationHTTP(),
        observation: FxObservationOptions(onEvent: collected.record)
    ), persistence: store)
    try await reopened.close()
    #expect(collected.events.last?.kind == .journalRestored)
    #expect(collected.events.last?.data["lastSeq"] == lastSequence)
}

@Test func observationReportsFencingWithoutClaimingCommit() async throws {
    let collected = Observations()
    let engine = try await FxEngine.open(configuration: FxConfiguration(
        apiKey: "test-key", model: "swift/observe", httpClient: ObservationHTTP(),
        observation: FxObservationOptions(onEvent: collected.record)
    ), persistence: FencedObservationStore())
    let turn = try await engine.prompt("hello")
    do { _ = try await turn.result; Issue.record("A fenced journal must fail the turn") } catch {}
    do { try await engine.close(); Issue.record("Close must report the journal failure") } catch {}
    #expect(collected.events.contains { $0.kind == .journalError && $0.data["fenced"] == .bool(true) })
    #expect(!collected.events.contains { $0.kind == .journalCommitted })
}

@Test func closeWaitsForCheckpointPersistence() async throws {
    let store = PausedCheckpointStore()
    let engine = try await FxEngine.open(configuration: FxConfiguration(
        apiKey: "test-key", model: "swift/observe", httpClient: ObservationHTTP()
    ), persistence: store)
    let turn = try await engine.prompt("remember me")
    for try await _ in turn {}
    _ = try await turn.result
    let saving = Task { try await engine.saveCheckpoint() }
    await store.waitUntilSaving()
    let closing = Task { try await engine.close(); await store.didClose() }
    // Observe that close has begun, while the persistence acknowledgement remains held.
    while true {
        do { _ = try await engine.prompt("closed"); Issue.record("Checkpoint must exclude prompts") }
        catch FxError.closed { break }
        catch FxError.busy {}
        await Task.yield()
    }
    #expect(await store.closeCompleted == false)
    await store.resume()
    try await saving.value
    try await closing.value
    #expect(await store.closeCompleted)
    #expect(await store.load().checkpoint != nil)
}

@Test func checkpointMetadataDetectsConfigurationChangesWithoutPreventingRestore() async throws {
    let observations = Observations()
    func tool(_ name: String, idempotent: Bool = true, reverseSchema: Bool = false) -> FxTool {
        let schema: JSONValue = reverseSchema
            ? .object(["properties": .object(["key": .object(["type": .string("string")])]), "type": .string("object")])
            : .object(["type": .string("object"), "properties": .object(["key": .object(["type": .string("string")])])])
        return FxTool(name: name, description: "Look up a value", inputSchema: schema, isIdempotent: idempotent) { _, _ in "value" }
    }
    var config = FxConfiguration(apiKey: "source-key", model: "swift/observe", tools: [tool("alpha"), tool("beta")],
                                 httpClient: ObservationHTTP(), observation: FxObservationOptions(onEvent: observations.record))
    let source = try await FxEngine.open(configuration: config)
    let turn = try await source.prompt("remember me")
    #expect(try await turn.result.stopReason == .endTurn)
    let checkpoint = try await source.checkpoint()
    try await source.close()
    config.provider = .gateway(apiKey: "new-key")
    config.instructions = "new instructions"
    config.tools = [tool("beta", reverseSchema: true), tool("alpha", reverseSchema: true)]
    let unchanged = try await FxEngine.open(configuration: config, checkpoint: checkpoint)
    try await unchanged.close()
    #expect(!observations.events.contains { $0.kind == .checkpointMismatch })
    config.model = "swift/other"
    config.tools = [tool("alpha", idempotent: false), tool("beta")]
    let changed = try await FxEngine.open(configuration: config, checkpoint: checkpoint)
    try await changed.close()
    let mismatch = try #require(observations.events.first { $0.kind == .checkpointMismatch })
    #expect(mismatch.data["changed"] == .array([.string("toolSchemaHash"), .string("model")]))
    #expect(mismatch.data["saved"]?["model"] == .string("swift/observe"))
    #expect(mismatch.data["current"]?["model"] == .string("swift/other"))
    #expect(mismatch.sessionID == changed.sessionID)
    #expect(!String(describing: mismatch).contains("source-key"))
}

@Test func snapshotMetadataReportsMismatchAndContainsObserverFailure() async throws {
    let store = FxMemoryPersistence(), observations = Observations()
    var config = FxConfiguration(apiKey: "test-key", model: "swift/observe", httpClient: ObservationHTTP(), checkpointAfterBytes: 0)
    let source = try await FxEngine.open(configuration: config, persistence: store)
    let turn = try await source.prompt("save metadata")
    #expect(try await turn.result.stopReason == .endTurn)
    try await source.close()
    #expect(await store.load().checkpoint != nil)
    config.model = "swift/other"
    config.observation = FxObservationOptions(onEvent: { event in
        observations.record(event)
        if event.kind == .checkpointMismatch { throw FxError.cancelled }
    }, onError: { _ in observations.recordError() })
    let restored = try await FxEngine.open(configuration: config, persistence: store)
    try await restored.close()
    #expect(observations.events.filter { $0.kind == .checkpointMismatch }.count == 1)
    #expect(observations.errorCount == 1)
    #expect(observations.events.last?.kind == .journalRestored)
    #expect(observations.events.last?.data["checkpoint"] == .bool(true))
}
