import Foundation
import Logging
import MCP

actor DriverMCPTransport: Transport {
    let logger = Logger(label: "libfx.conformance.mcp")
    private let stream: AsyncThrowingStream<Data, Error>
    private let continuation: AsyncThrowingStream<Data, Error>.Continuation
    private let write: @Sendable (Data) async -> Void

    init(write: @escaping @Sendable (Data) async -> Void) {
        let pair = AsyncThrowingStream<Data, Error>.makeStream()
        stream = pair.stream
        continuation = pair.continuation
        self.write = write
    }
    func connect() {}
    func disconnect() { continuation.finish() }
    func send(_ data: Data) async { await write(data) }
    func receive() -> AsyncThrowingStream<Data, Error> { stream }
    func receive(_ data: Data) { continuation.yield(data) }
}
