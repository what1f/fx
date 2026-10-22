import Foundation
import LibFx

func encodeLifecycleEvent(_ event: FxLifecycleEvent) -> JSONValue {
    var fields: [String: JSONValue] = ["timestamp": .number((Date().timeIntervalSince1970 * 1000).rounded())]
    switch event {
    case .journalOpened(let state):
        fields.merge([
            "type": .string("journal.open"), "sessionId": .string(state.sessionID),
            "cursor": state.cursor.map(JSONValue.string) ?? .null, "lastSeq": .number(Double(state.lastSequence)),
            "resumable": .bool(state.resumable), "openTurnId": state.openTurnID.map(JSONValue.string) ?? .null,
            "lastTurnId": state.lastTurnID.map(JSONValue.string) ?? .null, "events": .number(Double(state.eventCount)),
            "checkpoint": .bool(state.hasCheckpoint), "turns": .number(Double(state.turnCount)),
        ]) { _, value in value }
    case .checkpointSaved(let sessionID, let cursor, let byteCount):
        fields["type"] = .string("checkpoint.save")
        fields["sessionId"] = .string(sessionID)
        fields["through"] = .string(cursor)
        fields["bytes"] = .number(Double(byteCount))
    case .checkpointFailed(let sessionID, let error):
        fields["type"] = .string("checkpoint.error")
        fields["sessionId"] = .string(sessionID)
        fields["error"] = .string(String(describing: type(of: error)))
        fields["message"] = .string(String(describing: error))
        fields["fenced"] = .bool((error as? FxPersistenceError) == .fenced)
    case .checkpointMismatch(let sessionID, let changed, let saved, let current):
        fields["type"] = .string("checkpoint.mismatch")
        fields["sessionId"] = .string(sessionID)
        fields["changed"] = .array(changed.map { .string($0.rawValue) })
        fields["saved"] = checkpointIdentity(saved)
        fields["current"] = checkpointIdentity(current)
    case .deliveryDeadline(let sessionID, let epoch, let cutoffs):
        fields["type"] = .string("session.deadline")
        fields["sessionId"] = .string(sessionID)
        fields["epoch"] = .number(Double(epoch))
        fields["cutoffs"] = .number(Double(cutoffs))
    }
    return .object(fields)
}

private func checkpointIdentity(_ value: FxCheckpointIdentity) -> JSONValue {
    var fields: [String: JSONValue] = [:]
    if let version = value.version { fields["libfxVersion"] = .string(version) }
    if let hash = value.toolSchemaHash { fields["toolSchemaHash"] = .string(hash) }
    if let model = value.modelID { fields["model"] = .string(model) }
    return .object(fields)
}
