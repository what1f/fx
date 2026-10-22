import Foundation

/// A conversation executor. The agent owns scheduling, leases and persisted events.
public protocol FxSessionHarness: Sendable {
    var defersImageLimits: Bool { get }
    func validate(options: FxSessionOptions) throws
    func validate(input: [FxPromptContent], options: FxSessionOptions) throws
    /// Validates an exported checkpoint and returns the harness's stored snapshot format.
    func prepareCheckpoint(_ data: Data, options: FxSessionOptions) async throws -> Data
    func open(_ context: FxHarnessContext) async throws -> any FxHarnessSession
}

extension FxSessionHarness {
    public var defersImageLimits: Bool { false }
    public func validate(options: FxSessionOptions) throws {}
    public func validate(input: [FxPromptContent], options: FxSessionOptions) throws {
        _ = try PreparedPrompt(input, deferringImageLimits: defersImageLimits)
    }
}

public struct FxHarnessContext: Sendable {
    public let sessionID: String
    /// Nil when opening a read-only checkpoint view.
    public let inputID: String?
    public let options: FxSessionOptions
    public let persistence: any FxHarnessPersistence
    public let checkpointAfterBytes: Int?
    private let ownership: @Sendable () async throws -> Void

    init(sessionID: String, inputID: String?, options: FxSessionOptions,
         persistence: any FxHarnessPersistence, checkpointAfterBytes: Int?,
         ownership: @escaping @Sendable () async throws -> Void) {
        self.sessionID = sessionID; self.inputID = inputID; self.options = options
        self.persistence = persistence; self.checkpointAfterBytes = checkpointAfterBytes
        self.ownership = ownership
    }

    /// Check before starting an external effect, and after awaiting permission.
    public func checkOwnership() async throws { try await ownership() }
}

/// Commit routing and progress changes atomically with an opaque harness record.
public protocol FxHarnessPersistence: FxCheckpointPersistence, FxImagePersistence {
    func append(expected: String?, idempotencyKey: String, data: Data,
                marks: [FxSessionJournalMark], barrier: Bool) async throws -> String
}

public protocol FxHarnessSession: Sendable {
    var recoveryState: FxRecoveryState? { get async }
    var completedTurnID: String? { get async }
    func prompt(_ content: [FxPromptContent], id: String, yieldAt: Date?) async throws -> any FxHarnessTurn
    /// The harness chooses which interrupted effects are safe to rerun.
    func resume(rerunning: Bool, yieldAt: Date?) async throws -> (any FxHarnessTurn)?
    func saveCheckpoint() async throws
    func checkpoint() async throws -> Data
    /// Joins pending journal writes before returning. Recovery properties remain readable afterward.
    func close() async throws
}

public protocol FxHarnessTurn: Sendable {
    /// A single-consumer stream. Bound buffering for producers that can outpace storage.
    var events: AsyncThrowingStream<FxEvent, any Error> { get }
    var result: FxTurnResult { get async throws }
    func cancel() async
    /// Stop without storing a terminal result, so another delivery can resume.
    func handoff() async throws
    func steer(_ text: String, id: String) async throws -> FxSteeringReceipt
    func endForSteering() async throws
}

extension FxTurn: FxHarnessTurn {
    public func endForSteering() async throws { try await endForSteeringAction() }
}
