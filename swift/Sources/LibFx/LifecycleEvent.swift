/// Host-owned lifecycle notifications. These do not enable runtime hooks or content capture.
public enum FxLifecycleEvent: Sendable {
    case journalOpened(FxJournalRestoration)
    case checkpointSaved(sessionID: String, cursor: String, byteCount: Int)
    case checkpointFailed(sessionID: String, error: any Error)
    case checkpointMismatch(sessionID: String, fields: [FxCheckpointField], saved: FxCheckpointIdentity, current: FxCheckpointIdentity)
    case deliveryDeadline(sessionID: String, epoch: Int64, cutoffs: Int)
    case harnessFailed(sessionID: String, inputID: String, error: any Error)
    case permissionRequested(sessionID: String, turnID: String, toolID: String)
    case permissionResolved(sessionID: String, turnID: String, toolID: String, decision: FxPermissionDecision)
}

public struct FxJournalRestoration: Sendable, Equatable {
    public let sessionID: String
    public let cursor: String?
    public let lastSequence: UInt64
    public let resumable: Bool
    public let openTurnID: String?
    public let lastTurnID: String?
    public let eventCount: Int
    public let hasCheckpoint: Bool
    public let turnCount: Int
}

public enum FxCheckpointField: String, Sendable, Equatable {
    case version = "libfxVersion"
    case toolSchemaHash
    case model
}

public struct FxCheckpointIdentity: Sendable, Equatable {
    public let version: String?
    public let toolSchemaHash: String?
    public let modelID: String?

    init(_ value: JSONValue) {
        version = value["libfxVersion"]?.string
        toolSchemaHash = value["toolSchemaHash"]?.string
        modelID = value["model"]?.string
    }
}
