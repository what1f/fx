import Foundation
import JSONSchema

extension FxTool {
    /// Programmatic calls follow the same current-schema validation as native dispatch.
    public func invoke(_ input: JSONValue, context: FxToolContext) async throws -> FxToolResult {
        try Task.checkCancellation()
        try validateHostToolInput(input, tool: self)
        return try await execute(input, context)
    }
}

func validateHostToolInput(_ input: JSONValue, tool: FxTool) throws {
    let encoder = JSONEncoder()
    let schema = try JSONSerialization.jsonObject(with: encoder.encode(tool.inputSchema))
    let instance = try JSONSerialization.jsonObject(with: encoder.encode(input), options: [.fragmentsAllowed])
    guard let schema = schema as? [String: Any] else { throw FxError.invalidInput("Tool schema must be an object") }
    let result: ValidationResult = try JSONSchema.validate(instance, schema: schema)
    guard result.valid else {
        let issues = try JSONDecoder().decode(JSONValue.self, from: encoder.encode(result.errors ?? []))
        let failure: JSONValue = .object(["error": .object([
            "type": .string("invalid_tool_arguments"), "tool_name": .string(tool.name),
            "message": .string("Correct the arguments using the field errors and current tool definition."),
            "issues": issues,
            "definition": .object(["name": .string(tool.name), "description": .string(tool.description), "parameters": tool.inputSchema]),
        ])])
        throw FxError.invalidInput(String(decoding: try encoder.encode(failure), as: UTF8.self))
    }
}
