import Foundation
import Testing
import LibFx

private actor ReplicaQueue: FxSessionQueue {
    var wakeups: [FxSessionWakeup] = []
    func enqueue(_ wakeup: FxSessionWakeup) { wakeups.append(wakeup) }
}

@Suite struct RouterReplicaTests {
    @Test func separateHostsWithTheSameNamedHarnessShareOrderedWorkAndDeduplicate() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("replicas.sqlite")
        let firstStore = try FxSessionStore(url: url), secondStore = try FxSessionStore(url: url)
        let firstRouter = FxAgentRouter(store: firstStore), secondRouter = FxAgentRouter(store: secondStore)
        let queue = ReplicaQueue()
        let first = try await firstRouter.makeAgent(harness: CalculationHarness(), name: "calculator", queue: queue)
        let second = try await secondRouter.makeAgent(harness: CalculationHarness(), name: "calculator", queue: queue)
        let left = try await first.session(id: "shared"), right = try await second.session(id: "shared")
        let original = CalculationInput(values: [2, 3, 5])
        let one = try await left.submit(original, id: "one")
        let repeated = try await right.submit(CalculationInput(values: [100]), id: "one")
        let two = try await right.submit(CalculationInput(values: [7, 11, 13]), id: "two")
        #expect(!one.isRepeated && repeated.isRepeated)
        let wakeup = FxSessionWakeup(agent: "calculator", sessionID: "shared")
        async let firstDelivery = firstRouter.deliver(wakeup)
        async let secondDelivery = secondRouter.deliver(wakeup)
        _ = try await (firstDelivery, secondDelivery)
        // Duplicate messages remain valid after either host drains the shared inbox.
        #expect(try await secondRouter.deliver(wakeup) == .complete)
        #expect(try await one.result.stopReason == .endTurn)
        #expect(try await repeated.result.isRepeated)
        #expect(try await two.result.stopReason == .endTurn)
        let entries = try await firstStore.entries(session: "shared", agent: "calculator", after: 0)
        let starts = entries.compactMap { entry -> String? in
            if case .started(let id, _, _) = entry.event { return id }
            return nil
        }
        let updateIDs = entries.compactMap { entry -> String? in
            if case .update(let id, _) = entry.event { return id }
            return nil
        }
        #expect(starts == ["one", "two"])
        #expect(updateIDs == ["one", "one", "one", "two", "two", "two"])
        var updates: [CalculationUpdate] = []
        for try await update in repeated { updates.append(update) }
        #expect(updates.map(\.total) == [2, 5, 10])
        #expect(updates.allSatisfy { $0.input == original })
        try await first.close(); try await second.close()
        try await firstStore.close(); try await secondStore.close()
    }
}
