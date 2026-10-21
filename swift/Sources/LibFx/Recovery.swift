public struct FxRecoveryCall: Sendable, Equatable {
    public let executionID: String
    public let name: String
    public let input: JSONValue
}

public struct FxRecoveryState: Sendable, Equatable {
    public let turnID: String?
    public let runningCalls: [FxRecoveryCall]
}
