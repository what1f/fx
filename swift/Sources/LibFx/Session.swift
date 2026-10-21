import Foundation

public struct FxSession: Sendable, Identifiable {
    public let id: String
    public var options: FxSessionOptions
    let agent: FxAgent

    public func prompt(_ text: String, id: String = UUID().uuidString) async throws -> FxSessionTurn {
        try await prompt([.text(text)], id: id)
    }
    /// Returns after the input has been durably accepted.
    public func prompt(_ content: [FxPromptContent], id: String = UUID().uuidString) async throws -> FxSessionTurn {
        try await agent.accept(session: self.id, options: options, content: content, id: id)
    }
    @discardableResult public func resume() async throws -> FxSessionTurn? { try await agent.resume(id) }
    public func cancel() async throws { try await agent.store.cancel(session: id, agent: agent.name) }
    public func checkpoint() async throws -> Data { try await agent.checkpoint(id, options: options) }
    public func events(after cursor: Int64 = 0) -> FxSessionEvents {
        FxSessionEvents(sessionID: id, cursor: cursor, agent: agent)
    }
}

/// Each iterator reads durable history independently. Cancelling a reader leaves work running.
public struct FxSessionEvents: AsyncSequence, Sendable {
    public typealias Element = FxSessionEntry
    let sessionID: String
    let cursor: Int64
    let agent: FxAgent

    public struct AsyncIterator: AsyncIteratorProtocol {
        let sessionID: String
        var cursor: Int64
        let agent: FxAgent
        var buffered: ArraySlice<FxSessionEntry> = []
        public mutating func next() async throws -> FxSessionEntry? {
            while true {
                try Task.checkCancellation()
                if let entry = buffered.popFirst() { cursor = entry.cursor; return entry }
                do { buffered = ArraySlice(try await agent.store.entries(session: sessionID, agent: agent.name, after: cursor)) }
                catch FxSessionError.notFound { buffered = [] }
                if buffered.isEmpty {
                    try await agent.failure(sessionID)
                    try await Task.sleep(for: .milliseconds(20))
                }
            }
        }
    }
    public func makeAsyncIterator() -> AsyncIterator { AsyncIterator(sessionID: sessionID, cursor: cursor, agent: agent) }
}

public struct FxSessionTurn: Sendable, Identifiable, AsyncSequence {
    public typealias Element = FxEvent
    public let id: String
    public let sessionID: String
    public let isRepeated: Bool
    let agent: FxAgent

    public var result: FxSessionResult {
        get async throws {
            while true {
                try Task.checkCancellation()
                if let result = try await agent.store.result(session: sessionID, agent: agent.name, id: id) {
                    try Task.checkCancellation()
                    return FxSessionResult(id: result.id, stopReason: result.stopReason, usage: result.usage,
                                           error: result.error, epoch: result.epoch, isRepeated: isRepeated)
                }
                try await agent.failure(sessionID)
                try await Task.sleep(for: .milliseconds(20))
            }
        }
    }
    public func cancel() async throws { try await agent.store.cancel(session: sessionID, agent: agent.name, id: id) }
    public struct AsyncIterator: AsyncIteratorProtocol {
        let id: String
        var source: FxSessionEvents.AsyncIterator
        var ended = false
        public mutating func next() async throws -> FxEvent? {
            guard !ended else { return nil }
            while let entry = try await source.next() {
                switch entry.event {
                case .update(let id, let event) where id == self.id: return event
                case .ended(let result) where result.id == id: ended = true; return nil
                default: continue
                }
            }
            return nil
        }
    }
    public func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(id: id, source: FxSessionEvents(sessionID: sessionID, cursor: 0, agent: agent).makeAsyncIterator())
    }
}
