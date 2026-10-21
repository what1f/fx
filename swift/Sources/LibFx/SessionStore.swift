import Foundation
import CryptoKit
import CSQLite
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Durable intake, event history, and core journals. A nil URL keeps all data in memory.
public actor FxSessionStore {
    private let database: SQLiteDatabase
    private let lockDirectory: URL?
    private struct HeldLease { let lease: SessionLease; let descriptor: Int32? }
    private var held: [String: HeldLease] = [:]

    public init(url: URL? = nil) throws {
        if let url {
            guard url.isFileURL, !url.path.isEmpty, !url.path.utf8.contains(0) else { throw FxSQLiteError.invalidURL }
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        }
        let canonicalURL = url?.standardizedFileURL.resolvingSymlinksInPath()
        let database = try SQLiteDatabase(path: canonicalURL?.path ?? ":memory:")
        if url != nil {
            try database.execute("PRAGMA journal_mode=WAL")
            try database.execute("PRAGMA fullfsync=ON")
            try database.execute("PRAGMA checkpoint_fullfsync=ON")
        }
        try database.execute("PRAGMA synchronous=FULL")
        try database.transaction {
            let legacy = try database.statement("SELECT 1 FROM sqlite_master WHERE name='fx_state'") { try database.step($0) }
            guard !legacy else { throw FxPersistenceError.invalidJournal }
            try database.execute("CREATE TABLE IF NOT EXISTS fx_agent_schema (id INTEGER PRIMARY KEY CHECK(id=1), version INTEGER NOT NULL)")
            try database.execute("INSERT OR IGNORE INTO fx_agent_schema VALUES (1, 1)")
            let version = try database.statement("SELECT version FROM fx_agent_schema WHERE id=1") { statement in
                guard try database.step(statement) else { throw FxPersistenceError.invalidJournal }
                return Int(sqlite3_column_int(statement, 0))
            }
            guard version == 1 else { throw FxSQLiteError.unsupportedVersion(version) }
            try database.execute("CREATE TABLE IF NOT EXISTS fx_sessions (id TEXT PRIMARY KEY, agent TEXT NOT NULL, epoch INTEGER NOT NULL DEFAULT 0, owner TEXT, head INTEGER NOT NULL DEFAULT 0, checkpoint_cursor INTEGER, checkpoint BLOB)")
            try database.execute("CREATE TABLE IF NOT EXISTS fx_inputs (sequence INTEGER PRIMARY KEY AUTOINCREMENT, session TEXT NOT NULL, id TEXT NOT NULL, content BLOB NOT NULL, options BLOB NOT NULL, started INTEGER NOT NULL DEFAULT 0, cancelled INTEGER NOT NULL DEFAULT 0, result BLOB, UNIQUE(session,id))")
            try database.execute("CREATE TABLE IF NOT EXISTS fx_session_events (cursor INTEGER PRIMARY KEY AUTOINCREMENT, session TEXT NOT NULL, epoch INTEGER NOT NULL, data BLOB NOT NULL)")
            try database.execute("CREATE INDEX IF NOT EXISTS fx_session_events_read ON fx_session_events(session,cursor)")
            try database.execute("CREATE TABLE IF NOT EXISTS fx_session_records (session TEXT NOT NULL, cursor INTEGER NOT NULL, data BLOB NOT NULL, PRIMARY KEY(session,cursor))")
            try database.execute("CREATE TABLE IF NOT EXISTS fx_session_writes (session TEXT NOT NULL, key TEXT NOT NULL, cursor INTEGER NOT NULL, digest BLOB NOT NULL, PRIMARY KEY(session,key))")
        }
        self.database = database
        self.lockDirectory = canonicalURL.map { URL(fileURLWithPath: $0.path + ".locks", isDirectory: true) }
        if let lockDirectory { try FileManager.default.createDirectory(at: lockDirectory, withIntermediateDirectories: true) }
    }

    deinit {
        for item in held.values { if let descriptor = item.descriptor { closeDescriptor(descriptor) } }
    }

    public func close() throws {
        guard held.isEmpty else { throw FxError.busy }
        try database.close()
    }

    func accept(session: String, agent: String, id: String, content: [FxPromptContent], options: FxSessionOptions, checkpoint: Data? = nil) throws -> Bool {
        guard validSessionIdentifier(session), validSessionIdentifier(id) else { throw FxError.invalidInput("Invalid session or message ID") }
        _ = try PreparedPrompt(content)
        let data = try JSONEncoder().encode(content), settings = try JSONEncoder().encode(options)
        guard settings.count <= 1024 * 1024 else { throw FxError.invalidInput("Session settings exceed the size limit") }
        return try database.transaction {
            try Task.checkCancellation()
            try database.execute("INSERT OR IGNORE INTO fx_sessions(id,agent) VALUES (?,?)", [.text(session), .text(agent)])
            let created = try database.statement("SELECT changes()") { statement in
                guard try database.step(statement) else { throw FxPersistenceError.invalidJournal }
                return sqlite3_column_int(statement, 0) == 1
            }
            if created, let checkpoint {
                try database.execute("UPDATE fx_sessions SET head=1,checkpoint_cursor=1,checkpoint=? WHERE id=?", [.blob(sessionSeed(checkpoint)), .text(session)])
            }
            try checkAgent(session, agent: agent)
            let prior = try database.statement("SELECT 1 FROM fx_inputs WHERE session=? AND id=?", [.text(session), .text(id)]) { try database.step($0) }
            if prior { return true }
            try database.execute("INSERT INTO fx_inputs(session,id,content,options) VALUES (?,?,?,?)", [.text(session), .text(id), .blob(data), .blob(settings)])
            return false
        }
    }

    func pendingID(session: String, agent: String) throws -> String? {
        try checkAgent(session, agent: agent)
        return try database.statement("SELECT id FROM fx_inputs WHERE session=? AND result IS NULL ORDER BY sequence LIMIT 1", [.text(session)]) { statement in
            guard try database.step(statement) else { return nil }
            return database.text(statement, column: 0)
        }
    }

    func hasWork(session: String, agent: String) throws -> Bool {
        try checkAgent(session, agent: agent)
        return try database.statement("SELECT 1 FROM fx_inputs WHERE session=? AND result IS NULL LIMIT 1", [.text(session)]) { try database.step($0) }
    }

    func claim(session: String, agent: String) throws -> SessionLease? {
        try checkAgent(session, agent: agent)
        guard held[session] == nil else { return nil }
        var descriptor: Int32?
        if let lockDirectory {
            let name = SHA256.hash(data: Data(session.utf8)).map { String(format: "%02x", $0) }.joined()
            let fd = open(lockDirectory.appendingPathComponent(name).path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
            guard fd >= 0 else { throw FxError.transport("Could not open session lock") }
            if flock(fd, LOCK_EX | LOCK_NB) != 0 {
                let code = errno
                closeDescriptor(fd)
                if code == EWOULDBLOCK || code == EAGAIN { return nil }
                throw FxError.transport("Could not acquire session lock")
            }
            descriptor = fd
        }
        do {
            let lease = try database.transaction {
                try checkAgent(session, agent: agent)
                let epoch = try database.statement("SELECT epoch FROM fx_sessions WHERE id=?", [.text(session)]) { statement in
                    guard try database.step(statement) else { throw FxSessionError.notFound }
                    return sqlite3_column_int64(statement, 0)
                }
                guard epoch < Int64.max else { throw FxPersistenceError.sizeLimit }
                let lease = SessionLease(sessionID: session, owner: UUID().uuidString, epoch: epoch + 1)
                try database.execute("UPDATE fx_sessions SET epoch=?, owner=? WHERE id=?", [.integer(lease.epoch), .text(lease.owner), .text(session)])
                return lease
            }
            held[session] = HeldLease(lease: lease, descriptor: descriptor)
            return lease
        } catch {
            if let descriptor { closeDescriptor(descriptor) }
            throw error
        }
    }

    func release(_ lease: SessionLease) throws {
        guard held[lease.sessionID]?.lease == lease else { return }
        defer { if let descriptor = held.removeValue(forKey: lease.sessionID)?.descriptor { closeDescriptor(descriptor) } }
        try database.execute("UPDATE fx_sessions SET owner=NULL WHERE id=? AND owner=? AND epoch=?", [.text(lease.sessionID), .text(lease.owner), .integer(lease.epoch)])
    }

    func checkLease(_ lease: SessionLease) throws {
        let valid = try database.statement("SELECT 1 FROM fx_sessions WHERE id=? AND owner=? AND epoch=?", [.text(lease.sessionID), .text(lease.owner), .integer(lease.epoch)]) { try database.step($0) }
        guard valid else { throw FxPersistenceError.fenced }
    }

    private func checkAgent(_ session: String, agent: String) throws {
        guard try agentName(session) == agent else { throw FxSessionError.wrongAgent }
    }

    private func agentName(_ session: String) throws -> String {
        try database.statement("SELECT agent FROM fx_sessions WHERE id=?", [.text(session)]) { statement in
            guard try database.step(statement) else { throw FxSessionError.notFound }
            return database.text(statement, column: 0)
        }
    }

    func next(_ lease: SessionLease) throws -> SessionInput? {
        try database.transaction {
            try checkLease(lease)
            return try database.statement("SELECT id,content,options,started,cancelled FROM fx_inputs WHERE session=? AND result IS NULL ORDER BY sequence LIMIT 1", [.text(lease.sessionID)]) { statement in
                guard try database.step(statement) else { return nil }
                return SessionInput(id: database.text(statement, column: 0),
                    content: try JSONDecoder().decode([FxPromptContent].self, from: database.bytes(statement, column: 1)),
                    options: try JSONDecoder().decode(FxSessionOptions.self, from: database.bytes(statement, column: 2)),
                    wasStarted: sqlite3_column_int(statement, 3) != 0, cancelRequested: sqlite3_column_int(statement, 4) != 0)
            }
        }
    }

    func start(_ lease: SessionLease, input: SessionInput) throws {
        try database.transaction {
            try checkLease(lease)
            try database.execute("UPDATE fx_inputs SET started=1 WHERE session=? AND id=?", [.text(lease.sessionID), .text(input.id)])
            try insertEvent(lease, input.wasStarted ? .resumed(id: input.id, sessionID: lease.sessionID) : .started(id: input.id, sessionID: lease.sessionID))
        }
    }

    func appendEvent(_ lease: SessionLease, _ event: FxSessionEvent) throws {
        try database.transaction {
            try checkLease(lease)
            try insertEvent(lease, event)
        }
    }

    private func insertEvent(_ lease: SessionLease, _ event: FxSessionEvent) throws {
        try database.execute("INSERT INTO fx_session_events(session,epoch,data) VALUES (?,?,?)", [.text(lease.sessionID), .integer(lease.epoch), .blob(try JSONEncoder().encode(event))])
    }

    func finish(_ lease: SessionLease, id: String, result: FxSessionResult) throws {
        try database.transaction {
            try checkLease(lease)
            guard result.id == id, result.epoch == lease.epoch, !result.isRepeated else { throw FxPersistenceError.invalidJournal }
            let existing = try self.result(session: lease.sessionID, agent: agentName(lease.sessionID), id: id)
            if let existing {
                guard existing == result else { throw FxPersistenceError.fenced }
                return
            }
            try insertEvent(lease, .ended(result))
            try database.execute("UPDATE fx_inputs SET result=? WHERE session=? AND id=? AND result IS NULL", [.blob(try JSONEncoder().encode(result)), .text(lease.sessionID), .text(id)])
        }
    }

    func cancel(session: String, agent: String, id: String? = nil) throws {
        try database.transaction {
            try checkAgent(session, agent: agent)
            if let id {
                try database.execute("UPDATE fx_inputs SET cancelled=1 WHERE session=? AND id=? AND result IS NULL", [.text(session), .text(id)])
            } else {
                try database.execute("UPDATE fx_inputs SET cancelled=1 WHERE sequence=(SELECT sequence FROM fx_inputs WHERE session=? AND started=1 AND result IS NULL ORDER BY sequence LIMIT 1)", [.text(session)])
            }
        }
    }

    func cancelled(_ lease: SessionLease, id: String) throws -> Bool {
        try checkLease(lease)
        return try database.statement("SELECT cancelled FROM fx_inputs WHERE session=? AND id=?", [.text(lease.sessionID), .text(id)]) { statement in
            guard try database.step(statement) else { throw FxSessionError.notFound }
            return sqlite3_column_int(statement, 0) != 0
        }
    }

    func result(session: String, agent: String, id: String) throws -> FxSessionResult? {
        try checkAgent(session, agent: agent)
        return try database.statement("SELECT result FROM fx_inputs WHERE session=? AND id=?", [.text(session), .text(id)]) { statement in
            guard try database.step(statement) else { throw FxSessionError.notFound }
            guard sqlite3_column_type(statement, 0) != SQLITE_NULL else { return nil }
            return try JSONDecoder().decode(FxSessionResult.self, from: database.bytes(statement, column: 0))
        }
    }

    func entries(session: String, agent: String, after cursor: Int64) throws -> [FxSessionEntry] {
        guard cursor >= 0 else { throw FxSessionError.invalidCursor }
        try checkAgent(session, agent: agent)
        return try database.statement("SELECT cursor,epoch,data FROM fx_session_events WHERE session=? AND cursor>? ORDER BY cursor LIMIT 128", [.text(session), .integer(cursor)]) { statement in
            var entries: [FxSessionEntry] = []
            while try database.step(statement) {
                entries.append(FxSessionEntry(cursor: sqlite3_column_int64(statement, 0), epoch: sqlite3_column_int64(statement, 1),
                    event: try JSONDecoder().decode(FxSessionEvent.self, from: database.bytes(statement, column: 2))))
            }
            return entries
        }
    }

    /// Raw stored payloads for the cross-language privacy assertions.
    @_spi(Conformance) public func inspect(sessionID: String, agent: String) throws -> (records: [Data], entries: [FxSessionEntry]) {
        try database.transaction(mode: "DEFERRED") {
            try checkAgent(sessionID, agent: agent)
            var records: [Data] = []
            for (sql, columns) in [
                ("SELECT content,options,result FROM fx_inputs WHERE session=? ORDER BY sequence", 3),
                ("SELECT data FROM fx_session_events WHERE session=? ORDER BY cursor", 1),
                ("SELECT data FROM fx_session_records WHERE session=? ORDER BY cursor", 1),
                ("SELECT checkpoint FROM fx_sessions WHERE id=?", 1),
            ] {
                try database.statement(sql, [.text(sessionID)]) { statement in
                    while try database.step(statement) {
                        for column in 0..<Int32(columns) where sqlite3_column_type(statement, column) != SQLITE_NULL {
                            records.append(database.bytes(statement, column: column))
                        }
                    }
                }
            }
            var events: [FxSessionEntry] = [], cursor: Int64 = 0
            while true {
                let page = try entries(session: sessionID, agent: agent, after: cursor)
                events.append(contentsOf: page)
                guard let last = page.last, page.count == 128 else { break }
                cursor = last.cursor
            }
            return (records, events)
        }
    }

    func snapshot(session: String, agent: String) throws -> FxPersistenceSnapshot {
        try database.transaction(mode: "DEFERRED") {
            try checkAgent(session, agent: agent)
            return try readJournal(session)
        }
    }

    func loadJournal(_ lease: SessionLease) throws -> FxPersistenceSnapshot {
        try database.transaction(mode: "DEFERRED") {
            try checkLease(lease)
            return try readJournal(lease.sessionID)
        }
    }

    private func readJournal(_ session: String) throws -> FxPersistenceSnapshot {
        let state = try journalState(session)
        let records = try database.statement("SELECT cursor,data FROM fx_session_records WHERE session=? ORDER BY cursor", [.text(session)]) { statement in
            var records: [FxJournalRecord] = []
            while try database.step(statement) {
                records.append(FxJournalRecord(cursor: String(sqlite3_column_int64(statement, 0)), data: database.bytes(statement, column: 1)))
            }
            return records
        }
        return FxPersistenceSnapshot(checkpoint: state.checkpoint, journal: records, head: state.head == 0 ? nil : String(state.head))
    }

    func appendJournal(_ lease: SessionLease, expected: String?, key: String, data: Data) throws -> String {
        try database.transaction {
            try checkLease(lease)
            let digest = Data(SHA256.hash(data: data))
            if let cursor = try database.statement("SELECT cursor,digest FROM fx_session_writes WHERE session=? AND key=?", [.text(lease.sessionID), .text(key)], { statement -> String? in
                guard try database.step(statement) else { return nil }
                guard database.bytes(statement, column: 1) == digest else { throw FxPersistenceError.fenced }
                return String(sqlite3_column_int64(statement, 0))
            }) { return cursor }
            let state = try journalState(lease.sessionID)
            guard expected == (state.head == 0 ? nil : String(state.head)) else { throw FxPersistenceError.fenced }
            guard state.head < Int64.max else { throw FxPersistenceError.sizeLimit }
            let cursor = state.head + 1
            try database.execute("INSERT INTO fx_session_records VALUES (?,?,?)", [.text(lease.sessionID), .integer(cursor), .blob(data)])
            try database.execute("INSERT INTO fx_session_writes VALUES (?,?,?,?)", [.text(lease.sessionID), .text(key), .integer(cursor), .blob(digest)])
            try database.execute("UPDATE fx_sessions SET head=? WHERE id=?", [.integer(cursor), .text(lease.sessionID)])
            return String(cursor)
        }
    }

    func saveJournalCheckpoint(_ lease: SessionLease, _ checkpoint: FxStoredCheckpoint) throws {
        try database.transaction {
            try checkLease(lease)
            let state = try journalState(lease.sessionID)
            let previous = state.checkpoint.flatMap { Int64($0.through) } ?? 0
            guard let through = Int64(checkpoint.through), through > 0, through <= state.head,
                  checkpoint.through == String(through), through >= previous else { throw FxPersistenceError.fenced }
            if state.checkpoint?.through == checkpoint.through {
                guard state.checkpoint?.data == checkpoint.data else { throw FxPersistenceError.fenced }
                return
            }
            try database.execute("UPDATE fx_sessions SET checkpoint_cursor=?,checkpoint=? WHERE id=?", [.integer(through), .blob(checkpoint.data), .text(lease.sessionID)])
            try database.execute("DELETE FROM fx_session_records WHERE session=? AND cursor<=?", [.text(lease.sessionID), .integer(through)])
        }
    }

    private func journalState(_ session: String) throws -> (head: Int64, checkpoint: FxStoredCheckpoint?) {
        try database.statement("SELECT head,checkpoint_cursor,checkpoint FROM fx_sessions WHERE id=?", [.text(session)]) { statement in
            guard try database.step(statement) else { throw FxSessionError.notFound }
            let head = sqlite3_column_int64(statement, 0)
            guard head >= 0 else { throw FxPersistenceError.invalidJournal }
            let checkpoint: FxStoredCheckpoint?
            if sqlite3_column_type(statement, 1) != SQLITE_NULL {
                let cursor = sqlite3_column_int64(statement, 1)
                guard cursor > 0, cursor <= head, sqlite3_column_type(statement, 2) == SQLITE_BLOB else {
                    throw FxPersistenceError.invalidJournal
                }
                checkpoint = FxStoredCheckpoint(through: String(cursor), data: database.bytes(statement, column: 2))
            } else {
                guard sqlite3_column_type(statement, 2) == SQLITE_NULL else { throw FxPersistenceError.invalidJournal }
                checkpoint = nil
            }
            return (head, checkpoint)
        }
    }
}

private func closeDescriptor(_ descriptor: Int32) {
    #if canImport(Darwin)
    _ = Darwin.close(descriptor)
    #else
    _ = Glibc.close(descriptor)
    #endif
}
