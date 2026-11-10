import Foundation
import Testing
@testable import LibFx

private actor CancellationRuntime: EngineTransport {
    nonisolated let output: AsyncThrowingStream<Data, any Error>
    private let continuation: AsyncThrowingStream<Data, any Error>.Continuation
    let promptStarted = AsyncResult<Void>()
    let cancelReceived = AsyncResult<Void>()
    let effectsAborted = AsyncResult<Void>()
    private var promptID: JSONValue?
    private var cancelID: JSONValue?
    private(set) var abortedBeforeAcknowledgement = false
    private(set) var aborted = false
    private var acknowledged = false
    private let rejectsCancellation: Bool

    init(rejectsCancellation: Bool = false) {
        self.rejectsCancellation = rejectsCancellation
        (output, continuation) = AsyncThrowingStream.makeStream()
    }
    func start() {}
    func setContext(sessionID: String, modelID: String) {}
    func beginTurn() {}
    func discardAttachments() {}
    func putAttachment(_ data: Data, id: UInt32) throws { throw FxPersistenceError.invalidJournal }
    func takeAttachment(id: UInt32) throws -> Data { throw FxPersistenceError.invalidJournal }
    func close() { continuation.finish() }
    func write(_ data: Data) async throws {
        let message = try JSONDecoder().decode(JSONValue.self, from: data)
        switch message["method"]?.string {
        case "session/prompt":
            promptID = message["id"]
            await promptStarted.resolve(.success(()))
        case "session/cancel":
            if rejectsCancellation { throw FxError.transport("Cancel dispatch failed") }
            cancelID = message["id"]
            await cancelReceived.resolve(.success(()))
        default:
            guard let id = message["id"] else { return }
            let result: JSONValue = message["method"] == .string("libfx/new")
                ? .object(["sessionId": .string("cancel-order"), "configOptions": .array([
                    .object(["id": .string("model"), "currentValue": .string("fixture/cancel")]),
                ])]) : .object([:])
            try reply(id, result)
        }
    }
    func acknowledgeCancellation() throws {
        acknowledged = true
        if let cancelID { try reply(cancelID, .null) }
    }
    var cancellationHasRequestID: Bool { cancelID != nil }
    func abortEffects() async {
        abortedBeforeAcknowledgement = !acknowledged
        aborted = true
        if let promptID { try? reply(promptID, .object(["stopReason": .string("cancelled")])) }
        await effectsAborted.resolve(.success(()))
    }
    private func reply(_ id: JSONValue, _ result: JSONValue) throws {
        var data = try JSONEncoder().encode(JSONValue.object([
            "jsonrpc": .string("2.0"), "id": id, "result": result,
        ]))
        data.append(10)
        continuation.yield(data)
    }
}

@Suite(.serialized, .timeLimit(.minutes(1))) struct CancellationOrderingTests {
    @Test func aRejectedCancellationTerminatesTheEngineWithItsOriginalFailure() async throws {
        let runtime = CancellationRuntime(rejectsCancellation: true)
        let engine = try await FxEngine.openForConformance(
            configuration: FxConfiguration(apiKey: "fixture", model: "fixture/cancel"), transport: runtime)
        let turn = try await engine.prompt("start")
        try await runtime.promptStarted.wait()
        await turn.cancel()
        await #expect(throws: FxError.transport("Cancel dispatch failed")) { try await turn.result }
        await #expect(throws: FxError.transport("Cancel dispatch failed")) { try await engine.prompt("reuse") }
        try await engine.close()
    }

    @Test func coreAcknowledgesCancellationBeforeHostEffectsAreAborted() async throws {
        let runtime = CancellationRuntime()
        let engine = try await FxEngine.openForConformance(
            configuration: FxConfiguration(apiKey: "fixture", model: "fixture/cancel"), transport: runtime)
        let turn = try await engine.prompt("start")
        try await runtime.promptStarted.wait()
        let cancellation = Task { await turn.cancel() }
        try await runtime.cancelReceived.wait()
        await cancellation.value
        #expect(await runtime.cancellationHasRequestID)
        #expect(await runtime.aborted == false)
        try await runtime.acknowledgeCancellation()
        try await runtime.effectsAborted.wait()
        #expect(await runtime.aborted)
        #expect(await runtime.abortedBeforeAcknowledgement == false)
        #expect(try await turn.result.stopReason == .cancelled)
        try await engine.close()
    }
}
