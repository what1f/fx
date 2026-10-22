import Foundation

/// Ordered changes that a session store commits with a journal record.
/// Input identities use `FxSessionInput.runtimeID(for:)`.
public enum FxSessionJournalMark: Sendable, Equatable {
    case accepted(String)
    case withdrawn(String)
    case placed(String)
    /// An opaque token identifying the current execution step for delivery cutoffs.
    case progress(String)

    public static func decode(_ data: Data) throws -> [Self] {
        guard let record = try? JSONDecoder().decode(JSONValue.self, from: data),
              case .array(let events) = record["events"] else { throw FxPersistenceError.invalidJournal }
        var marks: [Self] = []
        for event in events {
            if event["type"] == .string("turn_progress") {
                let steps: Int?
                if let count = event["steps"]?.integer { steps = count }
                else if case .array(let calls) = event["data"]?["execution"]?["tool_steps"] { steps = calls.count }
                else { steps = nil }
                if let steps { marks.append(.progress("\(steps):\(event["data"]?["tool_state"]?.string ?? "none")")) }
            }
            if event["type"] == .string("input_accepted"), let id = event["data"]?["id"]?.string {
                marks.append(.accepted(id))
            } else if event["type"] == .string("input_withdrawn"), let id = event["data"]?["id"]?.string {
                marks.append(.withdrawn(id))
            }
            if case .array(let inputs) = event["inputs"] {
                marks += inputs.compactMap { $0.string.map(Self.placed) }
            }
        }
        return marks
    }
}
