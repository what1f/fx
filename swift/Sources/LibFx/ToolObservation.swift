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
        guard !Task.isCancelled, let id = state.begin(server: server, tool: tool, correlationID: correlationID) else {
            return try await operation()
        }
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

    /// Observes an input wait without changing its value, error, or decision.
    /// Use resolution and failure to classify host-specific results and timeout errors.
    public func wait<T: Sendable>(_ request: FxWaitRequest,
                                 resolution: @Sendable (T) -> FxWaitResolution = { _ in FxWaitResolution() },
                                 failure: @Sendable (any Error) -> FxWaitResolution.Outcome = { _ in .failed },
                                 operation: @Sendable () async throws -> T) async rethrows -> T {
        guard !Task.isCancelled, let id = state.beginWait(request) else { return try await operation() }
        return try await withTaskCancellationHandler {
            do {
                let value = try await operation()
                state.endWait(id, resolution: Task.isCancelled ? FxWaitResolution(outcome: .cancelled) : resolution(value))
                return value
            } catch {
                let outcome: FxWaitResolution.Outcome = Task.isCancelled || error is CancellationError ? .cancelled : failure(error)
                state.endWait(id, resolution: FxWaitResolution(outcome: outcome), error: String(describing: type(of: error)))
                throw error
            }
        } onCancel: {
            state.endWait(id, resolution: FxWaitResolution(outcome: .cancelled))
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
    private var operations: [String: FxObservation.Kind] = [:]
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
            operations[id] = .mcpEnded
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

    func beginWait(_ request: FxWaitRequest) -> String? {
        guard lock.withLock({ active }) else { return nil }
        let observed = request.observed(captureContent: options.captureContent)
        let result: (String?, Bool) = lock.withLock {
            guard active else { return (nil, false) }
            let id = "host:\(scope.executionID ?? ""):\(callID):\(UUID().uuidString.lowercased())"
            operations[id] = .waitEnded
            var data = observed.data
            data["requestId"] = .string(id)
            data["callId"] = .string(callID)
            enqueue(.waitStarted, data, truncated: observed.truncated)
            return (id, startDraining())
        }
        if result.1 { drain() }
        return result.0
    }

    func end(_ id: String, status: String, error: String? = nil) {
        finish(id, data: ["status": .string(status), "error": error.map(JSONValue.string) ?? .null])
    }

    func endWait(_ id: String, resolution: FxWaitResolution, error: String? = nil) {
        let observed = resolution.observed(captureContent: options.captureContent, error: error)
        finish(id, data: observed.data, truncated: observed.truncated)
    }

    private func finish(_ id: String, data: [String: JSONValue], truncated: Bool = false) {
        let shouldDrain = lock.withLock {
            guard let kind = operations.removeValue(forKey: id) else { return false }
            var data = data
            data[kind == .waitEnded ? "requestId" : "operationId"] = .string(id)
            enqueue(kind, data, truncated: truncated)
            return startDraining()
        }
        if shouldDrain { drain() }
    }

    func invalidate() {
        let shouldDrain = lock.withLock {
            active = false
            for (id, kind) in operations {
                var data: [String: JSONValue] = [
                    kind == .waitEnded ? "requestId" : "operationId": .string(id),
                    kind == .waitEnded ? "outcome" : "status": .string("cancelled"), "error": .null,
                ]
                if kind == .waitEnded, options.captureContent { data["answers"] = .array([]) }
                enqueue(kind, data)
            }
            operations.removeAll()
            return startDraining()
        }
        if shouldDrain { drain() }
    }

    // These helpers require the lock.
    private func enqueue(_ kind: FxObservation.Kind, _ data: [String: JSONValue], truncated: Bool = false) {
        pending.append(FxObservation(scope: scope, kind: kind, data: .object(data), timestamp: Date(),
                                     captureContent: options.captureContent, contentTruncated: truncated))
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
