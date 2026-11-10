import Foundation
import Testing
@testable import LibFx

private actor RecoveryBoundaryGate {
    let entered = AsyncResult<Void>()
    let release = AsyncResult<Void>()
    private(set) var returned = false
    func hold() async throws {
        await entered.resolve(.success(()))
        try await release.wait()
        returned = true
    }
}

private struct HeldRecoveryLoad: FxHarnessPersistence {
    let base: any FxHarnessPersistence
    let gate: RecoveryBoundaryGate
    func load() async throws -> FxPersistenceSnapshot { try await gate.hold(); return try await base.load() }
    func append(expected: String?, idempotencyKey: String, data: Data, barrier: Bool) async throws -> String {
        try await base.append(expected: expected, idempotencyKey: idempotencyKey, data: data, barrier: barrier)
    }
    func append(expected: String?, idempotencyKey: String, data: Data, marks: [FxSessionJournalMark], barrier: Bool) async throws -> String {
        try await base.append(expected: expected, idempotencyKey: idempotencyKey, data: data, marks: marks, barrier: barrier)
    }
    func saveCheckpoint(_ checkpoint: FxStoredCheckpoint) async throws { try await base.saveCheckpoint(checkpoint) }
    func storeImage(_ data: Data, named name: String) async throws { try await base.storeImage(data, named: name) }
    func loadImage(named name: String) async throws -> Data? { try await base.loadImage(named: name) }
}

private struct RecoveryReadHarness: FxSessionHarness {
    let configuration: FxConfiguration
    let gate: RecoveryBoundaryGate
    func validate(options: FxSessionOptions) throws { try KernelSessionHarness(configuration: configuration).validate(options: options) }
    func validate(input: [FxPromptContent], options: FxSessionOptions) throws { try KernelSessionHarness(configuration: configuration).validate(input: input, options: options) }
    func prepareCheckpoint(_ data: Data, options: FxSessionOptions) async throws -> Data {
        try await KernelSessionHarness(configuration: configuration).prepareCheckpoint(data, options: options)
    }
    func open(_ context: FxHarnessContext) async throws -> any FxHarnessSession {
        let persistence: any FxHarnessPersistence = context.inputID == nil
            ? HeldRecoveryLoad(base: context.persistence, gate: gate) : context.persistence
        let wrapped = FxHarnessContext(sessionID: context.sessionID, inputID: context.inputID, options: context.options,
            persistence: persistence, checkpointAfterBytes: context.checkpointAfterBytes,
            leaseGuard: context.leaseGuard, ownership: { try await context.checkOwnership() })
        return try await KernelSessionHarness(configuration: configuration).open(wrapped)
    }
}

private actor RecoveryBoundaryHTTP: FxHTTPClient {
    let toolFirst: Bool
    init(toolFirst: Bool = false) { self.toolFirst = toolFirst }
    private(set) var bodies: [String] = []
    func send(_ request: URLRequest) -> FxHTTPResponse {
        #expect(request.httpMethod == "POST")
        bodies.append(String(decoding: request.httpBody ?? Data(), as: UTF8.self))
        let frames = toolFirst && bodies.count == 1
            ? "data: {\"type\":\"tool-call\",\"toolCallId\":\"lookup-1\",\"toolName\":\"lookup\",\"input\":{}}\n\ndata: {\"type\":\"finish\",\"finishReason\":{\"unified\":\"tool-calls\",\"raw\":\"tool-calls\"}}\n\n"
            : "data: {\"type\":\"text-delta\",\"delta\":\"done\"}\n\ndata: {\"type\":\"finish\",\"finishReason\":{\"unified\":\"stop\",\"raw\":\"stop\"}}\n\n"
        return FxHTTPResponse(statusCode: 200, body: AsyncThrowingStream {
            $0.yield(Data((frames + "data: [DONE]\n\n").utf8)); $0.finish()
        })
    }
}

private actor RecoveryBoundaryTool {
    let first = RecoveryBoundaryGate(), second = RecoveryBoundaryGate()
    private(set) var calls = 0
    func execute() async throws -> FxToolResult {
        calls += 1
        try await (calls == 1 ? first : second).hold()
        return FxToolResult(text: "found")
    }
}

@Suite(.serialized, .timeLimit(.minutes(1))) struct DurableRecoveryBoundaryTests {
    private func configuration(_ http: RecoveryBoundaryHTTP, tools: [FxTool] = []) throws -> FxConfiguration {
        var configuration = FxConfiguration(apiKey: "fixture", model: "swift/recovery-boundary", tools: tools, httpClient: http)
        configuration.modelCatalog = try FxModelCatalog(response: Data(#"{"data":[{"id":"swift/recovery-boundary","type":"language","tags":["tool-use"]}]}"#.utf8))
        return configuration
    }

    @Test func acceptanceAndFirstResultDoNotWaitForAnUnrelatedJournalLoad() async throws {
        let store = try FxSessionStore(), http = RecoveryBoundaryHTTP(), gate = RecoveryBoundaryGate()
        let agent = try FxAgent(harness: RecoveryReadHarness(configuration: configuration(http), gate: gate), store: store, checkpointAfterBytes: nil)
        let session = try await agent.session(id: "independent-read")
        let seed = try await session.prompt("seed", id: "seed")
        #expect(try await seed.result.stopReason == .endTurn)
        let reading = Task { try await session.checkpoint() }
        defer { reading.cancel() }
        try await gate.entered.wait()
        let first = try await session.prompt("FIRST_ACCEPTANCE_TOKEN", id: "first")
        #expect(!first.isRepeated)
        let result = try await first.result
        #expect(result.stopReason == .endTurn && !result.isRepeated)
        #expect(await gate.returned == false)
        #expect(await http.bodies.count == 2)
        let repeated = try await session.prompt("IGNORED_RETRY_TOKEN", id: "first")
        #expect(repeated.isRepeated)
        #expect(try await repeated.result.isRepeated)
        #expect(await gate.returned == false)
        #expect(await http.bodies.count == 2)
        await gate.release.resolve(.success(()))
        #expect(!(try await reading.value).isEmpty)
        #expect(await http.bodies.last?.contains("FIRST_ACCEPTANCE_TOKEN") == true)
        #expect(await http.bodies.last?.contains("IGNORED_RETRY_TOKEN") == false)
        try await agent.close(); try await store.close()
    }

    @Test func snapshotRefusalRetainsUnplacedSteeringAcrossDatabaseReopen() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("recovery.sqlite")
        let http = RecoveryBoundaryHTTP(toolFirst: true), tool = RecoveryBoundaryTool()
        let lookup = FxTool(name: "lookup", description: "Lookup", inputSchema: .object(["type": .string("object")]), isIdempotent: true) { _, _ in try await tool.execute() }
        let configuration = try configuration(http, tools: [lookup])
        let store = try FxSessionStore(url: url)
        _ = try await store.accept(session: "unplaced", agent: "default", id: "original", content: [.text("lookup")], options: .init())
        let lease = try #require(try await store.claim(session: "unplaced", agent: "default"))
        let input = try #require(try await store.next(lease))
        try await store.start(lease, input: input)
        let engine = try await FxEngine.open(configuration: configuration, sessionID: "unplaced", persistence: SessionPersistence(store: store, lease: lease))
        let original = try await engine.prompt(input.content, id: sessionCoreInputID(input.id))
        try await tool.first.entered.wait()
        _ = try await store.accept(session: "unplaced", agent: "default", id: "guide", content: [.text("UNPLACED_GUIDANCE_TOKEN")], options: .init(), steering: true)
        _ = try await original.steer("UNPLACED_GUIDANCE_TOKEN", id: sessionCoreInputID("guide"))
        try await engine.flushPersistence()
        #expect(try await store.steering(lease, owner: "original").pending.isEmpty)
        try await original.handoff()
        #expect(try await original.result.stopReason == .cancelled)
        try await engine.close()

        // Native snapshots cannot carry unplaced steering. Refusing compaction
        // must retain the complete journal until recovery places the input.
        let snapshotter = try await FxEngine.open(configuration: configuration, sessionID: "unplaced", persistence: SessionPersistence(store: store, lease: lease))
        let recovery = try #require(await snapshotter.recoveryState)
        #expect(recovery.turnID == sessionCoreInputID("original"))
        #expect(recovery.runningCalls.map(\.executionID) == ["lookup-1"])
        let beforeSnapshot = try await store.loadJournal(lease)
        try await snapshotter.saveCheckpoint()
        let snapshot = try await store.loadJournal(lease)
        #expect(snapshot.checkpoint == nil && !snapshot.journal.isEmpty)
        #expect(snapshot.journal == beforeSnapshot.journal && snapshot.head == beforeSnapshot.head)
        #expect(try await store.steering(lease, owner: "original").pending.isEmpty)
        try await snapshotter.close()
        try await store.release(lease)
        try await store.close()

        let reopened = try FxSessionStore(url: url)
        let nextLease = try #require(try await reopened.claim(session: "unplaced", agent: "default"))
        let restored = try await FxEngine.open(configuration: configuration, sessionID: "unplaced", persistence: SessionPersistence(store: reopened, lease: nextLease))
        #expect(await restored.recoveryState?.turnID == sessionCoreInputID("original"))
        let resumed = try #require(try await restored.resume(rerunning: Set(recovery.runningCalls.map(\.executionID))))
        try await tool.second.entered.wait()
        // Resume legitimately places the recovered steer before replaying the
        // held call. There is no synthetic withdraw or injected journal mark.
        #expect(try await reopened.steering(nextLease, owner: "original").pending.isEmpty)
        await tool.second.release.resolve(.success(()))
        let result = try await resumed.result
        #expect(result.stopReason == .endTurn)
        #expect(await http.bodies.count == 2)
        #expect(await http.bodies.last?.components(separatedBy: "UNPLACED_GUIDANCE_TOKEN").count == 2)
        try await reopened.finish(nextLease, id: "original", result: .init(id: "original", stopReason: result.stopReason, usage: result.usage, epoch: nextLease.epoch))
        try await restored.close()
        #expect(try await reopened.next(nextLease) == nil)
        try await reopened.release(nextLease)

        let agent = try FxAgent(configuration: configuration, store: reopened, checkpointAfterBytes: nil)
        #expect(try await agent.session(id: "unplaced").resume() == nil)
        #expect(await http.bodies.count == 2)
        let entries = try await reopened.entries(session: "unplaced", agent: "default", after: 0)
        let ends = entries.compactMap { if case .ended(let result) = $0.event { return result.id }; return nil }
        #expect(ends == ["original"])
        let starts = entries.compactMap { if case .started(let id, _, _) = $0.event { return id }; return nil }
        #expect(starts == ["original"])
        try await agent.close(); try await reopened.close()
    }
}
