import Foundation

public enum FxQueueDeliveryError: Error, Sendable, Equatable {
    case invalidSource
    case invalidReceipt
    case invalidContext
    case reusedContext
    case missingAuthority
    case unsupportedStorage
}

/// Metadata returned by your authenticated queue callback verifier, never by a request body.
public struct FxQueueReceipt: Sendable {
    public let messageID: String
    public let attempt: Int64

    public init(messageID: String, attempt: Int64) throws {
        guard !messageID.isEmpty, messageID.utf8.count <= 1024, !messageID.utf8.contains(0), attempt > 0 else {
            throw FxQueueDeliveryError.invalidReceipt
        }
        self.messageID = messageID
        self.attempt = attempt
    }
}

/// One authenticated callback invocation. Create it in the host's queue middleware.
/// It is deliberately not Codable. Retrying a message uses a new callback context;
/// retrying this object cannot manufacture another ownership grant.
public final class FxQueueDeliveryContext: Sendable {
    let id = UUID().uuidString
    let metadata: any Sendable
    private let lock = NSLock()
    private nonisolated(unsafe) var state = State.fresh
    private enum State { case fresh, active, finished }

    public init<Metadata: Sendable>(_ metadata: Metadata) { self.metadata = metadata }

    func begin() throws {
        try lock.withLock {
            guard state == .fresh else { throw FxQueueDeliveryError.reusedContext }
            state = .active
        }
    }

    func finish() { lock.withLock { state = .finished } }
    var isActive: Bool { lock.withLock { state == .active } }
}

/// Configure this verifier once on the agent. It must authenticate queue metadata,
/// bind it to the supplied wakeup, and reject obsolete callbacks. The queue's
/// source includes its account and tenant scope. Do not return metadata decoded
/// only from HTTP JSON. Allow equal-attempt replacement only when the provider
/// guarantees that such a callback replaces its previous execution.
public struct FxQueueDeliveryAuthority: Sendable {
    public let source: String
    public let allowsSameAttemptRedelivery: Bool
    private let verify: @Sendable (FxSessionWakeup, any Sendable) async throws -> FxQueueReceipt

    public init<Metadata: Sendable>(
        source: String, allowsSameAttemptRedelivery: Bool = false,
        verify: @escaping @Sendable (FxSessionWakeup, Metadata) async throws -> FxQueueReceipt
    ) throws {
        guard !source.isEmpty, source.utf8.count <= 256, !source.utf8.contains(0) else {
            throw FxQueueDeliveryError.invalidSource
        }
        self.source = source
        self.allowsSameAttemptRedelivery = allowsSameAttemptRedelivery
        self.verify = { wakeup, value in
            guard let metadata = value as? Metadata else { throw FxQueueDeliveryError.invalidContext }
            return try await verify(wakeup, metadata)
        }
    }

    func prepare(_ context: FxQueueDeliveryContext, for wakeup: FxSessionWakeup) async throws -> FxQueueClaim {
        try context.begin()
        do {
            try Task.checkCancellation()
            let receipt = try await verify(wakeup, context.metadata)
            try Task.checkCancellation()
            return FxQueueClaim(authority: self, receipt: receipt, wakeup: wakeup, context: context)
        } catch {
            context.finish()
            throw error
        }
    }
}

/// A verified claim passed by the SDK to queue-aware storage. Host storage can
/// inspect the grant but cannot decode or construct one from a wakeup body.
public struct FxQueueClaim: Sendable {
    public let source: String
    public let messageID: String
    public let attempt: Int64
    public let invocationID: String
    public let processID: String
    public let allowsSameAttempt: Bool
    public let wakeup: FxSessionWakeup
    private let context: FxQueueDeliveryContext

    fileprivate init(authority: FxQueueDeliveryAuthority, receipt: FxQueueReceipt,
                     wakeup: FxSessionWakeup, context: FxQueueDeliveryContext) {
        source = authority.source
        messageID = receipt.messageID
        attempt = receipt.attempt
        invocationID = context.id
        processID = QueueDeliveryProcess.id
        allowsSameAttempt = authority.allowsSameAttemptRedelivery
        self.wakeup = wakeup
        self.context = context
    }

    public var isActive: Bool { context.isActive }
    func finish() { context.finish() }
}

/// Optional storage capability for authenticated queue redelivery. Each claim
/// validates its binding and advances ownership atomically. Plain deliveries
/// retain ordinary lease rules. endExecution releases only the process-local
/// live-holder marker; it must not release another epoch or alter durable work.
public protocol FxQueueSessionStorage: FxRenewableSessionStorage {
    var queueSource: String? { get }
    func claim(session: String, agent: String, delivery: FxQueueClaim) async throws -> FxSessionLease?
    func endExecution(_ lease: FxSessionLease) async
}

// Live execution identity spans store connections, without a path registry.
// The database still makes every ownership and fencing decision transactionally.
enum QueueDeliveryProcess {
    static let id = UUID().uuidString
    private static let owners = LiveOwners()
    static func mark(owner: String) { owners.mark(owner) }
    static func unmark(owner: String) { owners.unmark(owner) }
    static func contains(owner: String) -> Bool { owners.contains(owner) }

    private final class LiveOwners: @unchecked Sendable {
        private let lock = NSLock()
        private var values: Set<String> = []
        func mark(_ owner: String) { _ = lock.withLock { values.insert(owner) } }
        func unmark(_ owner: String) { _ = lock.withLock { values.remove(owner) } }
        func contains(_ owner: String) -> Bool { lock.withLock { values.contains(owner) } }
    }
}
