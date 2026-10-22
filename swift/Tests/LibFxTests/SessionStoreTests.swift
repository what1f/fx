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
        #expect(entries.map(\.event) == [.started(id: "first", sessionID: "session", input: [.text("一")]), .update(id: "first", .text("回复")), .ended(result)])
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
        _ = try await first.appendJournal(old, expected: nil, key: "k", data: journalFixture(1))
        try await first.release(old)
        let current = try #require(try await second.claim(session: "s", agent: "a"))
        #expect(current.epoch == old.epoch + 1)
        await #expect(throws: FxPersistenceError.fenced) { try await first.appendJournal(old, expected: nil, key: "k", data: journalFixture(1)) }
        await #expect(throws: FxPersistenceError.fenced) { try await first.appendEvent(old, .update(id: "m", .text("stale"))) }
        await #expect(throws: FxPersistenceError.fenced) { try await first.finish(old, id: "m", result: completed("m", old)) }
        await #expect(throws: FxPersistenceError.fenced) { try await first.saveJournalCheckpoint(old, .init(through: "1", data: journalFixture(2))) }
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
        let one = try await store.appendJournal(lease, expected: nil, key: "one", data: journalFixture(1))
        let two = try await store.appendJournal(lease, expected: one, key: "two", data: journalFixture(2))
        let connection = try SQLiteDatabase(path: url.path)
        try connection.execute("CREATE TRIGGER fail_prune BEFORE DELETE ON fx_session_records BEGIN SELECT RAISE(ABORT, 'fixture'); END")
        let checkpoint = FxStoredCheckpoint(through: one, data: Data([3]))
        await #expect(throws: FxSQLiteError.self) { try await store.saveJournalCheckpoint(lease, checkpoint) }
        let unchanged = try await store.loadJournal(lease)
        #expect(unchanged.checkpoint == nil && unchanged.journal.count == 2)
        try connection.execute("DROP TRIGGER fail_prune")
        try await store.saveJournalCheckpoint(lease, checkpoint)
        let loaded = try await store.loadJournal(lease)
        #expect(loaded.checkpoint == checkpoint && loaded.head == two && loaded.journal == [.init(cursor: two, data: journalFixture(2))])
        #expect(try await store.appendJournal(lease, expected: nil, key: "one", data: journalFixture(1)) == one)
        await #expect(throws: FxPersistenceError.fenced) { try await store.saveJournalCheckpoint(lease, .init(through: one, data: Data([4]))) }
        try await store.release(lease)
        try await store.close()
        try connection.close()
    }

    @Test func steeringAcceptanceAndWithdrawalCommitWithTheJournal() async throws {
        let url = location()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = try FxSessionStore(url: url)
        _ = try await store.accept(session: "s", agent: "a", id: "prompt", content: [.text("start")], options: .init())
        let lease = try #require(try await store.claim(session: "s", agent: "a"))
        let first = try #require(try await store.next(lease))
        try await store.start(lease, input: first)
        _ = try await store.accept(session: "s", agent: "a", id: "guide", content: [.text("guidance")], options: .init(), steering: true)
        let accepted = try JSONEncoder().encode(JSONValue.object(["format": .string("libfx-journal-v1"), "events": .array([
            .object(["type": .string("input_accepted"), "data": .object(["id": .string(sessionCoreInputID("guide"))])]),
        ])]))
        let connection = try SQLiteDatabase(path: url.path)
        try connection.execute("CREATE TRIGGER fail_steering BEFORE INSERT ON fx_session_writes BEGIN SELECT RAISE(ABORT, 'fixture'); END")
        await #expect(throws: FxSQLiteError.self) { try await store.appendJournal(lease, expected: nil, key: "accepted", data: accepted) }
        #expect(try await store.steering(lease, owner: "prompt").pending.map(\.id) == ["guide"])
        #expect(try await store.loadJournal(lease).journal.isEmpty)
        try connection.execute("DROP TRIGGER fail_steering")
        let cursor = try await store.appendJournal(lease, expected: nil, key: "accepted", data: accepted)
        #expect(try await store.steering(lease, owner: "prompt").pending.isEmpty)
        let withdrawn = try JSONEncoder().encode(JSONValue.object(["format": .string("libfx-journal-v1"), "events": .array([
            .object(["type": .string("input_withdrawn"), "data": .object(["id": .string(sessionCoreInputID("guide"))])]),
        ])]))
        _ = try await store.appendJournal(lease, expected: cursor, key: "withdrawn", data: withdrawn)
        #expect(try await store.appendJournal(lease, expected: nil, key: "accepted", data: accepted) == cursor)
        try await store.finish(lease, id: "prompt", result: completed("prompt", lease))
        #expect(try await store.next(lease)?.id == "guide")
        try await store.release(lease)
        try await store.close()
        let reopened = try FxSessionStore(url: url)
        let next = try #require(try await reopened.claim(session: "s", agent: "a"))
        #expect(try await reopened.next(next)?.id == "guide")
        try await reopened.release(next)
        try await reopened.close()
        try connection.close()
    }

    @Test func versionOneSessionDatabaseUpgradesWithoutLosingPendingInputs() async throws {
        let url = location()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let original = try FxSessionStore(url: url)
        _ = try await original.accept(session: "s", agent: "a", id: "pending", content: [.text("keep this")], options: .init(instructions: "original instructions"))
        try await original.close()
        let connection = try SQLiteDatabase(path: url.path)
        try connection.execute("DROP INDEX fx_inputs_core")
        for column in ["kind", "target", "accepted", "placed", "ends", "core_id", "step", "cut_step", "cutoffs", "stops", "stop_epoch"] {
            try connection.execute("ALTER TABLE fx_inputs DROP COLUMN \(column)")
        }
        try connection.execute("ALTER TABLE fx_sessions DROP COLUMN halted")
        try connection.execute("ALTER TABLE fx_sessions DROP COLUMN recovery_input")
        try connection.execute("UPDATE fx_agent_schema SET version=1")
        try connection.close()
        let upgraded = try FxSessionStore(url: url)
        let lease = try #require(try await upgraded.claim(session: "s", agent: "a"))
        let input = try #require(try await upgraded.next(lease))
        #expect(input.id == "pending" && input.content == [.text("keep this")])
        #expect(input.options.instructions == "original instructions")
        _ = try await upgraded.accept(session: "s", agent: "a", id: "guide", content: [.text("new guidance")], options: .init(), steering: true)
        #expect(try await upgraded.steering(lease, owner: "pending").pending.map(\.id) == ["guide"])
        try await upgraded.release(lease)
        try await upgraded.close()
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

    @Test func replayRetainsAcceptedInputAfterDuplicateAndDatabaseReopen() async throws {
        let url = location()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let png = try #require(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII="))
        let input: [FxPromptContent] = [.text("原始输入"), .image(FxImage(data: png, format: .png, sourceReference: "host:original"))]
        let store = try FxSessionStore(url: url)
        #expect(try await store.accept(session: "s", agent: "a", id: "m", content: input, options: .init()) == false)
        #expect(try await store.accept(session: "s", agent: "a", id: "m", content: [.text("replacement")], options: .init()) == true)
        let lease = try #require(try await store.claim(session: "s", agent: "a"))
        let accepted = try #require(try await store.next(lease))
        try await store.start(lease, input: accepted)
        try await store.finish(lease, id: "m", result: completed("m", lease))
        try await store.release(lease)
        try await store.close()

        let reopened = try FxSessionStore(url: url)
        let entries = try await reopened.entries(session: "s", agent: "a", after: 0)
        #expect(entries.count == 2)
        #expect(entries.first?.event == .started(id: "m", sessionID: "s", input: input))
        let cursor = try #require(entries.first?.cursor)
        let later = try await reopened.entries(session: "s", agent: "a", after: cursor)
        #expect(later == Array(entries.dropFirst()))
        try await reopened.close()
    }

    @Test func concurrentFirstConnectionsCanInitializeOneDatabase() async throws {
        for _ in 0..<10 {
            let url = location()
            defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
            try await withThrowingTaskGroup(of: FxSessionStore.self) { group in
                for _ in 0..<8 { group.addTask { try FxSessionStore(url: url) } }
                var stores: [FxSessionStore] = []
                for try await store in group { stores.append(store) }
                for store in stores { try await store.close() }
            }
        }
    }

    private func location() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("sessions.sqlite")
    }
    private func completed(_ id: String, _ lease: FxSessionLease) -> FxSessionResult {
        FxSessionResult(id: id, stopReason: .endTurn, usage: nil, error: nil, epoch: lease.epoch, isRepeated: false)
    }
}

private func journalFixture(_ value: Int) -> Data {
    Data("{\"format\":\"libfx-journal-v1\",\"events\":[],\"fixture\":\(value)}".utf8)
}
