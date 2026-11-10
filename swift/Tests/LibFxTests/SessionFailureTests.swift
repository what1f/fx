import Foundation
import Testing
import LibFx

private struct NamedServiceFailure: Error, LocalizedError, CustomNSError {
    static let errorDomain = "ServiceUnavailable"
    var errorCode: Int { 503 }
    var errorDescription: String? { "Try again later" }
}

private enum PlainFailure: Error { case unavailable }

private struct FailureHarness: FxSessionHarness {
    let failure: any Error
    let failsOpening: Bool
    func prepareCheckpoint(_ data: Data, options: FxSessionOptions) async throws -> Data { data }
    func open(_ context: FxHarnessContext) async throws -> any FxHarnessSession {
        if failsOpening { throw failure }
        return FailureSession(failure: failure)
    }
}

private struct FailureSession: FxHarnessSession {
    let failure: any Error
    var recoveryState: FxRecoveryState? { nil }
    var completedTurnID: String? { nil }
    func prompt(_ content: [FxPromptContent], id: String, yieldAt: Date?) async throws -> any FxHarnessTurn {
        FailureTurn(failure: failure)
    }
    func resume(rerunning: Bool, yieldAt: Date?) async throws -> (any FxHarnessTurn)? { nil }
    func saveCheckpoint() async throws {}
    func checkpoint() async throws -> Data { Data() }
    func close() async throws {}
}

private struct FailureTurn: FxHarnessTurn {
    let failure: any Error
    var events: AsyncThrowingStream<FxEvent, any Error> {
        AsyncThrowingStream { $0.finish(throwing: failure) }
    }
    var result: FxTurnResult { get async throws { throw failure } }
    func cancel() async {}
    func handoff() async throws {}
    func steer(_ text: String, id: String) async throws -> FxSteeringReceipt { throw FxError.noActiveTurn }
    func endForSteering() async throws {}
}

@Suite(.serialized, .timeLimit(.minutes(1))) struct SessionFailureTests {
    @Test func previousNativeMessageOnlyResultsDecodeAndWriteStructuredFailures() throws {
        let stored = Data(#"{"id":"input","stopReason":"error","error":"Request rejected","epoch":1,"isRepeated":false}"#.utf8)
        let result = try JSONDecoder().decode(FxSessionResult.self, from: stored)
        #expect(result.failure == FxSessionFailure(message: "Request rejected"))
        let encoded = try JSONEncoder().encode(result)
        let value = try JSONDecoder().decode(JSONValue.self, from: encoded)
        #expect(value["error"]?["message"] == .string("Request rejected"))
        #expect(value["error"]?["name"] == .string("Error"))
        #expect(try JSONDecoder().decode(FxSessionResult.self, from: encoded) == result)
    }

    @Test func normalizationRetainsUpstreamCodesAndSafeDiagnostics() throws {
        let rpc = FxSessionFailure(FxError.rpc(code: -32602, message: "Unsupported effort", data: .object([
            "code": .string("LIBFX_MODEL_UNSUPPORTED_EFFORT"), "name": .string("ModelError")
        ])))
        #expect(rpc == FxSessionFailure(message: "Unsupported effort", name: "ModelError",
            code: .string("LIBFX_MODEL_UNSUPPORTED_EFFORT"), rpcCode: -32602))
        #expect(FxSessionFailure(FxError.rpc(code: 42, message: "Rejected", data: nil)).code == .number(42))
        #expect(FxSessionFailure(FxError.invalidInput("Image is too large")).message == "Image is too large")
        #expect(FxSessionFailure(FxHarnessError.stopped("Executor exited")).code == .string("FX_HARNESS_STOPPED"))
        #expect(FxSessionFailure(NamedServiceFailure()) == FxSessionFailure(message: "Try again later",
            name: "ServiceUnavailable", code: .number(503)))
        #expect(FxSessionFailure(NSError(domain: "ImageService", code: 12,
            userInfo: [NSLocalizedDescriptionKey: "Image missing"])) == FxSessionFailure(
                message: "Image missing", name: "ImageService", code: .number(12)))
        #expect(FxSessionFailure(PlainFailure.unavailable) == FxSessionFailure(message: "unavailable", name: "PlainFailure"))
        let original = FxSessionFailure(message: "Unavailable", name: "RemoteError", code: .string("retry"))
        #expect(FxSessionFailure(original) == original)
        #expect(try JSONDecoder().decode(FxSessionFailure.self, from: JSONEncoder().encode(original)) == original)
    }

    @Test(arguments: [false, true]) func executorFailuresSurviveResultEventsRepetitionAndReopening(failsOpening: Bool) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("sessions.sqlite")
        let failure = FxSessionFailure(message: "Request rejected", name: "ProviderError", code: .string("MODEL_UNSUPPORTED"), rpcCode: -32602)
        let store = try FxSessionStore(url: url)
        let original: any Error = failsOpening
            ? FxError.rpc(code: -32602, message: failure.message, data: .object([
                "name": .string(failure.name), "code": .string("MODEL_UNSUPPORTED")
            ])) : failure
        let agent = try FxAgent(harness: FailureHarness(failure: original, failsOpening: failsOpening), store: store)
        let session = try await agent.session(id: "failure")
        let turn = try await session.prompt("hello", id: "input")
        let result = try await turn.result
        #expect(result.stopReason == .error)
        #expect(result.error == failure.message)
        #expect(result.failure == failure)
        let repeated = try await session.prompt("again", id: "input").result
        #expect(repeated.isRepeated && repeated.failure == failure)
        let entries = try await store.entries(session: session.id, agent: "default", after: 0)
        #expect(entries.contains { if case .ended(let result) = $0.event { return result.failure == failure }; return false })
        let encoded = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(result))
        #expect(encoded["error"]?["code"] == failure.code)
        #expect(encoded["error"]?["name"] == .string(failure.name))
        try await agent.close(); try await store.close()
        let reopened = try FxSessionStore(url: url)
        #expect(try await reopened.result(session: "failure", agent: "default", id: "input")?.failure == failure)
        #expect(try await reopened.entries(session: "failure", agent: "default", after: 0) == entries)
        try await reopened.close()
    }

    @Test func repeatedExecutorStopsHaveADurableStructuredDiagnostic() async throws {
        let store = try FxSessionStore()
        let agent = try FxAgent(harness: ScriptedSessionHarness(faults: ScriptedHarnessFaults()), store: store)
        let session = try await agent.session(id: "stopped")
        let result = try await session.prompt("doomed", id: "input").result
        #expect(result.stopReason == .error)
        #expect(result.failure?.name == "Error")
        #expect(result.failure?.message.contains("3 times") == true)
        #expect(try await store.result(session: session.id, agent: "default", id: "input")?.failure == result.failure)
        try await agent.close(); try await store.close()
    }

    @Test(arguments: [false, true]) func storageFailureFromOwnershipCheckRetainsIdentityAndPendingInput(duringOpening: Bool) async throws {
        let database = try FxSessionStore(), storage = SessionStorageProxy(database)
        let failure = SessionStorageTestFailure()
        await storage.failNext("checkLease", with: failure)
        let agent = try FxAgent(harness: OwnershipCheckingHarness(duringOpening: duringOpening), store: storage)
        let session = try await agent.session(id: "ownership-failure")
        let turn = try await session.prompt("hello", id: "input")
        do { _ = try await turn.result; Issue.record("Storage failure became a final result") }
        catch { #expect((error as? SessionStorageTestFailure) === failure) }
        do { try await agent.close(); Issue.record("Close lost original storage failure") }
        catch { #expect((error as? SessionStorageTestFailure) === failure) }
        #expect(try await database.result(session: session.id, agent: "default", id: "input") == nil)
        #expect(try await database.hasWork(session: session.id, agent: "default"))
        let recovery = try FxAgent(harness: ScriptedSessionHarness(), store: storage)
        let resumed = try await recovery.session(id: session.id)
        #expect(try await resumed.resume()?.result.stopReason == .endTurn)
        try await recovery.close(); try await database.close()
    }
}

private struct OwnershipCheckingHarness: FxSessionHarness {
    let duringOpening: Bool
    func prepareCheckpoint(_ data: Data, options: FxSessionOptions) async throws -> Data { data }
    func open(_ context: FxHarnessContext) async throws -> any FxHarnessSession {
        if duringOpening { try await context.checkOwnership() }
        return OwnershipCheckingSession(context: context)
    }
}

private struct OwnershipCheckingSession: FxHarnessSession {
    let context: FxHarnessContext
    var recoveryState: FxRecoveryState? { nil }
    var completedTurnID: String? { nil }
    func prompt(_ content: [FxPromptContent], id: String, yieldAt: Date?) async throws -> any FxHarnessTurn {
        try await context.checkOwnership()
        return FailureTurn(failure: FxSessionFailure(message: "Unexpected success"))
    }
    func resume(rerunning: Bool, yieldAt: Date?) async throws -> (any FxHarnessTurn)? { nil }
    func saveCheckpoint() async throws {}
    func checkpoint() async throws -> Data { Data() }
    func close() async throws {}
}
