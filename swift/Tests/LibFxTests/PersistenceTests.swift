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
    await #expect(throws: FxError.self) { try await resumed.prompt("would duplicate input") }
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
