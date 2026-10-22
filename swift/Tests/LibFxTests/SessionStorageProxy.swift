import Foundation
import LibFx

final class SessionStorageTestFailure: Error {}

// Public imports only: the independent consumer compiles this same host implementation.
actor SessionStorageProxy: FxSessionStorage {
    let base: FxSessionStore
    private var failure: (String, SessionStorageTestFailure)?
    private(set) var calls: [String] = []
    init(_ base: FxSessionStore) { self.base = base }
    func failNext(_ operation: String, with error: SessionStorageTestFailure) { failure = (operation, error) }
    private func before(_ operation: String) throws {
        calls.append(operation)
        if let failure, failure.0 == operation {
            self.failure = nil
            throw failure.1
        }
    }
    func accept(session: String, agent: String, id: String, content: [FxPromptContent], options: FxSessionOptions, checkpoint: Data?, steering: Bool, deferringImageLimits: Bool) async throws -> Bool {
        try before("accept")
        return try await base.accept(session: session, agent: agent, id: id, content: content, options: options, checkpoint: checkpoint, steering: steering, deferringImageLimits: deferringImageLimits)
    }
    func resumePoint(session: String, agent: String) async throws -> (id: String, cursor: Int64)? {
        try before("resumePoint")
        return try await base.resumePoint(session: session, agent: agent)
    }
    func hasWork(session: String, agent: String) async throws -> Bool {
        try before("hasWork")
        return try await base.hasWork(session: session, agent: agent)
    }
    func claim(session: String, agent: String) async throws -> FxSessionLease? {
        try before("claim")
        return try await base.claim(session: session, agent: agent)
    }
    func release(_ lease: FxSessionLease) async throws {
        try before("release")
        return try await base.release(lease)
    }
    func checkLease(_ lease: FxSessionLease) async throws {
        try before("checkLease")
        return try await base.checkLease(lease)
    }
    func next(_ lease: FxSessionLease) async throws -> FxSessionInput? {
        try before("next")
        return try await base.next(lease)
    }
    func start(_ lease: FxSessionLease, input: FxSessionInput) async throws {
        try before("start")
        return try await base.start(lease, input: input)
    }
    func appendEvent(_ lease: FxSessionLease, _ event: FxSessionEvent) async throws {
        try before("appendEvent")
        return try await base.appendEvent(lease, event)
    }
    func finish(_ lease: FxSessionLease, id: String, result: FxSessionResult) async throws {
        try before("finish")
        return try await base.finish(lease, id: id, result: result)
    }
    func cancel(session: String, agent: String, id: String?) async throws {
        try before("cancel")
        return try await base.cancel(session: session, agent: agent, id: id)
    }
    func cancelled(_ lease: FxSessionLease, id: String) async throws -> Bool {
        try before("cancelled")
        return try await base.cancelled(lease, id: id)
    }
    func result(session: String, agent: String, id: String) async throws -> FxSessionResult? {
        try before("result")
        return try await base.result(session: session, agent: agent, id: id)
    }
    func entries(session: String, agent: String, after cursor: Int64) async throws -> [FxSessionEntry] {
        try before("entries")
        return try await base.entries(session: session, agent: agent, after: cursor)
    }
    func snapshot(session: String, agent: String) async throws -> FxPersistenceSnapshot {
        try before("snapshot")
        return try await base.snapshot(session: session, agent: agent)
    }
    func loadJournal(_ lease: FxSessionLease) async throws -> FxPersistenceSnapshot {
        try before("loadJournal")
        return try await base.loadJournal(lease)
    }
    func appendJournal(_ lease: FxSessionLease, expected: String?, key: String, data: Data, barrier: Bool, marks: [FxSessionJournalMark]?) async throws -> String {
        try before("appendJournal")
        return try await base.appendJournal(lease, expected: expected, key: key, data: data, barrier: barrier, marks: marks)
    }
    func saveJournalCheckpoint(_ lease: FxSessionLease, _ checkpoint: FxStoredCheckpoint) async throws {
        try before("saveJournalCheckpoint")
        return try await base.saveJournalCheckpoint(lease, checkpoint)
    }
    func storeImage(_ data: Data, named name: String, lease: FxSessionLease) async throws {
        try before("storeImage")
        return try await base.storeImage(data, named: name, lease: lease)
    }
    func loadImage(named name: String, lease: FxSessionLease) async throws -> Data? {
        try before("loadImage")
        return try await base.loadImage(named: name, lease: lease)
    }
    func loadImage(named name: String, session: String, agent: String) async throws -> Data? {
        try before("loadImage")
        return try await base.loadImage(named: name, session: session, agent: agent)
    }
    func steering(_ lease: FxSessionLease, owner: String) async throws -> (pending: [FxSessionSteeringInput], ends: Bool) {
        try before("steering")
        return try await base.steering(lease, owner: owner)
    }
    func publicInputID(_ coreID: String, session: String) async throws -> String? {
        try before("publicInputID")
        return try await base.publicInputID(coreID, session: session)
    }
    func deliveryCutoffs(_ lease: FxSessionLease, id: String) async throws -> Int {
        try before("deliveryCutoffs")
        return try await base.deliveryCutoffs(lease, id: id)
    }
    func cutOffDelivery(_ lease: FxSessionLease, id: String) async throws -> Int {
        try before("cutOffDelivery")
        return try await base.cutOffDelivery(lease, id: id)
    }
}
