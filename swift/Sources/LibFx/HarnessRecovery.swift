import Foundation
import CSQLite

/// A running turn lost its executor. A later delivery must open a new one.
public enum FxHarnessError: Error, Sendable, Equatable, LocalizedError {
    case stopped(String)
    public var errorDescription: String? {
        switch self { case .stopped(let message): message }
    }
}

public struct FxHarnessFailureState: Sendable, Equatable {
    public let stops: Int
    public let halted: Bool
    public init(stops: Int, halted: Bool) { self.stops = stops; self.halted = halted }
}

struct HarnessStopped: Error { let cause: any Error }
struct HarnessOpeningFailure: Error { let cause: any Error }

func harnessTurnOperation<Value: Sendable>(isolation: isolated (any Actor)? = #isolation,
    _ operation: () async throws -> Value) async throws -> Value {
    do { return try await operation() }
    catch let error as SessionStorageFailure { throw error }
    catch let error as FxPersistenceError { throw error }
    catch let error as FxSQLiteError { throw error }
    catch let error as FxSessionError { throw error }
    catch { throw HarnessStopped(cause: error) }
}

extension FxSessionStore {
    public func harnessFailureState(_ lease: FxSessionLease, id: String) throws -> FxHarnessFailureState {
        try database.transaction(mode: "DEFERRED") {
            try checkLease(lease)
            return try readHarnessFailureState(lease, id: id)
        }
    }

    private func readHarnessFailureState(_ lease: FxSessionLease, id: String) throws -> FxHarnessFailureState {
        try database.statement("SELECT i.stops,s.halted FROM fx_inputs i JOIN fx_sessions s ON s.id=i.session WHERE i.session=? AND i.id=?", [.text(lease.sessionID), .text(id)]) { row in
            guard try database.step(row) else { throw FxSessionError.notFound }
            return FxHarnessFailureState(stops: Int(sqlite3_column_int64(row, 0)), halted: sqlite3_column_int(row, 1) != 0)
        }
    }

    public func recordHarnessStop(_ lease: FxSessionLease, id: String) throws -> Int {
        try database.transaction {
            try checkLease(lease)
            try database.execute("UPDATE fx_inputs SET stops=MIN(stops+1,5),stop_epoch=? WHERE session=? AND id=? AND stop_epoch<>?", [.integer(lease.epoch), .text(lease.sessionID), .text(id), .integer(lease.epoch)])
            try database.execute("UPDATE fx_sessions SET recovery_input=? WHERE id=?", [.text(id), .text(lease.sessionID)])
            return try readHarnessFailureState(lease, id: id).stops
        }
    }

    public func halt(_ lease: FxSessionLease) throws {
        try database.transaction {
            try checkLease(lease)
            try database.execute("UPDATE fx_sessions SET halted=1 WHERE id=?", [.text(lease.sessionID)])
        }
    }

    /// Includes completed inputs whose physical execution still needs cancellation.
    public func input(_ lease: FxSessionLease, id: String) throws -> FxSessionInput? {
        try database.transaction(mode: "DEFERRED") {
            try checkLease(lease)
            return try database.statement("SELECT content,options,started,cancelled FROM fx_inputs WHERE session=? AND id=?", [.text(lease.sessionID), .text(id)]) { row in
                guard try database.step(row) else { return nil }
                return FxSessionInput(id: id,
                    content: try JSONDecoder().decode([FxPromptContent].self, from: database.bytes(row, column: 0)),
                    options: try JSONDecoder().decode(FxSessionOptions.self, from: database.bytes(row, column: 1)),
                    wasStarted: sqlite3_column_int(row, 2) != 0, cancelRequested: sqlite3_column_int(row, 3) != 0)
            }
        }
    }

    public func harnessRecoveryInput(_ lease: FxSessionLease) throws -> FxSessionInput? {
        try checkLease(lease)
        let id = try database.statement("SELECT recovery_input FROM fx_sessions WHERE id=?", [.text(lease.sessionID)]) { row -> String? in
            guard try database.step(row), sqlite3_column_type(row, 0) != SQLITE_NULL else { return nil }
            return database.text(row, column: 0)
        }
        return try id.flatMap { try input(lease, id: $0) }
    }

    public func setHarnessRecoveryInput(_ lease: FxSessionLease, id: String?) throws {
        try database.transaction {
            try checkLease(lease)
            if let id, try inputExists(lease, id: id) == false { throw FxSessionError.notFound }
            try database.execute("UPDATE fx_sessions SET recovery_input=? WHERE id=?", [id.map(SQLiteDatabase.Value.text) ?? .null, .text(lease.sessionID)])
        }
    }

    private func inputExists(_ lease: FxSessionLease, id: String) throws -> Bool {
        try database.statement("SELECT 1 FROM fx_inputs WHERE session=? AND id=?", [.text(lease.sessionID), .text(id)]) { try database.step($0) }
    }
}
