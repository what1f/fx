import Foundation

/// A single result with independently cancellable waiters.
actor AsyncResult<Value: Sendable> {
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
