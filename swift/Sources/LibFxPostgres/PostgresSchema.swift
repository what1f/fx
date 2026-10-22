import Foundation
import LibFx
import PostgresNIO

extension FxPostgresStore {
  /// Creates the versioned relational schema. The caller runs the shared client pool.
  public func migrate() async throws {
    try await transaction { connection in
      try await self.execute(connection, "SELECT pg_advisory_xact_lock(4611208206341)")
      try await self.execute(
        connection,
        "CREATE TABLE IF NOT EXISTS fx_pg_schema(id INTEGER PRIMARY KEY CHECK(id=1), version INTEGER NOT NULL)"
      )
      try await self.execute(
        connection, "INSERT INTO fx_pg_schema VALUES(1,1) ON CONFLICT DO NOTHING")
      let versions = try await self.rows(connection, "SELECT version FROM fx_pg_schema WHERE id=1")
      guard try versions.first?.decode(Int.self) == 1 else {
        throw FxPersistenceError.invalidJournal
      }
      try await self.execute(
        connection,
        """
        CREATE TABLE IF NOT EXISTS fx_pg_sessions(
            namespace TEXT NOT NULL, session_id TEXT NOT NULL, agent TEXT NOT NULL,
            epoch BIGINT NOT NULL DEFAULT 0, owner TEXT, lease_until TIMESTAMPTZ,
            head BIGINT NOT NULL DEFAULT 0, checkpoint_cursor BIGINT, checkpoint BYTEA,
            completed_turn TEXT, halted BOOLEAN NOT NULL DEFAULT FALSE, recovery_input TEXT,
            event_head BIGINT NOT NULL DEFAULT 0, PRIMARY KEY(namespace,session_id))
        """)
      try await self.execute(
        connection,
        """
        CREATE TABLE IF NOT EXISTS fx_pg_inputs(
            namespace TEXT NOT NULL, session_id TEXT NOT NULL, id TEXT NOT NULL,
            sequence BIGSERIAL, content BYTEA NOT NULL, options BYTEA NOT NULL,
            kind TEXT NOT NULL, target TEXT, core_id TEXT NOT NULL,
            started BOOLEAN NOT NULL DEFAULT FALSE, cancelled BOOLEAN NOT NULL DEFAULT FALSE,
            result BYTEA, accepted BOOLEAN NOT NULL DEFAULT FALSE, placed BOOLEAN NOT NULL DEFAULT FALSE,
            ends BOOLEAN NOT NULL DEFAULT FALSE, step TEXT, cut_step TEXT,
            cutoffs BIGINT NOT NULL DEFAULT 0, stops BIGINT NOT NULL DEFAULT 0, stop_epoch BIGINT NOT NULL DEFAULT 0,
            PRIMARY KEY(namespace,session_id,id), UNIQUE(namespace,session_id,core_id),
            FOREIGN KEY(namespace,session_id) REFERENCES fx_pg_sessions(namespace,session_id))
        """)
      try await self.execute(
        connection,
        "CREATE INDEX IF NOT EXISTS fx_pg_inputs_order ON fx_pg_inputs(namespace,session_id,sequence)"
      )
      try await self.execute(
        connection,
        "CREATE TABLE IF NOT EXISTS fx_pg_events(namespace TEXT NOT NULL,session_id TEXT NOT NULL,cursor BIGINT NOT NULL,epoch BIGINT NOT NULL,data BYTEA NOT NULL,PRIMARY KEY(namespace,session_id,cursor))"
      )
      try await self.execute(
        connection,
        "CREATE TABLE IF NOT EXISTS fx_pg_records(namespace TEXT NOT NULL,session_id TEXT NOT NULL,cursor BIGINT NOT NULL,data BYTEA NOT NULL,PRIMARY KEY(namespace,session_id,cursor))"
      )
      try await self.execute(
        connection,
        "CREATE TABLE IF NOT EXISTS fx_pg_writes(namespace TEXT NOT NULL,session_id TEXT NOT NULL,key TEXT NOT NULL,cursor BIGINT NOT NULL,digest BYTEA NOT NULL,PRIMARY KEY(namespace,session_id,key))"
      )
      try await self.execute(
        connection,
        "CREATE TABLE IF NOT EXISTS fx_pg_images(namespace TEXT NOT NULL,session_id TEXT NOT NULL,name TEXT NOT NULL,data BYTEA NOT NULL,PRIMARY KEY(namespace,session_id,name))"
      )
      try await self.execute(
        connection,
        """
        CREATE TABLE IF NOT EXISTS fx_pg_wakes(namespace TEXT NOT NULL,agent TEXT NOT NULL,session_id TEXT NOT NULL,
            generation BIGINT NOT NULL DEFAULT 1,visible_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
            receipt TEXT,claimed_generation BIGINT,receipt_until TIMESTAMPTZ,attempts BIGINT NOT NULL DEFAULT 0,
            PRIMARY KEY(namespace,agent,session_id))
        """)
      try await self.execute(
        connection,
        "CREATE INDEX IF NOT EXISTS fx_pg_wakes_ready ON fx_pg_wakes(namespace,visible_at)")
    }
  }
}
