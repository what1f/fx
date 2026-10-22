/// Separates local turn creation from acceptance of its prompt frame by the transport.
actor PromptDispatch {
    private var result: Bool?
    private var waiters: [CheckedContinuation<Bool, Never>] = []

    func currentResult() -> Bool? { result }

    func wait() async -> Bool {
        if let result { return result }
        return await withCheckedContinuation { waiters.append($0) }
    }

    func resolve(sent: Bool) {
        guard result == nil else { return }
        result = sent
        for waiter in waiters { waiter.resume(returning: sent) }
        waiters.removeAll()
    }
}
