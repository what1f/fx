import LibFx

/// An effect classification assigned by the host to a tool implementation.
public enum FxToolEffect: Sendable, Equatable {
    case readOnly, write, dangerous
}

/// Authorizes host tool closures independently of core permission requests.
public actor FxToolApproval {
    public struct Request: Sendable {
        public let pluginID: String
        public let toolName: String
        public let input: JSONValue
        public let context: FxToolContext
        public let effect: FxToolEffect
    }

    public enum Decision: Sendable, Equatable {
        case allowOnce, allowPlugin, deny
    }

    public enum Failure: Error, Sendable, Equatable {
        case denied
    }

    private let onApproval: @Sendable (Request) async throws -> Decision
    private var grants: Set<String> = []
    private var revocations: [String: UInt64] = [:]

    public init(onApproval: @escaping @Sendable (Request) async throws -> Decision) {
        self.onApproval = onApproval
    }

    /// A snapshot for host-managed persistence. Grants cover write tools only.
    public var allowedPlugins: Set<String> { grants }

    /// Adds a host-approved write grant, including a grant restored by the host.
    public func allow(pluginID: String) {
        grants.insert(pluginID)
    }

    /// Prevents pending approvals from restoring this plugin's revoked grant.
    public func revoke(pluginID: String) {
        grants.remove(pluginID)
        revocations[pluginID, default: 0] += 1
    }

    /// Preserves the tool's descriptor and calls its implementation once after approval.
    public nonisolated func wrap(tool: FxTool, pluginID: String, effect: FxToolEffect) -> FxTool {
        FxTool(name: tool.name, description: tool.description, inputSchema: tool.inputSchema,
               isIdempotent: tool.isIdempotent, writes: tool.writes) { input, context in
            try await self.authorize(Request(pluginID: pluginID, toolName: tool.name,
                                             input: input, context: context, effect: effect))
            try Task.checkCancellation()
            return try await tool.execute(input, context)
        }
    }

    private func authorize(_ request: Request) async throws {
        try Task.checkCancellation()
        if request.effect == .readOnly { return }
        if request.effect == .write, grants.contains(request.pluginID) { return }

        let version = revocations[request.pluginID, default: 0]
        let decision = try await onApproval(request)
        try Task.checkCancellation()
        switch decision {
        case .deny:
            throw Failure.denied
        case .allowOnce:
            break
        case .allowPlugin:
            if request.effect == .write, revocations[request.pluginID, default: 0] == version {
                grants.insert(request.pluginID)
            }
        }
    }
}
