import Foundation
import Testing
import LibFx

private actor RoutingTrace {
    var opens: [String] = []
    var forwards: [String] = []
    var failures: [String: FxSessionFailure] = [:]
    func opened(_ name: String) { opens.append(name) }
    func event(_ event: FxLifecycleEvent) {
        if case .sessionForwarded(_, let agent) = event { forwards.append(agent) }
        if case .harnessFailed(_, let id, let error) = event { failures[id] = FxSessionFailure(error) }
    }
}

private actor RoutingBarrier {
    var waiting: CheckedContinuation<Void, Never>?
    var released = false
    func arrive() async {
        if released { return }
        if let waiting { self.waiting = nil; released = true; waiting.resume(); return }
        await withCheckedContinuation { waiting = $0 }
    }
}

private struct RoutedCalculation: FxDurableHarness {
    typealias Input = CalculationInput
    typealias Update = CalculationUpdate
    let name: String
    let trace: RoutingTrace
    var barrier: RoutingBarrier?
    var openBarrier: RoutingBarrier?
    var rejectsMarkedInput = false
    var rejectsInput = false
    var delay: Duration = .milliseconds(3)
    func validate(options: FxSessionOptions) throws {
        if options.settings?["reject"] == .bool(true) {
            throw FxSessionFailure(message: "Settings refused", name: "SettingsRejected", code: .string("settings"))
        }
    }
    func validate(_ input: Input, options: FxSessionOptions) throws {
        if rejectsMarkedInput, input.labels["reject"] == "yes" {
            throw FxSessionFailure(message: "Input refused", name: "InputRejected", code: .string("input"))
        }
        if rejectsInput { throw FxError.invalidInput("Unexpected executor") }
        try CalculationHarness().validate(input, options: options)
    }
    func prepareCheckpoint(_ data: Data, options: FxSessionOptions) async throws -> Data {
        await barrier?.arrive()
        return try CalculationHarness().prepareCheckpoint(data, options: options)
    }
    func open(_ context: FxHarnessContext) async throws -> any FxDurableHarnessSession<Input, Update> {
        await trace.opened(name)
        await openBarrier?.arrive()
        return try await CalculationHarness(delay: delay).open(context)
    }
}

private actor RoutingQueue: FxSessionQueue {
    var messages: [FxSessionWakeup] = []
    var failClosed = false
    func failNextWithClosed() { failClosed = true }
    func enqueue(_ wakeup: FxSessionWakeup) throws {
        if failClosed { failClosed = false; throw FxError.closed }
        messages.append(wakeup)
    }
}

@Suite(.serialized, .timeLimit(.minutes(1))) struct AgentRoutingTests {
    let input = CalculationInput(values: [2, -3, 8], labels: ["nested.key": "中文 café"], attachment: Data([0, 255, 10]))

    @Test func foreignViewsRouteInputsControlsAndReplayToTheStoredOwner() async throws {
        let store = try FxSessionStore(), router = FxAgentRouter(store: store), trace = RoutingTrace()
        let owner = try await router.makeAgent(harness: RoutedCalculation(name: "owner", trace: trace, delay: .milliseconds(20)), name: "owner")
        let sender = try await router.makeAgent(harness: RoutedCalculation(name: "sender", trace: trace, rejectsInput: true), name: "sender", onLifecycleEvent: { await trace.event($0) })
        // The foreign view predates ownership and must follow the first accepted input later.
        let foreign = try await sender.session(id: "routed"), canonical = try await owner.session(id: "routed")
        let first = try await canonical.submit(input, id: "one")
        #expect(try await first.result.stopReason == .endTurn)
        let repeated = try await foreign.submit(CalculationInput(values: [999]), id: "one")
        #expect(try await repeated.result.isRepeated)
        var replay = foreign.events().makeAsyncIterator()
        guard case .started("one", "routed", let saved) = try await replay.next()?.event else { Issue.record("Missing routed input"); return }
        #expect(saved == input)
        let active = try await foreign.submit(CalculationInput(values: Array(repeating: 1, count: 20)), id: "active")
        var updates = active.makeAsyncIterator()
        #expect(try await updates.next()?.index == 0)
        let steered = try await foreign.steer(input, id: "steer")
        #expect(try await active.result.stopReason == .cancelled)
        #expect(try await steered.result.stopReason == .endTurn)
        let cancel = try await foreign.submit(input, id: "cancel")
        var cancelling = cancel.makeAsyncIterator()
        #expect(try await cancelling.next()?.index == 0)
        try await foreign.cancel()
        #expect(try await cancel.result.stopReason == .cancelled)
        #expect(try await foreign.resume() == nil)
        #expect(!(try await foreign.checkpoint()).isEmpty)
        #expect(try await store.owner(session: "routed") == "owner")
        #expect(await trace.opens.allSatisfy { $0 == "owner" })
        #expect(await trace.forwards == ["owner", "owner", "owner", "owner"])
        try await owner.close()
        // Persisted reads do not need a live owner registration.
        #expect(try await repeated.result.isRepeated)
        var afterClose = foreign.events().makeAsyncIterator()
        #expect(try await afterClose.next() != nil)
        try await sender.close()
        await #expect(throws: FxError.closed) { try await foreign.resume() }
        await #expect(throws: FxError.closed) { try await foreign.checkpoint() }
        try await store.close()
    }

    @Test func simultaneousFirstInputsChooseOneExecutorAndDeduplicate() async throws {
        let store = try FxSessionStore(), router = FxAgentRouter(store: store), trace = RoutingTrace(), barrier = RoutingBarrier()
        let a = try await router.makeAgent(harness: RoutedCalculation(name: "a", trace: trace, barrier: barrier), name: "a", checkpoint: Data("[]".utf8))
        let b = try await router.makeAgent(harness: RoutedCalculation(name: "b", trace: trace, barrier: barrier), name: "b", checkpoint: Data("[]".utf8))
        let av = try await a.session(id: "racing"), bv = try await b.session(id: "racing")
        async let left = av.submit(input, id: "same")
        async let right = bv.submit(CalculationInput(values: [100]), id: "same")
        let (first, second) = try await (left, right)
        #expect(first.isRepeated != second.isRepeated)
        #expect(try await first.result.stopReason == .endTurn)
        #expect(try await second.result.stopReason == .endTurn)
        let winner = try #require(try await store.owner(session: "racing"))
        #expect(await trace.opens == [winner])
        let entries = try await store.entries(session: "racing", agent: winner, after: 0)
        #expect(entries.filter { if case .started = $0.event { return true }; return false }.count == 1)
        try await a.close(); try await b.close(); try await store.close()
    }

    @Test func queueRoutesByNameAndRetainsWorkWhileTheOwnerIsUnavailable() async throws {
        let store = try FxSessionStore(), router = FxAgentRouter(store: store), trace = RoutingTrace(), queue = RoutingQueue()
        let owner = try await router.makeAgent(harness: RoutedCalculation(name: "owner", trace: trace), name: "owner", queue: queue)
        let sender = try await router.makeAgent(harness: RoutedCalculation(name: "sender", trace: trace, rejectsInput: true), name: "sender", queue: queue)
        let view = try await owner.session(id: "queued-routing")
        let first = try await view.submit(input, id: "one")
        await #expect(throws: FxAgentRoutingError.duplicateName("owner")) { try await router.makeAgent(harness: CalculationHarness(), name: "owner") }
        try await owner.close()
        let foreign = try await sender.session(id: view.id)
        await #expect(throws: FxAgentRoutingError.unavailableAgent("owner")) { try await foreign.submit(input, id: "two") }
        #expect(try await store.resumePoint(session: view.id, agent: "owner")?.id == "one")
        let lease = try #require(try await store.claim(session: view.id, agent: "owner"))
        #expect(try await store.input(lease, id: "two") != nil)
        try await store.release(lease)
        await #expect(throws: FxAgentRoutingError.unavailableAgent("owner")) { try await router.deliver(FxSessionWakeup(agent: "owner", sessionID: view.id)) }
        #expect(await trace.opens.isEmpty)
        let replacement = try await router.makeAgent(harness: RoutedCalculation(name: "owner", trace: trace), name: "owner", queue: queue)
        let resumed = try #require(try await foreign.resume())
        let wakeup = try #require(await queue.messages.last)
        #expect(wakeup == FxSessionWakeup(agent: "owner", sessionID: view.id))
        let keys = try JSONSerialization.jsonObject(with: JSONEncoder().encode(wakeup)) as? [String: Any]
        #expect(Set(keys?.keys.map { $0 } ?? []) == ["agent", "sessionID"])
        #expect(try await router.deliver(wakeup) == .complete)
        #expect(try await router.deliver(wakeup) == .complete)
        #expect(try await first.result.stopReason == .endTurn)
        #expect(try await resumed.result.stopReason == .endTurn)
        #expect(await trace.opens == ["owner", "owner"])
        try await replacement.close(); try await sender.close(); try await store.close()
    }
    @Test func reopenedStoreKeepsItsOwnerAndRouterScope() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("routing.sqlite")
        let store = try FxSessionStore(url: url), router = FxAgentRouter(store: store), queue = RoutingQueue()
        let first = try await router.makeAgent(harness: CalculationHarness(), name: "original", queue: queue)
        _ = try await first.session(id: "reopen").submit(input, id: "one")
        try await first.close(); try await store.close()
        let reopened = try FxSessionStore(url: url), reopenedRouter = FxAgentRouter(store: reopened), trace = RoutingTrace()
        let owner = try await reopenedRouter.makeAgent(harness: RoutedCalculation(name: "original", trace: trace), name: "original", queue: queue)
        let sender = try await reopenedRouter.makeAgent(harness: RoutedCalculation(name: "sender", trace: trace, rejectsInput: true), name: "sender", queue: queue)
        let foreign = try await sender.session(id: "reopen")
        let second = try await foreign.submit(input, id: "two")
        #expect(try await reopenedRouter.deliver(FxSessionWakeup(agent: "original", sessionID: "reopen")) == .complete)
        #expect(try await second.result.stopReason == .endTurn)
        #expect(try await reopened.owner(session: "reopen") == "original")
        #expect(await trace.opens == ["original", "original"])
        let otherStore = try FxSessionStore(), otherRouter = FxAgentRouter(store: otherStore)
        await #expect(throws: FxAgentRoutingError.unavailableAgent("original")) {
            try await otherRouter.deliver(FxSessionWakeup(agent: "original", sessionID: "reopen"))
        }
        try await owner.close(); try await sender.close(); try await reopened.close(); try await otherStore.close()
    }

    @Test func closingRegisteredOwnerRetainsForwardedInputBeforeRejectingItsWakeup() async throws {
        let store = try FxSessionStore(), router = FxAgentRouter(store: store), trace = RoutingTrace(), barrier = RoutingBarrier()
        let owner = try await router.makeAgent(harness: RoutedCalculation(name: "owner", trace: trace, openBarrier: barrier), name: "owner")
        let sender = try await router.makeAgent(harness: RoutedCalculation(name: "sender", trace: trace, rejectsInput: true), name: "sender")
        let first = try await owner.session(id: "closing-owner").submit(input, id: "one")
        // Keep the owner's worker inside open so close cannot remove its registration yet.
        while await barrier.waiting == nil { await Task.yield() }
        let closing = Task { try await owner.close() }
        while true {
            do { _ = try await owner.session(id: "probe"); await Task.yield() }
            catch FxError.closed { break }
        }
        let foreign = try await sender.session(id: "closing-owner")
        await #expect(throws: FxAgentRoutingError.unavailableAgent("owner")) { try await foreign.submit(input, id: "two") }
        await #expect(throws: FxError.closed) {
            try await router.deliver(FxSessionWakeup(agent: "owner", sessionID: foreign.id))
        }
        await barrier.arrive()
        try await closing.value
        #expect(try await first.result.stopReason == .endTurn)
        let entries = try await store.entries(session: foreign.id, agent: "owner", after: 0)
        let saved = try entries.compactMap { entry -> CalculationInput? in
            guard case .started("two", _, let content) = entry.event,
                  case .payload(let data) = content.first else { return nil }
            return try JSONDecoder().decode(CalculationInput.self, from: data)
        }
        #expect(saved == [input])
        #expect(await trace.opens == ["owner", "owner"])
        #expect(await trace.forwards.isEmpty)
        try await sender.close(); try await store.close()
    }

    @Test func forwardingPreservesTheHostQueueClosedErrorWhileItsOwnerIsOpen() async throws {
        let store = try FxSessionStore(), router = FxAgentRouter(store: store), trace = RoutingTrace(), queue = RoutingQueue()
        let owner = try await router.makeAgent(harness: CalculationHarness(), name: "owner", queue: queue)
        let sender = try await router.makeAgent(harness: CalculationHarness(), name: "sender", onLifecycleEvent: { await trace.event($0) })
        _ = try await owner.session(id: "closed-queue").submit(input, id: "one")
        let foreign = try await sender.session(id: "closed-queue")
        await queue.failNextWithClosed()
        await #expect(throws: FxError.closed) { try await foreign.submit(input, id: "two") }
        #expect(await trace.forwards.isEmpty)
        let resumed = try #require(try await foreign.resume())
        #expect(try await router.deliver(FxSessionWakeup(agent: "owner", sessionID: foreign.id)) == .complete)
        #expect(try await resumed.result.stopReason == .endTurn)
        let entries = try await store.entries(session: foreign.id, agent: "owner", after: 0)
        #expect(entries.filter { if case .started("two", _, _) = $0.event { return true }; return false }.count == 1)
        try await owner.close(); try await sender.close(); try await store.close()
    }

    @Test func offlineInputsAreValidatedByTheirOwnerBeforeOpeningTheExecutor() async throws {
        let store = try FxSessionStore(), router = FxAgentRouter(store: store), trace = RoutingTrace(), queue = RoutingQueue()
        let initial = try await router.makeAgent(harness: CalculationHarness(), name: "owner", queue: queue)
        _ = try await initial.session(id: "offline-validation").submit(input, id: "seed")
        try await initial.close()
        let sender = try await router.makeAgent(harness: CalculationHarness(), name: "sender")
        let foreign = try await sender.session(id: "offline-validation")
        let badSettings = try await sender.session(id: foreign.id, options: .init(settings: .object(["reject": .bool(true)])))
        await #expect(throws: FxAgentRoutingError.unavailableAgent("owner")) { try await badSettings.submit(input, id: "settings") }
        let badInput = CalculationInput(values: [100], labels: ["reject": "yes"])
        await #expect(throws: FxAgentRoutingError.unavailableAgent("owner")) { try await foreign.submit(badInput, id: "input") }
        await #expect(throws: FxAgentRoutingError.unavailableAgent("owner")) { try await foreign.submit(input, id: "valid") }
        let owner = try await router.makeAgent(harness: RoutedCalculation(name: "owner", trace: trace, rejectsMarkedInput: true), name: "owner", queue: queue,
            onLifecycleEvent: { await trace.event($0) })
        let resumed = try #require(try await foreign.resume())
        let wakeup = FxSessionWakeup(agent: "owner", sessionID: foreign.id)
        #expect(try await router.deliver(wakeup) == .complete)
        #expect(try await router.deliver(wakeup) == .complete)
        #expect(try await resumed.result.stopReason == .endTurn)
        let expected = [
            "settings": FxSessionFailure(message: "Settings refused", name: "SettingsRejected", code: .string("settings")),
            "input": FxSessionFailure(message: "Input refused", name: "InputRejected", code: .string("input"))
        ]
        let entries = try await store.entries(session: foreign.id, agent: "owner", after: 0)
        for (id, failure) in expected {
            let result = try #require(try await store.result(session: foreign.id, agent: "owner", id: id))
            #expect(result.stopReason == .error && result.failure == failure)
            #expect(entries.filter { if case .ended(let value) = $0.event { return value.id == id }; return false }.count == 1)
            #expect(!entries.contains { entry in
                switch entry.event {
                case .started(let value, _, _), .update(let value, _): return value == id
                default: return false
                }
            })
        }
        #expect(await trace.failures == expected)
        #expect(await trace.opens == ["owner", "owner"])
        #expect(try await store.result(session: foreign.id, agent: "owner", id: "valid")?.stopReason == .endTurn)
        let lease = try #require(try await store.claim(session: foreign.id, agent: "owner"))
        for id in expected.keys {
            let state = try await store.harnessFailureState(lease, id: id)
            #expect(state.stops == 0 && !state.halted)
        }
        try await store.release(lease)
        try await owner.close(); try await sender.close(); try await store.close()
    }

}
