import Foundation

public enum FxEvent: Sendable, Equatable, Codable {
    /// Encoded update emitted by a custom durable harness.
    case payload(Data)
    case text(String)
    case reasoning(String)
    case userMessage(String, id: String?)
    case toolStarted(id: String, name: String, input: FxToolInput?)
    case toolFinished(id: String, name: String, content: String?, isError: Bool)

    // Keep the event record independent of the public display-input enum.
    private enum Record: Codable {
        case payload(Data)
        case text(String)
        case reasoning(String)
        case userMessage(String, id: String?)
        case toolStarted(id: String, name: String, input: JSONValue?, inputPreview: String?)
        case toolFinished(id: String, name: String, content: String?, isError: Bool)
    }

    public init(from decoder: any Decoder) throws {
        switch try Record(from: decoder) {
        case .payload(let data): self = .payload(data)
        case .text(let text): self = .text(text)
        case .reasoning(let text): self = .reasoning(text)
        case .userMessage(let text, let id): self = .userMessage(text, id: id)
        case .toolStarted(let id, let name, let input, let preview):
            if let preview {
                guard input == nil, preview.utf8.count <= 64 * 1024 else {
                    throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid tool input preview"))
                }
                self = .toolStarted(id: id, name: name, input: .truncated(preview: preview))
            } else {
                self = .toolStarted(id: id, name: name, input: try FxToolInput.display(input))
            }
        case .toolFinished(let id, let name, let content, let isError):
            self = .toolFinished(id: id, name: name, content: content, isError: isError)
        }
    }

    public func encode(to encoder: any Encoder) throws {
        let record: Record
        switch self {
        case .payload(let data): record = .payload(data)
        case .text(let text): record = .text(text)
        case .reasoning(let text): record = .reasoning(text)
        case .userMessage(let text, let id): record = .userMessage(text, id: id)
        case .toolStarted(let id, let name, let input):
            switch input {
            case .complete(let value): record = .toolStarted(id: id, name: name, input: value, inputPreview: nil)
            case .truncated(let preview):
                guard preview.utf8.count <= 64 * 1024 else {
                    throw EncodingError.invalidValue(preview, .init(codingPath: encoder.codingPath, debugDescription: "Tool input preview exceeds the size limit"))
                }
                record = .toolStarted(id: id, name: name, input: nil, inputPreview: preview)
            case nil: record = .toolStarted(id: id, name: name, input: nil, inputPreview: nil)
            }
        case .toolFinished(let id, let name, let content, let isError):
            record = .toolFinished(id: id, name: name, content: content, isError: isError)
        }
        try record.encode(to: encoder)
    }
}

public struct FxUsage: Sendable, Equatable, Codable {
    public let inputTokens: Int?
    public let outputTokens: Int?
    public let cacheReadTokens: Int?
    public let cacheWriteTokens: Int?
    public let reasoningTokens: Int?

    public init(inputTokens: Int? = nil, outputTokens: Int? = nil, cacheReadTokens: Int? = nil,
                cacheWriteTokens: Int? = nil, reasoningTokens: Int? = nil) {
        self.inputTokens = inputTokens; self.outputTokens = outputTokens
        self.cacheReadTokens = cacheReadTokens; self.cacheWriteTokens = cacheWriteTokens
        self.reasoningTokens = reasoningTokens
    }

    init(_ value: JSONValue?) {
        inputTokens = value?["inputTokens"]?.integer
        outputTokens = value?["outputTokens"]?.integer
        cacheReadTokens = value?["cacheReadTokens"]?.integer
        cacheWriteTokens = value?["cacheWriteTokens"]?.integer
        reasoningTokens = value?["reasoningTokens"]?.integer
    }
}

public struct FxTurnResult: Sendable, Equatable, Codable {
    public enum StopReason: String, Sendable, Codable {
        case endTurn = "end_turn", maxOutputTokens = "max_output_tokens"
        case maxModelTurns = "max_model_turns", refused, cancelled, error, unknown, yielded
    }
    public let stopReason: StopReason
    public let usage: FxUsage
    public let failure: FxSessionFailure?
    public init(stopReason: StopReason, usage: FxUsage = .init(), failure: FxSessionFailure? = nil) {
        self.stopReason = stopReason; self.usage = usage; self.failure = failure
    }
}

public struct FxSteeringReceipt: Sendable, Equatable {
    public let id: String
    public init(id: String) { self.id = id }
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
    public let events: AsyncThrowingStream<FxEvent, any Error>
    let completion: Task<FxTurnResult, any Error>
    let cancelAction: @Sendable () async -> Void
    let handoffAction: @Sendable () async throws -> Void
    let endForSteeringAction: @Sendable () async throws -> Void
    let steerAction: @Sendable (String, String) async throws -> FxSteeringReceipt
    let withdrawAction: @Sendable (String) async throws -> FxWithdrawal

    public var result: FxTurnResult {
        get async throws {
            try await withTaskCancellationHandler {
                try Task.checkCancellation()
                do {
                    let result = try await completion.value
                    try Task.checkCancellation()
                    return result
                } catch {
                    try Task.checkCancellation()
                    throw error
                }
            } onCancel: { Task { await cancelAction() } }
        }
    }
    public func makeAsyncIterator() -> AsyncIterator { events.makeAsyncIterator() }
    public func cancel() async { await cancelAction() }
    /// Stops this engine while keeping the interrupted turn for a new engine to resume.
    public func handoff() async throws { try await handoffAction() }
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
            cancelAction: {}, handoffAction: {}, endForSteeringAction: {}, steerAction: { _, _ in throw FxError.noActiveTurn },
            withdrawAction: { _ in .alreadyPlaced }
        )
    }
}
