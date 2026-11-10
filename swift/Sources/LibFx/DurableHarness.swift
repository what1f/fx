import Foundation

/// A durable executor with application-defined input and streamed update types.
public protocol FxDurableHarness<Input, Update>: Sendable {
    associatedtype Input: Codable & Sendable
    associatedtype Update: Codable & Sendable
    func validate(options: FxSessionOptions) throws
    func validate(_ input: Input, options: FxSessionOptions) throws
    func prepareCheckpoint(_ data: Data, options: FxSessionOptions) async throws -> Data
    func open(_ context: FxHarnessContext) async throws -> any FxDurableHarnessSession<Input, Update>
}

extension FxDurableHarness {
    public func validate(options: FxSessionOptions) throws {}
    public func validate(_ input: Input, options: FxSessionOptions) throws {}
}

public protocol FxDurableHarnessSession<Input, Update>: Sendable {
    associatedtype Input: Codable & Sendable
    associatedtype Update: Codable & Sendable
    var recoveryState: FxRecoveryState? { get async }
    var completedTurnID: String? { get async }
    func submit(_ input: Input, id: String, yieldAt: Date?) async throws -> any FxDurableHarnessTurn<Update>
    func resume(rerunning: Bool, yieldAt: Date?) async throws -> (any FxDurableHarnessTurn<Update>)?
    func saveCheckpoint() async throws
    func checkpoint() async throws -> Data
    /// Join pending writes and leave recovery properties readable afterward.
    /// After a durable terminal result, cleanup may overlap the session's next turn.
    func close() async throws
}

public protocol FxDurableHarnessTurn<Update>: Sendable {
    associatedtype Update: Codable & Sendable
    /// Single consumer. Produce updates only as fast as they can be persisted.
    var events: AsyncThrowingStream<Update, any Error> { get }
    /// A terminal result acknowledges all journal writes needed to recover that completion.
    var result: FxTurnResult { get async throws }
    func cancel() async
    func handoff() async throws
    func endForSteering() async throws
}

struct DurableHarnessAdapter<Harness: FxDurableHarness>: FxSessionHarness {
    let harness: Harness
    func validate(options: FxSessionOptions) throws { try harness.validate(options: options) }
    func validate(input: [FxPromptContent], options: FxSessionOptions) throws {
        try harness.validate(JSONDecoder().decode(Harness.Input.self, from: durablePayload(input)), options: options)
    }
    func prepareCheckpoint(_ data: Data, options: FxSessionOptions) async throws -> Data {
        try await harness.prepareCheckpoint(data, options: options)
    }
    func open(_ context: FxHarnessContext) async throws -> any FxHarnessSession {
        DurableSessionAdapter(session: try await harness.open(context))
    }
}

private struct DurableSessionAdapter<Input: Codable & Sendable, Update: Codable & Sendable>: FxHarnessSession {
    let session: any FxDurableHarnessSession<Input, Update>
    var recoveryState: FxRecoveryState? { get async { await session.recoveryState } }
    var completedTurnID: String? { get async { await session.completedTurnID } }
    func prompt(_ content: [FxPromptContent], id: String, yieldAt: Date?) async throws -> any FxHarnessTurn {
        let input = try JSONDecoder().decode(Input.self, from: durablePayload(content))
        return DurableTurnAdapter(turn: try await session.submit(input, id: id, yieldAt: yieldAt))
    }
    func resume(rerunning: Bool, yieldAt: Date?) async throws -> (any FxHarnessTurn)? {
        guard let turn = try await session.resume(rerunning: rerunning, yieldAt: yieldAt) else { return nil }
        return DurableTurnAdapter(turn: turn)
    }
    func saveCheckpoint() async throws { try await session.saveCheckpoint() }
    func checkpoint() async throws -> Data { try await session.checkpoint() }
    func close() async throws { try await session.close() }
}

private struct DurableTurnAdapter<Update: Codable & Sendable>: FxHarnessTurn {
    let turn: any FxDurableHarnessTurn<Update>
    var events: AsyncThrowingStream<FxEvent, any Error> {
        let source = DurableUpdateIterator(stream: turn.events)
        return AsyncThrowingStream(unfolding: { try await source.next() })
    }
    var result: FxTurnResult { get async throws { try await turn.result } }
    func cancel() async { await turn.cancel() }
    func handoff() async throws { try await turn.handoff() }
    func steer(_ text: String, id: String) async throws -> FxSteeringReceipt { throw FxError.noActiveTurn }
    func endForSteering() async throws { try await turn.endForSteering() }
}

// The adapter pulls one update at a time; it adds no producer task or event buffer.
// NSLock supports the package's macOS 14 target. A read takes the iterator out
// of the box until its await finishes; concurrent reads cannot access it.
private final class DurableUpdateIterator<Update: Codable & Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var iterator: AsyncThrowingStream<Update, any Error>.Iterator?
    init(stream: AsyncThrowingStream<Update, any Error>) { iterator = stream.makeAsyncIterator() }
    func next() async throws -> FxEvent? {
        var iterator = try lock.withLock {
            guard let iterator = self.iterator else { throw FxError.protocolViolation("Concurrent update iteration") }
            self.iterator = nil
            return iterator
        }
        defer { lock.withLock { self.iterator = iterator } }
        guard let update = try await iterator.next() else { return nil }
        return .payload(try encodeDurablePayload(update))
    }
}
