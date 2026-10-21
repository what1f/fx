import Foundation

/// A queued input. Acceptance and turn start are separate durability boundaries.
public struct FxFollowUp: Sendable, Identifiable {
    public let id: String
    let acceptance = FollowUpValue<Void>()
    let started = FollowUpValue<FxTurn>()

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

/// Cancelling one waiter does not remove the queued input or cancel other waiters.
actor FollowUpValue<Value: Sendable> {
    private var result: Result<Value, any Error>?
    private var waiters: [UUID: CheckedContinuation<Value, any Error>] = [:]

    func wait() async throws -> Value {
        try Task.checkCancellation()
        if let result { return try result.get() }
        let id = UUID()
        let value = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { waiters[id] = $0 }
        } onCancel: { Task { await self.cancel(id) } }
        try Task.checkCancellation()
        return value
    }

    func resolve(_ result: Result<Value, any Error>) {
        guard self.result == nil else { return }
        self.result = result
        for waiter in waiters.values { waiter.resume(with: result) }
        waiters.removeAll()
    }

    private func cancel(_ id: UUID) {
        waiters.removeValue(forKey: id)?.resume(throwing: CancellationError())
    }
}
