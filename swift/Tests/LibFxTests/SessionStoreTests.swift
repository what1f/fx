import Foundation
import Testing
import CSQLite
@testable import LibFx

@Suite struct SessionStoreTests {
    @Test func intakeIsDurableOrderedAndDeduplicated() async throws {
        let url = location()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = try FxSessionStore(url: url)
        let options = FxSessionOptions(model: FxModel("model"), instructions: "你好", context: .object(["value": .number(2)]))
        #expect(try await store.accept(session: "session", agent: "agent", id: "first", content: [.text("一")], options: options) == false)
        #expect(try await store.accept(session: "session", agent: "agent", id: "first", content: [.text("ignored")], options: .init()) == true)
        _ = try await store.accept(session: "session", agent: "agent", id: "second", content: [.text("二")], options: .init())
        try await store.close()
        let reopened = try FxSessionStore(url: url)
        let lease = try #require(try await reopened.claim(session: "session", agent: "agent"))
        let input = try #require(try await reopened.next(lease))
        #expect(input.id == "first" && input.content == [.text("一")] && input.options == options)
        try await reopened.start(lease, input: input)
        try await reopened.appendEvent(lease, .update(id: input.id, .text("回复")))
        let result = completed(input.id, lease)
        try await reopened.finish(lease, id: input.id, result: result)
        try await reopened.finish(lease, id: input.id, result: result)
        #expect(try await reopened.result(session: "session", agent: "agent", id: input.id) == result)
        let entries = try await reopened.entries(session: "session", agent: "agent", after: 0)
        #expect(entries.map(\.event) == [.started(id: "first", sessionID: "session"), .update(id: "first", .text("回复")), .ended(result)])
        #expect(try await reopened.entries(session: "session", agent: "agent", after: entries[0].cursor).count == 2)
        #expect(try await reopened.next(lease)?.id == "second")
        try await reopened.release(lease)
        try await reopened.close()
    }

    @Test func competingConnectionsAndStaleOwnersAreFenced() async throws {
        let url = location()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let first = try FxSessionStore(url: url), second = try FxSessionStore(url: url)
        _ = try await first.accept(session: "s", agent: "a", id: "m", content: [.text("hello")], options: .init())
        let old = try #require(try await first.claim(session: "s", agent: "a"))
        #expect(try await second.claim(session: "s", agent: "a") == nil)
        await #expect(throws: FxError.busy) { try await first.close() }
        _ = try await first.appendJournal(old, expected: nil, key: "k", data: Data([1]))
        try await first.release(old)
        let current = try #require(try await second.claim(session: "s", agent: "a"))
        #expect(current.epoch == old.epoch + 1)
        await #expect(throws: FxPersistenceError.fenced) { try await first.appendJournal(old, expected: nil, key: "k", data: Data([1])) }
        await #expect(throws: FxPersistenceError.fenced) { try await first.appendEvent(old, .update(id: "m", .text("stale"))) }
        await #expect(throws: FxPersistenceError.fenced) { try await first.finish(old, id: "m", result: completed("m", old)) }
        await #expect(throws: FxPersistenceError.fenced) { try await first.saveJournalCheckpoint(old, .init(through: "1", data: Data([2]))) }
        try await first.release(old)
        try await second.checkLease(current)
        #expect(try await second.entries(session: "s", agent: "a", after: 0).isEmpty)
        try await second.release(current)
        try await first.close()
        try await second.close()
    }

    @Test func recoveryKeepsStartedAndScopedCancellation() async throws {
        let store = try FxSessionStore()
        for id in ["one", "two"] { _ = try await store.accept(session: "s", agent: "a", id: id, content: [.text(id)], options: .init()) }
        let lease = try #require(try await store.claim(session: "s", agent: "a"))
        let first = try #require(try await store.next(lease))
        try await store.start(lease, input: first)
        try await store.cancel(session: "s", agent: "a", id: "two")
        #expect(try await store.cancelled(lease, id: "one") == false)
        try await store.cancel(session: "s", agent: "a")
        #expect(try await store.cancelled(lease, id: "one"))
        try await store.release(lease)
        let next = try #require(try await store.claim(session: "s", agent: "a"))
        let resumed = try #require(try await store.next(next))
        #expect(resumed.wasStarted && resumed.cancelRequested)
        try await store.start(next, input: resumed)
        #expect(try await store.entries(session: "s", agent: "a", after: 0).last?.event == .resumed(id: "one", sessionID: "s"))
        try await store.finish(next, id: "one", result: completed("one", next))
        #expect(try await store.next(next)?.cancelRequested == true)
        try await store.release(next)
        try await store.close()
    }

    @Test func snapshotFailureRollsBackPruningAndCanRetry() async throws {
        let url = location()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = try FxSessionStore(url: url)
        _ = try await store.accept(session: "s", agent: "a", id: "m", content: [.text("hello")], options: .init())
        let lease = try #require(try await store.claim(session: "s", agent: "a"))
        let one = try await store.appendJournal(lease, expected: nil, key: "one", data: Data([1]))
        let two = try await store.appendJournal(lease, expected: one, key: "two", data: Data([2]))
        let connection = try SQLiteDatabase(path: url.path)
        try connection.execute("CREATE TRIGGER fail_prune BEFORE DELETE ON fx_session_records BEGIN SELECT RAISE(ABORT, 'fixture'); END")
        let checkpoint = FxStoredCheckpoint(through: one, data: Data([3]))
        await #expect(throws: FxSQLiteError.self) { try await store.saveJournalCheckpoint(lease, checkpoint) }
        let unchanged = try await store.loadJournal(lease)
        #expect(unchanged.checkpoint == nil && unchanged.journal.count == 2)
        try connection.execute("DROP TRIGGER fail_prune")
        try await store.saveJournalCheckpoint(lease, checkpoint)
        let loaded = try await store.loadJournal(lease)
        #expect(loaded.checkpoint == checkpoint && loaded.head == two && loaded.journal == [.init(cursor: two, data: Data([2]))])
        #expect(try await store.appendJournal(lease, expected: nil, key: "one", data: Data([1])) == one)
        await #expect(throws: FxPersistenceError.fenced) { try await store.saveJournalCheckpoint(lease, .init(through: one, data: Data([4]))) }
        try await store.release(lease)
        try await store.close()
        try connection.close()
    }

    @Test func rejectsWrongAgentAndInvalidIntakeWithoutCreatingSession() async throws {
        let store = try FxSessionStore()
        await #expect(throws: FxError.self) { try await store.accept(session: "s", agent: "a", id: "bad/id", content: [.text("hello")], options: .init()) }
        await #expect(throws: FxSessionError.notFound) { try await store.claim(session: "s", agent: "a") }
        _ = try await store.accept(session: "s", agent: "a", id: "m", content: [.text("hello")], options: .init())
        await #expect(throws: FxSessionError.wrongAgent) { try await store.accept(session: "s", agent: "other", id: "m", content: [.text("hello")], options: .init()) }
        await #expect(throws: FxSessionError.wrongAgent) { try await store.claim(session: "s", agent: "other") }
        await #expect(throws: FxSessionError.invalidCursor) { try await store.entries(session: "s", agent: "a", after: -1) }
        try await store.close()
        await #expect(throws: FxSQLiteError.closed) { try await store.hasWork(session: "s", agent: "a") }
    }

    private func location() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("sessions.sqlite")
    }
    private func completed(_ id: String, _ lease: SessionLease) -> FxSessionResult {
        FxSessionResult(id: id, stopReason: .endTurn, usage: nil, error: nil, epoch: lease.epoch, isRepeated: false)
    }
}
