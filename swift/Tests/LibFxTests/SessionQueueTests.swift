import Foundation
import Testing
@testable import LibFx

private final class QueueFailure: Error {}

private actor TestSessionQueue: FxSessionQueue {
    private(set) var messages: [FxSessionWakeup] = []
    private var failure: QueueFailure?
    func failNext(_ error: QueueFailure) { failure = error }
    func enqueue(_ wakeup: FxSessionWakeup) throws {
        if let failure { self.failure = nil; throw failure }
        messages.append(wakeup)
    }
}

private actor QueueHTTP: FxHTTPClient {
    enum Mode { case immediate, held, loop, slow, stall }
    let mode: Mode
    let started = AsyncResult<Void>()
    let release = AsyncResult<Void>()
    private(set) var requests: [String] = []
    private(set) var cancellations = 0
    init(_ mode: Mode = .immediate) { self.mode = mode }
    func send(_ request: URLRequest) async throws -> FxHTTPResponse {
        if request.httpMethod == "GET" {
            return response(#"{"data":[{"id":"swift/queue","type":"language","tags":["tool-use"]}]}"#)
        }
        requests.append(String(decoding: request.httpBody ?? Data(), as: UTF8.self))
        await started.resolve(.success(()))
        do {
            if mode == .held { try await release.wait() }
            if mode == .slow { try await Task.sleep(for: .milliseconds(250)) }
            if mode == .stall { try await Task.sleep(for: .seconds(2)) }
        } catch { cancellations += 1; throw error }
        if mode == .loop && requests.count <= 3 {
            return response("data: {\"type\":\"tool-call\",\"toolCallId\":\"lookup-\(requests.count)\",\"toolName\":\"lookup\",\"input\":{}}\n\ndata: {\"type\":\"finish\",\"finishReason\":{\"unified\":\"tool-calls\",\"raw\":\"tool-calls\"}}\n\ndata: [DONE]\n\n")
        }
        return response("data: {\"type\":\"text-delta\",\"delta\":\"queued\"}\n\ndata: {\"type\":\"finish\",\"finishReason\":{\"unified\":\"stop\",\"raw\":\"stop\"}}\n\ndata: [DONE]\n\n")
    }
    private func response(_ text: String) -> FxHTTPResponse {
        FxHTTPResponse(statusCode: 200, body: AsyncThrowingStream { $0.yield(Data(text.utf8)); $0.finish() })
    }
}

@Suite(.serialized, .timeLimit(.minutes(1))) struct SessionQueueTests {
    private func agent(store: any FxSessionStorage, queue: TestSessionQueue, http: QueueHTTP = QueueHTTP(),
                       tools: [FxTool] = []) throws -> FxAgent {
        try FxAgent(configuration: FxConfiguration(apiKey: "queue-secret", model: "swift/queue", tools: tools, httpClient: http),
                    store: store, checkpointAfterBytes: nil, queue: queue)
    }

    @Test func intakePublishesIdentifiersAndAnotherOwnerExecutesOnce() async throws {
        let store = try FxSessionStore(), queue = TestSessionQueue(), http = QueueHTTP()
        let producer = try agent(store: store, queue: queue, http: http)
        let session = try await producer.session(id: "queued-session")
        let turn = try await session.prompt("private prompt", id: "input")
        #expect(await http.requests.isEmpty)
        #expect(try await store.result(session: session.id, agent: "default", id: "input") == nil)
        let wakeup = try #require(await queue.messages.first)
        let payload = String(decoding: try JSONEncoder().encode(wakeup), as: UTF8.self)
        #expect(!payload.contains("private prompt") && !payload.contains("queue-secret"))
        try await producer.close()
        let worker = try agent(store: store, queue: queue, http: http)
        #expect(try await worker.deliver(wakeup) == .complete)
        #expect(try await worker.deliver(wakeup) == .complete)
        #expect(try await turn.result.stopReason == .endTurn)
        #expect(await http.requests.count == 1)
        try await worker.close()
        try await store.close()
    }

    @Test(arguments: [false, true]) func publishFailureLeavesInputAvailableForResume(retryInput: Bool) async throws {
        let store = try FxSessionStore(), queue = TestSessionQueue(), failure = QueueFailure(), http = QueueHTTP()
        let producer = try agent(store: store, queue: queue, http: http)
        let session = try await producer.session(id: "publish-failure")
        await queue.failNext(failure)
        do { _ = try await session.prompt("original", id: "input"); Issue.record("Queue failure was ignored") }
        catch { #expect((error as? QueueFailure) === failure) }
        #expect(try await store.pendingID(session: session.id, agent: "default") == "input")
        #expect(await http.requests.isEmpty)
        let resumed: FxSessionTurn
        if retryInput {
            resumed = try await session.prompt("replacement must not execute", id: "input")
            #expect(resumed.isRepeated)
        } else { resumed = try #require(try await session.resume()) }
        let wakeup = try #require(await queue.messages.first)
        #expect(try await producer.deliver(wakeup) == .complete)
        #expect(try await resumed.result.stopReason == .endTurn)
        #expect(await http.requests.first?.contains("original") == true)
        #expect(await http.requests.first?.contains("replacement must not execute") == false)
        try await producer.close()
        try await store.close()
    }

    @Test func deliveryStorageFailureRetainsWorkAndCanBeRetried() async throws {
        let database = try FxSessionStore(), store = SessionStorageProxy(database)
        let queue = TestSessionQueue(), http = QueueHTTP(), failure = SessionStorageTestFailure()
        let worker = try agent(store: store, queue: queue, http: http)
        let session = try await worker.session(id: "retry-storage")
        _ = try await session.prompt("hello", id: "input")
        let wakeup = try #require(await queue.messages.first)
        await store.failNext("loadJournal", with: failure)
        do { _ = try await worker.deliver(wakeup); Issue.record("Storage failure was ignored") }
        catch { #expect((error as? SessionStorageTestFailure) === failure) }
        #expect(try await database.hasWork(session: session.id, agent: "default"))
        #expect(await http.requests.isEmpty)
        #expect(try await worker.deliver(wakeup) == .complete)
        #expect(try await database.result(session: session.id, agent: "default", id: "input")?.stopReason == .endTurn)
        #expect(await http.requests.count == 1)
        try await worker.close()
        try await database.close()
    }

    @Test func cancellingQueuedInputPreservesTheOtherInput() async throws {
        let store = try FxSessionStore(), queue = TestSessionQueue(), http = QueueHTTP()
        let worker = try agent(store: store, queue: queue, http: http)
        let session = try await worker.session(id: "queued-cancellation")
        let first = try await session.prompt("first", id: "first")
        let second = try await session.prompt("second", id: "second")
        try await second.cancel()
        #expect(await queue.messages.count == 3)
        let wakeup = try #require(await queue.messages.first)
        #expect(try await worker.deliver(wakeup) == .complete)
        #expect(try await first.result.stopReason == .endTurn)
        #expect(try await second.result.stopReason == .cancelled)
        #expect(await http.requests.count == 1)
        try await worker.close()
        try await store.close()
    }

    @Test func simultaneousDeliveryWaitersShareWorkAndCancelIndependently() async throws {
        let store = try FxSessionStore(), queue = TestSessionQueue(), http = QueueHTTP(.held)
        let worker = try agent(store: store, queue: queue, http: http)
        let session = try await worker.session(id: "duplicate")
        let turn = try await session.prompt("hello", id: "input")
        let wakeup = try #require(await queue.messages.first)
        let first = Task { try await worker.deliver(wakeup) }
        try await http.started.wait()
        let second = Task { try await worker.deliver(wakeup) }
        first.cancel()
        await #expect(throws: CancellationError.self) { try await first.value }
        #expect(await http.cancellations == 0)
        await http.release.resolve(.success(()))
        #expect(try await second.value == .complete)
        #expect(try await turn.result.stopReason == .endTurn)
        #expect(await http.requests.count == 1)
        try await worker.close()
        try await store.close()
    }

    @Test func anotherConnectionRetriesWhileTheCurrentOwnerRuns() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("sessions.sqlite")
        let store = try FxSessionStore(url: url), other = try FxSessionStore(url: url)
        let queue = TestSessionQueue(), http = QueueHTTP(.held)
        let first = try agent(store: store, queue: queue, http: http), second = try agent(store: other, queue: queue, http: http)
        let session = try await first.session(id: "competing"), turn = try await session.prompt("hello", id: "input")
        let wakeup = try #require(await queue.messages.first)
        let running = Task { try await first.deliver(wakeup) }
        try await http.started.wait()
        #expect(try await second.deliver(wakeup) == .retry(after: .seconds(1)))
        await http.release.resolve(.success(()))
        #expect(try await running.value == .complete)
        #expect(try await second.deliver(wakeup) == .complete)
        #expect(try await turn.result.stopReason == .endTurn)
        #expect(await http.requests.count == 1)
        try await first.close(); try await second.close()
        try await store.close(); try await other.close()
    }

    @Test func yieldedDeliveriesContinueOneLogicalTurn() async throws {
        let store = try FxSessionStore(), queue = TestSessionQueue(), http = QueueHTTP(.loop)
        let tool = FxTool(name: "lookup", description: "Lookup", inputSchema: .object(["type": .string("object")]), isIdempotent: true) { _, _ in "found" }
        let worker = try agent(store: store, queue: queue, http: http, tools: [tool])
        let session = try await worker.session(id: "yielded"), turn = try await session.prompt("look up", id: "input")
        let wakeup = try #require(await queue.messages.first)
        let policy = try FxDeliveryPolicy(maximumDuration: .zero, reserve: .zero)
        for _ in 0..<3 { #expect(try await worker.deliver(wakeup, policy: policy) == .retry(after: .zero)) }
        #expect(try await worker.deliver(wakeup, policy: policy) == .complete)
        #expect(try await turn.result.stopReason == .endTurn)
        let history = try await store.entries(session: session.id, agent: "default", after: 0)
        #expect(history.filter { if case .started = $0.event { return true }; return false }.count == 1)
        #expect(history.filter { if case .yielded = $0.event { return true }; return false }.count == 3)
        #expect(history.filter { if case .ended = $0.event { return true }; return false }.count == 1)
        #expect(await http.requests.count == 4)
        try await worker.close()
        try await store.close()
    }

    @Test func deliveryBudgetCoversAllInputsAndCutsOffQuietRequests() async throws {
        for mode in [QueueHTTP.Mode.slow, .stall] {
            let store = try FxSessionStore(), queue = TestSessionQueue(), http = QueueHTTP(mode)
            let worker = try agent(store: store, queue: queue, http: http)
            let session = try await worker.session(id: "budget")
            _ = try await session.prompt("one", id: "one")
            if mode == .slow { _ = try await session.prompt("two", id: "two") }
            let wakeup = try #require(await queue.messages.first)
            let policy = try FxDeliveryPolicy(maximumDuration: .milliseconds(mode == .slow ? 500 : 200),
                                              reserve: .milliseconds(100))
            #expect(try await worker.deliver(wakeup, policy: policy) == .retry(after: .zero))
            #expect(try await store.hasWork(session: session.id, agent: "default"))
            #expect(await http.requests.count <= (mode == .slow ? 2 : 1))
            try await worker.close()
            try await store.close()
        }
    }

    @Test func rejectedWakeupsDoNotCreateOrReadSessions() async throws {
        let database = try FxSessionStore(), store = SessionStorageProxy(database), queue = TestSessionQueue()
        let worker = try agent(store: store, queue: queue)
        await #expect(throws: FxSessionError.wrongAgent) { try await worker.deliver(.init(agent: "other", sessionID: "session")) }
        await #expect(throws: FxError.self) { try await worker.deliver(.init(agent: "default", sessionID: "bad id")) }
        #expect(await store.calls.isEmpty)
        #expect(try await worker.deliver(.init(agent: "default", sessionID: "missing")) == .complete)
        try await worker.close()
        try await database.close()
    }
}
