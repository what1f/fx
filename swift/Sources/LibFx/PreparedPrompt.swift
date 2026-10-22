import Foundation

struct PreparedPrompt: Sendable {
    let blocks: [JSONValue]
    let images: [Data]

    init(blocks: [JSONValue], images: [Data]) {
        self.blocks = blocks
        self.images = images
    }

    static func preparing(_ content: [FxPromptContent], with prepare: @Sendable (FxImage) async throws -> FxImage) async throws -> PreparedPrompt {
        var result: [FxPromptContent] = []
        for block in content {
            try Task.checkCancellation()
            guard case .image(let image) = block, image.data != nil else { result.append(block); continue }
            let prepared = try await prepare(image)
            try Task.checkCancellation()
            guard let data = prepared.data, !data.isEmpty else { throw FxError.invalidInput("Image preparation must return nonempty bytes") }
            result.append(.image(FxImage(data: data, format: prepared.format, sourceReference: image.sourceReference)))
        }
        return try PreparedPrompt(result)
    }

    init(_ content: [FxPromptContent], allowEmpty: Bool = false, deferringImageLimits: Bool = false) throws {
        guard allowEmpty || content.contains(where: {
            switch $0 {
            case .text(let text): return !text.isEmpty
            case .image: return true
            }
        }) else {
            throw FxError.invalidInput("Prompt must not be empty")
        }
        var blocks: [JSONValue] = []
        var images: [Data] = []
        var imageCount = 0
        for block in content {
            switch block {
            case .text(let text): blocks.append(.object(["type": .string("text"), "text": .string(text)]))
            case .image(let image):
                imageCount += 1
                try image.validate()
                var fields = image.fields
                if let data = image.data {
                    guard deferringImageLimits || data.count <= 5 * 1024 * 1024 / 4 * 3 || image.sourceReference != nil else {
                        throw FxError.invalidInput("Prompt image exceeds the size limit")
                    }
                    if deferringImageLimits || data.count <= 5 * 1024 * 1024 / 4 * 3 {
                        images.append(data)
                        fields["_meta"] = .object(["fx": .object(["attachment": .number(Double(images.count))])])
                    }
                }
                blocks.append(.object(fields))
            }
        }
        guard imageCount <= 8, deferringImageLimits || images.reduce(0, { $0 + $1.count }) <= 6 * 1024 * 1024 else {
            throw FxError.invalidInput("Prompt images exceed the count or size limit")
        }
        let encodedImageBytes = deferringImageLimits ? 0 : images.reduce(0) { $0 + (($1.count + 2) / 3) * 4 }
        guard try JSONEncoder().encode(JSONValue.array(blocks)).count + encodedImageBytes <= 8 * 1024 * 1024 - 1024 else {
            throw FxError.invalidInput("Prompt exceeds frame limit")
        }
        self.blocks = blocks
        self.images = images
    }
}
