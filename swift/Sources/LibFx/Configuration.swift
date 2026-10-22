import Foundation

public struct FxConfiguration: Sendable {
    /// Checks input without opening an engine or running image preparation.
    public func validatePrompt(_ content: [FxPromptContent]) throws {
        _ = try PreparedPrompt(content, deferringImageLimits: prepareImage != nil)
    }

    package func validateInstructions() throws {
        guard instructions.utf8.count <= 65536 else {
            throw FxError.invalidInput("Instructions exceed the 65536 byte limit")
        }
    }

    @_spi(Conformance) public var wireObserver: (@Sendable (FxWireDirection, JSONValue) async -> Void)?
    public var provider: FxProvider
    public var model: FxModel
    /// A supplied Gateway catalog replaces its model-list request.
    public var modelCatalog: FxModelCatalog?
    /// A smaller image window requires an FxImagePersistence store.
    public var imageWindow: FxImageWindow?
    /// Prepares prompt image bytes before admission. Return bytes and a format; the original reference is retained.
    public var prepareImage: (@Sendable (FxImage) async throws -> FxImage)?
    public var instructions: String
    public var tools: [FxTool]
    public var providerTools: [FxProviderTool]
    public var workspace: URL
    public var gatewayURL: URL
    public var httpClient: any FxHTTPClient
    public var observation: FxObservationOptions?
    /// Awaits host lifecycle notifications before advancing. Keep callbacks short.
    public var onLifecycleEvent: (@Sendable (FxLifecycleEvent) async -> Void)?
    var validatePermission: (@Sendable () async throws -> Void)?
    /// Chooses an offered core permission option. Missing or failed callbacks deny the request.
    public var onPermission: (@Sendable (FxPermissionRequest) async throws -> FxPermissionDecision)?
    /// Receives request metadata. The transport awaits this callback before advancing.
    public var onTransportEvent: (@Sendable (FxTransportEvent) async -> Void)?
    /// Journal bytes between automatic snapshots. Nil disables automatic snapshots.
    public var checkpointAfterBytes: Int?

    public init(
        apiKey: String, model: FxModel = .init(), instructions: String = "", tools: [FxTool] = [],
        providerTools: [FxProviderTool] = [],
        workspace: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath),
        gatewayURL: URL = URL(string: "https://ai-gateway.vercel.sh/v4/ai/language-model")!,
        httpClient: any FxHTTPClient = FxURLSessionHTTPClient(), observation: FxObservationOptions? = nil,
        checkpointAfterBytes: Int? = 1024 * 1024,
        onTransportEvent: (@Sendable (FxTransportEvent) async -> Void)? = nil,
        onPermission: (@Sendable (FxPermissionRequest) async throws -> FxPermissionDecision)? = nil,
        onLifecycleEvent: (@Sendable (FxLifecycleEvent) async -> Void)? = nil
    ) {
        self.init(provider: .gateway(apiKey: apiKey), model: model, instructions: instructions,
                  tools: tools, providerTools: providerTools, workspace: workspace, httpClient: httpClient,
                  observation: observation, checkpointAfterBytes: checkpointAfterBytes, onTransportEvent: onTransportEvent, onPermission: onPermission, onLifecycleEvent: onLifecycleEvent)
        self.gatewayURL = gatewayURL
    }

    public init(
        provider: FxProvider, model: FxModel = .init(), instructions: String = "", tools: [FxTool] = [],
        providerTools: [FxProviderTool] = [],
        workspace: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath),
        httpClient: any FxHTTPClient = FxURLSessionHTTPClient(), observation: FxObservationOptions? = nil,
        checkpointAfterBytes: Int? = 1024 * 1024,
        onTransportEvent: (@Sendable (FxTransportEvent) async -> Void)? = nil,
        onPermission: (@Sendable (FxPermissionRequest) async throws -> FxPermissionDecision)? = nil,
        onLifecycleEvent: (@Sendable (FxLifecycleEvent) async -> Void)? = nil
    ) {
        self.provider = provider
        self.model = model
        self.modelCatalog = nil
        self.imageWindow = nil
        self.prepareImage = nil
        self.instructions = instructions
        self.tools = tools
        self.providerTools = providerTools
        self.workspace = workspace
        self.gatewayURL = URL(string: "https://ai-gateway.vercel.sh/v4/ai/language-model")!
        self.httpClient = httpClient
        self.onTransportEvent = onTransportEvent
        self.observation = observation
        self.onPermission = onPermission
        self.onLifecycleEvent = onLifecycleEvent
        self.checkpointAfterBytes = checkpointAfterBytes
    }

    var toolDescriptors: [JSONValue] {
        tools.map(\.descriptor) + providerTools.map { .object(["name": .string($0.rawValue), "providerExecuted": .bool(true)]) }
    }

    var nativeOptions: JSONValue {
        get throws {
            var fields: [String: JSONValue] = [
                "home": .string(FileManager.default.homeDirectoryForCurrentUser.path),
                "workspaceRoot": .string(workspace.path), "gatewayChatUrl": .string(gatewayURL.absoluteString),
            ]
            if let id = model.id { fields["model"] = .string(id) }
            switch provider {
            case .gateway(let apiKey): fields["apiKey"] = .string(apiKey)
            case .subscription(let subscription): fields["provider"] = .string(subscription.provider.rawValue)
            case .custom(let provider, _):
                fields["provider"] = .string(provider.name)
                fields["configuredProviders"] = .string(String(decoding: try JSONEncoder().encode(provider.definition), as: UTF8.self))
            }
            if let effort = model.reasoningEffort { fields["effort"] = .string(effort) }
            if let fast = model.fast { fields["fast"] = .bool(fast) }
            if let ultrafast = model.ultrafast { fields["ultrafast"] = .bool(ultrafast) }
            return .object(fields)
        }
    }
}

public struct FxToolContext: Sendable {
    public let executionID: String
    public let sessionID: String
    public let turnID: String
    public var context: JSONValue? = nil
    public let observation: FxToolObservation?

    public init(executionID: String, sessionID: String, turnID: String, context: JSONValue? = nil,
                observation: FxToolObservation? = nil) {
        self.executionID = executionID
        self.sessionID = sessionID
        self.turnID = turnID
        self.context = context
        self.observation = observation
    }
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

/// A tool executed by the model service, without a host callback.
public enum FxProviderTool: String, Sendable, Codable {
    case webSearch = "web_search"
}
