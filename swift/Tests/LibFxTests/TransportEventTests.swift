import Foundation
import Testing
@testable import LibFx

private final class TransportEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [FxTransportEvent] = []
    var values: [FxTransportEvent] { lock.withLock { recorded } }
    func record(_ event: FxTransportEvent) { lock.withLock { recorded.append(event) } }
}

private actor DiagnosticHTTP: FxHTTPClient {
    enum Mode { case normal, retry, cancelled, bodyFailure, late }
    struct PrivateFailure: Error, CustomStringConvertible {
        var description: String { "transport-private-key private-input" }
    }
    let mode: Mode
    private(set) var posts = 0
    private var release: CheckedContinuation<Void, Never>?
    nonisolated let responseCancelled: AsyncStream<Void>
    private let responseCancelledContinuation: AsyncStream<Void>.Continuation

    init(_ mode: Mode) {
        self.mode = mode
        (responseCancelled, responseCancelledContinuation) = AsyncStream.makeStream()
    }
    func waitForPost() async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while posts == 0 {
            guard ContinuousClock.now < deadline else { throw PrivateFailure() }
            try await Task.sleep(for: .milliseconds(1))
        }
    }
    func releaseResponse() { release?.resume(); release = nil }

    func send(_ request: URLRequest) async throws -> FxHTTPResponse {
        if request.httpMethod == "GET" {
            let text = #"{"data":[{"id":"swift/diagnostic","type":"language"}]}"#
            return FxHTTPResponse(statusCode: 200, body: AsyncThrowingStream { $0.yield(Data(text.utf8)); $0.finish() })
        }
        posts += 1
        if mode == .retry && posts == 1 { throw PrivateFailure() }
        if mode == .cancelled { throw CancellationError() }
        if mode == .late { await withCheckedContinuation { release = $0 } }
        let continuation = responseCancelledContinuation
        return FxHTTPResponse(statusCode: 200, headers: [
            "x-vercel-id": "request-transport-private-key", "x-generation-id": "generation",
            "x-model-id": "served-model", "x-ai-gateway-provider": "fixture",
        ], body: AsyncThrowingStream {
            if mode == .bodyFailure { $0.finish(throwing: PrivateFailure()) }
            else {
                $0.yield(Data("data: {\"type\":\"text-delta\",\"delta\":\"complete\"}\n\ndata: {\"type\":\"finish\",\"finishReason\":{\"unified\":\"stop\",\"raw\":\"stop\"}}\n\ndata: [DONE]\n\n".utf8))
                $0.finish()
            }
        }, cancel: { continuation.finish() })
    }
}

private func diagnosticConfiguration(_ http: DiagnosticHTTP, _ events: TransportEvents) -> FxConfiguration {
    FxConfiguration(apiKey: "transport-private-key", model: "swift/diagnostic", instructions: "private-system",
        gatewayURL: URL(string: "http://127.0.0.1:12345/chat")!,
        httpClient: http, onTransportEvent: { events.record($0) })
}

@Test func transportEventsCorrelateRequestsAndProtectContent() async throws {
    let http = DiagnosticHTTP(.normal), events = TransportEvents()
    let engine = try await FxEngine.open(configuration: diagnosticConfiguration(http, events))
    for _ in 0..<2 {
        let turn = try await engine.prompt("private-input")
        #expect(try await turn.result.stopReason == .endTurn)
    }
    try await engine.close()
    let starts = events.values.compactMap { if case .started(let request) = $0 { return request }; return nil }
    let responses = events.values.compactMap { event -> (FxTransportEvent.Request, FxTransportEvent.Response)? in
        if case .response(let request, let response) = event { return (request, response) }; return nil
    }
    #expect(starts.map(\.number) == [1, 2, 1])
    #expect(Set(starts.map(\.id)).count == 3)
    #expect(starts.allSatisfy { $0.sessionID == engine.sessionID && $0.modelID == "swift/diagnostic" })
    #expect(responses.map { $0.0.id } == starts.map(\.id))
    #expect(responses.allSatisfy { $0.1.statusCode == 200 && $0.1.elapsed >= .zero })
    let chat = try #require(responses.first { $0.0.method == "POST" })
    #expect(chat.0.endpoint?.absoluteString == "http://127.0.0.1:12345/chat")
    #expect(chat.1.requestID == "request-[redacted]")
    #expect(chat.1.generationID == "generation")
    #expect(chat.1.modelID == "served-model")
    #expect(chat.1.provider == "fixture")
    let text = String(describing: events.values)
    for secret in ["transport-private-key", "private-input", "private-system", "query-secret", "fragment-secret"] {
        #expect(!text.contains(secret))
    }
}

@Test func transportEndpointRemovesCredentialsAndQuery() {
    let url = URL(string: "https://user:password@example.com/chat?credential=query-secret#fragment-secret")!
    #expect(transportEndpoint(url)?.absoluteString == "https://example.com/chat")
    #expect(transportEndpoint(nil) == nil)
}

@Test func transportMetadataBoundsPreserveUTF8() throws {
    let text = try #require(boundedTransportText(String(repeating: "a", count: 511) + "中"))
    #expect(text == String(repeating: "a", count: 511))
    #expect(text.utf8.count <= 512)
    #expect(boundedTransportText(nil) == nil)
    #expect(boundedTransportText("") == "")
}

@Test func retryEventsCountActualAttemptsWithoutCopyingErrors() async throws {
    let http = DiagnosticHTTP(.retry), events = TransportEvents()
    let engine = try await FxEngine.open(configuration: diagnosticConfiguration(http, events))
    let turn = try await engine.prompt("private-input")
    #expect(try await turn.result.stopReason == .endTurn)
    try await engine.close()
    let values = events.values
    let starts = values.compactMap { if case .started(let request) = $0 { return request.number }; return nil }
    #expect(starts == [1, 2, 3])
    #expect(values.contains { if case .failed(let request, let elapsed, .requestFailed) = $0 { return request.number == 2 && elapsed >= .zero }; return false })
    #expect(values.contains { if case .retrying(let request) = $0 { return request.number == 2 }; return false })
    #expect(!String(describing: values).contains("transport-private-key"))
    #expect(!String(describing: values).contains("private-input"))
    #expect(await http.posts == 2)
}

@Test(arguments: [false, true])
func cancelledHeadersAndFailedBodiesAreNotRetried(bodyFailure: Bool) async throws {
    let http = DiagnosticHTTP(bodyFailure ? .bodyFailure : .cancelled), events = TransportEvents()
    let engine = try await FxEngine.open(configuration: diagnosticConfiguration(http, events))
    let turn = try await engine.prompt("private-input")
    await #expect(throws: FxError.self) { try await turn.result }
    try await engine.close()
    #expect(await http.posts == 1)
    #expect(!events.values.contains { if case .retrying = $0 { return true }; return false })
    if !bodyFailure {
        #expect(events.values.contains { if case .failed(_, _, .cancelled) = $0 { return true }; return false })
    }
}

@Test func closingSuppressesLateResponseDiagnostics() async throws {
    let http = DiagnosticHTTP(.late), events = TransportEvents()
    let engine = try await FxEngine.open(configuration: diagnosticConfiguration(http, events))
    let turn = try await engine.prompt("private-input")
    try await http.waitForPost()
    try await engine.close()
    let count = events.values.count
    await http.releaseResponse()
    for await _ in http.responseCancelled {}
    #expect(events.values.count == count)
    await #expect(throws: FxError.self) { try await turn.result }
}
