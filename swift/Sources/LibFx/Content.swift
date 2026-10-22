import Foundation

public enum FxImageFormat: String, Sendable, Codable {
    case png = "image/png", jpeg = "image/jpeg", gif = "image/gif", webp = "image/webp"
}

/// Image bytes, a host reference, or both. The core validates the image content.
public struct FxImage: Sendable, Equatable, Codable {
    public let data: Data?
    public let format: FxImageFormat
    public let sourceReference: String?

    public init(data: Data, format: FxImageFormat, sourceReference: String? = nil) {
        self.data = data
        self.format = format
        self.sourceReference = sourceReference
    }

    public init(reference: String, format: FxImageFormat) {
        data = nil
        self.format = format
        sourceReference = reference
    }

    func validate() throws {
        if let sourceReference {
            guard !sourceReference.isEmpty, sourceReference.utf8.count <= 512,
                  !sourceReference.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else {
                throw FxError.invalidInput("Image reference must contain 1–512 UTF-8 bytes without control characters")
            }
        }
        if let data, data.isEmpty { throw FxError.invalidInput("Image data must not be empty") }
    }

    var fields: [String: JSONValue] {
        var fields: [String: JSONValue] = ["type": .string("image"), "mimeType": .string(format.rawValue)]
        if let sourceReference { fields["sourceRef"] = .string(sourceReference) }
        return fields
    }
}

public enum FxPromptContent: Sendable, Equatable, Codable {
    case text(String)
    case image(FxImage)
}

/// A tool's response, including optional images and an explicit failure flag.
public struct FxToolResult: Sendable, Equatable, ExpressibleByStringLiteral {
    public var text: String
    public var images: [FxImage]
    public var isError: Bool

    public init(text: String, images: [FxImage] = [], isError: Bool = false) {
        self.text = text
        self.images = images
        self.isError = isError
    }

    public init(stringLiteral value: String) { self.init(text: value) }

    func response(toolName: String) throws -> JSONValue {
        guard images.count <= 8 else { throw FxError.invalidInput("A tool result accepts at most 8 images") }
        var content = text
        if !images.isEmpty {
            let encoded = try images.map { image -> JSONValue in
                try image.validate()
                var fields = image.fields
                if let data = image.data {
                    guard data.count <= 5 * 1024 * 1024 / 4 * 3 else {
                        throw FxError.invalidInput("Tool image exceeds the size limit")
                    }
                    fields["data"] = .string(data.base64EncodedString())
                }
                return .object(fields)
            }
            let bytes = try JSONEncoder().encode(JSONValue.object(["text": .string(text), "images": .array(encoded)]))
            guard bytes.count <= 8 * 1024 * 1024 else { throw FxError.invalidInput("Tool result exceeds the size limit") }
            content = String(decoding: bytes, as: UTF8.self)
        }
        if isError && content.isEmpty { content = "Tool \(toolName) failed without a message" }
        var fields: [String: JSONValue] = ["content": .string(content), "isError": .bool(isError)]
        if !images.isEmpty { fields["contentType"] = .string("rich") }
        return .object(fields)
    }
}
