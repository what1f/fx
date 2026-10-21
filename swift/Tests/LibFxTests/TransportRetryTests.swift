import Foundation
import Testing
@testable import LibFx

private actor RetryHTTPClient: FxHTTPClient {
    enum Failure: Sendable { case headers, cancellation, urlCancellation, body }
    let failure: Failure
    var attempts = 0
    init(_ failure: Failure) { self.failure = failure }
    func send(_ request: URLRequest) async throws -> FxHTTPResponse {
        if request.httpMethod == "GET" {
            return FxHTTPResponse(statusCode: 200, body: AsyncThrowingStream { continuation in
                continuation.yield(Data(#"{"data":[{"id":"swift/retry","type":"language"}]}"#.utf8)); continuation.finish()
            })
        }
        attempts += 1
        if attempts == 1 {
            switch failure {
            case .headers: throw URLError(.networkConnectionLost)
            case .cancellation: throw CancellationError()
            case .urlCancellation: throw URLError(.cancelled)
            case .body:
                return FxHTTPResponse(statusCode: 200, body: AsyncThrowingStream { continuation in
                    continuation.finish(throwing: URLError(.networkConnectionLost))
                })
            }
        }
        let text = "data: {\"type\":\"text-delta\",\"delta\":\"retried\"}\n\ndata: {\"type\":\"finish\",\"finishReason\":{\"unified\":\"stop\",\"raw\":\"stop\"}}\n\ndata: [DONE]\n\n"
        return FxHTTPResponse(statusCode: 200, body: AsyncThrowingStream { continuation in
            continuation.yield(Data(text.utf8)); continuation.finish()
        })
    }
}

@Test func networkFailureBeforeHeadersRetriesOnce() async throws {
    let client = RetryHTTPClient(.headers)
    let engine = try await FxEngine.open(configuration: FxConfiguration(apiKey: "test-key", model: "swift/retry", httpClient: client))
    let turn = try await engine.prompt("hello")
    var text = ""
    for try await event in turn { if case .text(let delta) = event { text += delta } }
    #expect(try await turn.result.stopReason == .endTurn)
    #expect(text == "retried")
    #expect(await client.attempts == 2)
    try await engine.close()
}

@Test func cancellationAndBodyFailureDoNotReplayRequests() async throws {
    for failure in [RetryHTTPClient.Failure.cancellation, .urlCancellation, .body] {
        let client = RetryHTTPClient(failure)
        let engine = try await FxEngine.open(configuration: FxConfiguration(apiKey: "test-key", model: "swift/retry", httpClient: client))
        let turn = try await engine.prompt("hello")
        do {
            for try await _ in turn {}
            _ = try await turn.result
            Issue.record("Failed transport produced a successful turn")
        } catch FxError.rpc(let code, let message, _) {
            #expect(code == -32603)
            #expect(message == "HostStreamFailed")
        }
        #expect(await client.attempts == 1)
        try await engine.close()
    }
}
