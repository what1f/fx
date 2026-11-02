import Foundation
import Testing
@_spi(Conformance) @testable import LibFx

private actor PreparationHTTP: FxHTTPClient {
    private var blocked = true
    private(set) var catalogRequests = 0
    private(set) var chatRequests = 0
    private(set) var cancellations = 0
    func unblock() { blocked = false }
    func send(_ request: URLRequest) async throws -> FxHTTPResponse {
        if request.url?.host == "registry.npmjs.org" { return response(#"{"version":"0.162.1"}"#) }
        if request.httpMethod == "GET" {
            catalogRequests += 1
            if blocked {
                do { try await Task.sleep(for: .seconds(60)) }
                catch { cancellations += 1; throw error }
            }
            return response(#"{"data":[{"id":"swift/preparation","type":"language","tags":["reasoning"],"reasoning_options":[{"type":"effort","values":["high"]}]}]}"#)
        }
        chatRequests += 1
        return response("data: {\"type\":\"text-delta\",\"delta\":\"complete\"}\n\ndata: {\"type\":\"finish\",\"finishReason\":{\"unified\":\"stop\",\"raw\":\"stop\"}}\n\ndata: [DONE]\n\n")
    }
    private func response(_ text: String) -> FxHTTPResponse {
        FxHTTPResponse(statusCode: 200, body: AsyncThrowingStream { $0.yield(Data(text.utf8)); $0.finish() })
    }
}

private actor PreparationStore: FxPersistence {
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var cancelled = false
    private(set) var loads = 0
    func load() async -> FxPersistenceSnapshot {
        loads += 1
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation = $0 }
        } onCancel: { Task { await self.noteCancellation() } }
        return FxPersistenceSnapshot()
    }
    func append(expected: String?, idempotencyKey: String, data: Data, barrier: Bool) throws -> String {
        throw FxPersistenceError.invalidJournal
    }
    private func noteCancellation() { cancelled = true }
    func waitForLoad() async { while continuation == nil { await Task.yield() } }
    func waitForCancellation() async { while !cancelled { await Task.yield() } }
    func release() { continuation?.resume(); continuation = nil }
}

private actor PreparationFrames {
    private(set) var count = 0
    func record() { count += 1 }
}

private actor PreparationCredentials {
    private(set) var loads = 0
    private(set) var cancellations = 0
    func load() async throws -> FxSubscriptionCredentials {
        loads += 1
        do { try await Task.sleep(for: .seconds(60)) }
        catch { cancellations += 1; throw error }
        return try FxSubscriptionCredentials(accessToken: "preparation-test", accountID: "account")
    }
}

@Suite(.serialized, .timeLimit(.minutes(1))) struct PreparationTests {
    private func configuration(_ http: PreparationHTTP) -> FxConfiguration {
        FxConfiguration(apiKey: "preparation-test", model: FxModel(id: "swift/preparation", reasoningEffort: "high"), httpClient: http)
    }

    @Test func catalogTimeoutPreservesAcceptedInputAndReleasesOwnershipForRetry() async throws {
        let http = PreparationHTTP(), store = try FxSessionStore()
        let agent = try FxAgent(configuration: configuration(http), store: store,
                                deliveryPolicy: FxDeliveryPolicy(maximumDuration: .milliseconds(180), reserve: .milliseconds(80)))
        let session = try await agent.session(id: "s")
        let turn = try await session.prompt("keep this input", id: "original")
        await #expect(throws: FxSessionError.preparationTimedOut) { try await turn.result }
        #expect(await http.catalogRequests == 1)
        #expect(await http.cancellations == 1)
        #expect(await http.chatRequests == 0)
        #expect(try await store.result(session: "s", agent: "default", id: "original") == nil)
        #expect(try await store.pendingID(session: "s", agent: "default") == "original")
        let lease = try #require(try await store.claim(session: "s", agent: "default"))
        try await store.release(lease)
        await #expect(throws: FxSessionError.preparationTimedOut) { try await agent.close() }
        await http.unblock()
        // The short budget above tests the blocked preparation. Recovery uses a
        // normal delivery budget so runner load does not cause another timeout.
        let recoveringAgent = try FxAgent(configuration: configuration(http), store: store,
            deliveryPolicy: FxDeliveryPolicy(maximumDuration: .seconds(10), reserve: .seconds(1)))
        let recoveringSession = try await recoveringAgent.session(id: "s")
        let retry = try #require(try await recoveringSession.resume())
        #expect(retry.id == "original")
        #expect(try await retry.result.stopReason == .endTurn)
        #expect(await http.chatRequests == 1)
        try await recoveringAgent.close()
        let entries = try await store.entries(session: "s", agent: "default", after: 0)
        #expect(entries.filter { if case .started = $0.event { return true }; return false }.count == 1)
        // A delivery can yield before its model call when sanitizer overhead consumes its budget.
        // Each additional resume must follow a recorded yield for this same accepted input.
        let transitions = entries.compactMap { entry -> String? in
            switch entry.event {
            case .resumed(let id, let sessionID):
                #expect(id == "original" && sessionID == "s")
                return "resumed"
            case .yielded(let id):
                #expect(id == "original")
                return "yielded"
            default: return nil
            }
        }
        #expect(transitions.first == "resumed" && transitions.last == "resumed")
        for (index, transition) in transitions.enumerated() {
            #expect(transition == (index.isMultiple(of: 2) ? "resumed" : "yielded"))
        }
        #expect(entries.filter { if case .ended = $0.event { return true }; return false }.count == 1)
        try await store.close()
    }

    @Test func cancelledLoadCannotCreateANativeEngineAfterReturning() async throws {
        let store = PreparationStore(), frames = PreparationFrames(), http = PreparationHTTP()
        var configuration = configuration(http)
        configuration.wireObserver = { _, _ in await frames.record() }
        let saved = configuration
        let opening = Task { try await FxEngine.open(configuration: saved, persistence: store) }
        await store.waitForLoad()
        opening.cancel()
        await store.waitForCancellation()
        await store.release()
        await #expect(throws: CancellationError.self) { try await opening.value }
        #expect(await frames.count == 0)
        #expect(await http.catalogRequests == 0)
    }

    @Test func deadlineJoinsACancelledLoadBeforeReportingTimeout() async throws {
        let store = PreparationStore(), frames = PreparationFrames(), finished = PreparationFrames(), http = PreparationHTTP()
        var configuration = configuration(http)
        configuration.wireObserver = { _, _ in await frames.record() }
        let saved = configuration
        let opening = Task {
            do {
                let engine = try await openSessionEngine(configuration: saved, sessionID: "s", persistence: store,
                                                         deadline: .now.advanced(by: .milliseconds(100)))
                await finished.record()
                return engine
            } catch { await finished.record(); throw error }
        }
        await store.waitForLoad()
        await store.waitForCancellation()
        #expect(await finished.count == 0)
        await store.release()
        await #expect(throws: FxSessionError.preparationTimedOut) { try await opening.value }
        #expect(await finished.count == 1)
        #expect(await frames.count == 0)
        #expect(await http.catalogRequests == 0)
    }

    @Test func expiredPreparationDeadlineDoesNotLoadOrAllocate() async throws {
        let store = PreparationStore(), http = PreparationHTTP()
        await #expect(throws: FxSessionError.preparationTimedOut) {
            try await openSessionEngine(configuration: configuration(http), sessionID: "s", persistence: store, deadline: .now)
        }
        #expect(await store.loads == 0)
        #expect(await http.catalogRequests == 0)
    }

    @Test func repeatedOpenDeadlineRacesReleaseAllNativeSlots() async throws {
        let http = PreparationHTTP()
        await http.unblock()
        let configuration = FxConfiguration(apiKey: "preparation-test", model: "swift/preparation", httpClient: http)
        var retained: [FxEngine] = []
        for _ in 0..<70 {
            do {
                let engine = try await openSessionEngine(configuration: configuration, sessionID: "s", persistence: FxMemoryPersistence(),
                                                         deadline: .now.advanced(by: .milliseconds(2)))
                try await engine.close()
                retained.append(engine)
            } catch FxSessionError.preparationTimedOut {}
        }
        let engine = try await FxEngine.open(configuration: configuration)
        let turn = try await engine.prompt("after deadline races")
        #expect(try await turn.result.stopReason == .endTurn)
        try await engine.close()
        withExtendedLifetime(retained) {}
    }

    @Test func catalogPreparationDeadlineCancelsSubscriptionCredentialLookup() async throws {
        let http = PreparationHTTP(), credentials = PreparationCredentials(), store = try FxSessionStore()
        let subscription = FxSubscription(provider: .codex, credentials: { _ in try await credentials.load() })
        let agent = try FxAgent(configuration: FxConfiguration(provider: .subscription(subscription),
            model: FxModel(id: "gpt-6.1-sol", reasoningEffort: "low"), httpClient: http), store: store,
            deliveryPolicy: FxDeliveryPolicy(maximumDuration: .milliseconds(180), reserve: .milliseconds(80)))
        let session = try await agent.session(id: "s")
        let turn = try await session.prompt("retain this input", id: "original")
        await #expect(throws: FxSessionError.preparationTimedOut) { try await turn.result }
        #expect(await credentials.loads == 1)
        #expect(await credentials.cancellations == 1)
        #expect(await http.catalogRequests == 0)
        #expect(await http.chatRequests == 0)
        #expect(try await store.pendingID(session: "s", agent: "default") == "original")
        await #expect(throws: FxSessionError.preparationTimedOut) { try await agent.close() }
        try await store.close()
    }

    @Test func journalReadFailureKeepsTheAcceptedInputPending() async throws {
        let http = PreparationHTTP(), store = try FxSessionStore()
        try await store.removeJournalTableForPreparationTest()
        let agent = try FxAgent(configuration: configuration(http), store: store)
        let session = try await agent.session(id: "s")
        let turn = try await session.prompt("retain this input", id: "original")
        await #expect(throws: FxSQLiteError.self) { try await turn.result }
        #expect(try await store.pendingID(session: "s", agent: "default") == "original")
        #expect(try await store.result(session: "s", agent: "default", id: "original") == nil)
        #expect(await http.catalogRequests == 0)
        await #expect(throws: FxSQLiteError.self) { try await agent.close() }
        try await store.close()
    }
}

private extension FxSessionStore {
    func removeJournalTableForPreparationTest() throws { try database.execute("DROP TABLE fx_session_records") }
}
