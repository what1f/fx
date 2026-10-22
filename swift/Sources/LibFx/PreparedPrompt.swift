import Foundation

struct PreparedPrompt: Sendable {
    let blocks: [JSONValue]
    let images: [Data]

    init(_ content: [FxPromptContent], allowEmpty: Bool = false) throws {
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
                    guard data.count <= 5 * 1024 * 1024 / 4 * 3 || image.sourceReference != nil else {
                        throw FxError.invalidInput("Prompt image exceeds the size limit")
                    }
                    if data.count <= 5 * 1024 * 1024 / 4 * 3 {
                        images.append(data)
                        fields["_meta"] = .object(["fx": .object(["attachment": .number(Double(images.count))])])
                    }
                }
                blocks.append(.object(fields))
            }
        }
        guard imageCount <= 8, images.reduce(0, { $0 + $1.count }) <= 6 * 1024 * 1024 else {
            throw FxError.invalidInput("Prompt images exceed the count or size limit")
        }
        let encodedImageBytes = images.reduce(0) { $0 + (($1.count + 2) / 3) * 4 }
        guard try JSONEncoder().encode(JSONValue.array(blocks)).count + encodedImageBytes <= 8 * 1024 * 1024 - 1024 else {
            throw FxError.invalidInput("Prompt exceeds frame limit")
        }
        self.blocks = blocks
        self.images = images
    }
}
