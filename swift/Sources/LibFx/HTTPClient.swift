import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Supplies model HTTP requests. Cancellation must stop both headers and body work.
public protocol FxHTTPClient: Sendable {
    func send(_ request: URLRequest) async throws -> FxHTTPResponse
}

public struct FxHTTPResponse: Sendable {
    public let statusCode: Int
    public let headers: [String: String]
    public let body: AsyncThrowingStream<Data, any Error>
    var diagnosticHeaders: [String: String]?
    private let cancelBody: @Sendable () -> Void

    public init(
        statusCode: Int,
        headers: [String: String] = [:],
        body: AsyncThrowingStream<Data, any Error>,
        cancel: @escaping @Sendable () -> Void = {}
    ) {
        self.statusCode = statusCode
        self.headers = Dictionary(headers.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { _, new in new })
        self.body = body
        self.cancelBody = cancel
    }

    /// Releases response work, including a body that was never consumed.
    public func cancel() { cancelBody() }
}

/// Streams Foundation responses with bounded buffering and cancellation.
public struct FxURLSessionHTTPClient: FxHTTPClient {
    private let session: URLSession

    var usesSharedSession: Bool { session === URLSession.shared }
    var usesDefaultSession: Bool { session === Self.transientSession }

    private static let transientSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.urlCredentialStorage = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration)
    }()

    var permitsPersistentHTTPState: Bool {
        let configuration = session.configuration
        return configuration.urlCache != nil || configuration.urlCredentialStorage != nil || configuration.httpCookieStorage != nil
    }

    /// The default session does not persist request headers, credentials, cookies, or responses.
    public init() {
        self.session = Self.transientSession
    }

    /// A supplied session keeps the host's storage and caching policy.
    public init(session: URLSession) {
        self.session = session
    }

    public func send(_ request: URLRequest) async throws -> FxHTTPResponse {
        let (bytes, response) = try await session.bytes(for: request, delegate: CredentialRedirectPolicy())
        if Task.isCancelled {
            bytes.task.cancel()
            throw CancellationError()
        }
        guard let response = response as? HTTPURLResponse else {
            bytes.task.cancel()
            throw FxError.transport("Invalid HTTP response")
        }
        let reader = HTTPBodyReader(bytes)
        let body = AsyncThrowingStream<Data, any Error>(unfolding: { try await reader.next() })
        let headers = response.allHeaderFields.reduce(into: [String: String]()) { fields, entry in
            fields[String(describing: entry.key)] = String(describing: entry.value)
        }
        return FxHTTPResponse(statusCode: response.statusCode, headers: headers, body: body, cancel: { reader.cancel() })
    }
}

// Pull directly from Foundation when the consumer asks for another chunk. The
// iterator leaves the lock during an await; no producer reads ahead of demand.
private final class HTTPBodyReader: @unchecked Sendable {
    private let lock = NSLock()
    private let task: URLSessionTask
    private var iterator: URLSession.AsyncBytes.Iterator?
    private var ended = false
    private var cancelled = false

    init(_ bytes: URLSession.AsyncBytes) {
        task = bytes.task
        iterator = bytes.makeAsyncIterator()
    }

    deinit { task.cancel() }

    func cancel() {
        lock.withLock { cancelled = true; iterator = nil }
        task.cancel()
    }

    func next() async throws -> Data? {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            let current = try lock.withLock { () throws -> URLSession.AsyncBytes.Iterator? in
                guard !cancelled else { throw CancellationError() }
                if ended { return nil }
                guard let current = iterator else { throw FxError.protocolViolation("HTTP body already has a reader") }
                iterator = nil
                return current
            }
            guard var current else { return nil }
            defer { lock.withLock { if !cancelled && !ended { iterator = current } } }
            do {
                var chunk = Data()
                while let byte = try await current.next() {
                    try Task.checkCancellation()
                    chunk.append(byte)
                    if byte == 10 || chunk.count == 16 * 1024 {
                        try lock.withLock { if cancelled { throw CancellationError() } }
                        return chunk
                    }
                }
                try Task.checkCancellation()
                try lock.withLock {
                    guard !cancelled else { throw CancellationError() }
                    ended = true
                }
                return chunk.isEmpty ? nil : chunk
            } catch {
                cancel()
                throw error
            }
        } onCancel: { self.cancel() }
    }
}

/// Keep API credentials and request bodies at their original endpoint.
private final class CredentialRedirectPolicy: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? {
        guard let original = task.originalRequest,
              original.value(forHTTPHeaderField: "Authorization") == nil,
              ["GET", "HEAD"].contains(original.httpMethod ?? "GET") else { return nil }
        return request
    }
}
