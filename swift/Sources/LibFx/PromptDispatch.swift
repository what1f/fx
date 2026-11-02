/// Separates local turn creation from acceptance of its prompt frame by the transport.
actor PromptDispatch {
    private var result: Bool?
    private var waiters: [CheckedContinuation<Bool, Never>] = []
    private let cancellableResult = AsyncResult<Bool>()

    func currentResult() -> Bool? { result }

    func wait() async -> Bool {
        if let result { return result }
        return await withCheckedContinuation { waiters.append($0) }
    }

    func waitUnlessCancelled() async throws -> Bool {
        try await cancellableResult.wait()
    }

    func resolve(sent: Bool) async {
        guard result == nil else { return }
        result = sent
        for waiter in waiters { waiter.resume(returning: sent) }
        waiters.removeAll()
        await cancellableResult.resolve(.success(sent))
    }
}
