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
    }

    public let version: Int
    public let kind: Kind
    public let sessionID: String
    public let rootSessionID: String
    public let parentSessionID: String?
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
}

public struct FxObservationOptions: Sendable {
    public var captureContent: Bool
    /// Called in event order. Keep this callback short; it runs before the next event is handled.
    public let onEvent: @Sendable (FxObservation) throws -> Void
    public let onError: @Sendable (any Error) -> Void

    public init(
        captureContent: Bool = false,
        onEvent: @escaping @Sendable (FxObservation) throws -> Void,
        onError: @escaping @Sendable (any Error) -> Void = { _ in }
    ) {
        self.captureContent = captureContent
        self.onEvent = onEvent
        self.onError = onError
    }

    func deliver(_ event: FxObservation) {
        do { try onEvent(event) } catch { onError(error) }
    }
}
