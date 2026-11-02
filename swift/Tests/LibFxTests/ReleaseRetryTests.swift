import Foundation
import Testing
@testable import LibFx

private actor ReleaseQueue: FxSessionQueue {
    func enqueue(_ wakeup: FxSessionWakeup) {}
}

private actor ReleaseEvents {
    private(set) var failures: [any Error] = []
    private(set) var lease: FxSessionLease?
    func claimed(_ lease: FxSessionLease?) { if let lease { self.lease = lease } }
    func record(_ event: FxLifecycleEvent) {
        if case .storageFailed(_, let error) = event { failures.append(error) }
    }
}

private actor ReleaseHTTP: FxHTTPClient {
    private(set) var modelRequests = 0
    private(set) var toolCalls = 0
    func called() { toolCalls += 1 }
    func send(_ request: URLRequest) async throws -> FxHTTPResponse {
        let text: String
        if request.httpMethod == "GET" {
            text = #"{"data":[{"id":"swift/release","type":"language","tags":["tool-use"]}]}"#
        } else {
            modelRequests += 1
            text = modelRequests == 1
                ? "data: {\"type\":\"tool-call\",\"toolCallId\":\"lookup-once\",\"toolName\":\"lookup\",\"input\":{}}\n\ndata: {\"type\":\"finish\",\"finishReason\":{\"unified\":\"tool-calls\",\"raw\":\"tool-calls\"}}\n\ndata: [DONE]\n\n"
                : "data: {\"type\":\"text-delta\",\"delta\":\"complete\"}\n\ndata: {\"type\":\"finish\",\"finishReason\":{\"unified\":\"stop\",\"raw\":\"stop\"}}\n\ndata: [DONE]\n\n"
        }
        return FxHTTPResponse(statusCode: 200, body: AsyncThrowingStream { $0.yield(Data(text.utf8)); $0.finish() })
    }
}

@Suite(.serialized, .timeLimit(.minutes(1))) struct ReleaseRetryTests {
    @Test func failedSQLiteReleaseRetainsTheLockUntilItsWriteCommits() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("release.sqlite")
        let store = try FxSessionStore(url: url), other = try FxSessionStore(url: url)
        let database = try SQLiteDatabase(path: url.path)
        _ = try await store.accept(session: "session", agent: "default", id: "input", content: [.text("hello")], options: .init())
        let lease = try #require(try await store.claim(session: "session", agent: "default"))
        try database.execute("CREATE TRIGGER refuse_release BEFORE UPDATE OF owner ON fx_sessions WHEN OLD.owner IS NOT NULL AND NEW.owner IS NULL BEGIN SELECT RAISE(ABORT,'release unavailable'); END")
        await #expect(throws: FxSQLiteError.self) { try await store.release(lease) }
        try await store.checkLease(lease)
        #expect(try await other.claim(session: "session", agent: "default") == nil)
        try database.execute("DROP TRIGGER refuse_release")
        try await store.release(lease)
        let successor = try #require(try await other.claim(session: "session", agent: "default"))
        try await store.release(lease)
        try await other.checkLease(successor)
        try await other.release(successor)
        try database.close()
        try await store.close()
        try await other.close()
    }

    @Test func nativeToolYieldRecoversReleaseWithoutReplayingTheTool() async throws {
        let database = try FxSessionStore(), storage = SessionStorageProxy(database), http = ReleaseHTTP()
        await storage.failNext("release", with: SessionStorageTestFailure())
        let tool = FxTool(name: "lookup", description: "Look up", inputSchema: .object(["type": .string("object")]), isIdempotent: true) { _, _ in
            await http.called(); return "found"
        }
        let agent = try FxAgent(configuration: FxConfiguration(apiKey: "fixture", model: "swift/release", tools: [tool], httpClient: http),
            store: storage, deliveryPolicy: FxDeliveryPolicy(maximumDuration: .zero, reserve: .zero))
        let session = try await agent.session(id: "native-release")
        let turn = try await session.prompt("look up", id: "input")
        var text = ""
        for try await event in turn { if case .text(let delta) = event { text += delta } }
        #expect(text == "complete")
        #expect(try await turn.result.stopReason == .endTurn)
        try await agent.close()
        #expect(await http.toolCalls == 1)
        #expect(await http.modelRequests == 2)
        #expect(await storage.calls.filter { $0 == "release" }.count == 3)
        try await database.close()
    }

    @Test func transientReleaseFailureKeepsAcceptedWorkRecoverable() async throws {
        let database = try FxSessionStore(), storage = SessionStorageProxy(database)
        let fault = SessionStorageTestFailure(), harness = ScriptedHarnessFaults(), events = ReleaseEvents()
        await storage.failNext("release", with: fault)
        let agent = try FxAgent(harness: ScriptedSessionHarness(faults: harness), store: storage,
            queue: ReleaseQueue(), onLifecycleEvent: { await events.record($0) })
        let session = try await agent.session(id: "release-retry")
        let turn = try await session.prompt("xi", id: "turn-xi")
        let policy = try FxDeliveryPolicy(maximumDuration: .milliseconds(1), reserve: .zero)
        let wakeup = FxSessionWakeup(agent: "default", sessionID: session.id)
        var outcome = try await agent.deliver(wakeup, policy: policy)
        while outcome != .complete { outcome = try await agent.deliver(wakeup, policy: policy) }
        var text = ""
        for try await event in turn { if case .text(let delta) = event { text += delta } }
        #expect(text == "xi-0 xi-1 xi-2 ")
        #expect(try await turn.result.stopReason == .endTurn)
        #expect(await harness.prompts == ["xi"])
        #expect(await storage.calls.filter { $0 == "release" }.count == 4)
        #expect(await events.failures.count == 1)
        #expect(await events.failures.first as? SessionStorageTestFailure === fault)
        try await agent.close()
        try await database.close()
    }

    @Test func persistentReleaseFailureStopsAfterOneRetryAndRetainsTheError() async throws {
        let database = try FxSessionStore(), events = ReleaseEvents()
        let storage = SessionStorageProxy(database, afterClaim: { await events.claimed($0) })
        let failure = SessionStorageTestFailure()
        await storage.failNext("release", with: failure, count: 3)
        let agent = try FxAgent(harness: ScriptedSessionHarness(), store: storage, queue: ReleaseQueue())
        let session = try await agent.session(id: "persistent-release")
        _ = try await session.prompt("xi", id: "turn-xi")
        do {
            _ = try await agent.deliver(.init(agent: "default", sessionID: session.id))
            Issue.record("Expected release failure")
        } catch { #expect(error as? SessionStorageTestFailure === failure) }
        #expect(await storage.calls.filter { $0 == "release" }.count == 2)
        do { try await agent.close(); Issue.record("Close lost the release failure") }
        catch { #expect(error as? SessionStorageTestFailure === failure) }
        try await database.release(try #require(await events.lease))
        try await database.close()
    }

    @Test(arguments: [false, true]) func cancellationAndFencingDoNotRetry(cancelled: Bool) async throws {
        let database = try FxSessionStore(), events = ReleaseEvents()
        let storage = SessionStorageProxy(database, afterClaim: { await events.claimed($0) })
        let failure: any Error = cancelled ? CancellationError() : FxPersistenceError.fenced
        await storage.failNext("release", with: failure)
        let agent = try FxAgent(harness: ScriptedSessionHarness(), store: storage, queue: ReleaseQueue(),
            onLifecycleEvent: { await events.record($0) })
        let session = try await agent.session(id: "semantic-release")
        _ = try await session.prompt("xi", id: "turn-xi")
        do {
            _ = try await agent.deliver(.init(agent: "default", sessionID: session.id))
            Issue.record("Expected release failure")
        } catch {
            if cancelled { #expect(error is CancellationError) }
            else { #expect(error as? FxPersistenceError == .fenced) }
        }
        #expect(await storage.calls.filter { $0 == "release" }.count == 1)
        #expect(await events.failures.isEmpty)
        do { try await agent.close(); Issue.record("Close lost the release failure") } catch {}
        try await database.release(try #require(await events.lease))
        try await database.close()
    }
}
