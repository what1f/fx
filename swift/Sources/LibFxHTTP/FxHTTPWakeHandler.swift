import Foundation
import HTTPTypes
import LibFx

/// A reference to input already accepted by a durable agent. It contains no input content.
public struct FxHTTPWakeRequest: Sendable, Codable, Equatable {
    public let store: String
    public let agent: String
    public let sessionID: String
    public let inputID: String

    public init(store: String, agent: String, sessionID: String, inputID: String) {
        self.store = store
        self.agent = agent
        self.sessionID = sessionID
        self.inputID = inputID
    }

    public init(store: String, wakeup: FxSessionWakeup) throws {
        guard let inputID = wakeup.inputID else { throw FxError.invalidInput("Wakeup has no accepted input ID") }
        self.init(store: store, agent: wakeup.agent, sessionID: wakeup.sessionID, inputID: inputID)
    }
}

public struct FxHTTPWakeResponse: Sendable {
    public let response: HTTPResponse
    public let body: Data

    public init(response: HTTPResponse, body: Data = Data()) {
        self.response = response
        self.body = body
    }
}

/// A server-independent route for durable wakeups. The host owns routers and HTTP serving.
///
/// Complete deliveries and unknown input references return 200. A retry returns
/// 503 with Retry-After; a delivery failure returns 500. The queue must retain
/// every delivery receiving a non-success response. Cancellation throws and does
/// not acknowledge the delivery or stop its durable worker. Close the agents to
/// join their active work before shutting down the host.
public struct FxHTTPWakeHandler: Sendable {
    private let routes: [String: FxAgentRouter]
    private let policy: FxDeliveryPolicy?
    private let onError: (@Sendable (any Error) async -> Void)?

    public init(
        routes: [String: FxAgentRouter], policy: FxDeliveryPolicy? = nil,
        onError: (@Sendable (any Error) async -> Void)? = nil
    ) {
        self.routes = routes
        self.policy = policy
        self.onError = onError
    }

    /// Mount this operation in the application's existing HTTP server.
    /// The host must limit body collection to 16 KiB before calling this method.
    public func handle(_ request: HTTPRequest, body: Data,
                       context: FxQueueDeliveryContext? = nil) async throws -> FxHTTPWakeResponse {
        try Task.checkCancellation()
        guard request.method == .post else {
            var response = HTTPResponse(status: .methodNotAllowed)
            response.headerFields[.allow] = "POST"
            return FxHTTPWakeResponse(response: response)
        }
        guard body.count <= 16 * 1024 else {
            return FxHTTPWakeResponse(response: HTTPResponse(status: .contentTooLarge))
        }
        var available = false
        for router in routes.values {
            if await router.hasWakeAgents {
                available = true
                break
            }
        }
        try Task.checkCancellation()
        guard available else { return reply(.serviceUnavailable) }
        guard let message = try? JSONDecoder().decode(FxHTTPWakeRequest.self, from: body) else {
            return reply(.ok)
        }
        guard let router = routes[message.store] else { return reply(.internalServerError) }
        do {
            let outcome = try await router.deliverAccepted(
                FxSessionWakeup(agent: message.agent, sessionID: message.sessionID),
                inputID: message.inputID, policy: policy, context: context)
            try Task.checkCancellation()
            switch outcome {
            case .complete:
                return reply(.ok)
            case .retry(let delay):
                let parts = delay.components
                let rounded = parts.seconds.addingReportingOverflow(parts.attoseconds > 0 ? 1 : 0)
                let seconds = rounded.overflow ? Int64.max : max(0, rounded.partialValue)
                var response = HTTPResponse(status: .serviceUnavailable)
                response.headerFields[.retryAfter] = String(seconds)
                return FxHTTPWakeResponse(response: response)
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try Task.checkCancellation()
            await onError?(error)
            try Task.checkCancellation()
            return reply(.internalServerError)
        }
    }

    private func reply(_ status: HTTPResponse.Status) -> FxHTTPWakeResponse {
        FxHTTPWakeResponse(response: HTTPResponse(status: status))
    }
}
