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
    /// Configuration supplied to a custom durable harness for this input.
    public var settings: JSONValue?

    public init(model: FxModel? = nil, instructions: String? = nil, context: JSONValue? = nil, settings: JSONValue? = nil) {
        self.model = model; self.instructions = instructions; self.context = context
        self.settings = settings
    }
}

public struct FxSessionResult: Sendable, Codable, Equatable {
    public let id: String
    public let stopReason: FxTurnResult.StopReason
    public let usage: FxUsage?
    public let failure: FxSessionFailure?
    public var error: String? { failure?.message }

    private enum CodingKeys: String, CodingKey {
        case id, stopReason, usage, epoch, isRepeated
        case failure = "error"
    }
    public let epoch: Int64
    public let isRepeated: Bool

    public init(id: String, stopReason: FxTurnResult.StopReason, usage: FxUsage? = nil, error: String? = nil,
                epoch: Int64, isRepeated: Bool = false) {
        self.id = id; self.stopReason = stopReason; self.usage = usage; self.failure = error.map { FxSessionFailure(message: $0) }
        self.epoch = epoch; self.isRepeated = isRepeated
    }

    public init(id: String, stopReason: FxTurnResult.StopReason, usage: FxUsage? = nil, failure: FxSessionFailure?,
                epoch: Int64, isRepeated: Bool = false) {
        self.id = id; self.stopReason = stopReason; self.usage = usage; self.failure = failure
        self.epoch = epoch; self.isRepeated = isRepeated
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        stopReason = try values.decode(FxTurnResult.StopReason.self, forKey: .stopReason)
        usage = try values.decodeIfPresent(FxUsage.self, forKey: .usage)
        epoch = try values.decode(Int64.self, forKey: .epoch)
        isRepeated = try values.decode(Bool.self, forKey: .isRepeated)
        // Native databases previously stored only the failure message.
        if let message = try? values.decode(String.self, forKey: .failure) {
            failure = FxSessionFailure(message: message)
        } else {
            failure = try values.decodeIfPresent(FxSessionFailure.self, forKey: .failure)
        }
    }
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
    public init(cursor: Int64, epoch: Int64, event: FxSessionEvent) {
        self.cursor = cursor; self.epoch = epoch; self.event = event
    }
}

public struct FxSessionInput: Sendable, Codable {
    public let id: String
    public let content: [FxPromptContent]
    public let options: FxSessionOptions
    public let wasStarted: Bool
    public let cancelRequested: Bool
    /// Stable identity used by journal placement marks for a public input ID.
    public static func runtimeID(for id: String) -> String { sessionCoreInputID(id) }
    public init(id: String, content: [FxPromptContent], options: FxSessionOptions, wasStarted: Bool, cancelRequested: Bool) {
        self.id = id; self.content = content; self.options = options
        self.wasStarted = wasStarted; self.cancelRequested = cancelRequested
    }
}

public struct FxSessionLease: Sendable, Equatable, Codable {
    public let sessionID: String
    public let owner: String
    public let epoch: Int64
    public init(sessionID: String, owner: String, epoch: Int64) {
        self.sessionID = sessionID; self.owner = owner; self.epoch = epoch
    }
}

struct SessionPersistence: FxHarnessPersistence {
    let store: any FxSessionStorage
    let lease: FxSessionLease
    func load() async throws -> FxPersistenceSnapshot { try await sessionStorageOperation { try await store.loadJournal(lease) } }
    func append(expected: String?, idempotencyKey: String, data: Data, barrier: Bool) async throws -> String {
        try await sessionStorageOperation { try await store.appendJournal(lease, expected: expected, key: idempotencyKey, data: data, barrier: barrier, marks: nil) }
    }
    func append(expected: String?, idempotencyKey: String, data: Data, marks: [FxSessionJournalMark], barrier: Bool) async throws -> String {
        try await sessionStorageOperation { try await store.appendJournal(lease, expected: expected, key: idempotencyKey, data: data, barrier: barrier, marks: marks) }
    }
    func saveCheckpoint(_ checkpoint: FxStoredCheckpoint) async throws { try await sessionStorageOperation { try await store.saveJournalCheckpoint(lease, checkpoint) } }
    func storeImage(_ data: Data, named name: String) async throws { try await sessionStorageOperation { try await store.storeImage(data, named: name, lease: lease) } }
    func loadImage(named name: String) async throws -> Data? {
        try await sessionStorageOperation { try await store.loadImage(named: name, lease: lease) }
    }
}

struct ReadOnlySessionPersistence: FxHarnessPersistence {
    let snapshot: FxPersistenceSnapshot
    let store: any FxSessionStorage
    let session: String
    let agent: String
    func load() async throws -> FxPersistenceSnapshot { snapshot }
    func append(expected: String?, idempotencyKey: String, data: Data, barrier: Bool) async throws -> String {
        throw FxPersistenceError.fenced
    }
    func append(expected: String?, idempotencyKey: String, data: Data, marks: [FxSessionJournalMark], barrier: Bool) async throws -> String {
        throw FxPersistenceError.fenced
    }
    func saveCheckpoint(_ checkpoint: FxStoredCheckpoint) async throws { throw FxPersistenceError.fenced }
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
