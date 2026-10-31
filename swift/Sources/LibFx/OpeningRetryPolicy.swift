import Foundation

/// Retries host storage failures encountered while opening a durable session.
/// The host classifies transient errors. Missing images, invalid journals,
/// ownership failures and failures after opening never enter this policy.
/// Exhaustion propagates the final host error unchanged. Retry counts reset
/// after a successfully executed input; an agent has no retry policy by default.
public struct FxOpeningRetryPolicy: Sendable {
    public let maxRetries: UInt
    public let delay: Duration
    public let shouldRetry: @Sendable (any Error) -> Bool

    public init(maxRetries: UInt = 1, delay: Duration = .milliseconds(100),
                shouldRetry: @escaping @Sendable (any Error) -> Bool) throws {
        guard delay >= .zero else { throw FxError.invalidInput("Retry delay must not be negative") }
        self.maxRetries = maxRetries
        self.delay = delay
        self.shouldRetry = shouldRetry
    }
}
