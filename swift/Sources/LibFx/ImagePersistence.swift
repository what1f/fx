import Foundation
import CryptoKit

/// Restricts the images kept in a journaled conversation. The core's own limits still apply.
public struct FxImageWindow: Sendable, Equatable {
    public let maximumImages: Int?
    public let maximumBytes: Int?

    public init(maximumImages: Int? = nil, maximumBytes: Int? = nil) throws {
        guard [maximumImages, maximumBytes].compactMap({ $0 }).allSatisfy({ $0 > 0 && $0 <= 9_007_199_254_740_991 }) else {
            throw FxError.invalidInput("Image window limits must be positive and within the supported range")
        }
        self.maximumImages = maximumImages
        self.maximumBytes = maximumBytes
    }

    var value: JSONValue {
        var fields: [String: JSONValue] = [:]
        if let maximumImages { fields["images"] = .number(Double(maximumImages)) }
        if let maximumBytes { fields["bytes"] = .number(Double(maximumBytes)) }
        return .object(fields)
    }
}

enum PersistedImages {
    static func name(for data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func prompt(_ prepared: PreparedPrompt, store: any FxImagePersistence) async throws -> [JSONValue] {
        var blocks = prepared.blocks
        var stored: Set<String> = []
        for index in blocks.indices {
            try Task.checkCancellation()
            guard case .object(var fields) = blocks[index],
                  let attachment = fields["_meta"]?["fx"]?["attachment"]?.integer else { continue }
            let bytes = prepared.images[attachment - 1]
            let name = name(for: bytes)
            if stored.insert(name).inserted { try await store.storeImage(bytes, named: name) }
            try Task.checkCancellation()
            fields["_meta"] = .object(["fx": .object([
                "attachment": .number(Double(attachment)), "stored": .string(name),
            ])])
            blocks[index] = .object(fields)
        }
        return blocks
    }

    static func tool(_ value: FxToolResult, name: String, store: (any FxImagePersistence)?) async throws -> JSONValue {
        let validated = try value.response(toolName: name)
        guard let store else { return validated }
        var names: [Int: String] = [:]
        var stored: Set<String> = []
        for (index, image) in value.images.enumerated() {
            guard let bytes = image.data else { continue }
            try Task.checkCancellation()
            let name = self.name(for: bytes)
            do {
                if !stored.contains(name) {
                    try await store.storeImage(bytes, named: name)
                    stored.insert(name)
                }
                names[index] = name
            } catch {
                // The tool already ran. Keep an image the store rejected inline.
                try Task.checkCancellation()
            }
        }
        try Task.checkCancellation()
        return names.isEmpty ? validated : try value.response(toolName: name, storedImages: names)
    }
}
