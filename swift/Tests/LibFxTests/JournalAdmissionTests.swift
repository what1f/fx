import Foundation
import Testing
@testable import LibFx

private actor AdmissionHTTP: FxHTTPClient {
    private(set) var posts = 0
    func send(_ request: URLRequest) throws -> FxHTTPResponse {
        let text: String
        if request.httpMethod == "GET" {
            text = #"{"data":[{"id":"swift/journal-admission","type":"language","tags":["tool-use"]}]}"#
        } else {
            posts += 1
            var events: [JSONValue] = []
            if posts == 1 {
                events.append(.object(["type": .string("tool-call"), "toolCallId": .string("probe-1"),
                    "toolName": .string("probe"), "input": .object([:])]))
            }
            events.append(.object(["type": .string("finish"), "finishReason": .object([
                "unified": .string(posts == 1 ? "tool-calls" : "stop"),
                "raw": .string(posts == 1 ? "tool-calls" : "stop"),
            ])]))
            text = try events.map { "data: \(String(decoding: try JSONEncoder().encode($0), as: UTF8.self))\n\n" }.joined() + "data: [DONE]\n\n"
        }
        return FxHTTPResponse(statusCode: 200, body: AsyncThrowingStream { $0.yield(Data(text.utf8)); $0.finish() })
    }
}

private actor AdmissionStore: FxPersistence {
    let memory = FxMemoryPersistence()
    private var held: CheckedContinuation<Void, Never>?
    private var arrivals: [CheckedContinuation<Void, Never>] = []
    private(set) var intentPending = false
    private(set) var intentStored = false
    private(set) var toolSawStoredIntent: Bool?
    let failIntent: Bool
    init(failIntent: Bool = false) { self.failIntent = failIntent }
    func load() async -> FxPersistenceSnapshot { await memory.load() }
    func append(expected: String?, idempotencyKey: String, data: Data, barrier: Bool) async throws -> String {
        let record = try JSONDecoder().decode(JSONValue.self, from: data)
        if case .array(let events) = record["events"], events.contains(where: { $0["type"] == .string("tool_intent") }) {
            intentPending = true
            await withCheckedContinuation { continuation in
                held = continuation
                for arrival in arrivals { arrival.resume() }
                arrivals = []
            }
            intentPending = false
            if failIntent { throw FxPersistenceError.fenced }
            intentStored = true
        }
        return try await memory.append(expected: expected, idempotencyKey: idempotencyKey, data: data, barrier: barrier)
    }
    func waitForIntent() async {
        if held != nil { return }
        await withCheckedContinuation { arrivals.append($0) }
    }
    func release() { held?.resume(); held = nil }
    func execute(reader: Bool) -> FxToolResult {
        toolSawStoredIntent = intentStored
        if reader { release() }
        return FxToolResult(text: "probe result")
    }
}

private actor CommitLatch {
    private var gate: CheckedContinuation<Void, Never>?
    private var arrival: CheckedContinuation<Void, Never>?
    private(set) var cursors: [String] = []
    func receive(_ result: Result<JournalWriter.Commit, any Error>) async {
        guard case .success(let commit) = result else { Issue.record("Unexpected append failure"); return }
        cursors.append(commit.cursor)
        if cursors.count == 1 {
            await withCheckedContinuation { continuation in
                gate = continuation
                arrival?.resume(); arrival = nil
            }
        }
    }
    func wait() async {
        if gate != nil { return }
        await withCheckedContinuation { arrival = $0 }
    }
    func release() { gate?.resume(); gate = nil }
}

@Suite(.serialized) struct JournalAdmissionTests {
    @Test(.timeLimit(.minutes(1)))
    func flushJoinsCommitDeliveryAndPreservesQueuedRecordOrder() async throws {
        let store = FxMemoryPersistence(), commits = CommitLatch()
        let writer = JournalWriter(store: store, head: nil)
        await writer.setHandler { await commits.receive($0) }
        func event(_ sequence: Int) -> JSONValue {
            .object(["type": .string("turn_progress"), "seq": .number(Double(sequence))])
        }
        await writer.enqueue(.array([event(1)]), barrier: true)
        await commits.wait()
        // Keep commit delivery suspended while later events arrive. They must
        // share the next record and continue the cursor of the first write.
        await writer.enqueue(.array([event(2)]), barrier: false)
        await writer.enqueue(.array([event(3)]), barrier: false)
        let flushed = Task { try await writer.check() }
        #expect(await store.load().journal.count == 1)
        await commits.release()
        try await flushed.value
        let records = await store.load().journal
        #expect(records.count == 2)
        let batches = try records.map { try JSONDecoder().decode(JSONValue.self, from: $0.data)["events"] }
        #expect(batches == [.array([event(1)]), .array([event(2), event(3)])])
        #expect(await commits.cursors == records.map(\.cursor))
        try await writer.checkFailure()
    }

    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func nativeCoreControlsDurabilityBeforeToolExecution(reader: Bool) async throws {
        let store = AdmissionStore(), http = AdmissionHTTP()
        let tool = FxTool(name: "probe", description: "Admission probe", inputSchema: .object(["type": .string("object")]),
            isIdempotent: true, writes: !reader) { _, _ in
                if reader { await store.waitForIntent() }
                return await store.execute(reader: reader)
            }
        let engine = try await FxEngine.open(configuration: FxConfiguration(apiKey: "fixture", model: "swift/journal-admission", tools: [tool], httpClient: http), persistence: store)
        let turn = try await engine.prompt("run probe")
        if !reader {
            await store.waitForIntent()
            #expect(await store.toolSawStoredIntent == nil)
            await store.release()
        }
        #expect(try await turn.result.stopReason == .endTurn)
        #expect(await store.toolSawStoredIntent == !reader)
        #expect(await http.posts == 2)
        try await engine.close()
    }

    @Test(.timeLimit(.minutes(1)))
    func failedIntentAfterReadAdmissionStopsFurtherModelRequests() async throws {
        let store = AdmissionStore(failIntent: true), http = AdmissionHTTP()
        let tool = FxTool(name: "probe", description: "Admission probe", inputSchema: .object(["type": .string("object")]), isIdempotent: true) { _, _ in
            await store.waitForIntent()
            return await store.execute(reader: true)
        }
        let engine = try await FxEngine.open(configuration: FxConfiguration(apiKey: "fixture", model: "swift/journal-admission", tools: [tool], httpClient: http), persistence: store)
        let turn = try await engine.prompt("run probe")
        await #expect(throws: FxPersistenceError.fenced) { _ = try await turn.result }
        #expect(await store.toolSawStoredIntent == false)
        #expect(await http.posts == 1)
        await #expect(throws: FxPersistenceError.fenced) { try await engine.flushPersistence() }
        await #expect(throws: FxPersistenceError.fenced) { try await engine.close() }
    }
}
