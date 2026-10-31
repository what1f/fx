import Foundation
import Testing
import CryptoKit
@testable import LibFx

private actor SessionHTTP: FxHTTPClient {
    private var requests: [URLRequest] = []
    private var blocked = false
    private var gate: CheckedContinuation<Void, Never>?
    init(blocked: Bool = false) { self.blocked = blocked }
    func send(_ request: URLRequest) async throws -> FxHTTPResponse {
        if request.httpMethod == "GET" {
            let data = Data(#"{"data":[{"id":"swift/test","type":"language","tags":["vision"]}]}"#.utf8)
            return FxHTTPResponse(statusCode: 200, body: AsyncThrowingStream { $0.yield(data); $0.finish() })
        }
        requests.append(request)
        if blocked { await withCheckedContinuation { gate = $0 } }
        let text = "data: {\"type\":\"text-delta\",\"delta\":\"hello\"}\n\ndata: {\"type\":\"finish\",\"finishReason\":{\"unified\":\"stop\",\"raw\":\"stop\"}}\n\ndata: [DONE]\n\n"
        return FxHTTPResponse(statusCode: 200, body: AsyncThrowingStream { $0.yield(Data(text.utf8)); $0.finish() })
    }
    var count: Int { requests.count }
    var bodies: [String] { requests.map { String(decoding: $0.httpBody ?? Data(), as: UTF8.self) } }
    func waitForRequest() async { while requests.isEmpty { await Task.yield() } }
    func release() { blocked = false; gate?.resume(); gate = nil }
}

private actor SessionToolHTTP: FxHTTPClient {
    private(set) var bodies: [String] = []
    func send(_ request: URLRequest) async throws -> FxHTTPResponse {
        let text: String
        if request.httpMethod == "GET" {
            text = #"{"data":[{"id":"swift/test","type":"language","tags":["tool-use"]}]}"#
        } else {
            bodies.append(String(decoding: request.httpBody ?? Data(), as: UTF8.self))
            let frames: [JSONValue] = bodies.count == 1 ? [
                .object(["type": .string("tool-call"), "toolCallId": .string("call-1"), "toolName": .string("inspect"), "input": .object([:])]),
                .object(["type": .string("finish"), "finishReason": .object(["unified": .string("tool-calls"), "raw": .string("tool-calls")])]),
            ] : [
                .object(["type": .string("text-delta"), "delta": .string("inspected")]),
                .object(["type": .string("finish"), "finishReason": .object(["unified": .string("stop"), "raw": .string("stop")])]),
            ]
            text = try frames.map { "data: \(String(decoding: try JSONEncoder().encode($0), as: UTF8.self))\n\n" }.joined() + "data: [DONE]\n\n"
        }
        return FxHTTPResponse(statusCode: 200, body: AsyncThrowingStream { $0.yield(Data(text.utf8)); $0.finish() })
    }
}

private actor SessionToolCapture {
    private(set) var values: [FxToolContext] = []
    func record(_ value: FxToolContext) { values.append(value) }
}

private actor SessionStreamingHTTP: FxHTTPClient {
    private var body: AsyncThrowingStream<Data, any Error>.Continuation?
    func send(_ request: URLRequest) async throws -> FxHTTPResponse {
        if request.httpMethod == "GET" { return try await SessionHTTP().send(request) }
        let stream = AsyncThrowingStream<Data, any Error>.makeStream()
        body = stream.continuation
        body?.yield(Data("data: {\"type\":\"text-delta\",\"delta\":\"before\"}\n\n".utf8))
        return FxHTTPResponse(statusCode: 200, body: stream.stream)
    }
    func finish() {
        body?.yield(Data("data: {\"type\":\"text-delta\",\"delta\":\"after\"}\n\ndata: {\"type\":\"finish\",\"finishReason\":{\"unified\":\"stop\",\"raw\":\"stop\"}}\n\ndata: [DONE]\n\n".utf8))
        body?.finish()
        body = nil
    }
}

@Suite(.serialized) struct AgentTests {
    @Test func queueRunsNativeCoreAndResultsReplayWithoutNewCalls() async throws {
        let http = SessionHTTP(), store = try FxSessionStore()
        let agent = try FxAgent(configuration: config(http), store: store)
        let session = try await agent.session(id: "logical-session")
        #expect(try await session.resume() == nil)
        let first = try await session.prompt("first", id: "one")
        let second = try await session.prompt("second", id: "two")
        #expect(try await first.result.stopReason == .endTurn)
        #expect(try await second.result.stopReason == .endTurn)
        var text = ""
        for try await event in first { if case .text(let delta) = event { text += delta } }
        #expect(text == "hello")
        var replay = ""
        for try await event in first { if case .text(let delta) = event { replay += delta } }
        #expect(replay == text)
        let duplicate = try await session.prompt("ignored", id: "one")
        #expect(try await duplicate.result.isRepeated)
        try await agent.close()
        #expect(await http.count == 2)
        await #expect(throws: FxError.closed) { try await session.prompt("closed") }
        try await store.close()
    }

    @Test func closeDrainsAcceptedWorkAndReaderCancellationDoesNotCancelIt() async throws {
        let http = SessionHTTP(blocked: true), store = try FxSessionStore()
        let agent = try FxAgent(configuration: config(http), store: store)
        let session = try await agent.session(id: "s")
        let turn = try await session.prompt("hello", id: "m")
        await http.waitForRequest()
        let reader = Task { try await turn.result }
        reader.cancel()
        await #expect(throws: CancellationError.self) { try await reader.value }
        let closing = Task { try await agent.close() }
        await http.release()
        try await closing.value
        #expect(try await turn.result.stopReason == .endTurn)
        #expect(await http.count == 1)
        try await store.close()
    }

    @Test func explicitQueuedCancellationDoesNotAffectCurrentTurn() async throws {
        let http = SessionHTTP(blocked: true), store = try FxSessionStore()
        let agent = try FxAgent(configuration: config(http), store: store)
        let session = try await agent.session(id: "s")
        let first = try await session.prompt("first", id: "one")
        await http.waitForRequest()
        let second = try await session.prompt("second", id: "two")
        try await second.cancel()
        await http.release()
        #expect(try await first.result.stopReason == .endTurn)
        #expect(try await second.result.stopReason == .cancelled)
        try await agent.close()
        #expect(await http.count == 1)
        try await store.close()
    }

    @Test func sessionCancellationLeavesQueuedTurnsRunnable() async throws {
        for _ in 0..<20 {
            let http = SessionHTTP(blocked: true), store = try FxSessionStore()
            let agent = try FxAgent(configuration: config(http), store: store)
            let session = try await agent.session(id: "cancel-then-continue")
            let first = try await session.prompt("first", id: "one")
            await http.waitForRequest()
            let second = try await session.prompt("second", id: "two")
            try await session.cancel()
            await http.release()
            #expect(try await first.result.stopReason == .cancelled)
            #expect(try await second.result.stopReason == .endTurn)
            try await agent.close()
            try await store.close()
        }
    }

    @Test func competingAgentsDrainOneInboxAndReopenDeduplicatesHistory() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("sessions.sqlite")
        let http = SessionHTTP(blocked: true)
        let aStore = try FxSessionStore(url: url), bStore = try FxSessionStore(url: url)
        let a = try FxAgent(configuration: config(http), store: aStore)
        let b = try FxAgent(configuration: config(http), store: bStore)
        let aSession = try await a.session(id: "s"), bSession = try await b.session(id: "s")
        let first = try await aSession.prompt("first", id: "one")
        await http.waitForRequest()
        let second = try await bSession.prompt("second", id: "two")
        await http.release()
        #expect(try await first.result.stopReason == .endTurn)
        #expect(try await second.result.stopReason == .endTurn)
        try await a.close()
        try await b.close()
        try await aStore.close()
        try await bStore.close()
        let reopened = try FxSessionStore(url: url)
        let c = try FxAgent(configuration: config(http), store: reopened)
        let session = try await c.session(id: "s")
        let duplicate = try await session.prompt("ignored", id: "one")
        #expect(try await duplicate.result.isRepeated)
        #expect(await http.count == 2)
        try await c.close()
        try await reopened.close()
    }

    @Test func startedInputWithoutCoreDispatchResumesNormally() async throws {
        let store = try FxSessionStore(), http = SessionHTTP()
        _ = try await store.accept(session: "s", agent: "default", id: "m", content: [.text("accepted")], options: .init())
        let lease = try #require(try await store.claim(session: "s", agent: "default"))
        try await store.start(lease, input: #require(try await store.next(lease)))
        try await store.release(lease)
        let agent = try FxAgent(configuration: config(http), store: store)
        let session = try await agent.session(id: "s")
        let turn = try #require(try await session.resume())
        #expect(turn.id == "m")
        #expect(try await turn.result.stopReason == .endTurn)
        #expect(try await session.resume() == nil)
        #expect(await http.count == 1)
        let entries = try await store.entries(session: "s", agent: "default", after: 0)
        #expect(entries.contains { $0.event == .resumed(id: "m", sessionID: "s") })
        try await agent.close()
        try await store.close()
    }

    @Test func recoveryKeepsPreviouslyDeliveredReplyOnceInSessionReplay() async throws {
        let source = FxMemoryPersistence(), http = SessionHTTP()
        let id = "turn_" + SHA256.hash(data: Data("m".utf8)).map { String(format: "%02x", $0) }.joined()
        let engine = try await FxEngine.open(configuration: config(http), sessionID: "s", persistence: source)
        let original = try await engine.prompt("accepted", id: id)
        #expect(try await original.result.stopReason == .endTurn)
        try await engine.close()
        let events = try await source.load().journal.flatMap { record -> [JSONValue] in
            guard case .array(let batch) = try JSONDecoder().decode(JSONValue.self, from: record.data)["events"] else {
                throw FxPersistenceError.invalidJournal
            }
            return batch
        }
        let boundary = try #require(events.lastIndex { $0["type"] == .string("turn_progress") && $0["data"]?["action"] == .string("delivering_response") })
        let store = try FxSessionStore()
        _ = try await store.accept(session: "s", agent: "default", id: "m", content: [.text("accepted")], options: .init())
        let lease = try #require(try await store.claim(session: "s", agent: "default"))
        try await store.start(lease, input: #require(try await store.next(lease)))
        let data = try JSONEncoder().encode(JSONValue.object([
            "format": .string("libfx-journal-v1"), "events": .array(Array(events[...boundary])),
        ]))
        _ = try await store.appendJournal(lease, expected: nil, key: "cut", data: data)
        try await store.appendEvent(lease, .update(id: "m", .text("hello")))
        try await store.release(lease)
        // Simulate stopping after delivery, before the final core and host commits.
        let agent = try FxAgent(configuration: config(http), store: store)
        let session = try await agent.session(id: "s")
        let resumed = try #require(try await session.resume())
        #expect(try await resumed.result.stopReason == .endTurn)
        var text = ""
        for try await event in resumed { if case .text(let delta) = event { text += delta } }
        #expect(text.isEmpty, "A resumed turn must not redeliver stored output")
        let entries = try await store.entries(session: "s", agent: "default", after: 0)
        let replay = entries.compactMap { entry -> String? in
            guard case .update("m", .text(let delta)) = entry.event else { return nil }
            return delta
        }.joined()
        #expect(replay == "hello")
        #expect(await http.count == 1)
        #expect(try await session.resume() == nil)
        try await agent.close()
        try await store.close()
    }

    @Test func resumedViewStartsAfterAlreadyObservedOutput() async throws {
        let http = SessionStreamingHTTP(), store = try FxSessionStore()
        let configuration = FxConfiguration(apiKey: "test-key", model: "swift/test", httpClient: http)
        let agent = try FxAgent(configuration: configuration, store: store)
        let session = try await agent.session(id: "streaming")
        let original = try await session.prompt("hello", id: "m")
        var iterator = original.makeAsyncIterator()
        var before = ""
        while before.isEmpty, let event = try await iterator.next() {
            if case .text(let delta) = event { before += delta }
        }
        #expect(before == "before")
        let resumed = try #require(try await session.resume())
        await http.finish()
        var after = ""
        for try await event in resumed { if case .text(let delta) = event { after += delta } }
        #expect(after == "after")
        #expect(try await resumed.result.stopReason == .endTurn)
        var replay = ""
        for try await event in original { if case .text(let delta) = event { replay += delta } }
        #expect(replay == "beforeafter", "The original view retains its independent replay cursor")
        try await agent.close()
        try await store.close()
    }

    @Test func missingHostCompletionReportsUnknownWithoutRepeatingCoreWork() async throws {
        let store = try FxSessionStore(), http = SessionHTTP()
        _ = try await store.accept(session: "s", agent: "default", id: "m", content: [.text("accepted")], options: .init())
        let lease = try #require(try await store.claim(session: "s", agent: "default"))
        try await store.start(lease, input: #require(try await store.next(lease)))
        let engine = try await FxEngine.open(configuration: config(http), sessionID: "s", persistence: SessionPersistence(store: store, lease: lease))
        let id = "turn_" + SHA256.hash(data: Data("m".utf8)).map { String(format: "%02x", $0) }.joined()
        let turn = try await engine.prompt("accepted", id: id)
        #expect(try await turn.result.stopReason == .endTurn)
        try await engine.close()
        // Simulate a process stopping after the core commit, before the host result.
        try await store.release(lease)
        let agent = try FxAgent(configuration: config(http), store: store)
        let session = try await agent.session(id: "s")
        let repeated = try await session.prompt("ignored duplicate", id: "m")
        #expect(try await repeated.result.stopReason == .unknown)
        #expect(await http.count == 1)
        try await agent.close()
        try await store.close()
    }

    @Test func toolsReceivePublicIdentityAndPersistedContext() async throws {
        let http = SessionToolHTTP(), capture = SessionToolCapture(), store = try FxSessionStore()
        let tool = FxTool(name: "inspect", description: "Inspect", inputSchema: .object(["type": .string("object")]), isIdempotent: true) { _, context in
            await capture.record(context)
            return "inspected"
        }
        let config = FxConfiguration(apiKey: "test-key", model: "swift/test", instructions: "base instructions", tools: [tool], httpClient: http)
        let agent = try FxAgent(configuration: config, store: store)
        let options = FxSessionOptions(model: "swift/test", instructions: "session instructions", context: .object(["project": .string("example")]))
        let session = try await agent.session(id: "public-session", options: options)
        let turn = try await session.prompt("inspect", id: "public-message")
        #expect(try await turn.result.stopReason == .endTurn)
        let values = await capture.values
        #expect(values.count == 1)
        let context = try #require(values.first)
        #expect(context.executionID == "call-1" && context.sessionID == "public-session" && context.turnID == "public-message")
        #expect(context.context == options.context)
        let bodies = await http.bodies
        #expect(bodies.first?.contains("session instructions") == true)
        #expect(bodies.first?.contains("base instructions") == false)
        try await agent.close()
        try await store.close()
    }

    @Test func sessionCheckpointIsReadOnlyAndSeedsANewAgent() async throws {
        let http = SessionHTTP(), store = try FxSessionStore()
        let source = try FxAgent(configuration: config(http), store: store)
        let session = try await source.session(id: "source")
        let png = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jP0cAAAAASUVORK5CYII="
        let image = FxImage(data: try #require(Data(base64Encoded: png)), format: .png)
        let first = try await session.prompt([.text("remember kiwi"), .image(image)], id: "one")
        #expect(try await first.result.stopReason == .endTurn)
        let before = try await store.snapshot(session: "source", agent: "default")
        let events = try await store.entries(session: "source", agent: "default", after: 0)
        let checkpoint = try await session.checkpoint()
        let after = try await store.snapshot(session: "source", agent: "default")
        #expect(before.head == after.head && before.checkpoint == after.checkpoint && before.journal == after.journal)
        #expect(try await store.entries(session: "source", agent: "default", after: 0) == events)
        #expect(await http.count == 1)
        try await source.close()
        let clonedStore = try FxSessionStore()
        let cloned = try FxAgent(configuration: config(http), store: clonedStore, checkpoint: checkpoint)
        let clone = try await cloned.session(id: "clone")
        let next = try await clone.prompt("what word", id: "two")
        #expect(try await next.result.stopReason == .endTurn)
        #expect(await http.bodies.last?.contains("remember kiwi") == true)
        #expect(await http.bodies.last?.contains(png) == true)
        try await cloned.close()
        // A seed only applies when the stored session is first created.
        let reopened = try FxAgent(configuration: config(http), store: clonedStore, checkpoint: Data([1, 2, 3]))
        let existing = try await reopened.session(id: "clone")
        let final = try await existing.prompt("continue", id: "three")
        #expect(try await final.result.stopReason == .endTurn)
        #expect(await http.bodies.last?.contains("what word") == true)
        try await reopened.close()
        try await clonedStore.close()
        try await store.close()
    }

    @Test func activeCheckpointDoesNotTakeOverOrChangeTheLiveWorker() async throws {
        let http = SessionHTTP(blocked: true), store = try FxSessionStore()
        let agent = try FxAgent(configuration: config(http), store: store)
        let session = try await agent.session(id: "active")
        let turn = try await session.prompt("in flight")
        await http.waitForRequest()
        let before = try await store.snapshot(session: "active", agent: "default")
        let checkpoint = try await session.checkpoint()
        #expect(!checkpoint.isEmpty)
        let after = try await store.snapshot(session: "active", agent: "default")
        #expect(before.head == after.head && before.checkpoint == after.checkpoint && before.journal == after.journal)
        await http.release()
        #expect(try await turn.result.stopReason == .endTurn)
        #expect(await http.count == 1)
        try await agent.close()
        try await store.close()
    }

    @Test func newSessionCheckpointDoesNotCreateStoredData() async throws {
        let store = try FxSessionStore(), http = SessionHTTP()
        let agent = try FxAgent(configuration: config(http), store: store)
        let session = try await agent.session(id: "fresh")
        #expect(try await session.checkpoint().count > 0)
        await #expect(throws: FxSessionError.notFound) { try await store.claim(session: "fresh", agent: "default") }
        #expect(await http.count == 0)
        try await agent.close()
        try await store.close()
    }

    @Test func invalidCheckpointStoresNoInputOrSession() async throws {
        let store = try FxSessionStore(), http = SessionHTTP()
        let agent = try FxAgent(configuration: config(http), store: store, checkpoint: Data([1, 2, 3]))
        let session = try await agent.session(id: "invalid")
        await #expect(throws: FxError.self) { try await session.prompt("must not be accepted") }
        await #expect(throws: FxSessionError.notFound) { try await store.claim(session: "invalid", agent: "default") }
        #expect(await http.count == 0)
        try await agent.close()
        try await store.close()
    }

    @Test(arguments: [Int?.some(0), nil]) func agentCheckpointIntervalIsExplicit(_ interval: Int?) async throws {
        let http = SessionHTTP(), store = try FxSessionStore()
        let agent = try FxAgent(configuration: config(http), store: store, checkpointAfterBytes: interval)
        let session = try await agent.session(id: "checkpoint-interval")
        let turn = try await session.prompt("remember me")
        #expect(try await turn.result.stopReason == .endTurn)
        let snapshot = try await store.snapshot(session: session.id, agent: agent.name)
        #expect((snapshot.checkpoint != nil) == (interval == 0))
        try await agent.close()
        try await store.close()
    }

    @Test func negativeAgentCheckpointIntervalIsRejected() async throws {
        let store = try FxSessionStore()
        #expect(throws: FxError.invalidInput("Checkpoint interval must not be negative")) {
            try FxAgent(configuration: config(SessionHTTP()), store: store, checkpointAfterBytes: -1)
        }
        try await store.close()
    }

    private func config(_ http: SessionHTTP) -> FxConfiguration {
        FxConfiguration(apiKey: "test-key", model: "swift/test", httpClient: http)
    }
}

private actor ValidationStore: FxPersistence {
    private(set) var loads = 0
    func load() async throws -> FxPersistenceSnapshot {
        loads += 1
        return FxPersistenceSnapshot()
    }
    func append(expected: String?, idempotencyKey: String, data: Data, barrier: Bool) async throws -> String {
        throw FxPersistenceError.fenced
    }
}

@Test func invalidConfigurationIsRejectedBeforeStorageOrNetwork() async throws {
    let store = ValidationStore(), http = SessionHTTP()
    for (key, model, message) in [("", "swift/test", "API key is required"), ("test-key", "", "Model is required")] {
        let config = FxConfiguration(apiKey: key, model: FxModel(id: model), httpClient: http)
        await #expect(throws: FxError.invalidInput(message)) { try await FxEngine.open(configuration: config, persistence: store) }
    }
    #expect(await store.loads == 0)
    #expect(await http.count == 0)
}

@Test func durableConfigurationFailurePreservesSafeDiagnostic() async throws {
    let store = try FxSessionStore(), http = SessionHTTP()
    let agent = try FxAgent(configuration: .init(apiKey: "test-key", model: "", httpClient: http), store: store)
    let session = try await agent.session(id: "invalid-model")
    let turn = try await session.prompt("hello")
    let result = try await turn.result
    #expect(result.stopReason == .error && result.error == "Model is required")
    #expect(await http.count == 0)
    try await agent.close()
    try await store.close()
}

@Test func durableToolObservationConnectsARealChildEngine() async throws {
    let capture = SessionToolCapture()
    let observed = AgentObservationCapture()
    let tool = FxTool(name: "inspect", description: "Inspect", inputSchema: .object(["type": .string("object")]), isIdempotent: false) { _, context in
        await capture.record(context)
        let scope = try #require(context.observation)
        let answer = await scope.wait(FxWaitRequest(kind: .approval, prompt: "Continue?"), resolution: { $0 }) {
            FxWaitResolution(answers: ["approve"])
        }
        #expect(answer.outcome == .accepted && answer.answers == ["approve"])
        let child = try await FxEngine.open(configuration: FxConfiguration(
            apiKey: "test", model: "swift/test", httpClient: SessionHTTP(), observation: scope.childOptions()))
        let turn = try await child.prompt("child", id: "child-turn")
        for try await _ in turn {}
        _ = try await turn.result
        try await child.close()
        return FxToolResult(text: "child finished")
    }
    let store = try FxSessionStore()
    let agent = try FxAgent(configuration: FxConfiguration(apiKey: "test", model: "swift/test", tools: [tool],
        httpClient: SessionToolHTTP(), observation: FxObservationOptions(onEvent: observed.record)), store: store)
    let session = try await agent.session(id: "logical-parent")
    let turn = try await session.prompt("Inspect", id: "logical-turn")
    #expect(try await turn.result.stopReason == .endTurn)
    try await agent.close()
    try await store.close()
    let context = try #require(await capture.values.first)
    #expect(context.sessionID == "logical-parent" && context.turnID == "logical-turn")
    let scope = try #require(context.observation)
    let parentStart = try #require(observed.events.first { $0.kind == .toolStarted && $0.sessionID == context.sessionID })
    #expect(scope.scope.sessionID == context.sessionID && scope.scope.turnID == parentStart.turnID)
    #expect(scope.callID == "call-1")
    let waits = observed.events.filter { $0.kind == .waitStarted || $0.kind == .waitEnded }
    #expect(waits.map(\.kind) == [.waitStarted, .waitEnded])
    #expect(waits.first?.data["requestId"] == waits.last?.data["requestId"])
    #expect(waits.first?.data["callId"] == .string("call-1"))
    #expect(waits.last?.data["outcome"] == .string("accepted") && waits.last?.data["answers"] == nil)
    #expect(waits.allSatisfy { $0.sessionID == parentStart.sessionID && $0.turnID == parentStart.turnID && $0.executionID == parentStart.executionID })
    let children = observed.events.filter { $0.sessionID != "logical-parent" }
    #expect(children.contains { $0.kind == .turnStarted })
    #expect(children.contains { $0.kind == .turnEnded })
    #expect(children.allSatisfy {
        $0.rootSessionID == "logical-parent" && $0.parentSessionID == "logical-parent"
        && $0.parentTurnID == parentStart.turnID && $0.parentCallID == "call-1" && $0.turnID == "child-turn"
    })
    let count = observed.events.count
    #expect(await scope.mcp(tool: "retained-after-close") { "still calls the effect" } == "still calls the effect")
    #expect(observed.events.count == count)
}

private final class AgentObservationCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [FxObservation] = []
    var events: [FxObservation] { lock.withLock { stored } }
    func record(_ event: FxObservation) { lock.withLock { stored.append(event) } }
}
