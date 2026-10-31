import Foundation
import Testing
@testable import LibFx

private actor PublicationGate {
    private var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if released { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func release() {
        released = true
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.resume() }
    }
}

private actor LatePublicationProbe {
    let published = AsyncResult<Void>()
    let rejected = AsyncResult<Void>()
    private let releaseObserver = PublicationGate()
    private var idleAborted = false
    private var firstRequest: UUID?
    private(set) var publicationsAfterAbort = 0
    private(set) var cancelledRequestFailure = false

    func didAbortWithoutPrompt() { idleAborted = true }
    func observe(_ event: FxTransportEvent) async {
        switch event {
        case .started(let request) where firstRequest == nil:
            firstRequest = request.id
            if idleAborted { publicationsAfterAbort += 1 }
            await published.resolve(.success(()))
            // Ignore task cancellation until the test releases this observer
            // after the real core has reported the turn cancelled.
            await releaseObserver.wait()
        case .failed(let request, _, let reason) where request.id == firstRequest:
            cancelledRequestFailure = reason == .cancelled
            await rejected.resolve(.success(()))
        default: break
        }
    }
    func release() async { await releaseObserver.release() }
    func publicationFailed(_ error: any Error) async { await published.resolve(.failure(error)) }
}

/// Delays input bytes only. Output, fetch publication and HTTP dispatch use
/// the real core and production NativeTransport.
private actor PromptPublicationDelay: EngineTransport {
    nonisolated let native: NativeTransport
    nonisolated var output: AsyncThrowingStream<Data, any Error> { native.output }
    let promptHeld = AsyncResult<Void>()
    private let probe: LatePublicationProbe
    private var firstPrompt = true
    private var pendingPrompt: Data?

    init(native: NativeTransport, probe: LatePublicationProbe) { self.native = native; self.probe = probe }
    func start() async throws { try await native.start() }
    func setContext(sessionID: String, modelID: String) async { await native.setContext(sessionID: sessionID, modelID: modelID) }
    func beginTurn() async { await native.beginTurn() }
    func write(_ data: Data) async throws {
        let message = try JSONDecoder().decode(JSONValue.self, from: data)
        if firstPrompt, message["method"] == .string("session/prompt") {
            firstPrompt = false
            pendingPrompt = data
            await promptHeld.resolve(.success(()))
            return
        }
        try await native.write(data)
    }
    func stopStartingEffects() async {
        if let prompt = pendingPrompt {
            pendingPrompt = nil
            // The first abort runs before any prompt reaches the C core.
            await native.abortEffects()
            await probe.didAbortWithoutPrompt()
            do {
                try await native.write(prompt)
                // Delay forwarding the guard only until the real core's fetch
                // publication can be observed through the existing callback.
                try await probe.published.wait()
            } catch { await probe.publicationFailed(error) }
        }
        await native.stopStartingEffects()
    }
    func abortEffects() async { await native.abortEffects() }
    func putAttachment(_ data: Data, id: UInt32) async throws { try await native.putAttachment(data, id: id) }
    func takeAttachment(id: UInt32) async throws -> Data { try await native.takeAttachment(id: id) }
    func discardAttachments() async { await native.discardAttachments() }
    func close() async { await probe.release(); await native.close() }
}

private actor LatePublicationHTTP: FxHTTPClient {
    private(set) var catalogs = 0
    private(set) var prompts = 0
    func send(_ request: URLRequest) async throws -> FxHTTPResponse {
        let bytes: Data
        if request.httpMethod == "GET" {
            catalogs += 1
            bytes = Data(#"{"data":[{"id":"native/late-publication","type":"language","tags":["tool-use"]}]}"#.utf8)
        } else {
            prompts += 1
            bytes = Data("data: {\"type\":\"text-delta\",\"delta\":\"recovered\"}\n\ndata: {\"type\":\"finish\",\"finishReason\":{\"unified\":\"stop\",\"raw\":\"stop\"}}\n\ndata: [DONE]\n\n".utf8)
        }
        return FxHTTPResponse(statusCode: 200, body: AsyncThrowingStream {
            $0.yield(bytes); $0.finish()
        })
    }
}

@Suite(.serialized, .timeLimit(.minutes(1)))
struct NativeLatePublicationCancellationTests {
    @Test func aRealFetchPublishedAfterIdleAbortCannotStartHTTPAfterTheEffectGuardStops() async throws {
        let probe = LatePublicationProbe()
        let http = LatePublicationHTTP()
        let configuration = FxConfiguration(apiKey: "late-publication-test", model: "native/late-publication", httpClient: http)
        let native = try NativeTransport(options: configuration.nativeOptions, httpClient: http,
            onTransportEvent: { await probe.observe($0) })
        let transport = PromptPublicationDelay(native: native, probe: probe)
        let engine = try await FxEngine.openForConformance(configuration: configuration, transport: transport)
        do {
            let turn = try await engine.prompt("cancel before native publication")
            try await transport.promptHeld.wait()
            await turn.cancel()
            #expect(try await turn.result.stopReason == .cancelled)
            #expect(await probe.publicationsAfterAbort == 1)
            #expect(await http.catalogs == 0)
            #expect(await http.prompts == 0)

            await probe.release()
            try await probe.rejected.wait()
            #expect(await probe.cancelledRequestFailure)
            #expect(await http.catalogs == 0)
            #expect(await http.prompts == 0)

            let following = try await engine.prompt("continue after cancellation")
            var text = ""
            for try await event in following { if case .text(let delta) = event { text += delta } }
            #expect(try await following.result.stopReason == .endTurn)
            #expect(text == "recovered")
            #expect(await http.catalogs == 1)
            #expect(await http.prompts == 1)
            try await engine.close()
        } catch {
            await probe.release()
            try? await engine.close()
            throw error
        }
    }
}
