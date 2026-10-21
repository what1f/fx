import Foundation

public struct FxJournalRecord: Sendable, Equatable {
    public let cursor: String
    public let data: Data
    public init(cursor: String, data: Data) { self.cursor = cursor; self.data = data }
}

public struct FxStoredCheckpoint: Sendable, Equatable {
    public let through: String
    public let data: Data
    public init(through: String, data: Data) { self.through = through; self.data = data }
}

public struct FxPersistenceSnapshot: Sendable {
    public let checkpoint: FxStoredCheckpoint?
    public let journal: [FxJournalRecord]
    public let head: String?
    public init(checkpoint: FxStoredCheckpoint? = nil, journal: [FxJournalRecord] = [], head: String? = nil) {
        self.checkpoint = checkpoint; self.journal = journal; self.head = head
    }
}

/// Implementations must serialize appends and reject a stale expected cursor.
/// A barrier acknowledges durability of this record and every preceding record.
public protocol FxPersistence: Sendable {
    func load() async throws -> FxPersistenceSnapshot
    func append(expected: String?, idempotencyKey: String, data: Data, barrier: Bool) async throws -> String
}

public protocol FxCheckpointPersistence: FxPersistence {
    func saveCheckpoint(_ checkpoint: FxStoredCheckpoint) async throws
}

public enum FxPersistenceError: Error, Sendable, Equatable {
    case fenced
    case invalidJournal
    case unsupportedVersion
    case sizeLimit
    case invalidCursor
}

/// An in-memory store for tests and conversations that do not survive process exit.
public actor FxMemoryPersistence: FxCheckpointPersistence {
    private var records: [FxJournalRecord] = []
    private var checkpoint: FxStoredCheckpoint?
    private var head: String?
    private var writes: [String: (data: Data, cursor: String)] = [:]
    private var nextCursor = 1

    public init() {}
    public func load() -> FxPersistenceSnapshot {
        FxPersistenceSnapshot(checkpoint: checkpoint, journal: records, head: head)
    }
    public func append(expected: String?, idempotencyKey: String, data: Data, barrier: Bool) throws -> String {
        if let previous = writes[idempotencyKey] {
            guard previous.data == data else { throw FxPersistenceError.fenced }
            return previous.cursor
        }
        guard expected == head else { throw FxPersistenceError.fenced }
        let cursor = String(nextCursor)
        nextCursor += 1
        records.append(FxJournalRecord(cursor: cursor, data: data))
        writes[idempotencyKey] = (data, cursor)
        head = cursor
        return cursor
    }
    public func saveCheckpoint(_ checkpoint: FxStoredCheckpoint) throws {
        guard checkpoint.through == head || records.contains(where: { $0.cursor == checkpoint.through }) else {
            throw FxPersistenceError.fenced
        }
        if let index = records.firstIndex(where: { $0.cursor == checkpoint.through }) {
            records.removeFirst(index + 1)
        }
        self.checkpoint = checkpoint
    }
}

struct LoadedJournal: Sendable {
    let checkpoint: Data?
    let events: [JSONValue]
    let head: String?
    let lastSequence: UInt64
    let tailBytes: Int

    init(_ snapshot: FxPersistenceSnapshot) throws {
        func validateCursor(_ cursor: String) throws {
            guard !cursor.isEmpty, cursor.utf8.count <= 1024 else { throw FxPersistenceError.invalidCursor }
        }
        var covered: UInt64 = 0
        if let checkpoint = snapshot.checkpoint {
            try validateCursor(checkpoint.through)
            guard checkpoint.data.count <= 4 * 1024 * 1024 else { throw FxPersistenceError.sizeLimit }
            let bytes = [UInt8](checkpoint.data.prefix(13))
            guard bytes.count == 13, Array(bytes.prefix(4)) == Array("FXSN".utf8) else {
                throw FxPersistenceError.invalidJournal
            }
            for index in 0..<8 { covered |= UInt64(bytes[index + 5]) << (index * 8) }
        }
        var events: [JSONValue] = []
        var tailBytes = 0
        var head = snapshot.checkpoint?.through
        for record in snapshot.journal {
            try validateCursor(record.cursor)
            let value: JSONValue
            do { value = try JSONDecoder().decode(JSONValue.self, from: record.data) }
            catch { throw FxPersistenceError.invalidJournal }
            guard value["format"] == .string("libfx-journal-v1") else {
                if value["format"]?.string?.hasPrefix("libfx-journal-v") == true { throw FxPersistenceError.unsupportedVersion }
                throw FxPersistenceError.invalidJournal
            }
            guard case .array(let batch) = value["events"] else { throw FxPersistenceError.invalidJournal }
            let uncovered = batch.filter { event in
                guard let seq = event["seq"]?.integer, seq >= 0 else { return true }
                return UInt64(seq) > covered
            }
            events += uncovered
            if !uncovered.isEmpty { tailBytes += record.data.count }
            head = record.cursor
        }
        if let explicit = snapshot.head { try validateCursor(explicit); head = explicit }
        // Preserve sequence numbers while dropping payloads that newer progress replaces.
        // Delta progress keeps its base; only a full progress record supersedes it.
        var superseded = false
        var answered = false
        for index in events.indices.reversed() {
            let type = events[index]["type"]?.string
            if events[index]["data"] != nil,
               (type == "turn_progress" && superseded || type == "tool_result" && answered),
               case .object(var fields) = events[index] {
                fields["data"] = .null
                events[index] = .object(fields)
            }
            if type == "turn_committed" || type == "turn_progress_cleared" {
                superseded = true; answered = true
            } else if type == "turn_progress" {
                answered = true
                if events[index]["base"] == nil { superseded = true }
            }
        }
        let data = try JSONEncoder().encode(JSONValue.array(events))
        guard data.count <= 4 * 1024 * 1024 else { throw FxPersistenceError.sizeLimit }
        self.checkpoint = snapshot.checkpoint?.data
        self.events = events
        self.head = head
        self.lastSequence = events.last?["seq"]?.integer.flatMap(UInt64.init(exactly:)) ?? covered
        self.tailBytes = tailBytes
    }
}

/// The RPC reader awaits each append, so tool admission cannot pass its durability barrier.
actor JournalWriter {
    private let store: any FxPersistence
    private let writerID = UUID().uuidString
    private(set) var head: String?
    private var tail: Task<Void, any Error>?
    private var lastSequence: UInt64
    private var bytesSinceCheckpoint: Int

    init(store: any FxPersistence, head: String?, lastSequence: UInt64 = 0, tailBytes: Int = 0) {
        self.store = store; self.head = head; self.lastSequence = lastSequence
        self.bytesSinceCheckpoint = tailBytes
    }

    func append(_ events: JSONValue, barrier: Bool) async throws {
        guard case .array(let batch) = events, !batch.isEmpty else { return }
        let previous = tail
        let task = Task {
            try await previous?.value
            let data = try JSONEncoder().encode(JSONValue.object([
                "format": .string("libfx-journal-v1"), "events": .array(batch),
            ]))
            let first = batch.first?["seq"]?.integer ?? 0
            let waits = batch.contains { ["input_accepted", "input_withdrawn", "turn_committed", "turn_progress_cleared", "turn_yielded"].contains($0["type"]?.string ?? "") }
            let cursor = try await store.append(expected: head, idempotencyKey: "\(writerID):\(first)", data: data, barrier: barrier || waits)
            guard !cursor.isEmpty, cursor.utf8.count <= 1024 else { throw FxPersistenceError.invalidCursor }
            head = cursor
            bytesSinceCheckpoint += data.count
            if let seq = batch.last?["seq"]?.integer, let sequence = UInt64(exactly: seq) {
                lastSequence = sequence
            }
        }
        tail = task
        try await task.value
    }

    func check() async throws { try await tail?.value }

    func shouldCheckpoint(afterBytes limit: Int) -> Bool {
        store is any FxCheckpointPersistence && bytesSinceCheckpoint > 0 && bytesSinceCheckpoint >= limit
    }

    func saveSnapshot(_ data: Data, at sequence: UInt64) async throws -> String? {
        try await check()
        guard let store = store as? any FxCheckpointPersistence else {
            throw FxError.invalidInput("Persistence store does not support checkpoints")
        }
        guard sequence == lastSequence else { throw FxPersistenceError.invalidJournal }
        guard let head else { return nil }
        try await store.saveCheckpoint(FxStoredCheckpoint(through: head, data: data))
        bytesSinceCheckpoint = 0
        return head
    }
}
