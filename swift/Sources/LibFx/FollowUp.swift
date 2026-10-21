import Foundation

/// A queued input. Acceptance and turn start are separate durability boundaries.
public struct FxFollowUp: Sendable, Identifiable {
    public let id: String
    let acceptance = AsyncResult<Void>()
    let started = AsyncResult<FxTurn>()

    public var accepted: Void { get async throws { try await acceptance.wait() } }
    public var turn: FxTurn { get async throws { try await started.wait() } }
}

struct QueuedFollowUp: Sendable {
    enum Acceptance: Sendable { case onStart, pending, stored }
    let receipt: FxFollowUp
    let text: String
    var acceptance: Acceptance
    let held: Bool
    var acceptedInCore: Bool { acceptance == .stored }
    var ready: Bool { acceptance != .pending }
}
