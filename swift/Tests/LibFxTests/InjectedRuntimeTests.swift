import Foundation
import Testing
@_spi(Conformance) @testable import LibFx

private actor HookRuntime: EngineTransport {
    nonisolated let output: AsyncThrowingStream<Data, any Error>
    private let continuation: AsyncThrowingStream<Data, any Error>.Continuation
    private var promptID: JSONValue?
    private var requests: [String: CheckedContinuation<JSONValue, any Error>] = [:]
    private var nextID = 0
    private(set) var closed = false
    private(set) var writes = 0
    private let hooksVersion: Int

    init(hooksVersion: Int = 1) {
        self.hooksVersion = hooksVersion
        (output, continuation) = AsyncThrowingStream.makeStream()
    }
    func start() {}
    func setContext(sessionID: String, modelID: String) {}
    func beginTurn() {}
    func discardAttachments() {}
    func abortEffects() {}
    func putAttachment(_ data: Data, id: UInt32) throws { throw FxPersistenceError.invalidJournal }
    func takeAttachment(id: UInt32) throws -> Data { throw FxPersistenceError.invalidJournal }

    func write(_ bytes: Data) throws {
        writes += 1
        let message = try JSONDecoder().decode(JSONValue.self, from: bytes)
        if let id = message["id"]?.string, let pending = requests.removeValue(forKey: id) {
            pending.resume(returning: message)
            return
        }
        guard let id = message["id"] else { return }
        if message["method"] == .string("session/prompt") { promptID = id; return }
        let result: JSONValue = message["method"] == .string("libfx/new") ? .object([
            "sessionId": .string("root"), "_meta": .object(["fx": .object(["hooksVersion": .number(Double(hooksVersion))])]),
            "configOptions": .array([.object(["id": .string("model"), "currentValue": .string("fixture/scopes")])]),
        ]) : .object([:])
        try receive(.object(["id": id, "result": result]))
    }
    private func receive(_ value: JSONValue) throws {
        guard !closed, case .object(var fields) = value else { throw FxError.closed }
        fields["jsonrpc"] = .string("2.0")
        var bytes = try JSONEncoder().encode(JSONValue.object(fields))
        bytes.append(10)
        continuation.yield(bytes)
    }
    func waitForPrompt() async { while promptID == nil { await Task.yield() } }
    func hasPrompt() -> Bool { promptID != nil }
    func fail(_ error: any Error) { continuation.finish(throwing: error) }
    func finishPrompt() throws {
        guard let promptID else { throw FxError.noActiveTurn }
        try receive(.object(["id": promptID, "result": .object(["stopReason": .string("end_turn")])]))
    }
    func hook(_ kind: FxObservation.Kind, session: String = "root", execution: String, data: JSONValue) throws {
        try receive(.object(["method": .string("libfx/hook"), "params": .object([
            "version": .number(1), "type": .string(kind.rawValue), "sessionId": .string(session), "rootSessionId": .string("root"),
            "parentSessionId": session == "root" ? .null : .string("root"), "turnId": .string("native-turn"),
            "executionId": .string(execution), "stepIndex": .number(1), "timestamp": .number(1_000),
            "contentCaptured": .bool(false), "contentTruncated": .bool(false), "data": data,
        ])]))
    }
    func tool(session: String) async throws -> JSONValue {
        let id = "tool-\(nextID)"; nextID += 1
        return try await withCheckedThrowingContinuation { waiter in
            requests[id] = waiter
            do { try receive(.object(["id": .string(id), "method": .string("libfx/tool_call"), "params": .object([
                "sessionId": .string(session), "name": .string("lookup"), "toolCallId": .string("same"), "input": .object([:]),
            ])])) } catch { requests.removeValue(forKey: id)?.resume(throwing: error) }
        }
    }
    func close() {
        guard !closed else { return }
        closed = true
        for request in requests.values { request.resume(throwing: FxError.closed) }
        requests.removeAll(); continuation.finish()
    }
}

private actor RuntimeContexts {
    private(set) var values: [FxToolContext] = []
    func record(_ value: FxToolContext) { values.append(value) }
}

private actor PreparationFailureProbe {
    private(set) var started = false
    private(set) var finished = false
    func prepare(_ image: FxImage) async throws -> FxImage {
        started = true
        defer { finished = true }
        try await Task.sleep(for: .seconds(60))
        return image
    }
    func waitUntilStarted() async { while !started { await Task.yield() } }
}

@Test(.timeLimit(.minutes(1))) func runtimeFailureCancelsPreparationAndPreservesOriginalFailure() async throws {
    let runtime = HookRuntime(), probe = PreparationFailureProbe()
    let failure = FxError.transport("runtime exited during preparation")
    var configuration = FxConfiguration(apiKey: "fixture")
    configuration.prepareImage = { try await probe.prepare($0) }
    let engine = try await FxEngine.openForConformance(configuration: configuration, transport: runtime)
    let turn = try await engine.prompt([.image(FxImage(data: Data([1]), format: .png))])
    await probe.waitUntilStarted()
    await runtime.fail(failure)
    do { _ = try await turn.result; Issue.record("Runtime failure was lost") }
    catch { #expect(error as? FxError == failure) }
    do {
        for try await _ in turn {}
        Issue.record("Events completed without the runtime failure")
    } catch { #expect(error as? FxError == failure) }
    do { _ = try await engine.prompt("after exit"); Issue.record("Failed runtime accepted a turn") }
    catch { #expect(error as? FxError == failure) }
    try await engine.close()
    #expect(await probe.finished)
    #expect(await runtime.hasPrompt() == false)
}

private actor BeforeWriteProbe {
    private var waiter: CheckedContinuation<Void, Never>?
    private(set) var started = false
    func pause() async {
        started = true
        await withCheckedContinuation { waiter = $0 }
    }
    func waitUntilStarted() async { while !started { await Task.yield() } }
    func release() { waiter?.resume(); waiter = nil }
}

@Test(.timeLimit(.minutes(1)), arguments: [false, true])
func steeringDuringImagePreparationHasCountAndByteBounds(byteBound: Bool) async throws {
    let runtime = HookRuntime(), probe = PreparationFailureProbe()
    var configuration = FxConfiguration(apiKey: "fixture")
    configuration.prepareImage = { try await probe.prepare($0) }
    let engine = try await FxEngine.openForConformance(configuration: configuration, transport: runtime)
    let turn = try await engine.prompt([.image(FxImage(data: Data([1]), format: .png))])
    await probe.waitUntilStarted()
    let count = byteBound ? 16 : 64
    let text = byteBound ? String(repeating: "x", count: 65536) : "steer"
    let receipts = (0..<count).map { index in Task { try await turn.steer(text, id: "steer-\(index)") } }
    while await engine.pendingSteeringCount < count { await Task.yield() }
    do { _ = try await turn.steer("overflow", id: "overflow"); Issue.record("Steering queue exceeded its limit") }
    catch { #expect(error as? FxError == .steeringQueueFull) }
    await turn.cancel()
    #expect(try await turn.result.stopReason == .cancelled)
    for receipt in receipts {
        do { _ = try await receipt.value; Issue.record("Cancelled preparation accepted steering") }
        catch { #expect(error as? FxError == .noActiveTurn) }
    }
    #expect(await engine.pendingSteeringCount == 0)
    try await engine.close()
}

@Test(.timeLimit(.minutes(1))) func cancellationBeforePromptWriteReturnsAndPreventsDispatch() async throws {
    let runtime = HookRuntime(), probe = BeforeWriteProbe()
    var configuration = FxConfiguration(apiKey: "fixture")
    configuration.wireObserver = { direction, message in
        if direction == .sent, message["method"] == .string("session/prompt") { await probe.pause() }
    }
    let engine = try await FxEngine.openForConformance(configuration: configuration, transport: runtime)
    let turn = try await engine.prompt("cancel before write")
    await probe.waitUntilStarted()
    await turn.cancel()
    await probe.release()
    #expect(try await turn.result.stopReason == .cancelled)
    #expect(await runtime.hasPrompt() == false)
    try await engine.close()
}

@Test(.timeLimit(.minutes(1))) func nativeDescendantScopesCannotAuthorizeOrInvalidateRootTools() async throws {
    let runtime = HookRuntime(), contexts = RuntimeContexts()
    let tool = FxTool(name: "lookup", description: "Lookup", inputSchema: .object(["type": .string("object")]), isIdempotent: true) { _, context in
        await contexts.record(context)
        return FxToolResult(text: "ok")
    }
    let engine = try await FxEngine.openForConformance(configuration: FxConfiguration(apiKey: "fixture", tools: [tool],
        observation: FxObservationOptions(onEvent: { _ in })), transport: runtime)
    let turn = try await engine.prompt("scope ownership", id: "public-turn")
    await runtime.waitForPrompt()
    let started: JSONValue = .object(["call": .object(["callId": .string("same"), "name": .string("lookup"), "provenance": .string("fx_local")]), "rerun": .bool(false)])
    try await runtime.hook(.toolStarted, execution: "collision", data: started)
    try await runtime.hook(.toolStarted, session: "descendant", execution: "collision", data: started)
    try await engine.drainConformanceFrames()
    #expect(try await runtime.tool(session: "descendant")["error"] != nil)
    #expect(await contexts.values.isEmpty)
    try await runtime.hook(.turnEnded, session: "descendant", execution: "collision", data: .object(["outcome": .string("completed")]))
    try await runtime.hook(.journalError, session: "descendant", execution: "collision", data: .object(["fenced": .bool(true)]))
    try await engine.drainConformanceFrames()
    #expect(try await runtime.tool(session: "root")["result"]?["isError"] == .bool(false))
    await engine.joinConformanceTool("same")
    let first = try #require(await contexts.values.first)
    #expect(first.sessionID == "root" && first.turnID == "public-turn")
    #expect(first.observation?.scope.executionID == "collision")
    try await runtime.hook(.toolStarted, execution: "ended", data: started)
    try await runtime.hook(.turnEnded, execution: "ended", data: .object(["outcome": .string("completed")]))
    try await engine.drainConformanceFrames()
    _ = try await runtime.tool(session: "root")
    await engine.joinConformanceTool("same")
    #expect(await contexts.values.last?.observation == nil)
    try await runtime.hook(.toolStarted, execution: "fenced", data: started)
    try await runtime.hook(.journalError, execution: "fenced", data: .object(["fenced": .bool(true)]))
    try await engine.drainConformanceFrames()
    _ = try await runtime.tool(session: "root")
    await engine.joinConformanceTool("same")
    #expect(await contexts.values.count == 3)
    #expect(await contexts.values.last?.observation == nil)
    try await runtime.finishPrompt()
    #expect(try await turn.result.stopReason == .endTurn)
    try await engine.close()
    #expect(await runtime.closed)
}

@Test func injectedTransportClosesAfterValidationAndHandshakeFailures() async throws {
    for invalidKey in [true, false] {
        let runtime = HookRuntime(hooksVersion: 2)
        await #expect(throws: FxError.self) {
            try await FxEngine.openForConformance(configuration: FxConfiguration(apiKey: invalidKey ? "" : "fixture",
                observation: FxObservationOptions(onEvent: { _ in })), transport: runtime)
        }
        #expect(await runtime.closed)
        if invalidKey { #expect(await runtime.writes == 0) }
    }
}
