import Foundation
import LibFx
import Logging
import PostgresNIO

public enum FxPostgresQueueError: Error, Sendable, Equatable {
    /// Another consumer owns this delivery, or its visibility has expired.
    case fenced
}

/// A leased wakeup. Keep this value until it is completed or scheduled for retry.
public struct FxPostgresQueueDelivery: Sendable {
    public let wakeup: FxSessionWakeup
    public let attempt: Int64
    let receipt: String
    let generation: Int64
}

/// Durable wakeups in the same database and namespace as `FxPostgresStore`.
/// The caller owns the client and runs its connection pool. Call the store's
/// migration before using this queue. This queue never closes the client.
public struct FxPostgresQueue: FxSessionQueue, Sendable {
    let client: PostgresClient
    public let namespace: String
    public let visibilityDuration: Duration
    public let renewalInterval: Duration
    let visibilityMilliseconds: Int64
    private let logger = Logger(label: "LibFxPostgres.Queue")

    public init(client: PostgresClient, namespace: String = "default", visibilityDuration: Duration = .seconds(30),
                renewalInterval: Duration? = nil) throws {
        let interval = renewalInterval ?? visibilityDuration / 3
        guard !namespace.isEmpty, namespace.utf8.count <= 255, !namespace.utf8.contains(0),
              interval > .zero, interval < visibilityDuration else {
            throw FxError.invalidInput("Queue configuration is invalid")
        }
        self.visibilityMilliseconds = try postgresQueueMilliseconds(visibilityDuration)
        self.client = client
        self.namespace = namespace
        self.visibilityDuration = visibilityDuration
        self.renewalInterval = interval
    }

    public func enqueue(_ wakeup: FxSessionWakeup) async throws {
        try await receiptTransaction { connection in
            try await postgresEnqueueWake(connection: connection, namespace: namespace, wakeup: wakeup)
        }
    }

    /// Claims one available wakeup without holding a connection during execution.
    public func receive() async throws -> FxPostgresQueueDelivery? {
        try await receiptTransaction { connection in
        let receipt = UUID().uuidString
        let rows = try await postgresRows(connection, """
            WITH candidate AS (
                SELECT namespace, agent, session_id FROM fx_pg_wakes
                WHERE namespace = \(namespace) AND visible_at <= clock_timestamp()
                  AND (receipt IS NULL OR receipt_until <= clock_timestamp())
                ORDER BY visible_at, agent, session_id
                FOR UPDATE SKIP LOCKED LIMIT 1
            )
            UPDATE fx_pg_wakes AS w SET receipt = \(receipt), claimed_generation = w.generation,
                receipt_until = clock_timestamp() + \(visibilityMilliseconds) * INTERVAL '1 millisecond',
                attempts = w.attempts + 1
            FROM candidate AS c
            WHERE w.namespace = c.namespace AND w.agent = c.agent AND w.session_id = c.session_id
            RETURNING w.agent, w.session_id, w.claimed_generation, w.attempts
            """, logger: logger)
        var delivery: FxPostgresQueueDelivery?
        for row in rows {
            let (agent, session, generation, attempt) = try row.decode((String, String, Int64, Int64).self)
            delivery = FxPostgresQueueDelivery(wakeup: FxSessionWakeup(agent: agent, sessionID: session),
                attempt: attempt, receipt: receipt, generation: generation)
        }
        return delivery
        }
    }

    /// Extends only a currently live receipt. An expired receipt cannot be revived.
    public func renew(_ delivery: FxPostgresQueueDelivery) async throws {
        try await receiptTransaction { connection in
            try await lockReceipt(delivery, connection: connection)
            let rows = try await postgresRows(connection, """
                UPDATE fx_pg_wakes SET receipt_until = clock_timestamp() + \(visibilityMilliseconds) * INTERVAL '1 millisecond'
                WHERE namespace = \(namespace) AND agent = \(delivery.wakeup.agent) AND session_id = \(delivery.wakeup.sessionID)
                  AND receipt = \(delivery.receipt) AND claimed_generation = \(delivery.generation)
                  AND receipt_until > clock_timestamp()
                RETURNING generation
                """, logger: logger)
            var changed = false
            for _ in rows { changed = true }
            guard changed else { throw FxPostgresQueueError.fenced }
        }
    }

    /// Confirms this generation. A newer wakeup accepted during execution remains ready.
    public func complete(_ delivery: FxPostgresQueueDelivery) async throws {
        try await receiptTransaction { connection in
            let rows = try await postgresRows(connection, """
                SELECT generation FROM fx_pg_wakes
                WHERE namespace = \(namespace) AND agent = \(delivery.wakeup.agent) AND session_id = \(delivery.wakeup.sessionID)
                  AND receipt = \(delivery.receipt) AND claimed_generation = \(delivery.generation)
                  AND receipt_until > clock_timestamp()
                FOR UPDATE
                """, logger: logger)
            var current: Int64?
            for row in rows { current = try row.decode(Int64.self) }
            guard let current else { throw FxPostgresQueueError.fenced }
            let query: PostgresQuery
            if current == delivery.generation {
                query = """
                    DELETE FROM fx_pg_wakes WHERE namespace = \(namespace) AND agent = \(delivery.wakeup.agent)
                        AND session_id = \(delivery.wakeup.sessionID) AND receipt = \(delivery.receipt)
                        AND receipt_until > clock_timestamp() RETURNING generation
                    """
            } else {
                query = """
                    UPDATE fx_pg_wakes SET receipt = NULL, claimed_generation = NULL, receipt_until = NULL,
                        visible_at = clock_timestamp()
                    WHERE namespace = \(namespace) AND agent = \(delivery.wakeup.agent)
                        AND session_id = \(delivery.wakeup.sessionID) AND receipt = \(delivery.receipt)
                        AND receipt_until > clock_timestamp() RETURNING generation
                    """
            }
            let changed = try await postgresRows(connection, query, logger: logger)
            var confirmed = false
            for _ in changed { confirmed = true }
            guard confirmed else { throw FxPostgresQueueError.fenced }
        }
    }

    /// Retains the wakeup and makes it available after the requested delay.
    public func retry(_ delivery: FxPostgresQueueDelivery, after delay: Duration) async throws {
        let milliseconds = try postgresQueueMilliseconds(delay, allowingZero: true)
        try await receiptTransaction { connection in
            try await lockReceipt(delivery, connection: connection)
            let rows = try await postgresRows(connection, """
                UPDATE fx_pg_wakes SET receipt = NULL, claimed_generation = NULL, receipt_until = NULL,
                    visible_at = CASE WHEN generation <> \(delivery.generation) THEN clock_timestamp()
                        ELSE clock_timestamp() + \(milliseconds) * INTERVAL '1 millisecond' END
                WHERE namespace = \(namespace) AND agent = \(delivery.wakeup.agent) AND session_id = \(delivery.wakeup.sessionID)
                  AND receipt = \(delivery.receipt) AND claimed_generation = \(delivery.generation)
                  AND receipt_until > clock_timestamp()
                RETURNING generation
                """, logger: logger)
            var changed = false
            for _ in rows { changed = true }
            guard changed else { throw FxPostgresQueueError.fenced }
        }
    }

    private func receiptTransaction<Value: Sendable>(
        _ body: @escaping @Sendable (PostgresConnection) async throws -> Value
    ) async throws -> Value {
        try await postgresTransaction(client: client, logger: logger, body)
    }

    private func lockReceipt(_ delivery: FxPostgresQueueDelivery, connection: PostgresConnection) async throws {
        // Lock first, then evaluate expiry in the following mutation. A predicate
        // evaluated before waiting for a row lock must not revive an expired grant.
        let rows = try await postgresRows(connection, """
            SELECT generation FROM fx_pg_wakes
            WHERE namespace = \(namespace) AND agent = \(delivery.wakeup.agent) AND session_id = \(delivery.wakeup.sessionID)
                AND receipt = \(delivery.receipt) AND claimed_generation = \(delivery.generation)
            FOR UPDATE
            """, logger: logger)
        var found = false
        for _ in rows { found = true }
        guard found else { throw FxPostgresQueueError.fenced }
    }
}

func postgresQueueMilliseconds(_ duration: Duration, allowingZero: Bool = false) throws -> Int64 {
    let parts = duration.components
    guard duration >= (allowingZero ? .zero : .milliseconds(1)), parts.seconds < Int64.max / 1_000 else {
        throw FxError.invalidInput("Queue duration is invalid")
    }
    return parts.seconds * 1_000 + (parts.attoseconds + 999_999_999_999_999) / 1_000_000_000_000_000
}
