public struct FxRecoveryCall: Sendable, Equatable {
    public let executionID: String
    public let name: String
    public let input: JSONValue
    public init(executionID: String, name: String, input: JSONValue) {
        self.executionID = executionID; self.name = name; self.input = input
    }
}

public struct FxRecoveryState: Sendable, Equatable {
    public let turnID: String?
    public let runningCalls: [FxRecoveryCall]
    public init(turnID: String?, runningCalls: [FxRecoveryCall] = []) {
        self.turnID = turnID; self.runningCalls = runningCalls
    }
}
