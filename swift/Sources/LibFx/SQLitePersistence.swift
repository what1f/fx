import Foundation
import CryptoKit
import CSQLite

public enum FxSQLiteError: Error, Sendable, Equatable, LocalizedError {
    case invalidURL
    case closed
    case unsupportedVersion(Int)
    case database(code: Int32, message: String)

    public var errorDescription: String? {
        switch self {
        case .invalidURL: "A local database file URL is required."
        case .closed: "The persistence store is closed."
        case .unsupportedVersion(let version): "Unsupported persistence version: \(version)."
        case .database(let code, let message): "Persistence failed (\(code)): \(message)"
        }
    }
}

/// A local store for one conversation. Separate instances coordinate through SQLite transactions.
public actor FxSQLitePersistence: FxCheckpointPersistence, FxImagePersistence {
    private let database: SQLiteDatabase

    public init(url: URL) throws {
        guard url.isFileURL, !url.path.isEmpty, !url.path.utf8.contains(0) else { throw FxSQLiteError.invalidURL }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let database = try SQLiteDatabase(path: url.path)
        try database.enableWriteAheadLogging()
        try database.statement("PRAGMA journal_mode") { statement in
            guard try database.step(statement), let mode = sqlite3_column_text(statement, 0),
                  String(cString: mode) == "wal" else {
                throw FxSQLiteError.database(code: SQLITE_ERROR, message: "Could not enable durable journal storage")
            }
        }
        try database.execute("PRAGMA synchronous=FULL")
        try database.execute("PRAGMA fullfsync=ON")
        try database.execute("PRAGMA checkpoint_fullfsync=ON")
        try database.transaction {
            try database.execute("CREATE TABLE IF NOT EXISTS fx_state (id INTEGER PRIMARY KEY CHECK(id=1), version INTEGER NOT NULL, head INTEGER NOT NULL, checkpoint_cursor INTEGER, checkpoint BLOB)")
            try database.execute("INSERT OR IGNORE INTO fx_state (id, version, head) VALUES (1, 1, 0)")
            let version = try database.statement("SELECT version FROM fx_state WHERE id=1") { statement in
                guard try database.step(statement) else { throw FxPersistenceError.invalidJournal }
                return Int(sqlite3_column_int(statement, 0))
            }
            guard version == 1 else { throw FxSQLiteError.unsupportedVersion(version) }
            try database.execute("CREATE TABLE IF NOT EXISTS fx_records (cursor INTEGER PRIMARY KEY, data BLOB NOT NULL)")
            try database.execute("CREATE TABLE IF NOT EXISTS fx_images (name TEXT PRIMARY KEY, data BLOB NOT NULL)")
            try database.execute("CREATE TABLE IF NOT EXISTS fx_writes (key TEXT PRIMARY KEY, cursor INTEGER NOT NULL, digest BLOB NOT NULL)")
        }
        self.database = database
    }

    public func load() throws -> FxPersistenceSnapshot {
        try database.transaction(mode: "DEFERRED") {
            let state = try readState()
            var records: [FxJournalRecord] = []
            try database.statement("SELECT cursor, data FROM fx_records ORDER BY cursor") { statement in
                while try database.step(statement) {
                    records.append(FxJournalRecord(cursor: String(sqlite3_column_int64(statement, 0)), data: bytes(statement, column: 1)))
                }
            }
            return FxPersistenceSnapshot(checkpoint: state.checkpoint, journal: records, head: state.head == 0 ? nil : String(state.head))
        }
    }

    public func append(expected: String?, idempotencyKey: String, data: Data, barrier: Bool) throws -> String {
        let digest = Data(SHA256.hash(data: data))
        // Every transaction uses FULL durability, including records without a barrier.
        return try database.transaction {
            let previous: String? = try database.statement("SELECT cursor, digest FROM fx_writes WHERE key=?", [.text(idempotencyKey)]) { statement in
                guard try database.step(statement) else { return nil }
                guard bytes(statement, column: 1) == digest else { throw FxPersistenceError.fenced }
                return String(sqlite3_column_int64(statement, 0))
            }
            if let previous { return previous }
            let state = try readState()
            guard expected == (state.head == 0 ? nil : String(state.head)) else { throw FxPersistenceError.fenced }
            guard state.head < Int64.max else { throw FxPersistenceError.sizeLimit }
            let cursor = state.head + 1
            try database.execute("INSERT INTO fx_records (cursor, data) VALUES (?, ?)", [.integer(cursor), .blob(data)])
            try database.execute("INSERT INTO fx_writes (key, cursor, digest) VALUES (?, ?, ?)", [.text(idempotencyKey), .integer(cursor), .blob(digest)])
            try database.execute("UPDATE fx_state SET head=? WHERE id=1", [.integer(cursor)])
            return String(cursor)
        }
    }

    public func saveCheckpoint(_ checkpoint: FxStoredCheckpoint) throws {
        try database.transaction {
            let state = try readState()
            guard let through = Int64(checkpoint.through), through > 0, through <= state.head,
                  checkpoint.through == String(through) else { throw FxPersistenceError.fenced }
            if let saved = state.checkpoint {
                guard let savedCursor = Int64(saved.through), through >= savedCursor else { throw FxPersistenceError.fenced }
                if through == savedCursor {
                    guard checkpoint.data == saved.data else { throw FxPersistenceError.fenced }
                    return
                }
            }
            // Updating the snapshot and pruning its prefix share one commit.
            try database.execute("UPDATE fx_state SET checkpoint_cursor=?, checkpoint=? WHERE id=1", [.integer(through), .blob(checkpoint.data)])
            try database.execute("DELETE FROM fx_records WHERE cursor<=?", [.integer(through)])
        }
    }

    public func storeImage(_ data: Data, named name: String) throws {
        try Task.checkCancellation()
        guard PersistedImages.name(for: data) == name else { throw FxError.invalidInput("Image name does not match its bytes") }
        try database.execute("INSERT OR IGNORE INTO fx_images (name,data) VALUES (?,?)", [.text(name), .blob(data)])
    }

    public func loadImage(named name: String) throws -> Data? {
        try Task.checkCancellation()
        return try database.statement("SELECT data FROM fx_images WHERE name=?", [.text(name)]) { statement in
            try database.step(statement) ? database.bytes(statement, column: 0) : nil
        }
    }

    public func close() throws { try database.close() }

    private func readState() throws -> (head: Int64, checkpoint: FxStoredCheckpoint?) {
        try database.statement("SELECT head, checkpoint_cursor, checkpoint FROM fx_state WHERE id=1") { statement in
            guard try database.step(statement) else { throw FxPersistenceError.invalidJournal }
            let head = sqlite3_column_int64(statement, 0)
            guard head >= 0 else { throw FxPersistenceError.invalidJournal }
            var checkpoint: FxStoredCheckpoint?
            if sqlite3_column_type(statement, 1) != SQLITE_NULL {
                let through = sqlite3_column_int64(statement, 1)
                guard through > 0, through <= head, sqlite3_column_type(statement, 2) == SQLITE_BLOB else {
                    throw FxPersistenceError.invalidJournal
                }
                checkpoint = FxStoredCheckpoint(through: String(through), data: bytes(statement, column: 2))
            }
            return (head, checkpoint)
        }
    }

    private func bytes(_ statement: OpaquePointer, column: Int32) -> Data {
        let count = Int(sqlite3_column_bytes(statement, column))
        guard count > 0, let pointer = sqlite3_column_blob(statement, column) else { return Data() }
        return Data(bytes: pointer, count: count)
    }
}
