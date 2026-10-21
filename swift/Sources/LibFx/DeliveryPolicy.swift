import Foundation
import CSQLite

/// Limits each worker delivery while allowing the durable turn to continue.
public struct FxDeliveryPolicy: Sendable {
    public let maximumDuration: Duration
    public let reserve: Duration

    public init(maximumDuration: Duration, reserve: Duration = .seconds(30)) throws {
        guard maximumDuration >= .zero, reserve >= .zero else {
            throw FxError.invalidInput("Delivery durations must not be negative")
        }
        self.maximumDuration = maximumDuration
        self.reserve = reserve
    }

    func deadlines() -> (yield: Date, stop: ContinuousClock.Instant?) {
        let remaining = maximumDuration - reserve
        let seconds = Double(remaining.components.seconds) + Double(remaining.components.attoseconds) / 1e18
        let margin = min(.seconds(2), reserve / 2)
        return (Date().addingTimeInterval(seconds), margin > .zero && maximumDuration > margin
                ? .now.advanced(by: maximumDuration - margin) : nil)
    }
}

extension FxSessionStore {
    func deliveryCutoffs(_ lease: SessionLease, id: String) throws -> Int {
        try checkLease(lease)
        return try database.statement("SELECT CASE WHEN step IS cut_step THEN cutoffs ELSE 0 END FROM fx_inputs WHERE session=? AND id=?", [.text(lease.sessionID), .text(id)]) { statement in
            guard try database.step(statement) else { throw FxSessionError.notFound }
            return Int(sqlite3_column_int(statement, 0))
        }
    }

    func cutOffDelivery(_ lease: SessionLease, id: String) throws -> Int {
        try database.transaction {
            try checkLease(lease)
            try database.execute("UPDATE fx_inputs SET cutoffs=CASE WHEN step IS cut_step THEN cutoffs+1 ELSE 1 END,cut_step=step WHERE session=? AND id=? AND result IS NULL", [.text(lease.sessionID), .text(id)])
            return try deliveryCutoffs(lease, id: id)
        }
    }

    func recordDeliveryProgress(_ event: JSONValue, session: String) throws {
        guard event["type"] == .string("turn_progress") else { return }
        let steps: Int?
        if let count = event["steps"]?.integer { steps = count }
        else if case .array(let calls) = event["data"]?["execution"]?["tool_steps"] { steps = calls.count }
        else { steps = nil }
        guard let steps else { return }
        let step = "\(steps):\(event["data"]?["tool_state"]?.string ?? "none")"
        try database.execute("UPDATE fx_inputs SET step=? WHERE session=? AND target IS NULL AND started=1 AND result IS NULL", [.text(step), .text(session)])
    }
}
