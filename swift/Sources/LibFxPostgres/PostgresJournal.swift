import CryptoKit
import Foundation
import LibFx
import PostgresNIO

extension FxPostgresStore {
  public func snapshot(session: String, agent: String) async throws -> FxPersistenceSnapshot {
    try await transaction { c in
      try await checkAgent(c, session: session, agent: agent)
      return try await readJournal(c, session: session)
    }
  }
  public func loadJournal(_ lease: FxSessionLease) async throws -> FxPersistenceSnapshot {
    try await leased(lease) { c in try await readJournal(c, session: lease.sessionID) }
  }
  func readJournal(_ c: PostgresConnection, session: String) async throws -> FxPersistenceSnapshot {
    guard
      let row = try await rows(
        c,
        "SELECT head,checkpoint_cursor,checkpoint,completed_turn FROM fx_pg_sessions WHERE namespace=\(namespace) AND session_id=\(session)"
      ).first
    else { throw FxSessionError.notFound }
    let (head, cursor, bytes, completed) = try row.decode((Int64, Int64?, Data?, String?).self)
    var checkpoint: FxStoredCheckpoint?
    if let cursor {
      guard cursor > 0, cursor <= head, let bytes else { throw FxPersistenceError.invalidJournal }
      checkpoint = FxStoredCheckpoint(through: String(cursor), data: bytes)
    } else if bytes != nil {
      throw FxPersistenceError.invalidJournal
    }
    let journal = try await rows(
      c,
      "SELECT cursor,data FROM fx_pg_records WHERE namespace=\(namespace) AND session_id=\(session) ORDER BY cursor"
    ).map { row in
      let (cursor, data) = try row.decode((Int64, Data).self)
      return FxJournalRecord(cursor: String(cursor), data: data)
    }
    return FxPersistenceSnapshot(
      checkpoint: checkpoint, journal: journal, head: head == 0 ? nil : String(head),
      completedTurnID: completed)
  }
  public func appendJournal(
    _ lease: FxSessionLease, expected: String?, key: String, data: Data, barrier: Bool = true,
    marks: [FxSessionJournalMark]? = nil
  ) async throws -> String {
    struct MarkedWrite: Encodable {
      let data: Data
      let marks: [FxSessionJournalMark]
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let identity = try marks.map { try encoder.encode(MarkedWrite(data: data, marks: $0)) } ?? data
    let digest = Data(SHA256.hash(data: identity))
    return try await leased(lease) { c in
      if let previous = try await rows(
        c,
        "SELECT cursor,digest FROM fx_pg_writes WHERE namespace=\(namespace) AND session_id=\(lease.sessionID) AND key=\(key)"
      ).first {
        let (cursor, priorDigest) = try previous.decode((Int64, Data).self)
        guard digest == priorDigest else { throw FxPersistenceError.fenced }
        return String(cursor)
      }
      guard
        let row = try await rows(
          c,
          "SELECT head FROM fx_pg_sessions WHERE namespace=\(namespace) AND session_id=\(lease.sessionID)"
        ).first
      else { throw FxSessionError.notFound }
      let head = try row.decode(Int64.self)
      guard expected == (head == 0 ? nil : String(head)) else { throw FxPersistenceError.fenced }
      guard head < Int64.max else { throw FxPersistenceError.sizeLimit }
      let cursor = head + 1
      let decodedMarks = try marks ?? FxSessionJournalMark.decode(data)
      try await applyMarks(decodedMarks, c: c, session: lease.sessionID)
      try await execute(
        c, "INSERT INTO fx_pg_records VALUES(\(namespace),\(lease.sessionID),\(cursor),\(data))")
      try await execute(
        c,
        "INSERT INTO fx_pg_writes VALUES(\(namespace),\(lease.sessionID),\(key),\(cursor),\(digest))"
      )
      try await execute(
        c,
        "UPDATE fx_pg_sessions SET head=\(cursor) WHERE namespace=\(namespace) AND session_id=\(lease.sessionID)"
      )
      return String(cursor)
    }
  }
  public func saveJournalCheckpoint(_ lease: FxSessionLease, _ checkpoint: FxStoredCheckpoint)
    async throws
  {
    guard let through = Int64(checkpoint.through), through > 0,
      String(through) == checkpoint.through
    else { throw FxPersistenceError.fenced }
    try await leased(lease) { c in
      guard
        let row = try await rows(
          c,
          "SELECT head,checkpoint_cursor,checkpoint FROM fx_pg_sessions WHERE namespace=\(namespace) AND session_id=\(lease.sessionID)"
        ).first
      else { throw FxSessionError.notFound }
      let (head, previous, data) = try row.decode((Int64, Int64?, Data?).self)
      guard through <= head, through >= (previous ?? 0) else { throw FxPersistenceError.fenced }
      if through == previous {
        guard data == checkpoint.data else { throw FxPersistenceError.fenced }
        return
      }
      try await execute(
        c,
        "UPDATE fx_pg_sessions SET checkpoint_cursor=\(through),checkpoint=\(checkpoint.data) WHERE namespace=\(namespace) AND session_id=\(lease.sessionID)"
      )
      try await execute(
        c,
        "DELETE FROM fx_pg_records WHERE namespace=\(namespace) AND session_id=\(lease.sessionID) AND cursor<=\(through)"
      )
    }
  }
  public func storeImage(_ data: Data, named name: String, lease: FxSessionLease) async throws {
    guard FxSessionStorageValidation.imageName(for: data) == name else {
      throw FxError.invalidInput("Image name does not match its bytes")
    }
    try await leased(lease) { c in
      try await execute(
        c,
        "INSERT INTO fx_pg_images VALUES(\(namespace),\(lease.sessionID),\(name),\(data)) ON CONFLICT DO NOTHING"
      )
    }
  }
  public func loadImage(named name: String, lease: FxSessionLease) async throws -> Data? {
    try await leased(lease) { c in try await readImage(c, session: lease.sessionID, name: name) }
  }
  public func loadImage(named name: String, session: String, agent: String) async throws -> Data? {
    try await transaction { c in
      try await checkAgent(c, session: session, agent: agent)
      return try await readImage(c, session: session, name: name)
    }
  }
  func readImage(_ c: PostgresConnection, session: String, name: String) async throws -> Data? {
    try await rows(
      c,
      "SELECT data FROM fx_pg_images WHERE namespace=\(namespace) AND session_id=\(session) AND name=\(name)"
    ).first?.decode(Data.self)
  }
}
