import Foundation

/// Observes host effects within one tool call without changing their values or errors.
public struct FxToolObservation: Sendable {
    public let scope: FxObservation
    public let callID: String
    private let options: FxObservationOptions
    private let parent: FxObservationParent
    private let state: ToolObservationState

    init(scope: FxObservation, callID: String, options: FxObservationOptions) throws {
        guard let turnID = scope.turnID else { throw FxError.protocolViolation("Tool observation has no turn") }
        self.scope = scope
        self.callID = callID
        self.options = options
        parent = try FxObservationParent(rootSessionID: scope.rootSessionID, sessionID: scope.sessionID,
                                         turnID: turnID, callID: callID)
        state = ToolObservationState(scope: scope, callID: callID, options: options)
    }

    /// Carries the owning tool identity into a child engine's observation configuration.
    public func childOptions() -> FxObservationOptions {
        FxObservationOptions(captureContent: options.captureContent, parent: parent,
                             onEvent: options.onEvent, onError: options.onError)
    }

    /// Calls the effect exactly once. Cancellation ends its observation even if the effect settles later.
    public func mcp<T: Sendable>(server: String? = nil, tool: String, correlationID: String? = nil,
                                isError: @Sendable (T) -> Bool = { _ in false },
                                operation: @Sendable () async throws -> T) async rethrows -> T {
        let id = Task.isCancelled ? nil : state.begin(server: server, tool: tool, correlationID: correlationID)
        return try await withTaskCancellationHandler {
            do {
                let value = try await operation()
                state.end(id, status: Task.isCancelled ? "cancelled" : isError(value) ? "failure" : "success")
                return value
            } catch {
                state.end(id, status: Task.isCancelled || error is CancellationError ? "cancelled" : "failure",
                          error: String(describing: type(of: error)))
                throw error
            }
        } onCancel: {
            state.end(id, status: "cancelled")
        }
    }

    func invalidate() { state.invalidate() }
}

// State changes and event enqueueing are atomic. Callbacks drain outside the lock so they can
// cancel this or another tool without a lock inversion. No lock spans an asynchronous effect.
private final class ToolObservationState: @unchecked Sendable {
    private let lock = NSLock()
    private let scope: FxObservation
    private let callID: String
    private let options: FxObservationOptions
    private var active = true
    private var operations: Set<String> = []
    private var pending: [FxObservation] = []
    private var draining = false

    init(scope: FxObservation, callID: String, options: FxObservationOptions) {
        self.scope = scope
        self.callID = callID
        self.options = options
    }

    func begin(server: String?, tool: String, correlationID: String?) -> String? {
        let result: (String?, Bool) = lock.withLock {
            guard active else { return (nil, false) }
            let id = "host:\(scope.executionID ?? ""):\(callID):\(UUID().uuidString.lowercased())"
            operations.insert(id)
            enqueue(.mcpStarted, ["operationId": .string(id), "callId": .string(callID),
                                 "server": server.map(JSONValue.string) ?? .null, "tool": .string(tool), "transport": .null])
            if let correlationID {
                enqueue(.mcpRequest, ["operationId": .string(id), "requestId": .string(correlationID), "requestIdKind": .string("correlation")])
            }
            return (id, startDraining())
        }
        if result.1 { drain() }
        return result.0
    }

    func end(_ id: String?, status: String, error: String? = nil) {
        let shouldDrain = lock.withLock {
            guard let id, operations.remove(id) != nil else { return false }
            enqueue(.mcpEnded, ["operationId": .string(id), "status": .string(status), "error": error.map(JSONValue.string) ?? .null])
            return startDraining()
        }
        if shouldDrain { drain() }
    }

    func invalidate() {
        let shouldDrain = lock.withLock {
            active = false
            for id in operations {
                enqueue(.mcpEnded, ["operationId": .string(id), "status": .string("cancelled"), "error": .null])
            }
            operations.removeAll()
            return startDraining()
        }
        if shouldDrain { drain() }
    }

    // These helpers require the lock.
    private func enqueue(_ kind: FxObservation.Kind, _ data: [String: JSONValue]) {
        pending.append(FxObservation(scope: scope, kind: kind, data: .object(data), timestamp: Date(),
                                     captureContent: options.captureContent))
    }

    private func startDraining() -> Bool {
        guard !draining, !pending.isEmpty else { return false }
        draining = true
        return true
    }

    private func drain() {
        while let event = lock.withLock({ () -> FxObservation? in
            guard !pending.isEmpty else { draining = false; return nil }
            return pending.removeFirst()
        }) {
            options.deliver(event)
        }
    }
}
