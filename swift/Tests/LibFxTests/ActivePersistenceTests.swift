import Foundation
import Testing
@_spi(Conformance) @testable import LibFx

private enum ActiveFlushTimeout: Error { case waitingForTurn }
private final class ActiveJournalFailure: Error {}

private actor ActiveFlushState {
    let intentEntered = AsyncResult<Void>()
    let intentRelease = AsyncResult<Void>()
    private var signals: [String: AsyncResult<Void>] = [:]
    private var holdIntent = true
    private var journalFailure: ActiveJournalFailure?
    func failJournal(_ failure: ActiveJournalFailure) { journalFailure = failure }
    var flushes: [String: Int] = [:]
    var heldOpenings: Set<String> = []
    var heldCloses: Set<String> = ["one"]
    func signal(_ key: String) -> AsyncResult<Void> {
        if let signal = signals[key] { return signal }
        let signal = AsyncResult<Void>(); signals[key] = signal; return signal
    }
    func wait(_ key: String) async throws { try await signal(key).wait() }
    func release(_ key: String) async { await signal(key).resolve(.success(())) }
    func holdOpening(_ id: String) { heldOpenings.insert(id) }
    func opening(_ id: String) async throws {
        await release("opening-\(id)")
        if heldOpenings.contains(id) { try await wait("open-\(id)") }
    }
    func tool(_ id: String) async throws {
        await release("tool-\(id)")
        try await wait("release-tool-\(id)")
    }
    func journal(_ data: Data) async throws {
        guard holdIntent, String(decoding: data, as: UTF8.self).contains("\"tool_intent\"") else { return }
        holdIntent = false
        await intentEntered.resolve(.success(()))
        try await intentRelease.wait()
        if let journalFailure { throw journalFailure }
    }
    func flushing(_ id: String) async {
        flushes[id, default: 0] += 1
        await release("flushing-\(id)")
    }
    func closing(_ id: String) async throws {
        await release("closing-\(id)")
        if heldCloses.contains(id) { try await wait("close-\(id)") }
    }
    func releaseAll() async {
        await intentRelease.resolve(.success(()))
        for id in ["one", "two"] {
            for prefix in ["open-", "close-", "release-tool-"] { await release(prefix + id) }
        }
    }
}

private actor ActiveFlushHTTP: FxHTTPClient {
    var requests = 0
    func send(_ request: URLRequest) async throws -> FxHTTPResponse {
        let text: String
        if request.httpMethod == "GET" {
            text = #"{"data":[{"id":"swift/flush","type":"language","tags":["tool-use"]}]}"#
        } else {
            requests += 1
            if requests % 2 == 1 {
                text = "data: {\"type\":\"tool-call\",\"toolCallId\":\"call-\(requests)\",\"toolName\":\"inspect\",\"input\":{}}\n\ndata: {\"type\":\"finish\",\"finishReason\":{\"unified\":\"tool-calls\",\"raw\":\"tool-calls\"}}\n\ndata: [DONE]\n\n"
            } else {
                text = "data: {\"type\":\"text-delta\",\"delta\":\"done\"}\n\ndata: {\"type\":\"finish\",\"finishReason\":{\"unified\":\"stop\",\"raw\":\"stop\"}}\n\ndata: [DONE]\n\n"
            }
        }
        return FxHTTPResponse(statusCode: 200, body: AsyncThrowingStream { $0.yield(Data(text.utf8)); $0.finish() })
    }
}

private struct ActiveFlushHarness: FxSessionHarness {
    let configuration: FxConfiguration
    let state: ActiveFlushState
    var base: KernelSessionHarness { KernelSessionHarness(configuration: configuration) }
    func validate(options: FxSessionOptions) throws { try base.validate(options: options) }
    func validate(input: [FxPromptContent], options: FxSessionOptions) throws { try base.validate(input: input, options: options) }
    func prepareCheckpoint(_ data: Data, options: FxSessionOptions) async throws -> Data { try await base.prepareCheckpoint(data, options: options) }
    func open(_ context: FxHarnessContext) async throws -> any FxHarnessSession {
        let id = context.inputID ?? "checkpoint"
        try await state.opening(id)
        return ActiveFlushSession(base: try await base.open(context), id: id, state: state)
    }
}

private struct ActiveFlushSession: FxHarnessSession {
    let base: any FxHarnessSession
    let id: String
    let state: ActiveFlushState
    var recoveryState: FxRecoveryState? { get async { await base.recoveryState } }
    var completedTurnID: String? { get async { await base.completedTurnID } }
    func prompt(_ content: [FxPromptContent], id: String, yieldAt: Date?) async throws -> any FxHarnessTurn {
        try await base.prompt(content, id: id, yieldAt: yieldAt)
    }
    func resume(rerunning: Bool, yieldAt: Date?) async throws -> (any FxHarnessTurn)? { try await base.resume(rerunning: rerunning, yieldAt: yieldAt) }
    func flushPersistence() async throws {
        await state.flushing(id)
        try await base.flushPersistence()
    }
    func saveCheckpoint() async throws { try await base.saveCheckpoint() }
    func checkpoint() async throws -> Data { try await base.checkpoint() }
    func close() async throws {
        try await state.closing(id)
        try await base.close()
        await state.release("closed-\(id)")
    }
}

@Suite(.serialized, .timeLimit(.minutes(1))) struct ActivePersistenceTests {
    private func configuration(_ state: ActiveFlushState) -> FxConfiguration {
        FxConfiguration(apiKey: "fixture", model: "swift/flush", tools: [
            FxTool(name: "inspect", description: "Inspect", inputSchema: .object(["type": .string("object")]), isIdempotent: true) { _, context in
                try await state.tool(context.turnID)
                return FxToolResult(text: "inspected")
            }
        ], httpClient: ActiveFlushHTTP())
    }
    private func flush(_ agent: FxAgent, state: ActiveFlushState) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await agent.flushPersistence(sessionID: "active") }
            group.addTask {
                try await Task.sleep(for: .seconds(2))
                await state.releaseAll()
                throw ActiveFlushTimeout.waitingForTurn
            }
            defer { group.cancelAll() }
            _ = try await group.next()
        }
    }

    @Test func nativeJournalFlushWaitsForItsAcknowledgementWhileToolIsHeld() async throws {
        let state = ActiveFlushState(), store = try FxSessionStore()
        let storage = SessionStorageProxy(store, beforeJournalAppend: { data, _ in try await state.journal(data) })
        let agent = try FxAgent(harness: ActiveFlushHarness(configuration: configuration(state), state: state), store: storage)
        let session = try await agent.session(id: "active")
        let first = try await session.prompt("inspect", id: "one")
        try await state.wait("tool-one")
        try await state.intentEntered.wait()
        let flushing = Task {
            try await flush(agent, state: state)
            let snapshot = try await store.snapshot(session: session.id, agent: "default")
            #expect(snapshot.journal.contains { String(decoding: $0.data, as: UTF8.self).contains("\"tool_intent\"") })
        }
        try await state.wait("flushing-one")
        let before = try await store.snapshot(session: session.id, agent: "default")
        #expect(!before.journal.contains { String(decoding: $0.data, as: UTF8.self).contains("\"tool_intent\"") })
        await state.intentRelease.resolve(.success(()))
        try await flushing.value
        #expect(try await store.result(session: session.id, agent: "default", id: first.id) == nil)
        await state.release("release-tool-one")
        #expect(try await first.result.stopReason == .endTurn)
        try await state.wait("closing-one")
        let second = try await session.prompt("inspect again", id: "two")
        try await state.wait("tool-two")
        try await flush(agent, state: state)
        await state.release("close-one")
        try await state.wait("closed-one")
        try await flush(agent, state: state)
        #expect(await state.flushes["two"] == 2)
        #expect(try await store.result(session: session.id, agent: "default", id: second.id) == nil)
        await state.release("release-tool-two")
        #expect(try await second.result.stopReason == .endTurn)
        try await agent.close(); try await store.close()
    }

    @Test func flushDuringOpeningReachesTheOpenedEngineWithoutWaitingForItsTool() async throws {
        let state = ActiveFlushState(), store = try FxSessionStore()
        await state.holdOpening("one")
        await state.intentRelease.resolve(.success(()))
        let agent = try FxAgent(harness: ActiveFlushHarness(configuration: configuration(state), state: state), store: store)
        let session = try await agent.session(id: "active")
        let turn = try await session.prompt("inspect", id: "one")
        try await state.wait("opening-one")
        let cancelled = Task { try await agent.flushPersistence(sessionID: session.id) }
        cancelled.cancel()
        await #expect(throws: CancellationError.self) { try await cancelled.value }
        #expect(await state.flushes.isEmpty)
        let flushing = Task { try await flush(agent, state: state) }
        await state.release("open-one")
        try await flushing.value
        #expect(await state.flushes["one"] == 1)
        try await state.wait("tool-one")
        #expect(try await store.result(session: session.id, agent: "default", id: turn.id) == nil)
        await state.releaseAll()
        #expect(try await turn.result.stopReason == .endTurn)
        try await agent.close(); try await store.close()
    }
    @Test func aPendingJournalFailureRetainsItsHostErrorIdentity() async throws {
        let state = ActiveFlushState(), store = try FxSessionStore(), failure = ActiveJournalFailure()
        await state.failJournal(failure)
        let storage = SessionStorageProxy(store, beforeJournalAppend: { data, _ in try await state.journal(data) })
        let agent = try FxAgent(harness: ActiveFlushHarness(configuration: configuration(state), state: state), store: storage)
        let session = try await agent.session(id: "active")
        _ = try await session.prompt("inspect", id: "one")
        try await state.wait("tool-one")
        try await state.intentEntered.wait()
        let flushing = Task { try await flush(agent, state: state) }
        try await state.wait("flushing-one")
        await state.intentRelease.resolve(.success(()))
        do { try await flushing.value; Issue.record("Flush lost the pending write failure") }
        catch { #expect((error as? ActiveJournalFailure) === failure) }
        await state.releaseAll()
        do { try await agent.close(); Issue.record("Close lost the host storage failure") }
        catch { #expect((error as? ActiveJournalFailure) === failure) }
        try await store.close()
    }

}
