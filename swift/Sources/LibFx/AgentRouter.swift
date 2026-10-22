import Foundation

public enum FxAgentRoutingError: Error, Sendable, Equatable {
    case duplicateName(String)
    case unavailableAgent(String)
}

/// A host-owned set of named executors sharing one durable store.
public actor FxAgentRouter {
    private struct Registration {
        weak var agent: FxAgent?
    }
    private let store: any FxSessionStorage
    private var agents: [String: Registration] = [:]

    public init(store: any FxSessionStorage) { self.store = store }

    public func makeAgent<Harness: FxDurableHarness>(harness: Harness, name: String = "default",
        checkpoint: Data? = nil, checkpointAfterBytes: Int? = 64 * 1024,
        deliveryPolicy: FxDeliveryPolicy? = nil, openingRetryPolicy: FxOpeningRetryPolicy? = nil, queue: (any FxSessionQueue)? = nil,
        onLifecycleEvent: (@Sendable (FxLifecycleEvent) async -> Void)? = nil
    ) async throws -> FxDurableAgent<Harness.Input, Harness.Update> {
        let agent = try await makeAgent(harness: DurableHarnessAdapter(harness: harness), name: name,
            checkpoint: checkpoint, checkpointAfterBytes: checkpointAfterBytes, deliveryPolicy: deliveryPolicy, openingRetryPolicy: openingRetryPolicy,
            queue: queue, onLifecycleEvent: onLifecycleEvent)
        return FxDurableAgent(agent: agent)
    }

    public func makeAgent(harness: any FxSessionHarness, name: String = "default",
        checkpoint: Data? = nil, checkpointAfterBytes: Int? = 64 * 1024,
        deliveryPolicy: FxDeliveryPolicy? = nil, openingRetryPolicy: FxOpeningRetryPolicy? = nil, queue: (any FxSessionQueue)? = nil,
        onLifecycleEvent: (@Sendable (FxLifecycleEvent) async -> Void)? = nil
    ) async throws -> FxAgent {
        guard agents[name]?.agent == nil else { throw FxAgentRoutingError.duplicateName(name) }
        let agent = try FxAgent(harness: harness, name: name, store: store, checkpoint: checkpoint,
            checkpointAfterBytes: checkpointAfterBytes, deliveryPolicy: deliveryPolicy, openingRetryPolicy: openingRetryPolicy,
            queue: queue, onLifecycleEvent: onLifecycleEvent)
        agents[name] = Registration(agent: agent)
        await agent.attachRouter(self)
        return agent
    }

    public func makeAgent(configuration: FxConfiguration, name: String = "default",
        checkpoint: Data? = nil, checkpointAfterBytes: Int? = 64 * 1024,
        deliveryPolicy: FxDeliveryPolicy? = nil, openingRetryPolicy: FxOpeningRetryPolicy? = nil, queue: (any FxSessionQueue)? = nil
    ) async throws -> FxAgent {
        guard agents[name]?.agent == nil else { throw FxAgentRoutingError.duplicateName(name) }
        let agent = try FxAgent(configuration: configuration, name: name, store: store, checkpoint: checkpoint,
            checkpointAfterBytes: checkpointAfterBytes, deliveryPolicy: deliveryPolicy, openingRetryPolicy: openingRetryPolicy, queue: queue)
        agents[name] = Registration(agent: agent)
        await agent.attachRouter(self)
        return agent
    }

    func agent(named name: String) throws -> FxAgent {
        guard let agent = agents[name]?.agent else { throw FxAgentRoutingError.unavailableAgent(name) }
        return agent
    }

    func remove(_ agent: FxAgent) {
        if agents[agent.name]?.agent === agent { agents[agent.name] = nil }
    }

    /// An unknown target throws. The host must retain its wakeup for retry.
    public func deliver(_ wakeup: FxSessionWakeup, policy: FxDeliveryPolicy? = nil) async throws -> FxDeliveryOutcome {
        try await agent(named: wakeup.agent).deliver(wakeup, policy: policy)
    }
}
