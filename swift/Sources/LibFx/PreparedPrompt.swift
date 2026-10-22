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
        let admission = try PromptAdmission(content.map(PromptInputDescriptor.init), allowEmpty: allowEmpty, deferringImageLimits: deferringImageLimits)
        var blocks: [JSONValue] = []
        var images: [Data] = []
        for (index, block) in content.enumerated() {
            switch block {
            case .payload: throw FxError.invalidInput("Use a custom durable harness for data inputs")
            case .text(let text): blocks.append(.object(["type": .string("text"), "text": .string(text)]))
            case .image(let image):
                var fields = image.fields
                if admission.retainedImages.contains(index), let data = image.data {
                    images.append(data)
                    fields["_meta"] = .object(["fx": .object(["attachment": .number(Double(images.count))])])
                }
                blocks.append(.object(fields))
            }
        }
        self.blocks = blocks
        self.images = images
    }
}
