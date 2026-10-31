import Foundation
import LibFx

final class SessionStorageTestFailure: Error {}

// Public imports only: the independent consumer compiles this same host implementation.
actor SessionStorageProxy: FxSessionStorage {
    nonisolated var agentAdmission: FxAgentAdmission { base.agentAdmission }
    let base: FxSessionStore
    private var failure: (String, any Error, remaining: Int, count: Int)?
    private(set) var calls: [String] = []
    private let beforeJournalAppend: (@Sendable (Data, Bool) async throws -> Void)?
    let beforeLeaseRenewal: (@Sendable () async throws -> Void)?
    private let afterClaim: (@Sendable (FxSessionLease?) async throws -> Void)?
    private let afterLeaseCheck: (@Sendable (FxSessionLease) async throws -> Void)?
    private let beforeCancellationRead: (@Sendable () async throws -> Void)?
    private let beforeWorkRead: (@Sendable () async throws -> Void)?
    private let afterWorkRead: (@Sendable (Bool) async throws -> Void)?
    init(_ base: FxSessionStore, beforeJournalAppend: (@Sendable (Data, Bool) async throws -> Void)? = nil,
         beforeLeaseRenewal: (@Sendable () async throws -> Void)? = nil,
         afterClaim: (@Sendable (FxSessionLease?) async throws -> Void)? = nil,
         afterLeaseCheck: (@Sendable (FxSessionLease) async throws -> Void)? = nil,
         beforeCancellationRead: (@Sendable () async throws -> Void)? = nil,
         beforeWorkRead: (@Sendable () async throws -> Void)? = nil,
         afterWorkRead: (@Sendable (Bool) async throws -> Void)? = nil) {
        self.base = base; self.beforeJournalAppend = beforeJournalAppend
        self.beforeLeaseRenewal = beforeLeaseRenewal
        self.afterClaim = afterClaim; self.afterLeaseCheck = afterLeaseCheck
        self.beforeCancellationRead = beforeCancellationRead
        self.beforeWorkRead = beforeWorkRead; self.afterWorkRead = afterWorkRead
    }
    func failNext(_ operation: String, with error: any Error, after successfulCalls: Int = 0, count: Int = 1) {
        failure = (operation, error, successfulCalls, count)
    }
    private func before(_ operation: String) throws {
        calls.append(operation)
        if let failure, failure.0 == operation {
            if failure.remaining > 0 {
                self.failure?.remaining -= 1
                return
            }
            if failure.count > 1 { self.failure?.count -= 1 } else { self.failure = nil }
            throw failure.1
        }
    }
    func owner(session: String) async throws -> String? {
        try before("owner")
        return try await base.owner(session: session)
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
        try await beforeWorkRead?()
        let result = try await base.hasWork(session: session, agent: agent)
        try await afterWorkRead?(result)
        return result
    }
    func claim(session: String, agent: String) async throws -> FxSessionLease? {
        try before("claim")
        let lease = try await base.claim(session: session, agent: agent)
        try await afterClaim?(lease)
        return lease
    }
    func release(_ lease: FxSessionLease) async throws {
        try before("release")
        return try await base.release(lease)
    }
    func checkLease(_ lease: FxSessionLease) async throws {
        try before("checkLease")
        try await base.checkLease(lease)
        try await afterLeaseCheck?(lease)
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
        try await beforeCancellationRead?()
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
        try await beforeJournalAppend?(data, barrier)
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
    func harnessFailureState(_ lease: FxSessionLease, id: String) async throws -> FxHarnessFailureState {
        try before("harnessFailureState")
        return try await base.harnessFailureState(lease, id: id)
    }
    func recordHarnessStop(_ lease: FxSessionLease, id: String) async throws -> Int {
        try before("recordHarnessStop")
        return try await base.recordHarnessStop(lease, id: id)
    }
    func halt(_ lease: FxSessionLease) async throws {
        try before("halt")
        try await base.halt(lease)
    }
    func input(_ lease: FxSessionLease, id: String) async throws -> FxSessionInput? {
        try before("input")
        return try await base.input(lease, id: id)
    }

    func harnessRecoveryInput(_ lease: FxSessionLease) async throws -> FxSessionInput? {
        try before("harnessRecoveryInput")
        return try await base.harnessRecoveryInput(lease)
    }
    func setHarnessRecoveryInput(_ lease: FxSessionLease, id: String?) async throws {
        try before("setHarnessRecoveryInput")
        try await base.setHarnessRecoveryInput(lease, id: id)
    }

}
