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

/// Read events once. Await result to observe completion even when no events are consumed.
public struct FxTurn: AsyncSequence, Sendable {
    public typealias Element = FxEvent
    public typealias AsyncIterator = AsyncThrowingStream<FxEvent, any Error>.Iterator
    let events: AsyncThrowingStream<FxEvent, any Error>
    let completion: Task<FxTurnResult, any Error>
    let cancelAction: @Sendable () async -> Void

    public var result: FxTurnResult {
        get async throws {
            try await withTaskCancellationHandler {
                try Task.checkCancellation()
                return try await completion.value
            } onCancel: { Task { await cancelAction() } }
        }
    }
    public func makeAsyncIterator() -> AsyncIterator { events.makeAsyncIterator() }
    public func cancel() async { await cancelAction() }
}
