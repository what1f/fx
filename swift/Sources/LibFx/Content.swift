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
            guard sourceReference.utf8.count <= 512 else { throw FxError.invalidInput("Image reference exceeds the 512 byte limit") }
            guard !sourceReference.isEmpty,
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

    func response(toolName: String, storedImages: [Int: String] = [:]) throws -> JSONValue {
        guard images.count <= 8 else { throw FxError.invalidInput("invalid typed tool result") }
        var content = text
        if !images.isEmpty {
            var encoded = try images.enumerated().map { index, image -> JSONValue in
                do { try image.validate() }
                catch { throw FxError.invalidInput("Invalid tool image sourceRef or data") }
                guard image.data != nil || image.sourceReference != nil else {
                    throw FxError.invalidInput("invalid tool image")
                }
                var fields = image.fields
                if let data = image.data {
                    if data.count <= 5 * 1024 * 1024 / 4 * 3 {
                        fields["data"] = .string(data.base64EncodedString())
                        if let name = storedImages[index] { fields["stored"] = .string(name) }
                    } else if image.sourceReference == nil { throw FxError.invalidInput("invalid tool image") }
                }
                return .object(fields)
            }
            func omitReferencedBytes() {
                encoded = encoded.map { image in
                    guard image["sourceRef"] != nil, case .object(var fields) = image else { return image }
                    fields.removeValue(forKey: "data")
                    fields.removeValue(forKey: "stored")
                    return .object(fields)
                }
            }
            func dataSize() -> Int { encoded.reduce(0) { $0 + ($1["data"]?.string?.utf8.count ?? 0) } }
            if dataSize() > 8 * 1024 * 1024 { omitReferencedBytes() }
            guard dataSize() <= 8 * 1024 * 1024 else { throw FxError.invalidInput("tool images exceed the result limit") }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.withoutEscapingSlashes]
            func encode() throws -> Data {
                try encoder.encode(JSONValue.object(["text": .string(text), "images": .array(encoded)]))
            }
            var bytes = try encode()
            if bytes.count > 8 * 1024 * 1024 { omitReferencedBytes(); bytes = try encode() }
            guard bytes.count <= 8 * 1024 * 1024 else { throw FxError.invalidInput("typed tool result exceeds the result limit") }
            content = String(decoding: bytes, as: UTF8.self)
        }
        if isError && content.isEmpty { content = "Tool \(toolName) failed without a message" }
        var fields: [String: JSONValue] = ["content": .string(content), "isError": .bool(isError)]
        if !images.isEmpty { fields["contentType"] = .string("rich") }
        return .object(fields)
    }
}
