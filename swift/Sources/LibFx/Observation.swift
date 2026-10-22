import Foundation

/// A semantic runtime event. Content is omitted unless captureContent is enabled.
public struct FxObservation: Sendable, Codable, Equatable {
    public enum Kind: String, Sendable, Codable {
        case turnStarted = "turn.start", turnEnded = "turn.end"
        case stepStarted = "step.start", stepEnded = "step.end"
        case modelStarted = "model.start", modelAdmitted = "model.admitted"
        case modelOutputStarted = "model.output_start", modelEnded = "model.end"
        case toolStarted = "tool.start", toolEnded = "tool.end", toolResult = "tool.result"
        case permissionStarted = "permission.start", permissionEnded = "permission.end"
        case waitStarted = "wait.start", waitEnded = "wait.end"
        case mcpStarted = "mcp.start", mcpRequest = "mcp.request", mcpEnded = "mcp.end"
        case delegation
        case journalCommitted = "journal.commit", journalRestored = "journal.restore", journalError = "journal.error"
        case checkpointSaved = "checkpoint.save", checkpointError = "checkpoint.error"
        case checkpointMismatch = "checkpoint.mismatch"
        case sessionDeadline = "session.deadline"
    }

    public let version: Int
    public let kind: Kind
    public let sessionID: String
    public let rootSessionID: String
    public let parentSessionID: String?
    public let parentTurnID: String?
    public let parentCallID: String?
    public let sourceSessionID: String?
    public let workID: String?
    public let turnID: String?
    public let executionID: String?
    public let stepIndex: Int
    public let timestamp: Date
    public let contentCaptured: Bool
    public let contentTruncated: Bool
    public let data: JSONValue

    private enum CodingKeys: String, CodingKey {
        case version, kind = "type", sessionID = "sessionId", rootSessionID = "rootSessionId"
        case parentTurnID = "parentTurnId", parentCallID = "parentCallId"
        case parentSessionID = "parentSessionId", sourceSessionID = "sourceSessionId", workID = "workId"
        case turnID = "turnId", executionID = "executionId", stepIndex, timestamp
        case contentCaptured, contentTruncated, data
    }

    init(raw: JSONValue) throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        self = try decoder.decode(Self.self, from: JSONEncoder().encode(raw))
        guard version == 1 else { throw FxError.protocolViolation("Unsupported observation version") }
    }

    init(journal kind: Kind, sessionID: String, data: JSONValue) {
        self.version = 1
        self.kind = kind
        self.sessionID = sessionID
        self.rootSessionID = sessionID
        self.parentSessionID = nil
        self.parentTurnID = nil
        self.parentCallID = nil
        self.sourceSessionID = nil
        self.workID = nil
        self.turnID = nil
        self.executionID = nil
        self.stepIndex = 0
        self.timestamp = Date()
        self.contentCaptured = false
        self.contentTruncated = false
        self.data = data
    }

    init(scope: Self, kind: Kind? = nil, data: JSONValue? = nil, parent: FxObservationParent? = nil,
         timestamp: Date? = nil, captureContent: Bool? = nil) {
        version = scope.version
        self.kind = kind ?? scope.kind
        sessionID = scope.sessionID
        rootSessionID = parent?.rootSessionID ?? scope.rootSessionID
        let isRoot = scope.sessionID == scope.rootSessionID && scope.parentSessionID == nil
        parentSessionID = isRoot ? parent?.sessionID ?? scope.parentSessionID : scope.parentSessionID
        parentTurnID = isRoot ? parent?.turnID ?? scope.parentTurnID : scope.parentTurnID
        parentCallID = isRoot ? parent?.callID ?? scope.parentCallID : scope.parentCallID
        sourceSessionID = scope.sourceSessionID
        workID = scope.workID
        turnID = scope.turnID
        executionID = scope.executionID
        stepIndex = scope.stepIndex
        self.timestamp = timestamp ?? scope.timestamp
        contentCaptured = captureContent ?? scope.contentCaptured
        contentTruncated = kind == nil ? scope.contentTruncated : false
        self.data = data ?? scope.data
    }
}

/// The owning tool call for observations from a child engine.
public struct FxObservationParent: Sendable, Equatable {
    public let rootSessionID: String
    public let sessionID: String
    public let turnID: String
    public let callID: String

    public init(rootSessionID: String, sessionID: String, turnID: String, callID: String) throws {
        guard [rootSessionID, sessionID, turnID, callID].allSatisfy({ !$0.isEmpty && $0.utf8.count <= 1024 }) else {
            throw FxError.invalidInput("Observation identities must contain 1–1024 UTF-8 bytes")
        }
        self.rootSessionID = rootSessionID
        self.sessionID = sessionID
        self.turnID = turnID
        self.callID = callID
    }
}

public struct FxObservationOptions: Sendable {
    public var captureContent: Bool
    public var parent: FxObservationParent?
    /// Called synchronously. Concurrent tools may deliver events from different tasks.
    /// Keep this callback short. Events within each operation retain their order.
    public let onEvent: @Sendable (FxObservation) throws -> Void
    public let onError: @Sendable (any Error) -> Void

    public init(
        captureContent: Bool = false,
        parent: FxObservationParent? = nil,
        onEvent: @escaping @Sendable (FxObservation) throws -> Void,
        onError: @escaping @Sendable (any Error) -> Void = { _ in }
    ) {
        self.captureContent = captureContent
        self.parent = parent
        self.onEvent = onEvent
        self.onError = onError
    }

    func project(_ event: FxObservation) -> FxObservation {
        guard let parent else { return event }
        return FxObservation(scope: event, parent: parent)
    }

    func deliver(_ event: FxObservation) {
        do { try onEvent(project(event)) } catch { onError(error) }
    }
}
