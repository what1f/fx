import Foundation
import Testing
@testable import LibFx

private actor OpaqueSubmissions {
    private(set) var count = 0
    func record() { count += 1 }
}

private struct OpaqueCompletionHarness: FxDurableHarness {
    typealias Input = String
    typealias Update = String
    let submissions: OpaqueSubmissions
    func prepareCheckpoint(_ data: Data, options: FxSessionOptions) async throws -> Data { data }
    func open(_ context: FxHarnessContext) async throws -> any FxDurableHarnessSession<String, String> {
        OpaqueCompletionSession(context: context, snapshot: try await context.persistence.load(), submissions: submissions)
    }
}

private actor OpaqueCompletionSession: FxDurableHarnessSession {
    typealias Input = String
    typealias Update = String
    let context: FxHarnessContext
    let snapshot: FxPersistenceSnapshot
    let submissions: OpaqueSubmissions
    var completedTurnID: String?
    var recoveryState: FxRecoveryState? { nil }
    init(context: FxHarnessContext, snapshot: FxPersistenceSnapshot, submissions: OpaqueSubmissions) {
        self.context = context; self.snapshot = snapshot; self.submissions = submissions
        completedTurnID = snapshot.completedTurnID
    }
    func submit(_ input: String, id: String, yieldAt: Date?) async throws -> any FxDurableHarnessTurn<String> {
        await submissions.record()
        // No reader, including the fresh harness, interprets these opaque bytes.
        _ = try await context.persistence.append(expected: snapshot.head, idempotencyKey: id,
            data: Data([0xff, 0, 0x81]), marks: [.placed(id), .completed(id)], barrier: true)
        completedTurnID = id
        return OpaqueCompletedTurn()
    }
    func resume(rerunning: Bool, yieldAt: Date?) async throws -> (any FxDurableHarnessTurn<String>)? { nil }
    func saveCheckpoint() async throws {}
    func checkpoint() async throws -> Data { Data() }
    func close() async throws {}
}

private struct OpaqueCompletedTurn: FxDurableHarnessTurn {
    typealias Update = String
    var events: AsyncThrowingStream<String, any Error> { AsyncThrowingStream { $0.finish() } }
    var result: FxTurnResult { get async throws { FxTurnResult(stopReason: .endTurn) } }
    func cancel() async {}
    func handoff() async throws {}
    func endForSteering() async throws {}
}

@Suite(.serialized, .timeLimit(.minutes(1))) struct OpaqueCompletionTests {
    private func location() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("sessions.sqlite")
    }

    @Test func completionSurvivesReopeningAndCheckpointCompaction() async throws {
        let url = location()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = try FxSessionStore(url: url)
        _ = try await store.accept(session: "opaque", agent: "default", id: "one", content: [.text("one")], options: .init())
        let lease = try #require(try await store.claim(session: "opaque", agent: "default"))
        let id = FxSessionInput.runtimeID(for: "one")
        let cursor = try await store.appendJournal(lease, expected: nil, key: "terminal", data: Data([0xff, 0, 0x81]), marks: [.completed(id)])
        #expect(try await store.loadJournal(lease).completedTurnID == id)
        try await store.saveJournalCheckpoint(lease, .init(through: cursor, data: Data([0xfe, 0x80])))
        #expect(try await store.loadJournal(lease).journal.isEmpty)
        try await store.release(lease)
        try await store.close()
        let reopened = try FxSessionStore(url: url)
        let snapshot = try await reopened.snapshot(session: "opaque", agent: "default")
        #expect(snapshot.completedTurnID == id)
        #expect(snapshot.checkpoint?.data == Data([0xfe, 0x80]))
        #expect(snapshot.journal.isEmpty)
        try await reopened.close()
    }

    @Test func completionIsAtomicAndFencedWithItsRecord() async throws {
        let store = try FxSessionStore()
        _ = try await store.accept(session: "opaque", agent: "default", id: "one", content: [.text("one")], options: .init())
        let lease = try #require(try await store.claim(session: "opaque", agent: "default"))
        let first = FxSessionInput.runtimeID(for: "one"), second = FxSessionInput.runtimeID(for: "two")
        let bytes = Data([0xff, 0x81])
        await #expect(throws: FxPersistenceError.invalidJournal) {
            try await store.appendJournal(lease, expected: nil, key: "invalid", data: bytes, marks: [.completed("invalid id")])
        }
        #expect(try await store.loadJournal(lease).head == nil)
        #expect(try await store.loadJournal(lease).completedTurnID == nil)
        let cursor = try await store.appendJournal(lease, expected: nil, key: "first", data: bytes, marks: [.completed(first)])
        #expect(try await store.appendJournal(lease, expected: nil, key: "first", data: bytes, marks: [.completed(first)]) == cursor)
        await #expect(throws: FxPersistenceError.fenced) {
            try await store.appendJournal(lease, expected: nil, key: "first", data: bytes, marks: [.completed(second)])
        }
        await #expect(throws: FxPersistenceError.fenced) {
            try await store.appendJournal(lease, expected: nil, key: "stale", data: bytes, marks: [.completed(second)])
        }
        #expect(try await store.loadJournal(lease).completedTurnID == first)
        let next = try await store.appendJournal(lease, expected: cursor, key: "second", data: bytes, marks: [.completed(second)])
        #expect(try await store.loadJournal(lease).completedTurnID == second)
        #expect(try await store.loadJournal(lease).head == next)
        // A redelivery of an earlier successful write must not roll completion back.
        #expect(try await store.appendJournal(lease, expected: nil, key: "first", data: bytes, marks: [.completed(first)]) == cursor)
        #expect(try await store.loadJournal(lease).completedTurnID == second)
        try await store.release(lease)
        await #expect(throws: FxPersistenceError.fenced) {
            try await store.appendJournal(lease, expected: next, key: "released", data: bytes, marks: [.completed(first)])
        }
        try await store.close()
    }

    @Test func settledJournalDoesNotRepeatWhenPublicResultWriteFailed() async throws {
        let url = location()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let database = try FxSessionStore(url: url), store = SessionStorageProxy(database)
        let submissions = OpaqueSubmissions(), failure = SessionStorageTestFailure()
        await store.failNext("finish", with: failure)
        let first = try FxDurableAgent(harness: OpaqueCompletionHarness(submissions: submissions), store: store)
        let view = try await first.session(id: "opaque")
        let turn = try await view.submit("execute once", id: "one")
        do { _ = try await turn.result; Issue.record("The host storage error was swallowed") }
        catch { #expect((error as? SessionStorageTestFailure) === failure) }
        do { try await first.close(); Issue.record("Close lost the storage failure") }
        catch { #expect((error as? SessionStorageTestFailure) === failure) }
        #expect(try await database.result(session: "opaque", agent: "default", id: "one") == nil)
        try await database.close()
        let reopened = try FxSessionStore(url: url)
        let second = try FxDurableAgent(harness: OpaqueCompletionHarness(submissions: submissions), store: reopened)
        let resumedView = try await second.session(id: "opaque")
        let resumed = try #require(try await resumedView.resume())
        #expect(try await resumed.result.stopReason == .unknown)
        #expect(await submissions.count == 1)
        #expect(try await resumedView.submit("next", id: "two").result.stopReason == .endTurn)
        #expect(await submissions.count == 2)
        try await second.close(); try await reopened.close()
    }
}
