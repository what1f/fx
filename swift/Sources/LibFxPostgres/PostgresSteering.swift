import Foundation
import LibFx
import PostgresNIO

extension FxPostgresStore {
  func steeringOwner(_ c: PostgresConnection, session: String) async throws -> String? {
    let active = try await rows(
      c,
      "SELECT id,ends FROM fx_pg_inputs WHERE namespace=\(namespace) AND session_id=\(session) AND target IS NULL AND started=TRUE AND cancelled=FALSE AND result IS NULL ORDER BY sequence LIMIT 1"
    ).first?.decode((String, Bool).self)
    if let active, !active.1 { return active.0 }
    return try await rows(
      c,
      "SELECT id FROM fx_pg_inputs WHERE namespace=\(namespace) AND session_id=\(session) AND target IS NULL AND started=FALSE AND result IS NULL ORDER BY sequence DESC LIMIT 1"
    ).first?.decode(String.self) ?? active?.0
  }
  func routePending(_ c: PostgresConnection, session: String) async throws {
    let pending = try await rows(
      c,
      "SELECT id,kind,content FROM fx_pg_inputs WHERE namespace=\(namespace) AND session_id=\(session) AND result IS NULL ORDER BY sequence"
    )
    try await execute(
      c,
      "UPDATE fx_pg_inputs SET ends=FALSE WHERE namespace=\(namespace) AND session_id=\(session) AND result IS NULL"
    )
    var owner: String?
    for row in pending {
      let (id, kind, data) = try row.decode((String, String, Data).self)
      let content = try JSONDecoder().decode([FxPromptContent].self, from: data)
      let joinable = content.allSatisfy { if case .text = $0 { true } else { false } }
      if kind == "steer", joinable, let owner {
        try await execute(
          c,
          "UPDATE fx_pg_inputs SET target=\(owner) WHERE namespace=\(namespace) AND session_id=\(session) AND id=\(id)"
        )
      } else {
        if kind == "steer", !joinable, let owner {
          try await execute(
            c,
            "UPDATE fx_pg_inputs SET ends=TRUE WHERE namespace=\(namespace) AND session_id=\(session) AND id=\(owner)"
          )
        }
        try await execute(
          c,
          "UPDATE fx_pg_inputs SET target=NULL WHERE namespace=\(namespace) AND session_id=\(session) AND id=\(id)"
        )
        owner = id
      }
    }
  }
  public func steering(_ lease: FxSessionLease, owner: String) async throws -> (
    pending: [FxSessionSteeringInput], ends: Bool
  ) {
    try await leased(lease) { c in
      let pending = try await rows(
        c,
        "SELECT id,content FROM fx_pg_inputs WHERE namespace=\(namespace) AND session_id=\(lease.sessionID) AND target=\(owner) AND accepted=FALSE AND result IS NULL ORDER BY sequence"
      ).map { row in
        let (id, data) = try row.decode((String, Data).self)
        let content = try JSONDecoder().decode([FxPromptContent].self, from: data)
        return FxSessionSteeringInput(
          id: id,
          text: content.compactMap { if case .text(let text) = $0 { text } else { nil } }.joined(
            separator: "\n"))
      }
      guard
        let row = try await rows(
          c,
          "SELECT ends FROM fx_pg_inputs WHERE namespace=\(namespace) AND session_id=\(lease.sessionID) AND id=\(owner)"
        ).first
      else { throw FxSessionError.notFound }
      return (pending, try row.decode(Bool.self))
    }
  }
  public func publicInputID(_ coreID: String, session: String) async throws -> String? {
    try await transaction { c in
      try await rows(
        c,
        "SELECT id FROM fx_pg_inputs WHERE namespace=\(namespace) AND session_id=\(session) AND core_id=\(coreID)"
      ).first?.decode(String.self)
    }
  }
  func applyMarks(_ marks: [FxSessionJournalMark], c: PostgresConnection, session: String)
    async throws
  {
    try FxSessionStorageValidation.validateMarks(marks)
    for mark in marks {
      switch mark {
      case .accepted(let id):
        try await execute(
          c,
          "UPDATE fx_pg_inputs SET accepted=TRUE WHERE namespace=\(namespace) AND session_id=\(session) AND core_id=\(id) AND kind='steer'"
        )
      case .withdrawn(let id):
        try await execute(
          c,
          "UPDATE fx_pg_inputs SET target=NULL,accepted=FALSE,placed=FALSE WHERE namespace=\(namespace) AND session_id=\(session) AND core_id=\(id) AND kind='steer' AND result IS NULL"
        )
      case .placed(let id):
        try await execute(
          c,
          "UPDATE fx_pg_inputs SET accepted=TRUE,placed=TRUE WHERE namespace=\(namespace) AND session_id=\(session) AND core_id=\(id) AND kind='steer'"
        )
      case .completed(let id):
        try await execute(
          c,
          "UPDATE fx_pg_sessions SET completed_turn=\(id) WHERE namespace=\(namespace) AND session_id=\(session)"
        )
      case .progress(let token):
        try await execute(
          c,
          "UPDATE fx_pg_inputs SET step=\(token) WHERE namespace=\(namespace) AND session_id=\(session) AND target IS NULL AND started=TRUE AND result IS NULL"
        )
      }
    }
  }
}
