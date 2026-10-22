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
    let failures = collected.events.filter { $0.kind == .journalError }
    #expect(failures.count == 1)
    #expect(failures.first?.data["fenced"] == .bool(true))
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

@Test func observationParentProjectsNativeAndJournalEvents() async throws {
    let events = Observations()
    let parent = try FxObservationParent(rootSessionID: "root", sessionID: "parent", turnID: "parent-turn", callID: "parent-call")
    let engine = try await FxEngine.open(configuration: FxConfiguration(
        apiKey: "test-key", model: "swift/observe", httpClient: ObservationHTTP(),
        observation: FxObservationOptions(parent: parent, onEvent: events.record)
    ), persistence: FxMemoryPersistence())
    let turn = try await engine.prompt("hello")
    for try await _ in turn {}
    _ = try await turn.result
    try await engine.close()
    #expect(events.events.contains { $0.kind == .journalCommitted })
    #expect(events.events.contains { $0.kind == .turnEnded })
    #expect(events.events.allSatisfy {
        $0.rootSessionID == "root" && $0.sessionID == engine.sessionID && $0.parentSessionID == "parent"
        && $0.parentTurnID == "parent-turn" && $0.parentCallID == "parent-call"
    })
}

@Test func observationParentPreservesNativeDescendantAncestryAndEncoding() throws {
    let parent = try FxObservationParent(rootSessionID: "root", sessionID: "host", turnID: "host-turn", callID: "host-call")
    let native = try FxObservation(raw: .object([
        "version": .number(1), "type": .string("model.start"), "sessionId": .string("descendant"),
        "rootSessionId": .string("engine"), "parentSessionId": .string("native-parent"),
        "parentTurnId": .string("native-turn"), "parentCallId": .string("native-call"),
        "stepIndex": .number(0), "timestamp": .number(1_790_000_000_000),
        "contentCaptured": .bool(false), "contentTruncated": .bool(false), "data": .object([:]),
    ]))
    let projected = FxObservationOptions(parent: parent, onEvent: { _ in }).project(native)
    #expect(projected.rootSessionID == "root")
    #expect(projected.parentSessionID == "native-parent")
    #expect(projected.parentTurnID == "native-turn")
    #expect(projected.parentCallID == "native-call")
    #expect(try JSONDecoder().decode(FxObservation.self, from: JSONEncoder().encode(projected)) == projected)
    for field in 0..<4 {
        for invalid in ["", String(repeating: "界", count: 342)] {
            var values = ["root", "parent", "turn", "call"]
            values[field] = invalid
            #expect(throws: FxError.self) {
                try FxObservationParent(rootSessionID: values[0], sessionID: values[1], turnID: values[2], callID: values[3])
            }
        }
    }
}
