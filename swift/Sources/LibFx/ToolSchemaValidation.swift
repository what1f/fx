import Foundation
import JSONSchema

func validateHostToolInput(_ input: JSONValue, tool: FxTool) throws {
    let encoder = JSONEncoder()
    let schema = try JSONSerialization.jsonObject(with: encoder.encode(tool.inputSchema))
    let instance = try JSONSerialization.jsonObject(with: encoder.encode(input), options: [.fragmentsAllowed])
    guard let schema = schema as? [String: Any] else { throw FxError.invalidInput("Tool schema must be an object") }
    let result: ValidationResult = try JSONSchema.validate(instance, schema: schema)
    guard result.valid else {
        let definition = String(decoding: try encoder.encode(tool.descriptor), as: UTF8.self)
        throw FxError.invalidInput("Arguments do not match the current tool definition. Use this definition: \(definition)")
    }
}
