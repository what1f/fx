import Foundation
import CryptoKit

func sessionCoreInputID(_ id: String) -> String {
    "turn_" + SHA256.hash(data: Data(id.utf8)).map { String(format: "%02x", $0) }.joined()
}

func validSessionIdentifier(_ value: String) -> Bool {
    !value.isEmpty && value.utf8.count <= 255 && value.utf8.allSatisfy {
        (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || [45, 46, 95].contains($0)
    }
}

public enum FxSessionError: Error, Sendable, Equatable {
    case wrongAgent
    case notFound
    case invalidCursor
    case messageIDInUse
    case preparationTimedOut
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
    case started(id: String, sessionID: String, input: [FxPromptContent])
    case resumed(id: String, sessionID: String)
    case yielded(id: String)
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

struct SessionPersistence: FxCheckpointPersistence, FxImagePersistence {
    let store: FxSessionStore
    let lease: SessionLease
    func load() async throws -> FxPersistenceSnapshot { try await store.loadJournal(lease) }
    func append(expected: String?, idempotencyKey: String, data: Data, barrier: Bool) async throws -> String {
        try await store.appendJournal(lease, expected: expected, key: idempotencyKey, data: data)
    }
    func saveCheckpoint(_ checkpoint: FxStoredCheckpoint) async throws { try await store.saveJournalCheckpoint(lease, checkpoint) }
    func storeImage(_ data: Data, named name: String) async throws { try await store.storeImage(data, named: name, lease: lease) }
    func loadImage(named name: String) async throws -> Data? {
        try await store.loadImage(named: name, lease: lease)
    }
}

struct ReadOnlySessionPersistence: FxImagePersistence {
    let snapshot: FxPersistenceSnapshot
    let store: FxSessionStore
    let session: String
    let agent: String
    func load() async throws -> FxPersistenceSnapshot { snapshot }
    func append(expected: String?, idempotencyKey: String, data: Data, barrier: Bool) async throws -> String {
        throw FxPersistenceError.fenced
    }
    func storeImage(_ data: Data, named name: String) async throws { throw FxPersistenceError.fenced }
    func loadImage(named name: String) async throws -> Data? {
        try await store.loadImage(named: name, session: session, agent: agent)
    }
}

func sessionSeed(_ checkpoint: Data) -> Data {
    // FXSN v1 wraps an exported checkpoint with the covered sequence,
    // next turn number, and the absence of an open turn.
    var bytes = Data("FXSN".utf8)
    bytes.append(1)
    for value: UInt64 in [1, 1] {
        var littleEndian = value.littleEndian
        withUnsafeBytes(of: &littleEndian) { bytes.append(contentsOf: $0) }
    }
    bytes.append(0)
    bytes.append(checkpoint)
    return bytes
}
