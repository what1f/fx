import Foundation

/// Byte-source metadata lets the host check limits before reading asynchronous inputs.
package enum PromptInputDescriptor: Sendable {
    case text(String)
    case payload
    case resource(uri: String, text: String?)
    case image(format: FxImageFormat, reference: String?, byteCount: Int?, prefix: Data?)

    package init(_ content: FxPromptContent) {
        switch content {
        case .payload: self = .payload
        case .text(let text): self = .text(text)
        case .resource(let uri, let text): self = .resource(uri: uri, text: text)
        case .image(let image):
            self = .image(format: image.format, reference: image.sourceReference,
                          byteCount: image.data?.count, prefix: image.data.map { Data($0.prefix(12)) })
        }
    }
}

package struct PromptAdmission {
    package let retainedImages: Set<Int>

    package init(_ input: [PromptInputDescriptor], allowEmpty: Bool = false, deferringImageLimits: Bool = false) throws {
        var retained: Set<Int> = []
        var sizes: [Int: Int] = [:]
        var referenced: Set<Int> = []
        var images = 0
        var hasContent = allowEmpty
        for (index, block) in input.enumerated() {
            switch block {
            case .payload: throw FxError.invalidInput("Use a custom durable harness for data inputs")
            case .text(let text): hasContent = hasContent || !text.isEmpty
            case .resource: break
            case .image(let format, let reference, let byteCount, _):
                hasContent = true
                images += 1
                guard images <= 8 else { throw FxError.invalidInput("Prompt accepts at most 8 images") }
                if let reference { try FxImage(reference: reference, format: format).validate() }
                if let count = byteCount {
                    guard count > 0 else { throw FxError.invalidInput("Image data must not be empty") }
                    if reference != nil { referenced.insert(index) }
                    if !deferringImageLimits && count > 5 * 1024 * 1024 / 4 * 3 {
                        guard reference != nil else { throw FxError.invalidInput("Prompt image exceeds the size limit") }
                    } else {
                        retained.insert(index)
                        sizes[index] = count
                    }
                } else if reference == nil { throw FxError.invalidInput("Image data or reference is required") }
            }
        }
        guard hasContent else { throw FxError.invalidInput("Prompt must not be empty") }
        func imageBytes() -> Int { retained.reduce(0) { $0 + (sizes[$1] ?? 0) } }
        if !deferringImageLimits {
            if imageBytes() > 6 * 1024 * 1024 { retained.subtract(referenced) }
            guard imageBytes() <= 6 * 1024 * 1024 else { throw FxError.invalidInput("Prompt images exceed the count or size limit") }
            if try Self.frameSize(input, retaining: retained, countImages: true) > 8 * 1024 * 1024 {
                retained.subtract(referenced)
            }
        }
        guard try Self.frameSize(input, retaining: retained, countImages: !deferringImageLimits) <= 8 * 1024 * 1024 else {
            throw FxError.invalidInput("Prompt exceeds frame limit")
        }
        if !deferringImageLimits {
            for index in retained.sorted() {
                guard case .image(let format, _, _, let prefix) = input[index], let prefix else { continue }
                let detected = Self.imageFormat(prefix)
                guard let detected else { throw FxError.invalidInput("Image data is not a PNG, JPEG, GIF or WebP image") }
                guard detected == format else { throw FxError.invalidInput("Image holds \(detected.rawValue) data, not \(format.rawValue)") }
            }
        }
        retainedImages = retained
    }

    private static func frameSize(_ input: [PromptInputDescriptor], retaining images: Set<Int>, countImages: Bool) throws -> Int {
        var encodedBytes = 0
        let blocks: [JSONValue] = input.enumerated().map { index, block in
            switch block {
            case .payload: return .null // Rejected during admission, before frame sizing.
            case .text(let text): return .object(["type": .string("text"), "text": .string(text)])
            case .resource(let uri, let text): return resourcePromptBlock(uri: uri, text: text)
            case .image(let format, let reference, let byteCount, _):
                var fields: [String: JSONValue] = ["type": .string("image"), "mimeType": .string(format.rawValue)]
                if let reference { fields["sourceRef"] = .string(reference) }
                if images.contains(index) {
                    fields["_meta"] = .object(["fx": .object(["attachment": .number(Double(UInt32.max))])])
                    if countImages, let count = byteCount { encodedBytes += ((count + 2) / 3) * 4 }
                }
                return .object(fields)
            }
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        return try encoder.encode(JSONValue.object(["sessionId": .string(""), "prompt": .array(blocks)])).count + encodedBytes + 128
    }

    private static func imageFormat(_ data: Data) -> FxImageFormat? {
        if data.starts(with: [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]) { return .png }
        if data.starts(with: [0xff, 0xd8, 0xff]) { return .jpeg }
        if data.starts(with: Array("GIF87a".utf8)) || data.starts(with: Array("GIF89a".utf8)) { return .gif }
        if data.starts(with: Array("RIFF".utf8)), data.dropFirst(8).starts(with: Array("WEBP".utf8)) { return .webp }
        return nil
    }
}
