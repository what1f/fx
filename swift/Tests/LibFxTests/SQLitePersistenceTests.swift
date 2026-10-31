import Foundation
import Testing
import CSQLite
@testable import LibFx

private func databaseURL() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("conversation.sqlite")
}

private func executeSQL(_ url: URL, _ sql: String) throws {
    var handle: OpaquePointer?
    #expect(sqlite3_open(url.path, &handle) == SQLITE_OK)
    defer { sqlite3_close(handle) }
    let code = sqlite3_exec(handle, sql, nil, nil, nil)
    guard code == SQLITE_OK else { throw FxSQLiteError.database(code: code, message: "Test fixture SQL failed") }
}

@Test func sqlitePreservesBytesAndRetryIdentityAcrossReopen() async throws {
    let url = databaseURL()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let first = try FxSQLitePersistence(url: url)
    let data = Data([0, 255, 12, 0, 1])
    let cursor = try await first.append(expected: nil, idempotencyKey: "key\0one", data: data, barrier: true)
    let next = try await first.append(expected: cursor, idempotencyKey: "空", data: Data(), barrier: false)
    try await first.close()
    try await first.close()
    await #expect(throws: FxSQLiteError.closed) { try await first.load() }
    let reopened = try FxSQLitePersistence(url: url)
    #expect(try await reopened.append(expected: nil, idempotencyKey: "key\0one", data: data, barrier: true) == cursor)
    let snapshot = try await reopened.load()
    #expect(snapshot.head == next)
    #expect(snapshot.journal == [FxJournalRecord(cursor: cursor, data: data), FxJournalRecord(cursor: next, data: Data())])
    await #expect(throws: FxPersistenceError.fenced) {
        try await reopened.append(expected: next, idempotencyKey: "key\0one", data: Data([3]), barrier: true)
    }
    try await reopened.close()
}

@Test func sqliteConnectionsFenceCompetingWriters() async throws {
    let url = databaseURL()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let stores = try [FxSQLitePersistence(url: url), FxSQLitePersistence(url: url)]
    let results = await withTaskGroup(of: Result<String, any Error>.self) { group in
        for (index, store) in stores.enumerated() {
            group.addTask {
                do { return .success(try await store.append(expected: nil, idempotencyKey: "writer-\(index)", data: Data([UInt8(index)]), barrier: true)) }
                catch { return .failure(error) }
            }
        }
        var values: [Result<String, any Error>] = []
        for await result in group { values.append(result) }
        return values
    }
    #expect(results.filter { if case .success = $0 { true } else { false } }.count == 1)
    #expect(results.filter { if case .failure(let error) = $0 { error as? FxPersistenceError == .fenced } else { false } }.count == 1)
    for store in stores {
        #expect(try await store.load().journal.count == 1)
        try await store.close()
    }
}

@Test func sqliteSnapshotsKeepTailAndRetryKeys() async throws {
    let url = databaseURL()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let store = try FxSQLitePersistence(url: url)
    let first = try await store.append(expected: nil, idempotencyKey: "first", data: Data([1]), barrier: true)
    let second = try await store.append(expected: first, idempotencyKey: "second", data: Data([2]), barrier: true)
    let checkpoint = FxStoredCheckpoint(through: first, data: Data([3]))
    try await store.saveCheckpoint(checkpoint)
    try await store.close()
    let reopened = try FxSQLitePersistence(url: url)
    let loaded = try await reopened.load()
    #expect(loaded.checkpoint == checkpoint)
    #expect(loaded.head == second)
    #expect(loaded.journal == [FxJournalRecord(cursor: second, data: Data([2]))])
    #expect(try await reopened.append(expected: nil, idempotencyKey: "first", data: Data([1]), barrier: true) == first)
    try await reopened.saveCheckpoint(checkpoint)
    await #expect(throws: FxPersistenceError.fenced) {
        try await reopened.saveCheckpoint(FxStoredCheckpoint(through: first, data: Data([4])))
    }
    try await reopened.saveCheckpoint(FxStoredCheckpoint(through: second, data: Data([5])))
    await #expect(throws: FxPersistenceError.fenced) { try await reopened.saveCheckpoint(checkpoint) }
    #expect(try await reopened.load().journal.isEmpty)
    try await reopened.close()
}

@Test func sqliteSnapshotFailureRollsBackSnapshotAndPruning() async throws {
    let url = databaseURL()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let store = try FxSQLitePersistence(url: url)
    let cursor = try await store.append(expected: nil, idempotencyKey: "first", data: Data([1]), barrier: true)
    try executeSQL(url, "CREATE TRIGGER fail_prune BEFORE DELETE ON fx_records BEGIN SELECT RAISE(ABORT, 'fixture failure'); END")
    await #expect(throws: FxSQLiteError.self) {
        try await store.saveCheckpoint(FxStoredCheckpoint(through: cursor, data: Data([2])))
    }
    let loaded = try await store.load()
    #expect(loaded.checkpoint == nil)
    #expect(loaded.journal.count == 1)
    try executeSQL(url, "DROP TRIGGER fail_prune")
    try await store.saveCheckpoint(FxStoredCheckpoint(through: cursor, data: Data([2])))
    #expect(try await store.load().journal.isEmpty)
    try await store.close()
}

@Test func sqliteRejectsFutureSchemaWithoutChangingConversation() async throws {
    let url = databaseURL()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let store = try FxSQLitePersistence(url: url)
    _ = try await store.append(expected: nil, idempotencyKey: "first", data: Data([1]), barrier: true)
    try await store.close()
    try executeSQL(url, "UPDATE fx_state SET version=99")
    #expect(throws: FxSQLiteError.unsupportedVersion(99)) { try FxSQLitePersistence(url: url) }
    try executeSQL(url, "UPDATE fx_state SET version=1")
    let reopened = try FxSQLitePersistence(url: url)
    #expect(try await reopened.load().journal.count == 1)
    try await reopened.close()
    #expect(throws: FxSQLiteError.invalidURL) { try FxSQLitePersistence(url: URL(string: "https://example.com/store")!) }
}
