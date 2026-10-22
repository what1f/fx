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
    case .sessionForwarded(let sessionID, let agent):
        fields["type"] = .string("session.forwarded")
        fields["sessionId"] = .string(sessionID)
        fields["agent"] = .string(agent)
    case .harnessFailed(let sessionID, let inputID, let error):
        fields["type"] = .string("session.error")
        fields["sessionId"] = .string(sessionID)
        fields["messageId"] = .string(inputID)
        fields["message"] = .string((error as? any LocalizedError)?.errorDescription ?? String(describing: error))
    case .deliveryDeadline(let sessionID, let epoch, let cutoffs):
        fields["type"] = .string("session.deadline")
        fields["sessionId"] = .string(sessionID)
        fields["epoch"] = .number(Double(epoch))
        fields["cutoffs"] = .number(Double(cutoffs))
    case .permissionRequested(let sessionID, let turnID, let toolID):
        fields["type"] = .string("permission.request")
        fields["sessionId"] = .string(sessionID); fields["turnId"] = .string(turnID); fields["toolCallId"] = .string(toolID)
    case .permissionResolved(let sessionID, let turnID, let toolID, let decision):
        fields["type"] = .string("permission.resolve")
        fields["sessionId"] = .string(sessionID); fields["turnId"] = .string(turnID); fields["toolCallId"] = .string(toolID)
        if case .select(let id) = decision { fields["optionId"] = .string(id) }
        else { fields["optionId"] = .null }
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
