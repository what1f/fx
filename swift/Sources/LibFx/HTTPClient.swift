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
    public let body: AsyncThrowingStream<Data, any Error>
    private let cancelBody: @Sendable () -> Void

    public init(
        statusCode: Int,
        body: AsyncThrowingStream<Data, any Error>,
        cancel: @escaping @Sendable () -> Void = {}
    ) {
        self.statusCode = statusCode
        self.body = body
        self.cancelBody = cancel
    }

    /// Releases response work, including a body that was never consumed.
    public func cancel() { cancelBody() }
}

/// Streams Foundation responses with bounded buffering and cancellation.
public struct FxURLSessionHTTPClient: FxHTTPClient {
    private let session: URLSession

    public init(session: URLSession = .shared) { self.session = session }

    public func send(_ request: URLRequest) async throws -> FxHTTPResponse {
        let (bytes, response) = try await session.bytes(for: request)
        if Task.isCancelled {
            bytes.task.cancel()
            throw CancellationError()
        }
        guard let response = response as? HTTPURLResponse else {
            bytes.task.cancel()
            throw FxError.transport("Invalid HTTP response")
        }
        let (body, continuation) = AsyncThrowingStream<Data, any Error>.makeStream(
            bufferingPolicy: .bufferingOldest(256)
        )
        let producer = Task {
            do {
                try Task.checkCancellation()
                var chunk = Data()
                for try await byte in bytes {
                    chunk.append(byte)
                    // Forward SSE lines promptly, while bounding an individual chunk.
                    if byte == 10 || chunk.count == 16 * 1024 {
                        try Self.yield(chunk, to: continuation)
                        chunk.removeAll(keepingCapacity: true)
                    }
                }
                if !chunk.isEmpty { try Self.yield(chunk, to: continuation) }
                continuation.finish()
            } catch {
                bytes.task.cancel()
                continuation.finish(throwing: error)
            }
        }
        let cancel: @Sendable () -> Void = {
            producer.cancel()
            bytes.task.cancel()
        }
        continuation.onTermination = { _ in cancel() }
        return FxHTTPResponse(statusCode: response.statusCode, body: body, cancel: cancel)
    }

    private static func yield(
        _ data: Data,
        to continuation: AsyncThrowingStream<Data, any Error>.Continuation
    ) throws {
        try Task.checkCancellation()
        switch continuation.yield(data) {
        case .enqueued: return
        case .dropped: throw FxError.outputOverflow
        case .terminated: throw CancellationError()
        @unknown default: throw FxError.outputOverflow
        }
    }
}
