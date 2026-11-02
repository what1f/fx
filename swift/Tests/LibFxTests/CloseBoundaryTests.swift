import Foundation
import Testing
@testable import LibFx

private actor CloseBoundaryGate {
    let entered = AsyncResult<Void>()
    private var waiter: CheckedContinuation<Void, Never>?
    private var released = false
    private(set) var finished = false
    func hold() async {
        await entered.resolve(.success(()))
        if !released { await withCheckedContinuation { waiter = $0 } }
        finished = true
    }
    func release() { released = true; waiter?.resume(); waiter = nil }
}

private actor FinalWorkRead {
    let gate = CloseBoundaryGate()
    private var reads = 0
    func read() async {
        reads += 1
        if reads == 3 { await gate.hold() }
    }
}

private actor ClosingEngine {
    var engine: FxEngine?
    func set(_ engine: FxEngine) { self.engine = engine }
    func close() async throws { try await engine?.close() }
}

private actor CloseBoundaryRuntime: EngineTransport {
    nonisolated let output: AsyncThrowingStream<Data, any Error>
    private let sink: AsyncThrowingStream<Data, any Error>.Continuation
    private var promptID: JSONValue?
    init() { (output, sink) = AsyncThrowingStream.makeStream() }
    func start() {}
    func close() { sink.finish() }
    func setContext(sessionID: String, modelID: String) {}
    func beginTurn() {}
    func putAttachment(_ data: Data, id: UInt32) {}
    func takeAttachment(id: UInt32) -> Data { Data() }
    func discardAttachments() {}
    func abortEffects() {}
    func write(_ bytes: Data) throws {
        let value = try JSONDecoder().decode(JSONValue.self, from: bytes)
        guard let id = value["id"] else { return }
        switch value["method"]?.string {
        case "session/prompt":
            promptID = id
            try emit(.object(["id": .string("tool"), "method": .string("libfx/tool_call"), "params": .object([
                "sessionId": .string("s"), "toolCallId": .string("tool"), "name": .string("probe"), "input": .object([:]),
            ])]))
        case "session/cancel":
            try reply(id, .null)
            if let promptID { try reply(promptID, .object(["stopReason": .string("cancelled")])) }
        case "libfx/new":
            try reply(id, .object(["sessionId": .string("s"), "configOptions": .array([
                .object(["id": .string("model"), "currentValue": .string("fixture/model")]),
            ])]))
        default: try reply(id, .object([:]))
        }
    }
    private func reply(_ id: JSONValue, _ value: JSONValue) throws {
        try emit(.object(["id": id, "result": value]))
    }
    private func emit(_ value: JSONValue) throws {
        guard case .object(var fields) = value else { return }
        fields["jsonrpc"] = .string("2.0")
        var data = try JSONEncoder().encode(JSONValue.object(fields))
        data.append(10)
        sink.yield(data)
    }
}

@Suite(.serialized, .timeLimit(.minutes(1))) struct CloseBoundaryTests {
    @Test(arguments: ["close", "cancel", "reentrant"])
    func engineCloseJoinsToolCleanup(mode: String) async throws {
        let started = AsyncResult<Void>(), cleanup = CloseBoundaryGate(), holder = ClosingEngine()
        let tool = FxTool(name: "probe", description: "Probe", inputSchema: .object([:]), isIdempotent: false) { _, _ in
            await started.resolve(.success(()))
            if mode == "reentrant" {
                try await holder.close()
                await cleanup.hold()
                return "closed"
            }
            do { try await Task.sleep(for: .seconds(60)); return "unexpected" }
            catch { await cleanup.hold(); throw error }
        }
        let engine = try await FxEngine.openForConformance(
            configuration: FxConfiguration(apiKey: "fixture", model: "fixture/model", tools: [tool]),
            transport: CloseBoundaryRuntime())
        await holder.set(engine)
        let turn = try await engine.prompt("hello")
        try await started.wait()
        if mode == "cancel" { await turn.cancel() }
        let first = Task {
            try await engine.close()
            #expect(await cleanup.finished)
        }
        try await cleanup.entered.wait()
        let second = Task {
            try await engine.close()
            #expect(await cleanup.finished)
        }
        second.cancel()
        await cleanup.release()
        try await first.value
        try await second.value
        _ = try? await turn.result
    }

    @Test func agentCloseJoinsFinalReadAndLeavesNewSharedInputQueued() async throws {
        let base = try FxSessionStore(), read = FinalWorkRead(), faults = ScriptedHarnessFaults()
        let store = SessionStorageProxy(base, beforeWorkRead: { await read.read() })
        let agent = try FxAgent(harness: ScriptedSessionHarness(stepDuration: .zero, faults: faults), store: store)
        let session = try await agent.session(id: "closing")
        let first = try await session.prompt("first", id: "one")
        _ = try await first.result
        try await read.gate.entered.wait()
        let closing = Task {
            try await agent.close()
            #expect(await read.gate.finished)
        }
        while !(await agent.isClosed) { await Task.yield() }
        _ = try await base.accept(session: "closing", agent: "default", id: "two", content: [.text("second")], options: .init())
        await read.gate.release()
        try await closing.value
        #expect(await faults.opens == 1)
        #expect(try await base.result(session: "closing", agent: "default", id: "two") == nil)
        try await base.close()
    }

    @Test func intakeDuringFinalReadDoesNotLoseItsWakeup() async throws {
        let base = try FxSessionStore(), read = FinalWorkRead()
        let store = SessionStorageProxy(base, afterWorkRead: { _ in await read.read() })
        let agent = try FxAgent(harness: ScriptedSessionHarness(stepDuration: .zero), store: store)
        let session = try await agent.session(id: "intake")
        let first = try await session.prompt("first", id: "one")
        _ = try await first.result
        try await read.gate.entered.wait()
        let second = try await session.prompt("second", id: "two")
        await read.gate.release()
        #expect(try await second.result.stopReason == .endTurn)
        try await agent.close()
        try await base.close()
    }
}
