import Foundation

public struct FxConfiguration: Sendable {
    @_spi(Conformance) public var wireObserver: (@Sendable (FxWireDirection, JSONValue) async -> Void)?
    public var apiKey: String
    public var model: FxModel
    public var instructions: String
    public var tools: [FxTool]
    public var workspace: URL
    public var gatewayURL: URL
    public var httpClient: any FxHTTPClient
    public var observation: FxObservationOptions?
    /// Journal bytes between automatic snapshots. Nil disables automatic snapshots.
    public var checkpointAfterBytes: Int?

    public init(
        apiKey: String, model: FxModel, instructions: String = "", tools: [FxTool] = [],
        workspace: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath),
        gatewayURL: URL = URL(string: "https://ai-gateway.vercel.sh/v4/ai/language-model")!,
        httpClient: any FxHTTPClient = FxURLSessionHTTPClient(), observation: FxObservationOptions? = nil,
        checkpointAfterBytes: Int? = 1024 * 1024
    ) {
        self.apiKey = apiKey
        self.model = model
        self.instructions = instructions
        self.tools = tools
        self.workspace = workspace
        self.gatewayURL = gatewayURL
        self.httpClient = httpClient
        self.observation = observation
        self.checkpointAfterBytes = checkpointAfterBytes
    }

    var nativeOptions: JSONValue {
        var fields: [String: JSONValue] = [
            "apiKey": .string(apiKey), "model": .string(model.id),
            "home": .string(FileManager.default.homeDirectoryForCurrentUser.path),
            "workspaceRoot": .string(workspace.path), "gatewayChatUrl": .string(gatewayURL.absoluteString),
        ]
        if let effort = model.reasoningEffort { fields["effort"] = .string(effort) }
        if let fast = model.fast { fields["fast"] = .bool(fast) }
        if let ultrafast = model.ultrafast { fields["ultrafast"] = .bool(ultrafast) }
        return .object(fields)
    }
}

public struct FxToolContext: Sendable {
    public let executionID: String
    public let sessionID: String
    public let turnID: String
}

public struct FxTool: Sendable {
    public let name: String
    public let description: String
    public let inputSchema: JSONValue
    public let isIdempotent: Bool
    public let writes: Bool?
    public let execute: @Sendable (JSONValue, FxToolContext) async throws -> FxToolResult

    public init(
        name: String, description: String, inputSchema: JSONValue, isIdempotent: Bool,
        writes: Bool? = nil,
        execute: @escaping @Sendable (JSONValue, FxToolContext) async throws -> FxToolResult
    ) {
        self.name = name
        self.description = description
        self.inputSchema = inputSchema
        self.isIdempotent = isIdempotent
        self.writes = writes
        self.execute = execute
    }

    var descriptor: JSONValue {
        var fields: [String: JSONValue] = [
            "name": .string(name), "description": .string(description), "inputSchema": inputSchema,
        ]
        if isIdempotent { fields["idempotent"] = .bool(true) }
        if let writes { fields["writes"] = .bool(writes) }
        return .object(fields)
    }
}
