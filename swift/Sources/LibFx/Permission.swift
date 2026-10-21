import Foundation

public struct FxPermissionOption: Sendable, Equatable {
    public enum Kind: String, Sendable {
        case allowOnce = "allow_once", allowSession = "allow_always"
        case rejectOnce = "reject_once", rejectSession = "reject_always"
    }
    public let id: String
    public let name: String
    public let kind: Kind
}

public struct FxPermissionRequest: Sendable, Equatable {
    public struct Tool: Sendable, Equatable {
        public enum Kind: String, Sendable {
            case read, edit, delete, move, search, execute, think, fetch, other
        }
        public let id: String
        public let name: String
        public let title: String
        public let kind: Kind
        public let input: FxToolInput?
    }
    public let sessionID: String
    public let turnID: String
    public let tool: Tool
    public let options: [FxPermissionOption]

    private init(sessionID: String, turnID: String, tool: Tool, options: [FxPermissionOption]) {
        self.sessionID = sessionID; self.turnID = turnID; self.tool = tool; self.options = options
    }

    func scoped(sessionID: String, turnID: String) -> Self {
        Self(sessionID: sessionID, turnID: turnID, tool: tool, options: options)
    }

    init(_ params: JSONValue, turnID: String) throws {
        guard let sessionID = params["sessionId"]?.string,
              let call = params["toolCall"], let id = call["toolCallId"]?.string, !id.isEmpty,
              let name = call["name"]?.string, let title = call["title"]?.string,
              let rawKind = call["kind"]?.string, let kind = Tool.Kind(rawValue: rawKind),
              case .array(let choices) = params["options"] else {
            throw FxError.protocolViolation("Invalid permission request")
        }
        var options: [FxPermissionOption] = []
        var ids: Set<String> = []
        for choice in choices {
            guard let id = choice["optionId"]?.string, !id.isEmpty, ids.insert(id).inserted,
                  let name = choice["name"]?.string, let rawKind = choice["kind"]?.string,
                  let kind = FxPermissionOption.Kind(rawValue: rawKind) else {
                throw FxError.protocolViolation("Invalid permission options")
            }
            options.append(FxPermissionOption(id: id, name: name, kind: kind))
        }
        self.sessionID = sessionID
        self.turnID = turnID
        self.tool = Tool(id: id, name: name, title: title, kind: kind, input: try FxToolInput.display(call["rawInput"]))
        self.options = options
    }
}

public enum FxPermissionDecision: Sendable, Equatable {
    case select(optionID: String)
    case cancel
}

/// Keeps permission callbacks off the RPC reader so cancellation can still arrive.
actor PermissionRequests {
    typealias Handler = @Sendable (FxPermissionRequest) async throws -> FxPermissionDecision
    private let sessionID: String
    private let rpc: RPCClient
    private let handler: Handler?
    private var tasks: [UUID: (scope: UUID, task: Task<Void, Never>)] = [:]
    var pendingCount: Int { tasks.count }

    init(sessionID: String, rpc: RPCClient, handler: Handler?) {
        self.sessionID = sessionID; self.rpc = rpc; self.handler = handler
    }

    func handle(id: JSONValue, params: JSONValue, turnID: String?, scope: UUID?, isActive: @escaping @Sendable () async -> Bool) async {
        guard params["sessionId"]?.string == sessionID else {
            try? await rpc.respond(id: id, error: .protocolViolation("Permission request does not belong to this conversation"))
            return
        }
        guard let turnID, let scope, let handler, let request = try? FxPermissionRequest(params, turnID: turnID) else {
            try? await rpc.respond(id: id, result: Self.outcome(.cancel, options: []))
            return
        }
        let token = UUID()
        let task = Task { [weak self, rpc] in
            var decision = FxPermissionDecision.cancel
            do {
                try Task.checkCancellation()
                guard await isActive() else { await self?.remove(token); return }
                decision = try await handler(request)
            } catch { /* Failed callbacks deny the request without copying host error details. */ }
            if !Task.isCancelled, await isActive() {
                try? await rpc.respond(id: id, result: Self.outcome(decision, options: request.options))
            }
            await self?.remove(token)
        }
        tasks[token] = (scope, task)
    }

    func cancelAll() {
        for pending in tasks.values { pending.task.cancel() }
    }

    func cancel(scope: UUID) {
        for pending in tasks.values where pending.scope == scope {
            pending.task.cancel()
        }
    }

    private func remove(_ token: UUID) { tasks.removeValue(forKey: token) }

    private static func outcome(_ decision: FxPermissionDecision, options: [FxPermissionOption]) -> JSONValue {
        if case .select(let id) = decision, options.contains(where: { $0.id == id }) {
            return .object(["outcome": .object(["outcome": .string("selected"), "optionId": .string(id)])])
        }
        return .object(["outcome": .object(["outcome": .string("cancelled")])])
    }
}
