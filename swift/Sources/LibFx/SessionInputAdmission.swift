import Foundation

// Durable storage admission is separate from the conversation engine's frame and image limits.
enum SessionInputAdmission {
    static let maximumBytes = 8 * 1024 * 1024

    static func validate(_ content: [FxPromptContent], options: FxSessionOptions) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        var bytes = 0
        func add(_ count: Int) throws {
            guard count <= maximumBytes - bytes else {
                throw FxError.invalidInput("Input, context and settings exceed the 8 MiB size limit")
            }
            bytes += count
        }
        if content.count == 1, case .payload(let data) = content[0] {
            // Payload is already JSON. Its private storage envelope and base64 are not input bytes.
            try add(data.count)
        } else {
            let blocks = try content.map { block -> JSONValue in
                switch block {
                case .payload: throw FxError.invalidInput("A data input must contain exactly one payload")
                case .text(let text): return .object(["type": .string("text"), "text": .string(text)])
                case .image(let image):
                    var fields = image.fields
                    if let data = image.data {
                        guard data.count <= maximumBytes else {
                            throw FxError.invalidInput("Input, context and settings exceed the 8 MiB size limit")
                        }
                        try add(((data.count + 2) / 3) * 4)
                        fields["data"] = .string("")
                    }
                    return .object(fields)
                }
            }
            try add(encoder.encode(JSONValue.array(blocks)).count)
        }
        if let context = options.context { try add(encoder.encode(context).count) }
        if let settings = options.settings { try add(encoder.encode(settings).count) }
        if options.model != nil || options.instructions != nil {
            struct Overrides: Encodable {
                let model: FxModel?
                let instructions: String?
            }
            try add(encoder.encode(Overrides(model: options.model, instructions: options.instructions)).count)
        }
    }
}
