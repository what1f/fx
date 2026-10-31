import Foundation

// Keep arbitrary data out of the conversation admission and image preparation path.
func validateSessionInput(_ content: [FxPromptContent], deferringImageLimits: Bool) throws {
    if content.contains(where: { if case .payload = $0 { return true }; return false }) {
        _ = try durablePayload(content)
    } else {
        _ = try PreparedPrompt(content, deferringImageLimits: deferringImageLimits)
    }
}

func durablePayload(_ content: [FxPromptContent]) throws -> Data {
    guard content.count == 1, case .payload(let data) = content[0] else {
        throw FxError.invalidInput("A data input must contain exactly one payload")
    }
    guard data.count <= 8 * 1024 * 1024 else { throw FxError.invalidInput("Payload exceeds the size limit") }
    return data
}

func encodeDurablePayload<Value: Encodable>(_ value: Value) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let data = try encoder.encode(value)
    guard data.count <= 8 * 1024 * 1024 else { throw FxError.invalidInput("Payload exceeds the size limit") }
    return data
}

func decodeDurableUpdate<Update: Decodable>(_ event: FxEvent, as: Update.Type) throws -> Update {
    guard case .payload(let data) = event else { throw FxPersistenceError.invalidJournal }
    return try JSONDecoder().decode(Update.self, from: data)
}
