import Foundation
import LibFx
import PostgresNIO

extension FxPostgresStore {
  public func accept(
    session: String, agent: String, id: String, content: [FxPromptContent],
    options: FxSessionOptions, checkpoint: Data? = nil, steering: Bool = false,
    deferringImageLimits: Bool = false
  ) async throws -> Bool {
    try FxSessionStorageValidation.validateInput(
      sessionID: session, inputID: id, content: content, options: options,
      deferringImageLimits: deferringImageLimits)
    let data = try JSONEncoder().encode(content)
    let settings = try JSONEncoder().encode(options)
    return try await transaction { c in
      let created = try await rows(
        c,
        "INSERT INTO fx_pg_sessions(namespace,session_id,agent) VALUES(\(namespace),\(session),\(agent)) ON CONFLICT DO NOTHING RETURNING session_id"
      )
      try await checkAgent(c, session: session, agent: agent)
      if !created.isEmpty, let checkpoint {
        try await execute(
          c,
          "UPDATE fx_pg_sessions SET head=1,checkpoint_cursor=1,checkpoint=\(checkpoint) WHERE namespace=\(namespace) AND session_id=\(session)"
        )
      }
      let kind = steering ? "steer" : "prompt"
      if let previous = try await rows(
        c,
        "SELECT kind FROM fx_pg_inputs WHERE namespace=\(namespace) AND session_id=\(session) AND id=\(id)"
      ).first {
        guard try previous.decode(String.self) == kind else { throw FxSessionError.messageIDInUse }
        return true
      }
      try FxSessionStorageValidation.validateInput(
        sessionID: session, inputID: id, content: content, options: options, steering: steering,
        deferringImageLimits: deferringImageLimits)
      let owner = steering ? try await steeringOwner(c, session: session) : nil
      let joinable = content.allSatisfy { if case .text = $0 { true } else { false } }
      if steering, !joinable, let owner {
        try await execute(
          c,
          "UPDATE fx_pg_inputs SET ends=TRUE WHERE namespace=\(namespace) AND session_id=\(session) AND id=\(owner)"
        )
      }
      let target: String? = steering && joinable ? owner : nil
      let core = FxSessionInput.runtimeID(for: id)
      try await execute(
        c,
        "INSERT INTO fx_pg_inputs(namespace,session_id,id,content,options,kind,target,core_id) VALUES(\(namespace),\(session),\(id),\(data),\(settings),\(kind),\(target),\(core))"
      )
      try await postgresEnqueueWake(
        connection: c, namespace: namespace,
        wakeup: FxSessionWakeup(agent: agent, sessionID: session))
      return false
    }
  }
  public func resumePoint(session: String, agent: String) async throws -> (
    id: String, cursor: Int64
  )? {
    try await transaction { c in
      try await checkAgent(c, session: session, agent: agent)
      guard
        let row = try await rows(
          c,
          "SELECT i.id,s.event_head FROM fx_pg_inputs i JOIN fx_pg_sessions s USING(namespace,session_id) WHERE i.namespace=\(namespace) AND i.session_id=\(session) AND i.result IS NULL ORDER BY i.sequence LIMIT 1"
        ).first
      else { return nil }
      return try row.decode((String, Int64).self)
    }
  }
  public func hasWork(session: String, agent: String) async throws -> Bool {
    try await resumePoint(session: session, agent: agent) != nil
  }
  func decodeInput(_ row: PostgresRow) throws -> FxSessionInput {
    let (id, content, options, started, cancelled) = try row.decode(
      (String, Data, Data, Bool, Bool).self)
    return FxSessionInput(
      id: id, content: try JSONDecoder().decode([FxPromptContent].self, from: content),
      options: try JSONDecoder().decode(FxSessionOptions.self, from: options), wasStarted: started,
      cancelRequested: cancelled)
  }
  public func next(_ lease: FxSessionLease) async throws -> FxSessionInput? {
    try await leased(lease) { c in
      try await rows(
        c,
        "SELECT id,content,options,started,cancelled FROM fx_pg_inputs WHERE namespace=\(namespace) AND session_id=\(lease.sessionID) AND result IS NULL AND target IS NULL ORDER BY sequence LIMIT 1"
      ).first.map(decodeInput)
    }
  }
  public func input(_ lease: FxSessionLease, id: String) async throws -> FxSessionInput? {
    try await leased(lease) { c in try await readInput(c, session: lease.sessionID, id: id) }
  }
  func readInput(_ c: PostgresConnection, session: String, id: String) async throws
    -> FxSessionInput?
  {
    try await rows(
      c,
      "SELECT id,content,options,started,cancelled FROM fx_pg_inputs WHERE namespace=\(namespace) AND session_id=\(session) AND id=\(id)"
    ).first.map(decodeInput)
  }
  public func start(_ lease: FxSessionLease, input: FxSessionInput) async throws {
    try await leased(lease) { c in
      try await execute(
        c,
        "UPDATE fx_pg_inputs SET started=TRUE WHERE namespace=\(namespace) AND session_id=\(lease.sessionID) AND id=\(input.id)"
      )
      try await insertEvent(
        c, lease: lease,
        event: input.wasStarted
          ? .resumed(id: input.id, sessionID: lease.sessionID)
          : .started(id: input.id, sessionID: lease.sessionID, input: input.content))
    }
  }
  func insertEvent(_ c: PostgresConnection, lease: FxSessionLease, event: FxSessionEvent)
    async throws
  {
    guard
      let row = try await rows(
        c,
        "UPDATE fx_pg_sessions SET event_head=event_head+1 WHERE namespace=\(namespace) AND session_id=\(lease.sessionID) AND event_head<9223372036854775807 RETURNING event_head"
      ).first
    else { throw FxPersistenceError.sizeLimit }
    let cursor = try row.decode(Int64.self)
    let data = try JSONEncoder().encode(event)
    try await execute(
      c,
      "INSERT INTO fx_pg_events VALUES(\(namespace),\(lease.sessionID),\(cursor),\(lease.epoch),\(data))"
    )
  }
  public func appendEvent(_ lease: FxSessionLease, _ event: FxSessionEvent) async throws {
    try await leased(lease) { c in try await insertEvent(c, lease: lease, event: event) }
  }
  public func finish(_ lease: FxSessionLease, id: String, result: FxSessionResult) async throws {
    guard result.id == id, result.epoch == lease.epoch, !result.isRepeated else {
      throw FxPersistenceError.invalidJournal
    }
    try await leased(lease) { c in
      guard
        let row = try await rows(
          c,
          "SELECT result FROM fx_pg_inputs WHERE namespace=\(namespace) AND session_id=\(lease.sessionID) AND id=\(id)"
        ).first
      else { throw FxSessionError.notFound }
      if let data = try row.decode(Data?.self) {
        guard try JSONDecoder().decode(FxSessionResult.self, from: data) == result else {
          throw FxPersistenceError.fenced
        }
        return
      }
      try await insertEvent(c, lease: lease, event: .ended(result))
      let data = try JSONEncoder().encode(result)
      try await execute(
        c,
        "UPDATE fx_pg_inputs SET result=\(data) WHERE namespace=\(namespace) AND session_id=\(lease.sessionID) AND id=\(id)"
      )
      let joined = try await rows(
        c,
        "SELECT id FROM fx_pg_inputs WHERE namespace=\(namespace) AND session_id=\(lease.sessionID) AND target=\(id) AND accepted=TRUE AND result IS NULL"
      )
      for row in joined {
        let joinedID = try row.decode(String.self)
        let joinedData = try JSONEncoder().encode(
          FxSessionResult(
            id: joinedID, stopReason: result.stopReason, failure: result.failure,
            epoch: result.epoch))
        try await execute(
          c,
          "UPDATE fx_pg_inputs SET result=\(joinedData) WHERE namespace=\(namespace) AND session_id=\(lease.sessionID) AND id=\(joinedID)"
        )
      }
      try await routePending(c, session: lease.sessionID)
    }
  }
  public func cancel(session: String, agent: String, id: String? = nil) async throws {
    try await transaction { c in
      try await checkAgent(c, session: session, agent: agent)
      if let id {
        try await execute(
          c,
          "UPDATE fx_pg_inputs SET cancelled=TRUE WHERE namespace=\(namespace) AND session_id=\(session) AND id=\(id) AND result IS NULL"
        )
      } else {
        try await execute(
          c,
          "UPDATE fx_pg_inputs SET cancelled=TRUE WHERE sequence=(SELECT sequence FROM fx_pg_inputs WHERE namespace=\(namespace) AND session_id=\(session) AND started=TRUE AND result IS NULL ORDER BY sequence LIMIT 1)"
        )
      }
      try await postgresEnqueueWake(
        connection: c, namespace: namespace,
        wakeup: FxSessionWakeup(agent: agent, sessionID: session))
    }
  }
  public func cancelled(_ lease: FxSessionLease, id: String) async throws -> Bool {
    try await leased(lease) { c in
      guard
        let row = try await rows(
          c,
          "SELECT cancelled FROM fx_pg_inputs WHERE namespace=\(namespace) AND session_id=\(lease.sessionID) AND id=\(id)"
        ).first
      else { throw FxSessionError.notFound }
      return try row.decode(Bool.self)
    }
  }
  public func result(session: String, agent: String, id: String) async throws -> FxSessionResult? {
    try await transaction { c in
      try await checkAgent(c, session: session, agent: agent)
      guard
        let row = try await rows(
          c,
          "SELECT result FROM fx_pg_inputs WHERE namespace=\(namespace) AND session_id=\(session) AND id=\(id)"
        ).first
      else { throw FxSessionError.notFound }
      return try row.decode(Data?.self).map {
        try JSONDecoder().decode(FxSessionResult.self, from: $0)
      }
    }
  }
  public func entries(session: String, agent: String, after cursor: Int64) async throws
    -> [FxSessionEntry]
  {
    guard cursor >= 0 else { throw FxSessionError.invalidCursor }
    return try await transaction { c in
      try await checkAgent(c, session: session, agent: agent)
      return try await rows(
        c,
        "SELECT cursor,epoch,data FROM fx_pg_events WHERE namespace=\(namespace) AND session_id=\(session) AND cursor>\(cursor) ORDER BY cursor LIMIT 128"
      ).map { row in
        let (cursor, epoch, data) = try row.decode((Int64, Int64, Data).self)
        return FxSessionEntry(
          cursor: cursor, epoch: epoch,
          event: try JSONDecoder().decode(FxSessionEvent.self, from: data))
      }
    }
  }
}
