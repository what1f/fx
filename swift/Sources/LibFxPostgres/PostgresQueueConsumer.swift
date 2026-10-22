import Foundation
import LibFx

extension FxPostgresQueue {
    /// Consumes wakeups using the router's existing durable workers.
    ///
    /// Cancellation stops acquisition, then waits for active deliveries while
    /// renewing their visibility. It does not close the router or client. Supply
    /// a delivery policy to bound graceful shutdown; without one an active turn
    /// may keep this call alive until it finishes. Unknown agents remain queued.
    public func run(router: FxAgentRouter, concurrency: Int = 1,
                    pollInterval: Duration = .milliseconds(100), retryDelay: Duration = .seconds(1),
                    deliveryPolicy: FxDeliveryPolicy? = nil) async throws {
        guard concurrency > 0, pollInterval > .zero, retryDelay >= .zero else {
            throw FxError.invalidInput("Queue consumer configuration is invalid")
        }
        _ = try postgresQueueMilliseconds(retryDelay, allowingZero: true)
        try Task.checkCancellation()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<concurrency {
                group.addTask {
                    while !Task.isCancelled {
                        guard let delivery = try await receive() else {
                            try await Task.sleep(for: pollInterval)
                            continue
                        }
                        // Cancelling a deliver waiter does not stop the agent's
                        // worker. Keep both that waiter and visibility renewal
                        // alive independently until the real delivery settles.
                        let active = Task.detached {
                            try await consume(delivery, router: router, retryDelay: retryDelay,
                                              deliveryPolicy: deliveryPolicy)
                        }
                        try await active.value
                    }
                }
            }
            do {
                while let _ = try await group.next() {}
            } catch {
                group.cancelAll()
                // Structured joining drains the remaining workers; each joins
                // its independent active delivery before it can exit.
                throw error
            }
        }
        try Task.checkCancellation()
    }

    private func consume(_ delivery: FxPostgresQueueDelivery, router: FxAgentRouter,
                         retryDelay: Duration, deliveryPolicy: FxDeliveryPolicy?) async throws {
        let renewal = Task { () -> Result<Void, any Error> in
            do {
                while true {
                    try await Task.sleep(for: renewalInterval)
                    try Task.checkCancellation()
                    try await renew(delivery)
                }
            } catch is CancellationError {
                return .success(())
            } catch {
                return .failure(error)
            }
        }
        let outcome: Result<FxDeliveryOutcome, any Error>
        do { outcome = .success(try await router.deliver(delivery.wakeup, policy: deliveryPolicy)) }
        catch { outcome = .failure(error) }
        renewal.cancel()
        // Join renewal before acknowledging. A lost receipt cannot be confirmed
        // even when the agent finished successfully while renewal was failing.
        try await renewal.value.get()
        switch outcome {
        case .success(.complete): try await complete(delivery)
        case .success(.retry(let delay)): try await retry(delivery, after: delay)
        case .failure: try await retry(delivery, after: retryDelay)
        }
    }
}
