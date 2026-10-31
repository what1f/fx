import Foundation

public enum FxAgentRoutingError: Error, Sendable, Equatable {
    case unavailableAgent(String)
}

/// A host-owned set of named executors sharing one durable store.
public actor FxAgentRouter {
    private struct Registration {
        weak var agent: FxAgent?
    }
    private let store: any FxSessionStorage
    private var agents: [String: [Registration]] = [:]

    public init(store: any FxSessionStorage) { self.store = store }

    public func makeAgent<Harness: FxDurableHarness>(harness: Harness, name: String = "default",
        checkpoint: Data? = nil, checkpointAfterBytes: Int? = 64 * 1024,
        deliveryPolicy: FxDeliveryPolicy? = nil, openingRetryPolicy: FxOpeningRetryPolicy? = nil, queue: (any FxSessionQueue)? = nil, queueAuthority: FxQueueDeliveryAuthority? = nil,
        compatibilityID: String? = nil,
        onLifecycleEvent: (@Sendable (FxLifecycleEvent) async -> Void)? = nil
    ) async throws -> FxDurableAgent<Harness.Input, Harness.Update> {
        let agent = try await makeAgent(harness: DurableHarnessAdapter(harness: harness), name: name,
            checkpoint: checkpoint, checkpointAfterBytes: checkpointAfterBytes, deliveryPolicy: deliveryPolicy, openingRetryPolicy: openingRetryPolicy,
            queue: queue, queueAuthority: queueAuthority, compatibilityID: compatibilityID, onLifecycleEvent: onLifecycleEvent)
        return FxDurableAgent(agent: agent)
    }

    public func makeAgent(harness: any FxSessionHarness, name: String = "default",
        checkpoint: Data? = nil, checkpointAfterBytes: Int? = 64 * 1024,
        deliveryPolicy: FxDeliveryPolicy? = nil, openingRetryPolicy: FxOpeningRetryPolicy? = nil, queue: (any FxSessionQueue)? = nil, queueAuthority: FxQueueDeliveryAuthority? = nil,
        compatibilityID: String? = nil,
        onLifecycleEvent: (@Sendable (FxLifecycleEvent) async -> Void)? = nil
    ) async throws -> FxAgent {
        let agent = try FxAgent(harness: harness, name: name, store: store, checkpoint: checkpoint,
            checkpointAfterBytes: checkpointAfterBytes, deliveryPolicy: deliveryPolicy, openingRetryPolicy: openingRetryPolicy,
            queue: queue, queueAuthority: queueAuthority, compatibilityID: compatibilityID, onLifecycleEvent: onLifecycleEvent)
        agents[name, default: []].append(Registration(agent: agent))
        await agent.attachRouter(self)
        return agent
    }

    public func makeAgent(configuration: FxConfiguration, name: String = "default",
        checkpoint: Data? = nil, checkpointAfterBytes: Int? = 64 * 1024,
        deliveryPolicy: FxDeliveryPolicy? = nil, openingRetryPolicy: FxOpeningRetryPolicy? = nil, queue: (any FxSessionQueue)? = nil, queueAuthority: FxQueueDeliveryAuthority? = nil, compatibilityID: String? = nil
    ) async throws -> FxAgent {
        let agent = try FxAgent(configuration: configuration, name: name, store: store, checkpoint: checkpoint,
            checkpointAfterBytes: checkpointAfterBytes, deliveryPolicy: deliveryPolicy, openingRetryPolicy: openingRetryPolicy, queue: queue, queueAuthority: queueAuthority, compatibilityID: compatibilityID)
        agents[name, default: []].append(Registration(agent: agent))
        await agent.attachRouter(self)
        return agent
    }

    func agent(named name: String) async throws -> FxAgent {
        let members = agents[name]?.compactMap(\.agent) ?? []
        for agent in members where !(await agent.isClosed) { return agent }
        if let closing = members.first { return closing }
        throw FxAgentRoutingError.unavailableAgent(name)
    }

    func remove(_ agent: FxAgent) {
        agents[agent.name]?.removeAll { $0.agent == nil || $0.agent === agent }
        if agents[agent.name]?.isEmpty == true { agents[agent.name] = nil }
    }

    /// An unknown target throws. The host must retain its wakeup for retry.
    public func deliver(_ wakeup: FxSessionWakeup, policy: FxDeliveryPolicy? = nil) async throws -> FxDeliveryOutcome {
        try await agent(named: wakeup.agent).deliver(wakeup, policy: policy)
    }

    public func deliver(_ wakeup: FxSessionWakeup, context: FxQueueDeliveryContext,
                        policy: FxDeliveryPolicy? = nil) async throws -> FxDeliveryOutcome {
        try await agent(named: wakeup.agent).deliver(wakeup, context: context, policy: policy)
    }

    package var hasWakeAgents: Bool { agents.values.contains { $0.contains { $0.agent != nil } } }

    /// HTTP deliveries reference accepted input; their bodies never create work.
    package func deliverAccepted(_ wakeup: FxSessionWakeup, inputID: String,
                                 policy: FxDeliveryPolicy?, context: FxQueueDeliveryContext? = nil) async throws -> FxDeliveryOutcome {
        _ = try await agent(named: wakeup.agent)
        guard validSessionIdentifier(wakeup.sessionID), validSessionIdentifier(inputID) else { return .complete }
        guard let owner = try await store.owner(session: wakeup.sessionID) else { return .complete }
        do {
            _ = try await store.result(session: wakeup.sessionID, agent: owner, id: inputID)
        } catch FxSessionError.notFound {
            return .complete
        }
        try Task.checkCancellation()
        let target = try await agent(named: owner)
        let accepted = FxSessionWakeup(agent: owner, sessionID: wakeup.sessionID, inputID: inputID)
        if let context {
            guard owner == wakeup.agent else { throw FxQueueDeliveryError.invalidContext }
            return try await target.deliver(accepted, context: context, policy: policy)
        }
        return try await target.deliver(accepted, policy: policy)
    }
}
