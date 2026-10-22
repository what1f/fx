import Foundation

/// Storage used by durable agents. The host owns its connection and lifetime.
///
/// Each mutation must be atomic and durably acknowledged. Lease-scoped operations
/// must reject stale ownership with `FxPersistenceError.fenced`. A session belongs
/// to one agent; accessing it with another name must throw `FxSessionError.wrongAgent`.
/// Implementations must cooperate with task cancellation.
public protocol FxSessionStorage: Sendable {
    /// Accepts an input once in session order. Returns true for an existing ID.
    /// Prompt and steering IDs share a namespace. A retry must not modify stored input.
    func accept(session: String, agent: String, id: String, content: [FxPromptContent], options: FxSessionOptions,
                checkpoint: Data?, steering: Bool, deferringImageLimits: Bool) async throws -> Bool
    /// Atomically reads the pending input ID and the last published event cursor.
    func resumePoint(session: String, agent: String) async throws -> (id: String, cursor: Int64)?
    func hasWork(session: String, agent: String) async throws -> Bool
    /// Returns nil while another live worker owns the session.
    func claim(session: String, agent: String) async throws -> FxSessionLease?
    func release(_ lease: FxSessionLease) async throws
    func checkLease(_ lease: FxSessionLease) async throws
    func next(_ lease: FxSessionLease) async throws -> FxSessionInput?
    /// Stores the started or resumed event together with the input's started state.
    func start(_ lease: FxSessionLease, input: FxSessionInput) async throws
    func appendEvent(_ lease: FxSessionLease, _ event: FxSessionEvent) async throws
    /// Atomically stores the result, end event and disposition of joined steering.
    func finish(_ lease: FxSessionLease, id: String, result: FxSessionResult) async throws
    /// A nil ID targets only the currently started unfinished input, never queued prompts.
    func cancel(session: String, agent: String, id: String?) async throws
    func cancelled(_ lease: FxSessionLease, id: String) async throws -> Bool
    func result(session: String, agent: String, id: String) async throws -> FxSessionResult?
    /// Returns ordered entries strictly after cursor. Zero starts at the beginning.
    func entries(session: String, agent: String, after cursor: Int64) async throws -> [FxSessionEntry]
    func snapshot(session: String, agent: String) async throws -> FxPersistenceSnapshot
    func loadJournal(_ lease: FxSessionLease) async throws -> FxPersistenceSnapshot
    /// Enforces the expected head and idempotency key. Applies the ordered changes
    /// from `FxSessionJournalMark.decode(_:)` atomically with the record's bytes.
    func appendJournal(_ lease: FxSessionLease, expected: String?, key: String, data: Data, barrier: Bool) async throws -> String
    func saveJournalCheckpoint(_ lease: FxSessionLease, _ checkpoint: FxStoredCheckpoint) async throws
    func storeImage(_ data: Data, named name: String, lease: FxSessionLease) async throws
    func loadImage(named name: String, lease: FxSessionLease) async throws -> Data?
    func loadImage(named name: String, session: String, agent: String) async throws -> Data?
    func steering(_ lease: FxSessionLease, owner: String) async throws -> (pending: [FxSessionSteeringInput], ends: Bool)
    func publicInputID(_ coreID: String, session: String) async throws -> String?
    func deliveryCutoffs(_ lease: FxSessionLease, id: String) async throws -> Int
    func cutOffDelivery(_ lease: FxSessionLease, id: String) async throws -> Int
}

struct SessionStorageFailure: Error {
    let cause: any Error
}

// Keep a host storage failure distinct from a model failure without changing
// the error eventually received by session readers and close().
func sessionStorageOperation<Value: Sendable>(isolation: isolated (any Actor)? = #isolation,
                                              _ operation: () async throws -> Value) async throws -> Value {
    do { return try await operation() }
    catch let error as FxPersistenceError { throw error }
    catch let error as FxSQLiteError { throw error }
    catch let error as FxSessionError { throw error }
    catch let error as SessionStorageFailure { throw error }
    catch { throw SessionStorageFailure(cause: error) }
}
