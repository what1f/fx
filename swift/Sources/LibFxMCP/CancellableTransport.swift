import Foundation
import Logging
import MCP

/// Cancel an unsent request even if the client's request task has not registered
/// its continuation yet. Once send starts, the client's cancellation owns it.
actor CancellableTransport: Transport {
    let logger: Logger
    private let base: any Transport
    private var connected = false
    private var closing: Task<Void, Never>?
    private var registered: Set<ID> = []
    private var cancelled: Set<ID> = []
    private var input: AsyncThrowingStream<Data, Error>?

    init(_ base: any Transport, logger: Logger) {
        self.base = base
        self.logger = logger
    }

    func connect() async throws {
        guard closing == nil else { throw CancellationError() }
        try await base.connect()
        guard closing == nil else { await base.disconnect(); throw CancellationError() }
        input = await base.receive()
        guard closing == nil else { await base.disconnect(); throw CancellationError() }
        connected = true
    }

    func disconnect() async {
        if let closing { await closing.value; return }
        connected = false
        registered.removeAll()
        cancelled.removeAll()
        let task = Task { await base.disconnect() }
        closing = task
        await task.value
    }

    func register(_ id: ID) { registered.insert(id) }
    func discard(_ id: ID) { registered.remove(id); cancelled.remove(id) }
    func cancel(_ id: ID) {
        if registered.contains(id) { cancelled.insert(id) }
    }

    func send(_ data: Data) async throws {
        guard connected, closing == nil else { throw CancellationError() }
        struct Envelope: Decodable { let id: ID?; let method: String? }
        if let envelope = try? JSONDecoder().decode(Envelope.self, from: data), envelope.method != nil, let id = envelope.id {
            registered.remove(id)
            if cancelled.remove(id) != nil { throw CancellationError() }
        }
        try await base.send(data)
    }

    func receive() -> AsyncThrowingStream<Data, Error> {
        input ?? AsyncThrowingStream { $0.finish(throwing: CancellationError()) }
    }
}
