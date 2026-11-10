import Foundation
import Testing
import LibFx

private actor CalculationQueue: FxSessionQueue {
    func enqueue(_ wakeup: FxSessionWakeup) {}
}

@Suite(.serialized, .timeLimit(.minutes(1))) struct DurablePayloadTests {
    private let input = CalculationInput(values: [2, -3, 8], labels: ["中文": "café", "empty": ""], attachment: Data([0, 255, 13, 10]))

    @Test func typedInputUpdatesReplayAndRepeatedIDsUseTheSharedWorker() async throws {
        let store = try FxSessionStore()
        let agent = try FxDurableAgent(harness: CalculationHarness(), store: store)
        let session = try await agent.session(id: "typed")
        let turn = try await session.submit(input, id: "one")
        var updates: [CalculationUpdate] = []
        for try await update in turn { updates.append(update) }
        #expect(updates.map(\.total) == [2, -1, 7])
        #expect(updates.allSatisfy { $0.input == input })
        #expect(try await turn.result.stopReason == .endTurn)
        let repeated = try await session.submit(CalculationInput(values: [999]), id: "one")
        #expect(try await repeated.result.isRepeated)
        var replay = session.events().makeAsyncIterator()
        let started = try #require(try await replay.next())
        guard case .started(let id, let sessionID, let storedInput) = started.event else { Issue.record("Missing typed start"); return }
        #expect(id == "one" && sessionID == "typed" && storedInput == input)
        for expected in updates {
            let entry = try #require(try await replay.next())
            guard case .update("one", let update) = entry.event else { Issue.record("Missing typed update"); return }
            #expect(update == expected)
        }
        let ended = try #require(try await replay.next())
        guard case .ended(let result) = ended.event else { Issue.record("Missing typed end"); return }
        #expect(result.stopReason == .endTurn)
        var cursor = session.events(after: started.cursor).makeAsyncIterator()
        guard case .update = try await cursor.next()?.event else { Issue.record("Cursor did not advance"); return }
        try await agent.close(); try await store.close()
    }

    @Test func yieldingAndDatabaseReopeningPreserveTypedDataAndProgress() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("typed.sqlite"), store = try FxSessionStore(url: url)
        let wakeup = FxSessionWakeup(agent: "default", sessionID: "typed-resume")
        let first = try FxDurableAgent(harness: CalculationHarness(delay: .milliseconds(15)), store: store, queue: CalculationQueue())
        let session = try await first.session(id: wakeup.sessionID)
        _ = try await session.submit(input, id: "one")
        let policy = try FxDeliveryPolicy(maximumDuration: .milliseconds(1), reserve: .zero)
        #expect(try await first.deliver(wakeup, policy: policy) == .retry(after: .zero))
        try await first.close(); try await store.close()
        let reopened = try FxSessionStore(url: url)
        let second = try FxDurableAgent(harness: CalculationHarness(), store: reopened)
        let view = try await second.session(id: wakeup.sessionID)
        let resumed = try #require(try await view.resume())
        #expect(try await resumed.result.stopReason == .endTurn)
        let entries = try await reopened.entries(session: wakeup.sessionID, agent: "default", after: 0)
        let updates = try entries.compactMap { entry -> CalculationUpdate? in
            guard case .update(_, .payload(let bytes)) = entry.event else { return nil }
            return try JSONDecoder().decode(CalculationUpdate.self, from: bytes)
        }
        #expect(updates.map(\.index) == [0, 1, 2])
        #expect(updates.map(\.total) == [2, -1, 7])
        #expect(updates.allSatisfy { $0.input == input })
        try await second.close(); try await reopened.close()
    }

    @Test func typedCheckpointSeedsAndValidationRunBeforeStorage() async throws {
        let store = try FxSessionStore(), agent = try FxDurableAgent(harness: CalculationHarness(), store: store)
        let session = try await agent.session(id: "typed-seed")
        await #expect(throws: FxError.self) { try await session.submit(CalculationInput(values: []), id: "invalid") }
        await #expect(throws: FxSessionError.notFound) { try await store.snapshot(session: session.id, agent: "default") }
        #expect(try await session.submit(input, id: "one").result.stopReason == .endTurn)
        let checkpoint = try await session.checkpoint()
        try await agent.close()
        let seeded = try FxDurableAgent(harness: CalculationHarness(), store: store, checkpoint: checkpoint)
        let fresh = try await seeded.session(id: "new-typed-seed")
        #expect(try await fresh.submit(input, id: "one").result.stopReason == .endTurn)
        try await seeded.close(); try await store.close()
    }

    @Test func cancellingAndSteeringTypedInputsLeavesQueuedWorkUsable() async throws {
        let store = try FxSessionStore()
        let agent = try FxDurableAgent(harness: CalculationHarness(delay: .milliseconds(10)), store: store)
        let session = try await agent.session(id: "typed-cancel")
        let first = try await session.submit(input, id: "one")
        var iterator = first.makeAsyncIterator()
        #expect(try await iterator.next()?.index == 0)
        let guidance = try await session.steer(CalculationInput(values: [99]), id: "guide")
        #expect(guidance.id == "guide")
        #expect(try await first.result.stopReason == .cancelled)
        #expect(try await guidance.result.stopReason == .endTurn)
        var updates: [CalculationUpdate] = []
        for try await update in guidance { updates.append(update) }
        #expect(updates.map(\.total) == [99])
        let cancelled = try await session.submit(input, id: "cancel")
        try await cancelled.cancel()
        #expect(try await cancelled.result.stopReason == .cancelled)
        #expect(try await session.submit(input, id: "after").result.stopReason == .endTurn)
        try await agent.close(); try await store.close()
    }

    @Test func payloadAdmissionRejectsMixedAndOversizedStorageInput() async throws {
        let store = try FxSessionStore()
        let invalid: [[FxPromptContent]] = [[.text("bad"), .payload(Data())], [.payload(Data()), .payload(Data())], [.payload(Data(repeating: 0, count: 8 * 1024 * 1024 + 1))]]
        for content in invalid {
            await #expect(throws: FxError.self) {
                try await store.accept(session: "invalid", agent: "default", id: "one", content: content, options: .init())
            }
        }
        await #expect(throws: FxSessionError.notFound) { try await store.snapshot(session: "invalid", agent: "default") }
        try await store.close()
    }

    @Test func conversationEngineRejectsDataBeforeCreatingAStoredSession() async throws {
        let store = try FxSessionStore()
        let agent = try FxAgent(configuration: FxConfiguration(apiKey: "unused", model: "unused"), store: store)
        let session = try await agent.session(id: "conversation-data")
        await #expect(throws: FxError.self) { try await session.prompt([.payload(Data("{}".utf8))], id: "invalid") }
        await #expect(throws: FxSessionError.notFound) { try await store.snapshot(session: session.id, agent: "default") }
        try await agent.close(); try await store.close()
    }

    @Test func terminalResultPreservesStructuredFailureWithoutThrowingOrRetrying() async throws {
        let failure = FxSessionFailure(message: "The calculation was refused", name: "CalculationError", code: .string("CALC_REFUSED"))
        let store = try FxSessionStore()
        let agent = try FxDurableAgent(harness: CalculationHarness(terminalFailure: failure), store: store)
        let session = try await agent.session(id: "typed-result-error")
        let turn = try await session.submit(input, id: "one")
        let result = try await turn.result
        #expect(result.stopReason == .error && result.failure == failure)
        let repeated = try await session.submit(input, id: "one")
        #expect(try await repeated.result.failure == failure)
        let entries = try await store.entries(session: session.id, agent: "default", after: 0)
        #expect(entries.filter { if case .started = $0.event { return true }; return false }.count == 1)
        #expect(entries.filter { if case .update = $0.event { return true }; return false }.count == 3)
        #expect(try JSONDecoder().decode(FxSessionResult.self, from: JSONEncoder().encode(result)).failure == failure)
        try await agent.close(); try await store.close()
    }
}
