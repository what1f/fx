import Foundation

public enum FxEvent: Sendable, Equatable {
    case text(String)
    case reasoning(String)
    case userMessage(String, id: String?)
    case toolStarted(id: String, name: String, input: JSONValue?)
    case toolFinished(id: String, name: String, content: String?, isError: Bool)
}

public struct FxUsage: Sendable, Equatable {
    public let inputTokens: Int?
    public let outputTokens: Int?
    public let cacheReadTokens: Int?
    public let cacheWriteTokens: Int?
    public let reasoningTokens: Int?

    init(_ value: JSONValue?) {
        inputTokens = value?["inputTokens"]?.integer
        outputTokens = value?["outputTokens"]?.integer
        cacheReadTokens = value?["cacheReadTokens"]?.integer
        cacheWriteTokens = value?["cacheWriteTokens"]?.integer
        reasoningTokens = value?["reasoningTokens"]?.integer
    }
}

public struct FxTurnResult: Sendable, Equatable {
    public enum StopReason: String, Sendable {
        case endTurn = "end_turn", maxOutputTokens = "max_output_tokens"
        case maxModelTurns = "max_model_turns", refused, cancelled, error, unknown, yielded
    }
    public let stopReason: StopReason
    public let usage: FxUsage
}

public struct FxSteeringReceipt: Sendable, Equatable {
    public let id: String
}

public enum FxWithdrawal: String, Sendable {
    case withdrawn
    case alreadyPlaced = "already_placed"
}

/// Read events once. Await result to observe completion even when no events are consumed.
public struct FxTurn: AsyncSequence, Sendable, Identifiable {
    public typealias Element = FxEvent
    public typealias AsyncIterator = AsyncThrowingStream<FxEvent, any Error>.Iterator
    public let id: String
    let events: AsyncThrowingStream<FxEvent, any Error>
    let completion: Task<FxTurnResult, any Error>
    let cancelAction: @Sendable () async -> Void
    let steerAction: @Sendable (String, String) async throws -> FxSteeringReceipt
    let withdrawAction: @Sendable (String) async throws -> FxWithdrawal

    public var result: FxTurnResult {
        get async throws {
            try await withTaskCancellationHandler {
                try Task.checkCancellation()
                let result = try await completion.value
                try Task.checkCancellation()
                return result
            } onCancel: { Task { await cancelAction() } }
        }
    }
    public func makeAsyncIterator() -> AsyncIterator { events.makeAsyncIterator() }
    public func cancel() async { await cancelAction() }
    public func steer(_ text: String, id: String = UUID().uuidString) async throws -> FxSteeringReceipt {
        try await steerAction(text, id)
    }
    public func withdraw(_ id: String) async throws -> FxWithdrawal { try await withdrawAction(id) }

    static func completed(id: String) -> FxTurn {
        let (events, continuation) = AsyncThrowingStream<FxEvent, any Error>.makeStream()
        continuation.finish()
        return FxTurn(
            id: id, events: events,
            completion: Task<FxTurnResult, any Error> { FxTurnResult(stopReason: .endTurn, usage: FxUsage(nil)) },
            cancelAction: {}, steerAction: { _, _ in throw FxError.noActiveTurn },
            withdrawAction: { _ in .alreadyPlaced }
        )
    }
}
