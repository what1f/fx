import Foundation

func validSessionIdentifier(_ value: String) -> Bool {
    !value.isEmpty && value.utf8.count <= 255 && value.utf8.allSatisfy {
        (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || [45, 46, 95].contains($0)
    }
}

public enum FxSessionError: Error, Sendable, Equatable {
    case wrongAgent
    case notFound
    case invalidCursor
}

public struct FxSessionOptions: Sendable, Codable, Equatable {
    public var model: FxModel?
    public var instructions: String?
    public var context: JSONValue?

    public init(model: FxModel? = nil, instructions: String? = nil, context: JSONValue? = nil) {
        self.model = model; self.instructions = instructions; self.context = context
    }
}

public struct FxSessionResult: Sendable, Codable, Equatable {
    public let id: String
    public let stopReason: FxTurnResult.StopReason
    public let usage: FxUsage?
    public let error: String?
    public let epoch: Int64
    public let isRepeated: Bool
}

public enum FxSessionEvent: Sendable, Codable, Equatable {
    case started(id: String, sessionID: String)
    case resumed(id: String, sessionID: String)
    case update(id: String, FxEvent)
    case ended(FxSessionResult)
}

public struct FxSessionEntry: Sendable, Codable, Equatable {
    public let cursor: Int64
    public let epoch: Int64
    public let event: FxSessionEvent
}

struct SessionInput: Sendable, Codable {
    let id: String
    let content: [FxPromptContent]
    let options: FxSessionOptions
    let wasStarted: Bool
    let cancelRequested: Bool
}

struct SessionLease: Sendable, Equatable {
    let sessionID: String
    let owner: String
    let epoch: Int64
}

struct SessionPersistence: FxCheckpointPersistence {
    let store: FxSessionStore
    let lease: SessionLease
    func load() async throws -> FxPersistenceSnapshot { try await store.loadJournal(lease) }
    func append(expected: String?, idempotencyKey: String, data: Data, barrier: Bool) async throws -> String {
        try await store.appendJournal(lease, expected: expected, key: idempotencyKey, data: data)
    }
    func saveCheckpoint(_ checkpoint: FxStoredCheckpoint) async throws { try await store.saveJournalCheckpoint(lease, checkpoint) }
}
