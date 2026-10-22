import Foundation
import Testing
@testable import LibFx
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

private final class StopState: @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false
    func set() { lock.lock(); stopped = true; lock.unlock() }
    var value: Bool { lock.lock(); defer { lock.unlock() }; return stopped }
}

private final class ScriptedURLProtocol: URLProtocol, @unchecked Sendable {
    static let stalledStopped = StopState()
    static let stalledStarted = StopState()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        if url.path == "/invalid" {
            let response = URLResponse(url: url, mimeType: "text/plain", expectedContentLength: 0, textEncodingName: nil)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        let response = HTTPURLResponse(url: url, statusCode: 503, httpVersion: nil, headerFields: [:])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        let data: Data
        if url.path == "/burst" { data = Data(String(repeating: "data: {\"text\":\"hi\"}\n\n", count: 1000).utf8) }
        else if url.path == "/large" { data = Data(repeating: 65, count: 128 * 1024) }
        else { data = Data("data: 你好\n\n".utf8) }
        client?.urlProtocol(self, didLoad: data)
        if url.path == "/stalled" { Self.stalledStarted.set() }
        else { client?.urlProtocolDidFinishLoading(self) }
    }

    override func stopLoading() {
        if request.url?.path == "/stalled" { Self.stalledStopped.set() }
    }
}

private func session() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [ScriptedURLProtocol.self]
    return URLSession(configuration: configuration)
}

@Test func httpClientPreservesStatusAndUnicodeBody() async throws {
    let session = session()
    defer { session.invalidateAndCancel() }
    let client = FxURLSessionHTTPClient(session: session)
    let response = try await client.send(URLRequest(url: URL(string: "https://example.invalid/stream")!))
    defer { response.cancel() }
    #expect(response.statusCode == 503)
    var body = Data()
    for try await chunk in response.body { body.append(chunk) }
    #expect(String(decoding: body, as: UTF8.self) == "data: 你好\n\n")
}

@Test func httpClientBoundsEachChunk() async throws {
    let session = session()
    defer { session.invalidateAndCancel() }
    let client = FxURLSessionHTTPClient(session: session)
    let response = try await client.send(URLRequest(url: URL(string: "https://example.invalid/large")!))
    defer { response.cancel() }
    var count = 0
    for try await chunk in response.body {
        #expect(chunk.count <= 16 * 1024)
        count += chunk.count
    }
    #expect(count == 128 * 1024)
}

@Test func httpClientPreservesBurstWhileConsumerIsPaused() async throws {
    let session = session()
    defer { session.invalidateAndCancel() }
    let response = try await FxURLSessionHTTPClient(session: session).send(
        URLRequest(url: URL(string: "https://example.invalid/burst")!))
    defer { response.cancel() }
    try await Task.sleep(for: .milliseconds(200))
    var body = Data()
    for try await chunk in response.body { body.append(chunk) }
    #expect(body == Data(String(repeating: "data: {\"text\":\"hi\"}\n\n", count: 1000).utf8))
}

@Test func httpClientCancellationBeforeConsumptionStopsBody() async throws {
    let session = session()
    defer { session.invalidateAndCancel() }
    let response = try await FxURLSessionHTTPClient(session: session).send(
        URLRequest(url: URL(string: "https://example.invalid/burst")!))
    response.cancel()
    await #expect(throws: CancellationError.self) {
        var iterator = response.body.makeAsyncIterator()
        _ = try await iterator.next()
    }
}

@Test func httpClientRejectsNonHTTPResponse() async throws {
    let session = session()
    defer { session.invalidateAndCancel() }
    let client = FxURLSessionHTTPClient(session: session)
    do {
        _ = try await client.send(URLRequest(url: URL(string: "https://example.invalid/invalid")!))
        Issue.record("Non-HTTP response was accepted")
    } catch { #expect(error as? FxError == .transport("Invalid HTTP response")) }
}

@Test func httpClientCancelsPendingHeaders() async throws {
    let session = session()
    defer { session.invalidateAndCancel() }
    let client = FxURLSessionHTTPClient(session: session)
    let task = Task {
        try await client.send(URLRequest(url: URL(string: "https://example.invalid/stalled")!))
    }
    let deadline = ContinuousClock.now + .seconds(2)
    while !ScriptedURLProtocol.stalledStarted.value, ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(1))
    }
    #expect(ScriptedURLProtocol.stalledStarted.value)
    task.cancel()
    do {
        let response = try await task.value
        response.cancel()
        Issue.record("Cancelled headers returned a response")
    } catch { }
    let stoppedDeadline = ContinuousClock.now + .seconds(2)
    while !ScriptedURLProtocol.stalledStopped.value, ContinuousClock.now < stoppedDeadline {
        try await Task.sleep(for: .milliseconds(1))
    }
    #expect(ScriptedURLProtocol.stalledStopped.value)
}
