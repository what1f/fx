import Foundation
import Testing
import LibFx

private actor AdmissionEvents {
    private(set) var count = 0
    func record(_ event: FxLifecycleEvent) { count += 1 }
}

@Suite(.timeLimit(.minutes(1))) struct AgentAdmissionTests {
    private actor Queue: FxSessionQueue {
        func enqueue(_ wakeup: FxSessionWakeup) {}
    }

    @Test func queueAuthorityPolicyMustMatchEvenWithTheSameCompatibilityID() async throws {
        let policy = try FxSessionLeasePolicy(duration: .seconds(60), renewalInterval: .seconds(20))
        let store = try FxSessionStore(leasePolicy: policy, queueSource: "queue"), queue = Queue()
        func authority(_ equal: Bool) throws -> FxQueueDeliveryAuthority {
            try FxQueueDeliveryAuthority(source: "queue", allowsSameAttemptRedelivery: equal) {
                (_: FxSessionWakeup, receipt: FxQueueReceipt) in receipt
            }
        }
        let configuration = FxConfiguration(apiKey: "fixture")
        let first = try FxAgent(configuration: configuration, store: store, queue: queue,
            queueAuthority: authority(false), compatibilityID: "queue/v1")
        #expect(throws: FxAgentAdmissionError.incompatibleConfiguration(name: "default")) {
            try FxAgent(configuration: configuration, store: store, queue: queue,
                queueAuthority: authority(true), compatibilityID: "queue/v1")
        }
        #expect(throws: FxAgentAdmissionError.incompatibleConfiguration(name: "default")) {
            try FxAgent(configuration: configuration, store: store, queue: queue, compatibilityID: "queue/v1")
        }
        let copy = try FxAgent(configuration: configuration, store: store, queue: queue,
            queueAuthority: authority(false), compatibilityID: "queue/v1")
        try await first.close(); try await copy.close(); try await store.close()
    }

    @Test func defaultKernelCopiesIgnoreObserversAndCloseIndependently() async throws {
        let store = try FxSessionStore(), router = FxAgentRouter(store: store)
        let configuration = FxConfiguration(apiKey: "private-key", instructions: "same")
        let first = try await router.makeAgent(configuration: configuration)
        var observed = configuration
        observed.observation = FxObservationOptions(onEvent: { _ in })
        observed.onLifecycleEvent = { _ in }
        observed.onTransportEvent = { _ in }
        let copy = try await router.makeAgent(configuration: observed)
        #expect(first !== copy)
        try await first.close()
        _ = try await copy.session(id: "still-open")
        var changed = configuration
        changed.instructions = "different"
        #expect(throws: FxAgentAdmissionError.incompatibleConfiguration(name: "default")) {
            try FxAgent(configuration: changed, store: store)
        }
        try await copy.close()
        let later = try FxAgent(configuration: changed, store: store)
        try await later.close()
        try await store.close()
    }

    @Test func opaqueFirstInstanceNeedsNoIDButCannotAdmitUnprovenCopies() async throws {
        let store = try FxSessionStore()
        let first = try FxDurableAgent(harness: CalculationHarness(), store: store)
        #expect(throws: FxAgentAdmissionError.incompatibleConfiguration(name: "default")) {
            try FxDurableAgent(harness: CalculationHarness(), store: store)
        }
        // An ID on only the second registration cannot prove what the first meant.
        #expect(throws: FxAgentAdmissionError.incompatibleConfiguration(name: "default")) {
            try FxDurableAgent(harness: CalculationHarness(), store: store, compatibilityID: "calc/v1")
        }
        let otherName = try FxDurableAgent(harness: CalculationHarness(), name: "other", store: store)
        let otherStore = try FxSessionStore()
        let elsewhere = try FxDurableAgent(harness: CalculationHarness(), store: otherStore)
        try await first.close(); try await otherName.close(); try await elsewhere.close()
        try await store.close(); try await otherStore.close()
    }

    @Test func hostIdentityAllowsCopiesAcrossDirectAndRoutedConstruction() async throws {
        let store = try FxSessionStore(), router = FxAgentRouter(store: store)
        let firstEvents = AdmissionEvents(), copyEvents = AdmissionEvents()
        let first = try await router.makeAgent(harness: CalculationHarness(), name: "calc",
            compatibilityID: "calc/v1", onLifecycleEvent: { await firstEvents.record($0) })
        let copy = try await router.makeAgent(harness: CalculationHarness(), name: "calc",
            compatibilityID: "calc/v1", onLifecycleEvent: { await copyEvents.record($0) })
        let direct = try FxDurableAgent(harness: CalculationHarness(), name: "calc", store: store,
            compatibilityID: "calc/v1")
        #expect(throws: FxAgentAdmissionError.incompatibleConfiguration(name: "calc")) {
            try FxDurableAgent(harness: CalculationHarness(), name: "calc", store: store,
                compatibilityID: "calc/v2")
        }
        let firstSession = try await first.session(id: "first")
        let firstTurn = try await firstSession.submit(CalculationInput(values: [2, 3]))
        #expect(try await firstTurn.result.stopReason == .endTurn)
        try await first.close()
        let session = try await copy.session(id: "copy")
        let turn = try await session.submit(CalculationInput(values: [7, 11]))
        #expect(try await turn.result.stopReason == .endTurn)
        try await copy.close()
        await #expect(throws: FxAgentRoutingError.unavailableAgent("calc")) {
            try await router.deliver(FxSessionWakeup(agent: "calc", sessionID: "copy"))
        }
        // A direct registration still owns the definition after both routed copies close.
        await #expect(throws: FxAgentAdmissionError.incompatibleConfiguration(name: "calc")) {
            try await router.makeAgent(harness: CalculationHarness(), name: "calc", compatibilityID: "calc/v2")
        }
        try await direct.close()
        let later = try await router.makeAgent(harness: CalculationHarness(), name: "calc", compatibilityID: "calc/v2")
        try await later.close(); try await store.close()
    }

    @Test(arguments: ["model", "instructions", "schema", "tool-name", "checkpoint", "checkpoint-interval", "provider", "catalog", "image-window", "workspace", "delivery"])
    func identityNeverOverridesStructuralDifferences(field: String) async throws {
        let store = try FxSessionStore()
        let tool = FxTool(name: "read", description: "Read", inputSchema: .object(["type": .string("object")]),
            isIdempotent: true) { _, _ in FxToolResult(text: "done") }
        var configuration = FxConfiguration(apiKey: "private-key", instructions: "original", tools: [tool])
        let first = try FxAgent(configuration: configuration, store: store, compatibilityID: "host/v1")
        var checkpoint: Data?
        var interval: Int? = 64 * 1024
        var delivery: FxDeliveryPolicy?
        switch field {
        case "model": configuration.model = "different-model"
        case "instructions": configuration.instructions = "changed"
        case "schema": configuration.tools = [FxTool(name: "read", description: "Read", inputSchema: .object(["type": .string("string")]), isIdempotent: true) { _, _ in FxToolResult(text: "done") }]
        case "tool-name": configuration.tools = [FxTool(name: "write", description: "Read", inputSchema: tool.inputSchema, isIdempotent: true) { _, _ in FxToolResult(text: "done") }]
        case "checkpoint": checkpoint = Data("different".utf8)
        case "checkpoint-interval": interval = 1
        case "provider": configuration.provider = .gateway(apiKey: "another-private-key")
        case "catalog": configuration.modelCatalog = try FxModelCatalog(response: Data("{\"data\":[{\"id\":\"other\"}]}".utf8))
        case "image-window": configuration.imageWindow = try FxImageWindow(maximumImages: 1)
        case "workspace": configuration.workspace = URL(fileURLWithPath: "/tmp/another-workspace")
        default: delivery = try FxDeliveryPolicy(maximumDuration: .seconds(60))
        }
        #expect(throws: FxAgentAdmissionError.incompatibleConfiguration(name: "default")) {
            try FxAgent(configuration: configuration, store: store, checkpoint: checkpoint,
                checkpointAfterBytes: interval, deliveryPolicy: delivery, compatibilityID: "host/v1")
        }
        try await first.close()
        // Failed registrations must not keep the old definition alive.
        let changed = try FxAgent(configuration: configuration, store: store, checkpoint: checkpoint,
            checkpointAfterBytes: interval, deliveryPolicy: delivery, compatibilityID: "host/v1")
        try await changed.close(); try await store.close()
    }

    @Test func separateConnectionsAndProxiesUseTheHostsSharedAdmissionDomain() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let domain = FxAgentAdmission(), url = directory.appendingPathComponent("admission.sqlite")
        let firstStore = try FxSessionStore(url: url, agentAdmission: domain)
        let secondStore = try FxSessionStore(url: url, agentAdmission: domain)
        let proxy = SessionStorageProxy(secondStore)
        #expect(proxy.agentAdmission === domain)
        let first = try FxDurableAgent(harness: CalculationHarness(), store: firstStore, compatibilityID: "v1")
        let router = FxAgentRouter(store: proxy)
        await #expect(throws: FxAgentAdmissionError.incompatibleConfiguration(name: "default")) {
            try await router.makeAgent(harness: CalculationHarness(), compatibilityID: "v2")
        }
        let copy = try await router.makeAgent(harness: CalculationHarness(), compatibilityID: "v1")
        try await first.close(); try await copy.close()
        try await firstStore.close(); try await secondStore.close()
    }

    @Test func aDrainedCloseReleasesAdmissionEvenWhenItReportsAStorageFailure() async throws {
        let store = try FxSessionStore(), proxy = SessionStorageProxy(store)
        let failure = SessionStorageTestFailure()
        await proxy.failNext("loadJournal", with: failure)
        let first = try FxDurableAgent(harness: CalculationHarness(), store: proxy, compatibilityID: "v1")
        let session = try await first.session(id: "failed")
        let turn = try await session.submit(CalculationInput(values: [1]))
        do { _ = try await turn.result; Issue.record("Expected storage failure") }
        catch { #expect((error as? SessionStorageTestFailure) === failure) }
        do { try await first.close(); Issue.record("Expected close to retain storage failure") }
        catch { #expect((error as? SessionStorageTestFailure) === failure) }
        let replacement = try FxDurableAgent(harness: CalculationHarness(), store: proxy, compatibilityID: "v2")
        try await replacement.close(); try await store.close()
    }

    @Test func concurrentConflictingCreationAdmitsExactlyOneDefinition() async throws {
        let store = try FxSessionStore()
        let agents = await withTaskGroup(of: FxAgent?.self, returning: [FxAgent].self) { group in
            for index in 0..<20 {
                group.addTask {
                    try? FxAgent(configuration: FxConfiguration(apiKey: "key", instructions: "\(index)"), store: store)
                }
            }
            var agents: [FxAgent] = []
            for await agent in group { if let agent { agents.append(agent) } }
            return agents
        }
        #expect(agents.count == 1)
        for agent in agents { try await agent.close() }
        try await store.close()
    }
}
