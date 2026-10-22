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

private enum EnginePreparation: Sendable {
    case opened(FxEngine)
    case failed(any Error)
    case timedOut
}

func openSessionEngine(configuration: FxConfiguration, sessionID: String,
                       persistence: any FxPersistence, deadline: ContinuousClock.Instant?) async throws -> FxEngine {
    guard let deadline else {
        return try await FxEngine.open(configuration: configuration, sessionID: sessionID, persistence: persistence)
    }
    try Task.checkCancellation()
    guard ContinuousClock.now < deadline else { throw FxSessionError.preparationTimedOut }
    return try await withThrowingTaskGroup(of: EnginePreparation.self) { group in
        group.addTask {
            do { return .opened(try await FxEngine.open(configuration: configuration, sessionID: sessionID, persistence: persistence)) }
            catch { return .failed(error) }
        }
        group.addTask {
            do { try await Task.sleep(until: deadline, clock: .continuous); return .timedOut }
            catch { return .failed(error) }
        }
        let first = try await group.next()!
        group.cancelAll()
        // An open can finish at the same time as the timer. Join both tasks and
        // close any engine whose result the caller will not receive.
        for try await remaining in group {
            if case .opened(let engine) = remaining { try? await engine.close() }
        }
        switch first {
        case .opened(let engine):
            if Task.isCancelled { try? await engine.close(); throw CancellationError() }
            return engine
        case .failed(let error): throw error
        case .timedOut:
            try Task.checkCancellation()
            throw FxSessionError.preparationTimedOut
        }
    }
}

extension FxSessionStore {
    public func deliveryCutoffs(_ lease: FxSessionLease, id: String) throws -> Int {
        try checkLease(lease)
        return try database.statement("SELECT CASE WHEN step IS cut_step THEN cutoffs ELSE 0 END FROM fx_inputs WHERE session=? AND id=?", [.text(lease.sessionID), .text(id)]) { statement in
            guard try database.step(statement) else { throw FxSessionError.notFound }
            return Int(sqlite3_column_int(statement, 0))
        }
    }

    public func cutOffDelivery(_ lease: FxSessionLease, id: String) throws -> Int {
        try database.transaction {
            try checkLease(lease)
            try database.execute("UPDATE fx_inputs SET cutoffs=CASE WHEN step IS cut_step THEN cutoffs+1 ELSE 1 END,cut_step=step WHERE session=? AND id=? AND result IS NULL", [.text(lease.sessionID), .text(id)])
            return try deliveryCutoffs(lease, id: id)
        }
    }

}
