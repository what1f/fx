import Foundation
import CSQLite

public struct FxSessionSteeringInput: Sendable {
    public let id: String
    public let text: String
    public init(id: String, text: String) { self.id = id; self.text = text }
}

extension FxSessionStore {
    func steeringOwner(session: String) throws -> String? {
        let active = try database.statement("SELECT id,ends FROM fx_inputs WHERE session=? AND target IS NULL AND started=1 AND cancelled=0 AND result IS NULL ORDER BY sequence LIMIT 1", [.text(session)]) { statement -> (String, Bool)? in
            guard try database.step(statement) else { return nil }
            return (database.text(statement, column: 0), sqlite3_column_int(statement, 1) != 0)
        }
        if let active, !active.1 { return active.0 }
        return try database.statement("SELECT id FROM fx_inputs WHERE session=? AND target IS NULL AND started=0 AND result IS NULL ORDER BY sequence DESC LIMIT 1", [.text(session)]) { statement in
            guard try database.step(statement) else { return active?.0 }
            return database.text(statement, column: 0)
        }
    }

    public func steering(_ lease: FxSessionLease, owner: String) throws -> (pending: [FxSessionSteeringInput], ends: Bool) {
        try database.transaction(mode: "DEFERRED") {
            try checkLease(lease)
            let pending = try database.statement("SELECT id,content FROM fx_inputs WHERE session=? AND target=? AND accepted=0 AND result IS NULL ORDER BY sequence", [.text(lease.sessionID), .text(owner)]) { statement in
                var result: [FxSessionSteeringInput] = []
                while try database.step(statement) {
                    let content = try JSONDecoder().decode([FxPromptContent].self, from: database.bytes(statement, column: 1))
                    let text = content.compactMap { if case .text(let text) = $0 { return text }; return nil }.joined(separator: "\n")
                    result.append(FxSessionSteeringInput(id: database.text(statement, column: 0), text: text))
                }
                return result
            }
            let ends = try database.statement("SELECT ends FROM fx_inputs WHERE session=? AND id=?", [.text(lease.sessionID), .text(owner)]) { statement in
                guard try database.step(statement) else { throw FxSessionError.notFound }
                return sqlite3_column_int(statement, 0) != 0
            }
            return (pending, ends)
        }
    }

    // Called inside the transaction that appends the core journal. A crash can
    // never preserve acceptance without also preserving its routing state.
    func applyJournalMarks(_ data: Data, session: String) throws {
        for mark in try FxSessionJournalMark.decode(data) {
            switch mark {
            case .accepted(let id):
                try database.execute("UPDATE fx_inputs SET accepted=1 WHERE session=? AND core_id=? AND kind='steer'", [.text(session), .text(id)])
            case .withdrawn(let id):
                try database.execute("UPDATE fx_inputs SET target=NULL,accepted=0,placed=0 WHERE session=? AND core_id=? AND kind='steer' AND result IS NULL", [.text(session), .text(id)])
            case .placed(let id):
                try database.execute("UPDATE fx_inputs SET accepted=1,placed=1 WHERE session=? AND core_id=? AND kind='steer'", [.text(session), .text(id)])
            case .progress(let token):
                try database.execute("UPDATE fx_inputs SET step=? WHERE session=? AND target IS NULL AND started=1 AND result IS NULL", [.text(token), .text(session)])
            }
        }
    }

    func finishSteering(_ lease: FxSessionLease, owner: String, result: FxSessionResult) throws {
        let joined = try database.statement("SELECT id FROM fx_inputs WHERE session=? AND target=? AND accepted=1 AND result IS NULL", [.text(lease.sessionID), .text(owner)]) { statement in
            var ids: [String] = []
            while try database.step(statement) { ids.append(database.text(statement, column: 0)) }
            return ids
        }
        for id in joined {
            let settled = FxSessionResult(id: id, stopReason: result.stopReason, usage: nil, error: result.error,
                                          epoch: result.epoch, isRepeated: false)
            try database.execute("UPDATE fx_inputs SET result=? WHERE session=? AND id=?", [.blob(try JSONEncoder().encode(settled)), .text(lease.sessionID), .text(id)])
        }
        try routePendingSteering(session: lease.sessionID)
    }

    private func routePendingSteering(session: String) throws {
        let pending = try database.statement("SELECT id,kind,content FROM fx_inputs WHERE session=? AND result IS NULL ORDER BY sequence", [.text(session)]) { statement in
            var rows: [(String, String, Bool)] = []
            while try database.step(statement) {
                let content = try JSONDecoder().decode([FxPromptContent].self, from: database.bytes(statement, column: 2))
                let joinable = content.allSatisfy { if case .text = $0 { return true }; return false }
                rows.append((database.text(statement, column: 0), database.text(statement, column: 1), joinable))
            }
            return rows
        }
        try database.execute("UPDATE fx_inputs SET ends=0 WHERE session=? AND result IS NULL", [.text(session)])
        var owner: String?
        for (id, kind, joinable) in pending {
            if kind == "steer", joinable, let owner {
                try database.execute("UPDATE fx_inputs SET target=? WHERE session=? AND id=?", [.text(owner), .text(session), .text(id)])
            } else {
                if kind == "steer", !joinable, let owner {
                    try database.execute("UPDATE fx_inputs SET ends=1 WHERE session=? AND id=?", [.text(session), .text(owner)])
                }
                try database.execute("UPDATE fx_inputs SET target=NULL WHERE session=? AND id=?", [.text(session), .text(id)])
                owner = id
            }
        }
    }

    public func publicInputID(_ coreID: String, session: String) throws -> String? {
        try database.statement("SELECT id FROM fx_inputs WHERE session=? AND core_id=?", [.text(session), .text(coreID)]) { statement in
            try database.step(statement) ? database.text(statement, column: 0) : nil
        }
    }
}
