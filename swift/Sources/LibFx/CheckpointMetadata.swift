import Foundation
import CryptoKit

struct CheckpointMetadata: Sendable {
    let value: JSONValue

    init(configuration: FxConfiguration, modelID: String? = nil) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let descriptors = configuration.toolDescriptors.sorted { ($0["name"]?.string ?? "") < ($1["name"]?.string ?? "") }
        let bytes = try encoder.encode(JSONValue.array(descriptors))
        let hash = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        var fields: [String: JSONValue] = [
            "libfxVersion": .string("2"),
            "toolSchemaHash": .string("sha256:" + hash),
        ]
        if let model = modelID ?? configuration.model.id { fields["model"] = .string(model) }
        value = .object(fields)
    }

    func compare(_ saved: JSONValue?, sessionID: String, observation: FxObservationOptions?) {
        guard let saved else { return }
        let changed = ["libfxVersion", "toolSchemaHash", "model"].filter { key in
            guard let text = saved[key]?.string, !text.isEmpty else { return false }
            return saved[key] != value[key]
        }
        guard !changed.isEmpty else { return }
        observation?.deliver(FxObservation(journal: .checkpointMismatch, sessionID: sessionID, data: .object([
            "changed": .array(changed.map(JSONValue.string)), "saved": saved, "current": value,
        ])))
    }
}
