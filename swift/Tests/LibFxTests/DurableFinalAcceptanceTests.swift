import Foundation
import Testing
@testable import LibFx

private let finalAcceptancePNG = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jP0cAAAAASUVORK5CYII=")!

private actor FinalAcceptanceQueue: FxSessionQueue {
    private(set) var messages: [FxSessionWakeup] = []
    func enqueue(_ wakeup: FxSessionWakeup) { messages.append(wakeup) }
}

private actor FinalAcceptanceHTTP: FxHTTPClient {
    let holdFirst: Bool
    let entered = AsyncResult<Void>()
    let release = AsyncResult<Void>()
    private(set) var bodies: [String] = []
    init(holdFirst: Bool = false) { self.holdFirst = holdFirst }
    func send(_ request: URLRequest) async throws -> FxHTTPResponse {
        #expect(request.httpMethod == "POST")
        bodies.append(String(decoding: request.httpBody ?? Data(), as: UTF8.self))
        await entered.resolve(.success(()))
        if holdFirst && bodies.count == 1 { try await release.wait() }
        let frames = "data: {\"type\":\"text-delta\",\"delta\":\"answer\"}\n\ndata: {\"type\":\"finish\",\"finishReason\":{\"unified\":\"stop\",\"raw\":\"stop\"}}\n\ndata: [DONE]\n\n"
        return FxHTTPResponse(statusCode: 200, body: AsyncThrowingStream {
            $0.yield(Data(frames.utf8)); $0.finish()
        })
    }
}

private struct FaultedHistoryPersistence: FxHarnessPersistence {
    let base: any FxHarnessPersistence
    let corrupt: Bool
    func load() async throws -> FxPersistenceSnapshot { try await base.load() }
    func append(expected: String?, idempotencyKey: String, data: Data, barrier: Bool) async throws -> String {
        try await base.append(expected: expected, idempotencyKey: idempotencyKey, data: data, barrier: barrier)
    }
    func append(expected: String?, idempotencyKey: String, data: Data, marks: [FxSessionJournalMark], barrier: Bool) async throws -> String {
        try await base.append(expected: expected, idempotencyKey: idempotencyKey, data: data, marks: marks, barrier: barrier)
    }
    func saveCheckpoint(_ checkpoint: FxStoredCheckpoint) async throws { try await base.saveCheckpoint(checkpoint) }
    func storeImage(_ data: Data, named name: String) async throws { try await base.storeImage(data, named: name) }
    func loadImage(named name: String) async throws -> Data? {
        // The actual native journal requests its stored content hash. Only the
        // host's read response is faulty; journal and input remain unchanged.
        if corrupt { return Data([0, 1, 2]) }
        return nil
    }
}

private struct FaultedHistoryHarness: FxSessionHarness {
    let configuration: FxConfiguration
    let corrupt: Bool
    func validate(options: FxSessionOptions) throws { try KernelSessionHarness(configuration: configuration).validate(options: options) }
    func validate(input: [FxPromptContent], options: FxSessionOptions) throws { try KernelSessionHarness(configuration: configuration).validate(input: input, options: options) }
    func prepareCheckpoint(_ data: Data, options: FxSessionOptions) async throws -> Data {
        try await KernelSessionHarness(configuration: configuration).prepareCheckpoint(data, options: options)
    }
    func open(_ context: FxHarnessContext) async throws -> any FxHarnessSession {
        let wrapped = FxHarnessContext(sessionID: context.sessionID, inputID: context.inputID, options: context.options,
            persistence: FaultedHistoryPersistence(base: context.persistence, corrupt: corrupt),
            checkpointAfterBytes: context.checkpointAfterBytes, leaseGuard: context.leaseGuard,
            ownership: { try await context.checkOwnership() })
        return try await KernelSessionHarness(configuration: configuration).open(wrapped)
    }
}

@Suite(.serialized, .timeLimit(.minutes(1))) struct DurableFinalAcceptanceTests {
    private func configuration(_ http: FinalAcceptanceHTTP) throws -> FxConfiguration {
        var value = FxConfiguration(apiKey: "fixture", model: "swift/final-acceptance", httpClient: http)
        value.modelCatalog = try FxModelCatalog(response: Data(#"{"data":[{"id":"swift/final-acceptance","type":"language","tags":["vision","file-input"]}]}"#.utf8))
        return value
    }

    @Test func deniedHistoryReadFailsOnlyItsViewAndUnreadResultDoesNotReadEntries() async throws {
        let database = try FxSessionStore(), storage = SessionStorageProxy(database), http = FinalAcceptanceHTTP()
        let agent = try FxAgent(configuration: configuration(http), store: storage)
        let session = try await agent.session(id: "denied-view")
        let turn = try await session.prompt("UNREAD_NATIVE_INPUT", id: "input")
        #expect(try await turn.result.stopReason == .endTurn)
        #expect(await storage.calls.filter { $0 == "entries" }.isEmpty)
        let denied = SessionStorageTestFailure()
        await storage.failNext("entries", with: denied)
        var reader = session.events().makeAsyncIterator()
        do { _ = try await reader.next(); Issue.record("Denied view must throw") }
        catch { #expect(error as? SessionStorageTestFailure === denied) }
        #expect(try await turn.result.stopReason == .endTurn)
        var replayed: [FxEvent] = []
        for try await event in turn { replayed.append(event) }
        #expect(!replayed.isEmpty)
        #expect(replayed.contains(.text("answer")))
        let history = try await database.entries(session: session.id, agent: "default", after: 0)
        #expect(history.filter { if case .ended = $0.event { return true }; return false }.count == 1)
        #expect(await http.bodies.count == 1)
        try await agent.close(); try await database.close()
    }

    @Test func withdrawingMiddleInputKeepsThirdBehindHeldFirst() async throws {
        let store = try FxSessionStore(), queue = FinalAcceptanceQueue(), http = FinalAcceptanceHTTP(holdFirst: true)
        let agent = try FxAgent(configuration: configuration(http), store: store, checkpointAfterBytes: nil, queue: queue)
        let session = try await agent.session(id: "three-inputs")
        let first = try await session.prompt("FIRST_ORDER_TOKEN", id: "first")
        let second = try await session.prompt("WITHDRAWN_ORDER_TOKEN", id: "second")
        let third = try await session.prompt("THIRD_ORDER_TOKEN", id: "third")
        try await second.cancel()
        let wakeup = try #require(await queue.messages.first)
        let delivery = Task { try await agent.deliver(wakeup) }
        defer { delivery.cancel() }
        try await http.entered.wait()
        #expect(await http.bodies.count == 1)
        #expect(try await store.result(session: session.id, agent: "default", id: "third") == nil)
        #expect(await http.bodies.first?.contains("FIRST_ORDER_TOKEN") == true)
        #expect(await http.bodies.first?.contains("THIRD_ORDER_TOKEN") == false)
        await http.release.resolve(.success(()))
        #expect(try await delivery.value == .complete)
        #expect(try await first.result.stopReason == .endTurn)
        #expect(try await second.result.stopReason == .cancelled)
        #expect(try await third.result.stopReason == .endTurn)
        let bodies = await http.bodies
        #expect(bodies.count == 2)
        #expect(bodies.last?.contains("THIRD_ORDER_TOKEN") == true)
        #expect(bodies.allSatisfy { !$0.contains("WITHDRAWN_ORDER_TOKEN") })
        let entries = try await store.entries(session: session.id, agent: "default", after: 0)
        let starts = entries.compactMap { if case .started(let id, _, _) = $0.event { return id }; return nil }
        let ends = entries.compactMap { if case .ended(let result) = $0.event { return result.id }; return nil }
        #expect(starts == ["first", "second", "third"])
        #expect(Set(ends) == Set(["first", "second", "third"]) && ends.count == 3)
        try await agent.close(); try await store.close()
    }

    @Test(arguments: [false, true]) func damagedSavedImageHistoryStopsEffectsAndRepairsTheSameInput(corrupt: Bool) async throws {
        let store = try FxSessionStore(), http = FinalAcceptanceHTTP()
        let config = try configuration(http)
        let seed = try FxAgent(configuration: config, store: store)
        let seeded = try await seed.session(id: "saved-image").prompt([.image(FxImage(data: finalAcceptancePNG, format: .png))], id: "image")
        #expect(try await seeded.result.stopReason == .endTurn)
        try await seed.close()
        let broken = try FxAgent(harness: FaultedHistoryHarness(configuration: config, corrupt: corrupt), store: store)
        let pending = try await broken.session(id: "saved-image").prompt("REPAIR_SAME_INPUT_TOKEN", id: "repair")
        let imageName = PersistedImages.name(for: finalAcceptancePNG)
        let expectedFault: FxPersistenceError = corrupt ? .corruptImage(imageName) : .missingImage(imageName)
        var observed: (any Error)?
        do { let result = try await pending.result; Issue.record("Damaged committed history must fail its reader; got \(result)") }
        catch { observed = error }
        #expect(observed != nil)
        #expect(observed as? FxPersistenceError == expectedFault)
        #expect(await http.bodies.count == 1)
        #expect(try await store.result(session: "saved-image", agent: "default", id: "repair") == nil)
        #expect(try await store.resumePoint(session: "saved-image", agent: "default")?.id == "repair")
        do { try await broken.close(); Issue.record("Close must retain the history fault") }
        catch { #expect(error as? FxPersistenceError == expectedFault) }
        let repaired = try FxAgent(configuration: config, store: store)
        let session = try await repaired.session(id: "saved-image")
        let resumed = try #require(try await session.resume())
        #expect(resumed.id == "repair")
        #expect(try await resumed.result.stopReason == .endTurn)
        let next = try await session.prompt("AFTER_REPAIR_TOKEN", id: "next")
        #expect(try await next.result.stopReason == .endTurn)
        #expect(await http.bodies.count == 3)
        #expect(await http.bodies[1].contains("REPAIR_SAME_INPUT_TOKEN"))
        #expect(await http.bodies[1].contains(finalAcceptancePNG.base64EncodedString()))
        let entries = try await store.entries(session: "saved-image", agent: "default", after: 0)
        #expect(entries.filter { if case .ended(let result) = $0.event { return result.id == "repair" }; return false }.count == 1)
        try await repaired.close(); try await store.close()
    }

    @Test func completedImageRetryBypassesAWriterThatNowFails() async throws {
        let database = try FxSessionStore(), storage = SessionStorageProxy(database), http = FinalAcceptanceHTTP()
        let agent = try FxAgent(configuration: configuration(http), store: storage)
        let session = try await agent.session(id: "repeated-image")
        let first = try await session.prompt([.image(FxImage(data: finalAcceptancePNG, format: .png))], id: "image")
        #expect(try await first.result.stopReason == .endTurn)
        try await agent.close()
        let writes = await storage.calls.filter { $0 == "storeImage" }.count
        #expect(writes == 1)
        await storage.failNext("storeImage", with: SessionStorageTestFailure(), count: 100)
        let reopened = try FxAgent(configuration: configuration(http), store: storage)
        let repeated = try await reopened.session(id: "repeated-image").prompt([.image(FxImage(data: finalAcceptancePNG, format: .png))], id: "image")
        #expect(repeated.isRepeated)
        let result = try await repeated.result
        #expect(result.isRepeated && result.stopReason == .endTurn && result.error == nil)
        try await reopened.close()
        #expect(await storage.calls.filter { $0 == "storeImage" }.count == writes)
        #expect(await http.bodies.count == 1)
        #expect(try await database.loadImage(named: PersistedImages.name(for: finalAcceptancePNG), session: "repeated-image", agent: "default") == finalAcceptancePNG)
        try await database.close()
    }
}
