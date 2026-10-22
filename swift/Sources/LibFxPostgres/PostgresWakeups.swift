import LibFx
import Logging
import PostgresNIO

/// Used inside the storage transaction, so accepted work survives producer exit
/// before the public enqueue call. The caller drains this statement before commit.
func postgresEnqueueWake(connection: PostgresConnection, namespace: String, wakeup: FxSessionWakeup) async throws {
    _ = try await postgresRows(connection, """
        INSERT INTO fx_pg_wakes(namespace, agent, session_id, generation, visible_at, attempts)
        VALUES (\(namespace), \(wakeup.agent), \(wakeup.sessionID), 1, clock_timestamp(), 0)
        ON CONFLICT (namespace, agent, session_id) DO UPDATE
        SET generation = fx_pg_wakes.generation + 1,
            visible_at = CASE WHEN fx_pg_wakes.receipt IS NULL THEN clock_timestamp() ELSE fx_pg_wakes.visible_at END
        """, logger: Logger(label: "LibFxPostgres.Queue"))
}
