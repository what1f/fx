import Foundation
import CryptoKit
import CSQLite
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Durable intake, event history, and core journals. A nil URL keeps all data in memory.
public actor FxSessionStore: FxSessionStorage {
    let database: SQLiteDatabase
    private let lockDirectory: URL?
    private struct HeldLease { let lease: FxSessionLease; let descriptor: Int32? }
    private var held: [String: HeldLease] = [:]

    public init(url: URL? = nil) throws {
        if let url {
            guard url.isFileURL, !url.path.isEmpty, !url.path.utf8.contains(0) else { throw FxSQLiteError.invalidURL }
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        }
        let canonicalURL = url?.standardizedFileURL.resolvingSymlinksInPath()
        let database = try SQLiteDatabase(path: canonicalURL?.path ?? ":memory:")
        if url != nil {
            try database.enableWriteAheadLogging()
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
            guard (1...4).contains(version) else { throw FxSQLiteError.unsupportedVersion(version) }
            try database.execute("CREATE TABLE IF NOT EXISTS fx_sessions (id TEXT PRIMARY KEY, agent TEXT NOT NULL, epoch INTEGER NOT NULL DEFAULT 0, owner TEXT, head INTEGER NOT NULL DEFAULT 0, checkpoint_cursor INTEGER, checkpoint BLOB)")
            try database.execute("CREATE TABLE IF NOT EXISTS fx_inputs (sequence INTEGER PRIMARY KEY AUTOINCREMENT, session TEXT NOT NULL, id TEXT NOT NULL, content BLOB NOT NULL, options BLOB NOT NULL, started INTEGER NOT NULL DEFAULT 0, cancelled INTEGER NOT NULL DEFAULT 0, result BLOB, UNIQUE(session,id))")
            try database.execute("CREATE TABLE IF NOT EXISTS fx_session_events (cursor INTEGER PRIMARY KEY AUTOINCREMENT, session TEXT NOT NULL, epoch INTEGER NOT NULL, data BLOB NOT NULL)")
            try database.execute("CREATE INDEX IF NOT EXISTS fx_session_events_read ON fx_session_events(session,cursor)")
            try database.execute("CREATE TABLE IF NOT EXISTS fx_session_records (session TEXT NOT NULL, cursor INTEGER NOT NULL, data BLOB NOT NULL, PRIMARY KEY(session,cursor))")
            try database.execute("CREATE TABLE IF NOT EXISTS fx_session_images (session TEXT NOT NULL, name TEXT NOT NULL, data BLOB NOT NULL, PRIMARY KEY(session,name))")
            try database.execute("CREATE TABLE IF NOT EXISTS fx_session_writes (session TEXT NOT NULL, key TEXT NOT NULL, cursor INTEGER NOT NULL, digest BLOB NOT NULL, PRIMARY KEY(session,key))")
            if version == 1 {
                try database.execute("ALTER TABLE fx_inputs ADD COLUMN kind TEXT NOT NULL DEFAULT 'prompt'")
                try database.execute("ALTER TABLE fx_inputs ADD COLUMN target TEXT")
                try database.execute("ALTER TABLE fx_inputs ADD COLUMN accepted INTEGER NOT NULL DEFAULT 0")
                try database.execute("ALTER TABLE fx_inputs ADD COLUMN placed INTEGER NOT NULL DEFAULT 0")
                try database.execute("ALTER TABLE fx_inputs ADD COLUMN ends INTEGER NOT NULL DEFAULT 0")
                try database.execute("ALTER TABLE fx_inputs ADD COLUMN core_id TEXT")
                try database.execute("UPDATE fx_agent_schema SET version=2 WHERE id=1")
            }
            try database.execute("CREATE INDEX IF NOT EXISTS fx_inputs_core ON fx_inputs(session,core_id)")
            if version < 3 {
                try database.execute("ALTER TABLE fx_inputs ADD COLUMN step TEXT")
                try database.execute("ALTER TABLE fx_inputs ADD COLUMN cut_step TEXT")
                try database.execute("ALTER TABLE fx_inputs ADD COLUMN cutoffs INTEGER NOT NULL DEFAULT 0")
                try database.execute("UPDATE fx_agent_schema SET version=3 WHERE id=1")
            }
            if version < 4 {
                try database.execute("ALTER TABLE fx_inputs ADD COLUMN stops INTEGER NOT NULL DEFAULT 0")
                try database.execute("ALTER TABLE fx_inputs ADD COLUMN stop_epoch INTEGER NOT NULL DEFAULT 0")
                try database.execute("ALTER TABLE fx_sessions ADD COLUMN halted INTEGER NOT NULL DEFAULT 0")
                try database.execute("ALTER TABLE fx_sessions ADD COLUMN recovery_input TEXT")
                try database.execute("UPDATE fx_agent_schema SET version=4 WHERE id=1")
            }
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

    public func accept(session: String, agent: String, id: String, content: [FxPromptContent], options: FxSessionOptions, checkpoint: Data? = nil, steering: Bool = false, deferringImageLimits: Bool = false) throws -> Bool {
        guard validSessionIdentifier(session), validSessionIdentifier(id) else { throw FxError.invalidInput("Invalid session or message ID") }
        try validateSessionInput(content, deferringImageLimits: deferringImageLimits)
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
                try database.execute("UPDATE fx_sessions SET head=1,checkpoint_cursor=1,checkpoint=? WHERE id=?", [.blob(checkpoint), .text(session)])
            }
            try checkAgent(session, agent: agent)
            let prior = try database.statement("SELECT kind FROM fx_inputs WHERE session=? AND id=?", [.text(session), .text(id)]) { statement in
                guard try database.step(statement) else { return false }
                guard database.text(statement, column: 0) == (steering ? "steer" : "prompt") else { throw FxSessionError.messageIDInUse }
                return true
            }
            if prior { return true }
            let owner = steering ? try steeringOwner(session: session) : nil
            let joinable = content.allSatisfy { if case .text = $0 { return true }; return false }
            if steering, joinable {
                let text = content.compactMap { if case .text(let text) = $0 { return text }; return nil }.joined(separator: "\n")
                guard text.utf8.count <= 64 * 1024 else { throw FxError.invalidInput("Steering text exceeds the size limit") }
            }
            if steering, !joinable, let owner {
                try database.execute("UPDATE fx_inputs SET ends=1 WHERE session=? AND id=?", [.text(session), .text(owner)])
            }
            let target: SQLiteDatabase.Value = steering && joinable ? owner.map(SQLiteDatabase.Value.text) ?? .null : .null
            try database.execute("INSERT INTO fx_inputs(session,id,content,options,kind,target,core_id) VALUES (?,?,?,?,?,?,?)", [.text(session), .text(id), .blob(data), .blob(settings), .text(steering ? "steer" : "prompt"), target, .text(sessionCoreInputID(id))])
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

    public func resumePoint(session: String, agent: String) throws -> (id: String, cursor: Int64)? {
        try database.transaction(mode: "DEFERRED") {
            guard let id = try pendingID(session: session, agent: agent) else { return nil }
            return try database.statement("SELECT COALESCE(MAX(cursor),0) FROM fx_session_events WHERE session=?", [.text(session)]) { statement in
                guard try database.step(statement) else { throw FxPersistenceError.invalidJournal }
                return (id, sqlite3_column_int64(statement, 0))
            }
        }
    }

    public func hasWork(session: String, agent: String) throws -> Bool {
        try checkAgent(session, agent: agent)
        return try database.statement("SELECT 1 FROM fx_inputs WHERE session=? AND result IS NULL LIMIT 1", [.text(session)]) { try database.step($0) }
    }

    public func claim(session: String, agent: String) throws -> FxSessionLease? {
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
                let lease = FxSessionLease(sessionID: session, owner: UUID().uuidString, epoch: epoch + 1)
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

    public func release(_ lease: FxSessionLease) throws {
        guard held[lease.sessionID]?.lease == lease else { return }
        defer { if let descriptor = held.removeValue(forKey: lease.sessionID)?.descriptor { closeDescriptor(descriptor) } }
        try database.execute("UPDATE fx_sessions SET owner=NULL WHERE id=? AND owner=? AND epoch=?", [.text(lease.sessionID), .text(lease.owner), .integer(lease.epoch)])
    }

    public func checkLease(_ lease: FxSessionLease) throws {
        let valid = try database.statement("SELECT 1 FROM fx_sessions WHERE id=? AND owner=? AND epoch=?", [.text(lease.sessionID), .text(lease.owner), .integer(lease.epoch)]) { try database.step($0) }
        guard valid else { throw FxPersistenceError.fenced }
    }

    func checkAgent(_ session: String, agent: String) throws {
        guard try agentName(session) == agent else { throw FxSessionError.wrongAgent }
    }

    public func owner(session: String) throws -> String? {
        do { return try agentName(session) }
        catch FxSessionError.notFound { return nil }
    }

    func agentName(_ session: String) throws -> String {
        try database.statement("SELECT agent FROM fx_sessions WHERE id=?", [.text(session)]) { statement in
            guard try database.step(statement) else { throw FxSessionError.notFound }
            return database.text(statement, column: 0)
        }
    }

    public func next(_ lease: FxSessionLease) throws -> FxSessionInput? {
        try database.transaction {
            try checkLease(lease)
            return try database.statement("SELECT id,content,options,started,cancelled FROM fx_inputs WHERE session=? AND result IS NULL AND target IS NULL ORDER BY sequence LIMIT 1", [.text(lease.sessionID)]) { statement in
                guard try database.step(statement) else { return nil }
                return FxSessionInput(id: database.text(statement, column: 0),
                    content: try JSONDecoder().decode([FxPromptContent].self, from: database.bytes(statement, column: 1)),
                    options: try JSONDecoder().decode(FxSessionOptions.self, from: database.bytes(statement, column: 2)),
                    wasStarted: sqlite3_column_int(statement, 3) != 0, cancelRequested: sqlite3_column_int(statement, 4) != 0)
            }
        }
    }

    public func start(_ lease: FxSessionLease, input: FxSessionInput) throws {
        try database.transaction {
            try checkLease(lease)
            try database.execute("UPDATE fx_inputs SET started=1 WHERE session=? AND id=?", [.text(lease.sessionID), .text(input.id)])
            try insertEvent(lease, input.wasStarted ? .resumed(id: input.id, sessionID: lease.sessionID) : .started(id: input.id, sessionID: lease.sessionID, input: input.content))
        }
    }

    public func appendEvent(_ lease: FxSessionLease, _ event: FxSessionEvent) throws {
        try database.transaction {
            try checkLease(lease)
            try insertEvent(lease, event)
        }
    }

    private func insertEvent(_ lease: FxSessionLease, _ event: FxSessionEvent) throws {
        try database.execute("INSERT INTO fx_session_events(session,epoch,data) VALUES (?,?,?)", [.text(lease.sessionID), .integer(lease.epoch), .blob(try JSONEncoder().encode(event))])
    }

    public func finish(_ lease: FxSessionLease, id: String, result: FxSessionResult) throws {
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
            try finishSteering(lease, owner: id, result: result)
        }
    }

    public func cancel(session: String, agent: String, id: String? = nil) throws {
        try database.transaction {
            try checkAgent(session, agent: agent)
            if let id {
                try database.execute("UPDATE fx_inputs SET cancelled=1 WHERE session=? AND id=? AND result IS NULL", [.text(session), .text(id)])
            } else {
                try database.execute("UPDATE fx_inputs SET cancelled=1 WHERE sequence=(SELECT sequence FROM fx_inputs WHERE session=? AND started=1 AND result IS NULL ORDER BY sequence LIMIT 1)", [.text(session)])
            }
        }
    }

    public func cancelled(_ lease: FxSessionLease, id: String) throws -> Bool {
        try checkLease(lease)
        return try database.statement("SELECT cancelled FROM fx_inputs WHERE session=? AND id=?", [.text(lease.sessionID), .text(id)]) { statement in
            guard try database.step(statement) else { throw FxSessionError.notFound }
            return sqlite3_column_int(statement, 0) != 0
        }
    }

    public func result(session: String, agent: String, id: String) throws -> FxSessionResult? {
        try checkAgent(session, agent: agent)
        return try database.statement("SELECT result FROM fx_inputs WHERE session=? AND id=?", [.text(session), .text(id)]) { statement in
            guard try database.step(statement) else { throw FxSessionError.notFound }
            guard sqlite3_column_type(statement, 0) != SQLITE_NULL else { return nil }
            return try JSONDecoder().decode(FxSessionResult.self, from: database.bytes(statement, column: 0))
        }
    }

    public func entries(session: String, agent: String, after cursor: Int64) throws -> [FxSessionEntry] {
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

    public func snapshot(session: String, agent: String) throws -> FxPersistenceSnapshot {
        try database.transaction(mode: "DEFERRED") {
            try checkAgent(session, agent: agent)
            return try readJournal(session)
        }
    }

    public func storeImage(_ data: Data, named name: String, lease: FxSessionLease) throws {
        try Task.checkCancellation()
        guard PersistedImages.name(for: data) == name else { throw FxError.invalidInput("Image name does not match its bytes") }
        try database.transaction {
            try checkLease(lease)
            try database.execute("INSERT OR IGNORE INTO fx_session_images (session,name,data) VALUES (?,?,?)",
                                 [.text(lease.sessionID), .text(name), .blob(data)])
        }
    }

    public func loadImage(named name: String, session: String, agent: String) throws -> Data? {
        try Task.checkCancellation()
        return try database.transaction(mode: "DEFERRED") {
            try checkAgent(session, agent: agent)
            return try readImage(named: name, session: session)
        }
    }

    public func loadImage(named name: String, lease: FxSessionLease) throws -> Data? {
        try Task.checkCancellation()
        return try database.transaction(mode: "DEFERRED") {
            try checkLease(lease)
            return try readImage(named: name, session: lease.sessionID)
        }
    }

    private func readImage(named name: String, session: String) throws -> Data? {
        try database.statement("SELECT data FROM fx_session_images WHERE session=? AND name=?", [.text(session), .text(name)]) { statement in
            try database.step(statement) ? database.bytes(statement, column: 0) : nil
        }
    }

    public func loadJournal(_ lease: FxSessionLease) throws -> FxPersistenceSnapshot {
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

    public func appendJournal(_ lease: FxSessionLease, expected: String?, key: String, data: Data, barrier: Bool = true, marks: [FxSessionJournalMark]? = nil) throws -> String {
        try database.transaction {
            try checkLease(lease)
            struct MarkedWrite: Encodable { let data: Data; let marks: [FxSessionJournalMark] }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let identity = try marks.map { try encoder.encode(MarkedWrite(data: data, marks: $0)) } ?? data
            let digest = Data(SHA256.hash(data: identity))
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
            try applyJournalMarks(marks ?? FxSessionJournalMark.decode(data), session: lease.sessionID)
            try database.execute("INSERT INTO fx_session_writes VALUES (?,?,?,?)", [.text(lease.sessionID), .text(key), .integer(cursor), .blob(digest)])
            try database.execute("UPDATE fx_sessions SET head=? WHERE id=?", [.integer(cursor), .text(lease.sessionID)])
            return String(cursor)
        }
    }

    public func saveJournalCheckpoint(_ lease: FxSessionLease, _ checkpoint: FxStoredCheckpoint) throws {
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
