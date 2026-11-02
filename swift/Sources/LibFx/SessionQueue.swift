import Foundation

/// Routes a wakeup to an agent using the same session store. Contains no prompt or credentials.
public struct FxSessionWakeup: Sendable, Codable, Equatable {
    public let agent: String
    public let sessionID: String
    /// The accepted input that caused publication. Nil is for manual session deliveries.
    public let inputID: String?

    public init(agent: String, sessionID: String, inputID: String? = nil) {
        self.agent = agent; self.sessionID = sessionID; self.inputID = inputID
    }
}

/// The host owns publishing, delivery retries and acknowledgement.
public protocol FxSessionQueue: Sendable {
    /// Returns after the queue accepts the wakeup, without waiting for execution.
    /// Delivery may occur more than once. Retry messages until `deliver` returns complete.
    func enqueue(_ wakeup: FxSessionWakeup) async throws
}

public enum FxDeliveryOutcome: Sendable, Equatable {
    /// The queue may acknowledge this message.
    case complete
    /// Keep the message and deliver it again after this delay.
    case retry(after: Duration)
}
