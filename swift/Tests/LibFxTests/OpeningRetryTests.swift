import Foundation
import Testing
@testable import LibFx

private let openingImage = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jP0cAAAAASUVORK5CYII=")!

private actor OpeningRetryHTTP: FxHTTPClient {
    private(set) var bodies: [String] = []
    func send(_ request: URLRequest) async throws -> FxHTTPResponse {
        bodies.append(String(decoding: request.httpBody ?? Data(), as: UTF8.self))
        let data = Data("data: {\"type\":\"text-delta\",\"delta\":\"answer\"}\n\ndata: {\"type\":\"finish\",\"finishReason\":{\"unified\":\"stop\",\"raw\":\"stop\"}}\n\ndata: [DONE]\n\n".utf8)
        return FxHTTPResponse(statusCode: 200, body: AsyncThrowingStream { $0.yield(data); $0.finish() })
    }
}

private func openingConfiguration(_ http: OpeningRetryHTTP) throws -> FxConfiguration {
    var configuration = FxConfiguration(apiKey: "fixture", model: "swift/images", httpClient: http)
    configuration.modelCatalog = try FxModelCatalog(response: Data(#"{"data":[{"id":"swift/images","type":"language","tags":["vision","file-input"]}]}"#.utf8))
    return configuration
}

@Suite(.serialized, .timeLimit(.minutes(1))) struct OpeningRetryTests {
    private func seed(_ store: FxSessionStore, configuration: FxConfiguration) async throws {
        let agent = try FxAgent(configuration: configuration, store: store)
        let turn = try await agent.session(id: "pictures").prompt([.image(FxImage(data: openingImage, format: .png))], id: "image")
        #expect(try await turn.result.stopReason == .endTurn)
        try await agent.close()
    }

    @Test func transientStoredImageReadReopensTheSameAcceptedTurn() async throws {
        let store = try FxSessionStore(), storage = SessionStorageProxy(store), http = OpeningRetryHTTP()
        let configuration = try openingConfiguration(http)
        try await seed(store, configuration: configuration)
        let original = SessionStorageTestFailure()
        await storage.failNext("loadImage", with: original)
        let policy = try FxOpeningRetryPolicy(delay: .zero) { $0 as? SessionStorageTestFailure === original }
        let agent = try FxAgent(configuration: configuration, store: storage, openingRetryPolicy: policy)
        let turn = try await agent.session(id: "pictures").prompt("recall", id: "recall")
        let events = Task { () throws -> [FxEvent] in
            var values: [FxEvent] = []
            for try await value in turn { values.append(value) }
            return values
        }
        let result = try await turn.result
        #expect(result.id == "recall")
        #expect(result.stopReason == .endTurn)
        #expect(!(try await events.value).isEmpty)
        try await agent.close()
        #expect(await storage.calls.filter { $0 == "loadImage" }.count == 2)
        #expect(await storage.calls.filter { $0 == "release" }.count == 2)
        #expect(await storage.calls.filter { $0 == "recordHarnessStop" }.isEmpty)
        #expect(await http.bodies.count == 2)
        #expect(await http.bodies.last?.contains(openingImage.base64EncodedString()) == true)
        #expect(try await store.loadImage(named: PersistedImages.name(for: openingImage), session: "pictures", agent: "default") == openingImage)
        #expect(try await store.resumePoint(session: "pictures", agent: "default") == nil)
        let history = try await store.entries(session: "pictures", agent: "default", after: 0)
        #expect(history.filter { if case .started(id: "recall", sessionID: "pictures", input: _) = $0.event { return true }; return false }.count == 1)
        #expect(history.filter { if case .resumed(id: "recall", sessionID: "pictures") = $0.event { return true }; return false }.count == 1)
        try await store.close()
    }

    @Test func failureAfterOpeningDoesNotRetryExecution() async throws {
        let store = try FxSessionStore(), storage = SessionStorageProxy(store), http = OpeningRetryHTTP()
        let original = SessionStorageTestFailure()
        await storage.failNext("appendJournal", with: original)
        let policy = try FxOpeningRetryPolicy(delay: .zero) { _ in Issue.record("Execution failure reached opening retry policy"); return true }
        let agent = try FxAgent(configuration: openingConfiguration(http), store: storage, openingRetryPolicy: policy)
        let turn = try await agent.session(id: "execution").prompt("hello", id: "input")
        do { _ = try await turn.result; Issue.record("Expected host journal failure") }
        catch { #expect(error as? SessionStorageTestFailure === original) }
        #expect(await storage.calls.filter { $0 == "claim" }.count == 1)
        #expect(try await store.result(session: "execution", agent: "default", id: "input") == nil)
        do { try await agent.close(); Issue.record("Close must retain host failure") }
        catch { #expect(error as? SessionStorageTestFailure === original) }
        try await store.close()
    }

    @Test func backoffDoesNotExtendLocalDeliveryDeadline() async throws {
        let store = try FxSessionStore(), storage = SessionStorageProxy(store), http = OpeningRetryHTTP()
        let configuration = try openingConfiguration(http)
        try await seed(store, configuration: configuration)
        let original = SessionStorageTestFailure()
        await storage.failNext("loadImage", with: original, count: 4)
        let retry = try FxOpeningRetryPolicy(maxRetries: 3, delay: .seconds(10)) { _ in true }
        let delivery = try FxDeliveryPolicy(maximumDuration: .seconds(1), reserve: .zero)
        let agent = try FxAgent(configuration: configuration, store: storage, deliveryPolicy: delivery, openingRetryPolicy: retry)
        let turn = try await agent.session(id: "pictures").prompt("recall", id: "recall")
        do { _ = try await turn.result; Issue.record("Expected original host failure") }
        catch { #expect(error as? SessionStorageTestFailure === original) }
        #expect(await storage.calls.filter { $0 == "loadImage" }.count == 1)
        do { try await agent.close(); Issue.record("Close must retain host failure") }
        catch { #expect(error as? SessionStorageTestFailure === original) }
        try await store.close()
    }

    @Test(arguments: [false, true]) func disabledAndExhaustedRetryPreserveOriginalError(enabled: Bool) async throws {
        let store = try FxSessionStore(), storage = SessionStorageProxy(store), http = OpeningRetryHTTP()
        let configuration = try openingConfiguration(http)
        try await seed(store, configuration: configuration)
        let original = SessionStorageTestFailure()
        await storage.failNext("loadImage", with: original, count: 4)
        let policy = try FxOpeningRetryPolicy(maxRetries: 2, delay: .zero) { $0 as? SessionStorageTestFailure === original }
        let agent = try FxAgent(configuration: configuration, store: storage, openingRetryPolicy: enabled ? policy : nil)
        let turn = try await agent.session(id: "pictures").prompt("recall", id: "recall")
        do { _ = try await turn.result; Issue.record("Expected original host failure") }
        catch { #expect(error as? SessionStorageTestFailure === original) }
        #expect(await storage.calls.filter { $0 == "loadImage" }.count == (enabled ? 3 : 1))
        #expect(await storage.calls.filter { $0 == "recordHarnessStop" }.isEmpty)
        #expect(await http.bodies.count == 1)
        #expect(try await store.result(session: "pictures", agent: "default", id: "recall") == nil)
        #expect(try await store.resumePoint(session: "pictures", agent: "default")?.id == "recall")
        do { try await agent.close(); Issue.record("Close must retain host failure") }
        catch { #expect(error as? SessionStorageTestFailure === original) }
        try await store.close()
    }

    @Test(arguments: [FxPersistenceError.missingImage("image"), .invalidJournal, .fenced])
    func semanticStorageFailuresNeverEnterHostPolicy(failure: FxPersistenceError) async throws {
        let store = try FxSessionStore(), storage = SessionStorageProxy(store), http = OpeningRetryHTTP()
        let configuration = try openingConfiguration(http)
        try await seed(store, configuration: configuration)
        await storage.failNext("loadImage", with: failure)
        let policy = try FxOpeningRetryPolicy(delay: .zero) { _ in Issue.record("Semantic failure reached retry classifier"); return true }
        let agent = try FxAgent(configuration: configuration, store: storage, openingRetryPolicy: policy)
        let turn = try await agent.session(id: "pictures").prompt("recall", id: "recall")
        await #expect(throws: failure) { try await turn.result }
        #expect(await storage.calls.filter { $0 == "loadImage" }.count == 1)
        await #expect(throws: failure) { try await agent.close() }
        try await store.close()
    }

    @Test func cancelledOpeningNeverEntersHostPolicy() async throws {
        let store = try FxSessionStore(), storage = SessionStorageProxy(store), http = OpeningRetryHTTP()
        let configuration = try openingConfiguration(http)
        try await seed(store, configuration: configuration)
        await storage.failNext("loadImage", with: CancellationError())
        let policy = try FxOpeningRetryPolicy(delay: .zero) { _ in Issue.record("Cancellation reached retry classifier"); return true }
        let agent = try FxAgent(configuration: configuration, store: storage, openingRetryPolicy: policy)
        let turn = try await agent.session(id: "pictures").prompt("recall", id: "recall")
        await #expect(throws: CancellationError.self) { try await turn.result }
        #expect(await storage.calls.filter { $0 == "loadImage" }.count == 1)
        await #expect(throws: CancellationError.self) { try await agent.close() }
        try await store.close()
    }
}
