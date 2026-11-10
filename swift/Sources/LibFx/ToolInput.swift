import Foundation

/// Display input for a tool start. The tool executor receives the complete arguments separately.
public enum FxToolInput: Sendable, Equatable, Codable {
    case complete(JSONValue)
    case truncated(preview: String)

    static func display(_ value: JSONValue?) throws -> Self? {
        guard let value, value != .null else { return nil }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(value)
        let limit = 64 * 1024
        guard data.count > limit else { return .complete(value) }
        var bytes = data.prefix(limit)
        // A prefix can cut through a UTF-8 scalar; at most three trailing bytes need removal.
        while !bytes.isEmpty {
            if let preview = String(data: bytes, encoding: .utf8) { return .truncated(preview: preview) }
            bytes = bytes.dropLast()
        }
        return .truncated(preview: "")
    }
}
