import Foundation

/// Typed data execution using the same durable worker as conversation sessions.
public struct FxDurableAgent<Input: Codable & Sendable, Update: Codable & Sendable>: Sendable {
    private let agent: FxAgent
    public var name: String { agent.name }
    init(agent: FxAgent) { self.agent = agent }

    public init<Harness: FxDurableHarness>(harness: Harness, name: String = "default", store: any FxSessionStorage,
        checkpoint: Data? = nil, checkpointAfterBytes: Int? = 64 * 1024,
        deliveryPolicy: FxDeliveryPolicy? = nil, queue: (any FxSessionQueue)? = nil,
        onLifecycleEvent: (@Sendable (FxLifecycleEvent) async -> Void)? = nil
    ) throws where Harness.Input == Input, Harness.Update == Update {
        agent = try FxAgent(harness: DurableHarnessAdapter(harness: harness), name: name, store: store,
            checkpoint: checkpoint, checkpointAfterBytes: checkpointAfterBytes, deliveryPolicy: deliveryPolicy,
            queue: queue, onLifecycleEvent: onLifecycleEvent)
    }

    public func session(id: String = UUID().uuidString, options: FxSessionOptions = .init()) async throws -> FxDurableSession<Input, Update> {
        FxDurableSession(session: try await agent.session(id: id, options: options))
    }
    public func deliver(_ wakeup: FxSessionWakeup, policy: FxDeliveryPolicy? = nil) async throws -> FxDeliveryOutcome {
        try await agent.deliver(wakeup, policy: policy)
    }
    public func close() async throws { try await agent.close() }
}

public struct FxDurableSession<Input: Codable & Sendable, Update: Codable & Sendable>: Sendable, Identifiable {
    private var session: FxSession
    public var id: String { session.id }
    public var options: FxSessionOptions {
        get { session.options }
        set { session.options = newValue }
    }
    init(session: FxSession) { self.session = session }

    public func submit(_ input: Input, id: String = UUID().uuidString) async throws -> FxDurableTurn<Update> {
        FxDurableTurn(turn: try await session.prompt([.payload(encodeDurablePayload(input))], id: id))
    }
    /// Ends an active turn and queues this input as a separate turn.
    public func steer(_ input: Input, id: String = UUID().uuidString) async throws -> FxDurableTurn<Update> {
        FxDurableTurn(turn: try await session.agent.accept(session: session.id, options: session.options,
            content: [.payload(encodeDurablePayload(input))], id: id, steering: true))
    }
    public func resume() async throws -> FxDurableTurn<Update>? {
        try await session.resume().map { FxDurableTurn(turn: $0) }
    }
    public func cancel() async throws { try await session.cancel() }
    public func checkpoint() async throws -> Data { try await session.checkpoint() }
    public func events(after cursor: Int64 = 0) -> FxDurableEvents<Input, Update> {
        FxDurableEvents(source: session.events(after: cursor))
    }
}

public struct FxDurableTurn<Update: Codable & Sendable>: Sendable, Identifiable, AsyncSequence {
    public typealias Element = Update
    private let turn: FxSessionTurn
    public var id: String { turn.id }
    public var sessionID: String { turn.sessionID }
    public var isRepeated: Bool { turn.isRepeated }
    public var result: FxSessionResult { get async throws { try await turn.result } }
    init(turn: FxSessionTurn) { self.turn = turn }
    public func cancel() async throws { try await turn.cancel() }
    public struct AsyncIterator: AsyncIteratorProtocol {
        var source: FxSessionTurn.AsyncIterator
        public mutating func next() async throws -> Update? {
            guard let event = try await source.next() else { return nil }
            return try decodeDurableUpdate(event, as: Update.self)
        }
    }
    public func makeAsyncIterator() -> AsyncIterator { AsyncIterator(source: turn.makeAsyncIterator()) }
}

public enum FxDurableEvent<Input: Codable & Sendable, Update: Codable & Sendable>: Sendable {
    case started(id: String, sessionID: String, input: Input)
    case resumed(id: String, sessionID: String)
    case yielded(id: String)
    case update(id: String, Update)
    case ended(FxSessionResult)
}

public struct FxDurableEntry<Input: Codable & Sendable, Update: Codable & Sendable>: Sendable {
    public let cursor: Int64
    public let epoch: Int64
    public let event: FxDurableEvent<Input, Update>
}

/// Independent typed replay readers. Cancelling a reader leaves execution running.
public struct FxDurableEvents<Input: Codable & Sendable, Update: Codable & Sendable>: Sendable, AsyncSequence {
    public typealias Element = FxDurableEntry<Input, Update>
    let source: FxSessionEvents
    public struct AsyncIterator: AsyncIteratorProtocol {
        var source: FxSessionEvents.AsyncIterator
        public mutating func next() async throws -> Element? {
            guard let entry = try await source.next() else { return nil }
            let event: FxDurableEvent<Input, Update>
            switch entry.event {
            case .started(let id, let session, let input):
                event = .started(id: id, sessionID: session, input: try JSONDecoder().decode(Input.self, from: durablePayload(input)))
            case .resumed(let id, let session): event = .resumed(id: id, sessionID: session)
            case .yielded(let id): event = .yielded(id: id)
            case .update(let id, let update): event = .update(id: id, try decodeDurableUpdate(update, as: Update.self))
            case .ended(let result): event = .ended(result)
            }
            return Element(cursor: entry.cursor, epoch: entry.epoch, event: event)
        }
    }
    public func makeAsyncIterator() -> AsyncIterator { AsyncIterator(source: source.makeAsyncIterator()) }
}
