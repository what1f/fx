import Foundation

/// Ownership expires unless the worker durably renews it before its deadline.
public struct FxSessionLeasePolicy: Sendable, Equatable {
    public let duration: Duration
    public let renewalInterval: Duration

    public init(duration: Duration, renewalInterval: Duration) throws {
        guard duration >= .milliseconds(1), renewalInterval > .zero, renewalInterval < duration,
              duration.components.seconds < Int64.max / 1_000_000 else {
            throw FxError.invalidInput("Lease duration and renewal interval are invalid")
        }
        self.duration = duration
        self.renewalInterval = renewalInterval
    }

    var milliseconds: Int64 {
        let parts = duration.components
        return parts.seconds * 1_000 + (parts.attoseconds + 999_999_999_999_999) / 1_000_000_000_000_000
    }
}

/// Optional timed ownership. Nil policy preserves a store's ordinary ownership mode.
///
/// Claim and renew must durably grant at least `duration` from a backend clock
/// sample taken during the atomic operation, after the client sends the request.
/// The TTL is not measured from response receipt or completion of disk syncing.
/// Renew and every lease-scoped mutation must atomically validate owner, epoch and
/// unexpired ownership. A renewal must never resurrect an expired lease.
/// Implementations must cooperate with cancellation; the SDK cannot stop host code.
public protocol FxRenewableSessionStorage: FxSessionStorage {
    var leasePolicy: FxSessionLeasePolicy? { get }
    func renew(_ lease: FxSessionLease) async throws
}
