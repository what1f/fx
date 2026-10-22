import Foundation
import CSQLite

// The actor owns all access. FULLMUTEX also protects SQLite during connection teardown.
final class SQLiteDatabase: @unchecked Sendable {
    enum Value { case text(String), blob(Data), integer(Int64), null }
    private var handle: OpaquePointer?

    init(path: String) throws {
        let code = sqlite3_open_v2(path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil)
        guard code == SQLITE_OK else {
            let failure = error(code)
            if let handle { sqlite3_close_v2(handle) }
            handle = nil
            throw failure
        }
        sqlite3_extended_result_codes(handle, 1)
        sqlite3_busy_timeout(handle, 1_000)
    }

    deinit { if let handle { sqlite3_close_v2(handle) } }

    func enableWriteAheadLogging() throws {
        guard let handle else { throw FxSQLiteError.closed }
        // Concurrent mode changes can return BUSY without invoking SQLite's busy handler.
        // Retry only this initialization operation, within the existing one-second budget.
        let deadline = ContinuousClock.now.advanced(by: .seconds(1))
        sqlite3_busy_timeout(handle, 0)
        defer { sqlite3_busy_timeout(handle, 1_000) }
        while true {
            do {
                try execute("PRAGMA journal_mode=WAL")
                return
            } catch let failure as FxSQLiteError {
                guard case .database(let code, _) = failure,
                      code & 0xff == SQLITE_BUSY, ContinuousClock.now < deadline else { throw failure }
                try Task.checkCancellation()
                sqlite3_sleep(1)
            }
        }
    }

    func close() throws {
        guard let handle else { return }
        let code = sqlite3_close(handle)
        guard code == SQLITE_OK else { throw error(code) }
        self.handle = nil
    }

    func statement<T>(_ sql: String, _ values: [Value] = [], _ body: (OpaquePointer) throws -> T) throws -> T {
        guard let handle else { throw FxSQLiteError.closed }
        var prepared: OpaquePointer?
        let code = sqlite3_prepare_v2(handle, sql, -1, &prepared, nil)
        guard code == SQLITE_OK, let prepared else { throw error(code) }
        defer { sqlite3_finalize(prepared) }
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            let result: Int32
            switch value {
            case .null: result = sqlite3_bind_null(prepared, index)
            case .integer(let number): result = sqlite3_bind_int64(prepared, index, number)
            case .text(let text):
                guard let count = Int32(exactly: text.utf8.count) else { throw FxPersistenceError.sizeLimit }
                result = text.withCString { fx_sqlite_bind_string(prepared, index, $0, count) }
            case .blob(let data):
                guard let count = Int32(exactly: data.count) else { throw FxPersistenceError.sizeLimit }
                result = data.withUnsafeBytes { fx_sqlite_bind_bytes(prepared, index, $0.baseAddress, count) }
            }
            guard result == SQLITE_OK else { throw error(result) }
        }
        return try body(prepared)
    }

    func step(_ statement: OpaquePointer) throws -> Bool {
        let code = sqlite3_step(statement)
        switch code {
        case SQLITE_ROW: return true
        case SQLITE_DONE: return false
        default: throw error(code)
        }
    }

    func execute(_ sql: String, _ values: [Value] = []) throws {
        try statement(sql, values) { statement in while try step(statement) {} }
    }

    func transaction<T>(mode: String = "IMMEDIATE", _ body: () throws -> T) throws -> T {
        try execute("BEGIN \(mode)")
        do {
            let value = try body()
            try execute("COMMIT")
            return value
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    func bytes(_ statement: OpaquePointer, column: Int32) -> Data {
        let count = Int(sqlite3_column_bytes(statement, column))
        guard count > 0, let pointer = sqlite3_column_blob(statement, column) else { return Data() }
        return Data(bytes: pointer, count: count)
    }

    func text(_ statement: OpaquePointer, column: Int32) -> String {
        guard let pointer = sqlite3_column_text(statement, column) else { return "" }
        return String(cString: pointer)
    }

    private func error(_ code: Int32) -> FxSQLiteError {
        .database(code: code, message: handle.map { String(cString: sqlite3_errmsg($0)) } ?? "Could not open persistence store")
    }
}
