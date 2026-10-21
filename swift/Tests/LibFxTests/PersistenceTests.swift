import Foundation
import Testing
@testable import LibFx

private actor JournalGateway: FxHTTPClient {
    var bodies: [String] = []
    func send(_ request: URLRequest) async throws -> FxHTTPResponse {
        let text: String
        if request.httpMethod == "GET" {
            text = #"{"data":[{"id":"swift/journal","type":"language"}]}"#
        } else {
            bodies.append(String(decoding: request.httpBody ?? Data(), as: UTF8.self))
            text = "data: {\"type\":\"text-delta\",\"delta\":\"remembered answer\"}\n\ndata: {\"type\":\"finish\",\"finishReason\":{\"unified\":\"stop\",\"raw\":\"stop\"}}\n\ndata: [DONE]\n\n"
        }
        return FxHTTPResponse(statusCode: 200, body: AsyncThrowingStream { continuation in
            continuation.yield(Data(text.utf8)); continuation.finish()
        })
    }
}

private actor FailingPersistence: FxPersistence {
    var appends = 0
    func load() -> FxPersistenceSnapshot { FxPersistenceSnapshot() }
    func append(expected: String?, idempotencyKey: String, data: Data, barrier: Bool) throws -> String {
        appends += 1
        throw FxPersistenceError.fenced
    }
}

private actor RetryingCheckpointStore: FxCheckpointPersistence {
    let memory = FxMemoryPersistence()
    private(set) var attempts = 0
    func load() async -> FxPersistenceSnapshot { await memory.load() }
    func append(expected: String?, idempotencyKey: String, data: Data, barrier: Bool) async throws -> String {
        try await memory.append(expected: expected, idempotencyKey: idempotencyKey, data: data, barrier: barrier)
    }
    func saveCheckpoint(_ checkpoint: FxStoredCheckpoint) async throws {
        attempts += 1
        if attempts == 1 { throw FxPersistenceError.sizeLimit }
        try await memory.saveCheckpoint(checkpoint)
    }
}

@Test func automaticSnapshotsSurviveSQLiteReopenWithJournalTail() async throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("conversation.sqlite")
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let gateway = JournalGateway()
    var config = FxConfiguration(apiKey: "test-key", model: "swift/journal", httpClient: gateway, checkpointAfterBytes: 0)
    let store = try FxSQLitePersistence(url: url)
    let first = try await FxEngine.open(configuration: config, persistence: store)
    let turn = try await first.prompt("remember this disk turn")
    for try await _ in turn {}
    #expect(try await turn.result.stopReason == .endTurn)
    let snapshot = try await store.load()
    #expect(snapshot.checkpoint != nil)
    #expect(snapshot.journal.isEmpty)
    try await first.close()
    try await store.close()

    let reopened = try FxSQLitePersistence(url: url)
    config.checkpointAfterBytes = nil
    let second = try await FxEngine.open(configuration: config, persistence: reopened)
    let next = try await second.prompt("append a disk tail")
    for try await _ in next {}
    #expect(try await next.result.stopReason == .endTurn)
    #expect(try await reopened.load().journal.isEmpty == false)
    try await second.close()
    try await reopened.close()

    let finalStore = try FxSQLitePersistence(url: url)
    let third = try await FxEngine.open(configuration: config, persistence: finalStore)
    let final = try await third.prompt("restore the snapshot and tail")
    for try await _ in final {}
    _ = try await final.result
    let bodies = await gateway.bodies
    #expect(bodies.last?.contains("remember this disk turn") == true)
    #expect(bodies.last?.contains("append a disk tail") == true)
    #expect(bodies.last?.contains("remembered answer") == true)
    try await third.close()
    try await finalStore.close()
}

@Test func failedAutomaticSnapshotPreservesJournalAndRetriesNextTurn() async throws {
    let store = RetryingCheckpointStore()
    let engine = try await FxEngine.open(configuration: FxConfiguration(
        apiKey: "test-key", model: "swift/journal", httpClient: JournalGateway(), checkpointAfterBytes: 0
    ), persistence: store)
    for expectedAttempts in 1...2 {
        let turn = try await engine.prompt("turn \(expectedAttempts)")
        for try await _ in turn {}
        #expect(try await turn.result.stopReason == .endTurn)
        #expect(await store.attempts == expectedAttempts)
        let snapshot = await store.load()
        #expect((snapshot.checkpoint != nil) == (expectedAttempts == 2))
        #expect(snapshot.journal.isEmpty == (expectedAttempts == 2))
    }
    try await engine.close()
}

@Test func journalRestoresConversationAcrossEngines() async throws {
    let gateway = JournalGateway()
    let store = FxMemoryPersistence()
    let config = FxConfiguration(apiKey: "test-key", model: "swift/journal", httpClient: gateway)
    let first = try await FxEngine.open(configuration: config, persistence: store)
    let turn = try await first.prompt("remember this turn")
    for try await _ in turn {}
    #expect(try await turn.result.stopReason == .endTurn)
    try await first.flushPersistence()
    let snapshot = await store.load()
    #expect(!snapshot.journal.isEmpty)
    let loaded = try LoadedJournal(snapshot)
    #expect(loaded.events.contains { $0["type"] == .string("turn_committed") })
    try await first.saveCheckpoint()
    let compacted = await store.load()
    #expect(compacted.checkpoint != nil)
    #expect(compacted.journal.isEmpty)
    try await first.close()
    let second = try await FxEngine.open(configuration: config, persistence: store)
    #expect(await second.recoveryState == nil)
    let next = try await second.prompt("continue from memory")
    for try await _ in next {}
    #expect(try await next.result.stopReason == .endTurn)
    let requests = await gateway.bodies
    #expect(requests.count == 2)
    #expect(requests.last?.contains("remember this turn") == true)
    #expect(requests.last?.contains("remembered answer") == true)
    try await second.close()
}

@Test func persistenceFailureRejectsTurnAndStopsLaterWrites() async throws {
    let gateway = JournalGateway()
    let store = FailingPersistence()
    let engine = try await FxEngine.open(configuration: FxConfiguration(
        apiKey: "test-key", model: "swift/journal", httpClient: gateway
    ), persistence: store)
    let turn = try await engine.prompt("must be stored")
    await #expect(throws: FxPersistenceError.fenced) { try await turn.result }
    await #expect(throws: FxPersistenceError.fenced) { try await engine.flushPersistence() }
    #expect(await store.appends == 1)
    #expect(await gateway.bodies.isEmpty)
    await #expect(throws: FxPersistenceError.fenced) { try await engine.prompt("must not start another turn") }
    await #expect(throws: FxPersistenceError.fenced) { try await engine.close() }
}

@Test func memoryStoreFencesWritersAndDeduplicatesRetries() async throws {
    let store = FxMemoryPersistence()
    let data = Data("record".utf8)
    let cursor = try await store.append(expected: nil, idempotencyKey: "a", data: data, barrier: true)
    #expect(try await store.append(expected: nil, idempotencyKey: "a", data: data, barrier: true) == cursor)
    await #expect(throws: FxPersistenceError.fenced) {
        try await store.append(expected: nil, idempotencyKey: "b", data: data, barrier: true)
    }
    await #expect(throws: FxPersistenceError.fenced) {
        try await store.append(expected: cursor, idempotencyKey: "a", data: Data(), barrier: true)
    }
}

@Test func journalRejectsMalformedAndFutureRecords() throws {
    #expect(throws: FxPersistenceError.invalidJournal) {
        try LoadedJournal(FxPersistenceSnapshot(journal: [.init(cursor: "1", data: Data("invalid".utf8))]))
    }
    #expect(throws: FxPersistenceError.unsupportedVersion) {
        try LoadedJournal(FxPersistenceSnapshot(journal: [.init(cursor: "1", data: Data(#"{"format":"libfx-journal-v99","events":[]}"#.utf8))]))
    }
}

@Test func resumeContinuesJournalStoppedBeforeModelRequest() async throws {
    let gateway = JournalGateway()
    let complete = FxMemoryPersistence()
    let config = FxConfiguration(apiKey: "test-key", model: "swift/journal", httpClient: gateway)
    let original = try await FxEngine.open(configuration: config, persistence: complete)
    let turn = try await original.prompt("interrupted prompt")
    for try await _ in turn {}
    _ = try await turn.result
    try await original.close()
    let saved = await complete.load()
    let events = try saved.journal.flatMap { record -> [JSONValue] in
        let value = try JSONDecoder().decode(JSONValue.self, from: record.data)
        guard case .array(let batch) = value["events"] else { throw FxPersistenceError.invalidJournal }
        return batch
    }
    guard let boundary = events.firstIndex(where: { $0["type"] == .string("turn_progress") }) else {
        Issue.record("Missing pre-request progress record"); return
    }
    // Simulate a process losing everything after its durable pre-request record.
    let interrupted = FxMemoryPersistence()
    let record = try JSONEncoder().encode(JSONValue.object([
        "format": .string("libfx-journal-v1"), "events": .array(Array(events[...boundary])),
    ]))
    _ = try await interrupted.append(expected: nil, idempotencyKey: "seed", data: record, barrier: true)
    let resumed = try await FxEngine.open(configuration: config, persistence: interrupted)
    #expect(await resumed.recoveryState != nil)
    await #expect(throws: FxError.self) { try await resumed.prompt("") }
    #expect(await resumed.recoveryState != nil)
    let recovery = try #require(try await resumed.resume())
    for try await _ in recovery {}
    #expect(try await recovery.result.stopReason == .endTurn)
    #expect(await resumed.recoveryState == nil)
    #expect(try await resumed.resume() == nil)
    try await resumed.close()
    let requests = await gateway.bodies
    #expect(requests.count == 2)
    #expect(requests.last?.contains("interrupted prompt") == true)
}
