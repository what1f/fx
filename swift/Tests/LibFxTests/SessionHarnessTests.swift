import Foundation
import Testing
import LibFx

private actor HarnessQueue: FxSessionQueue {
    private(set) var messages: [FxSessionWakeup] = []
    func enqueue(_ wakeup: FxSessionWakeup) { messages.append(wakeup) }
}

private actor HarnessPreparationProbe {
    private(set) var cancelled = false
    func didCancel() { cancelled = true }
}

private struct SlowOpeningHarness: FxSessionHarness {
    let probe: HarnessPreparationProbe
    func prepareCheckpoint(_ data: Data, options: FxSessionOptions) async throws -> Data {
        try ScriptedSessionHarness().prepareCheckpoint(data, options: options)
    }
    func open(_ context: FxHarnessContext) async throws -> any FxHarnessSession {
        do { try await Task.sleep(for: .seconds(2)) }
        catch { await probe.didCancel(); throw error }
        return try await ScriptedSessionHarness().open(context)
    }
}

private final class HarnessValidationFailure: Error {}
private struct ValidatingHarness: FxSessionHarness {
    let failure: HarnessValidationFailure
    func validate(options: FxSessionOptions) throws {
        if options.context == .string("reject") { throw failure }
    }
    func validate(input: [FxPromptContent], options: FxSessionOptions) throws {
        if input == [.text("reject")] { throw failure }
    }
    func prepareCheckpoint(_ data: Data, options: FxSessionOptions) throws -> Data {
        try ScriptedSessionHarness().prepareCheckpoint(data, options: options)
    }
    func open(_ context: FxHarnessContext) async throws -> any FxHarnessSession {
        try await ScriptedSessionHarness().open(context)
    }
}

@Suite(.serialized, .timeLimit(.minutes(1))) struct SessionHarnessTests {
    @Test func harnessValidationRunsBeforeAnyStorageCall() async throws {
        let database = try FxSessionStore(), store = SessionStorageProxy(database), failure = HarnessValidationFailure()
        let agent = try FxAgent(harness: ValidatingHarness(failure: failure), store: store)
        do { _ = try await agent.session(id: "session", options: .init(context: .string("reject"))); Issue.record("Invalid settings accepted") }
        catch { #expect((error as? HarnessValidationFailure) === failure) }
        let session = try await agent.session(id: "session")
        do { _ = try await session.prompt("reject"); Issue.record("Invalid input accepted") }
        catch { #expect((error as? HarnessValidationFailure) === failure) }
        var changed = session
        changed.options.context = .string("reject")
        do { _ = try await changed.prompt("accepted"); Issue.record("Changed settings accepted") }
        catch { #expect((error as? HarnessValidationFailure) === failure) }
        #expect(await store.calls.isEmpty)
        #expect(try await session.prompt("accepted").result.stopReason == .endTurn)
        try await agent.close(); try await database.close()
    }
    @Test func preparationDeadlineJoinsCustomCleanupAndRetainsInput() async throws {
        let store = try FxSessionStore(), queue = HarnessQueue(), probe = HarnessPreparationProbe()
        let policy = try FxDeliveryPolicy(maximumDuration: .milliseconds(500), reserve: .milliseconds(200))
        let first = try FxAgent(harness: SlowOpeningHarness(probe: probe), store: store, deliveryPolicy: policy, queue: queue)
        let session = try await first.session(id: "slow-open")
        _ = try await session.prompt("saved", id: "input")
        let wakeup = try #require(await queue.messages.first)
        await #expect(throws: FxSessionError.preparationTimedOut) { try await first.deliver(wakeup) }
        #expect(await probe.cancelled)
        #expect(try await store.hasWork(session: session.id, agent: "default"))
        #expect(try await store.result(session: session.id, agent: "default", id: "input") == nil)
        await #expect(throws: FxSessionError.preparationTimedOut) { try await first.close() }
        let recovery = try FxAgent(harness: ScriptedSessionHarness(), store: store, queue: queue)
        #expect(try await recovery.deliver(wakeup) == .complete)
        #expect(try await store.result(session: session.id, agent: "default", id: "input")?.stopReason == .endTurn)
        try await recovery.close(); try await store.close()
    }
    @Test func customExecutorRunsAndDeduplicatesWithoutAKernel() async throws {
        let store = try FxSessionStore()
        let agent = try FxAgent(harness: ScriptedSessionHarness(), store: store)
        let session = try await agent.session(id: "scripted")
        let turn = try await session.prompt("hello", id: "input")
        var text = ""
        for try await event in turn { if case .text(let delta) = event { text += delta } }
        #expect(text == "hello-0 hello-1 hello-2 ")
        #expect(try await turn.result.stopReason == .endTurn)
        let before = try await store.entries(session: session.id, agent: "default", after: 0)
        let repeated = try await session.prompt("replacement", id: "input")
        #expect(try await repeated.result.isRepeated)
        #expect(try await store.entries(session: session.id, agent: "default", after: 0) == before)
        try await agent.close()
        try await store.close()
    }

    @Test func opaqueRecordsYieldAndRecoverAcrossDatabaseReopening() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("sessions.sqlite"), queue = HarnessQueue()
        let policy = try FxDeliveryPolicy(maximumDuration: .zero, reserve: .zero)
        let firstStore = try FxSessionStore(url: url)
        let first = try FxAgent(harness: ScriptedSessionHarness(), store: firstStore, deliveryPolicy: policy, queue: queue)
        let session = try await first.session(id: "recovery")
        _ = try await session.prompt("recover", id: "input")
        let wakeup = try #require(await queue.messages.first)
        #expect(try await first.deliver(wakeup) == .retry(after: .zero))
        #expect(try await firstStore.snapshot(session: session.id, agent: "default").checkpoint?.data.starts(with: Data("SCRIPT1\n".utf8)) == true)
        try await first.close(); try await firstStore.close()
        let store = try FxSessionStore(url: url)
        let second = try FxAgent(harness: ScriptedSessionHarness(), store: store, deliveryPolicy: policy, queue: queue)
        let reopened = try await second.session(id: session.id)
        let resumed = try #require(try await reopened.resume())
        #expect(try await second.deliver(wakeup) == .retry(after: .zero))
        #expect(try await second.deliver(wakeup) == .complete)
        #expect(try await resumed.result.stopReason == .endTurn)
        let history = try await store.entries(session: session.id, agent: "default", after: 0)
        let text = history.compactMap { entry -> String? in
            if case .update(_, .text(let text)) = entry.event { return text }; return nil
        }.joined()
        #expect(text == "recover-0 recover-1 recover-2 ")
        #expect(history.filter { if case .started = $0.event { return true }; return false }.count == 1)
        #expect(history.filter { if case .resumed = $0.event { return true }; return false }.count == 2)
        #expect(history.filter { if case .yielded = $0.event { return true }; return false }.count == 2)
        try await second.close(); try await store.close()
    }

    @Test func customCheckpointsSeedAndExportWithoutKernelWrapping() async throws {
        let store = try FxSessionStore()
        let source = try FxAgent(harness: ScriptedSessionHarness(), store: store)
        let sourceSession = try await source.session(id: "source")
        _ = try await sourceSession.prompt("source", id: "input").result
        let checkpoint = try await sourceSession.checkpoint()
        #expect(checkpoint.starts(with: Data("SCRIPT1\n".utf8)))
        let queue = HarnessQueue()
        let target = try FxAgent(harness: ScriptedSessionHarness(), store: store, checkpoint: checkpoint, queue: queue)
        let unused = try await target.session(id: "unused")
        #expect(try await unused.checkpoint() == checkpoint)
        await #expect(throws: FxSessionError.notFound) { try await store.snapshot(session: unused.id, agent: "default") }
        let session = try await target.session(id: "target")
        let turn = try await session.prompt("target", id: "input")
        let seeded = try await store.snapshot(session: session.id, agent: "default")
        #expect(seeded.checkpoint?.data == checkpoint)
        let wakeup = try #require(await queue.messages.first)
        #expect(try await target.deliver(wakeup) == .complete)
        #expect(try await turn.result.stopReason == .endTurn)
        let before = try await store.snapshot(session: session.id, agent: "default")
        let exported = try await session.checkpoint()
        #expect(exported.starts(with: Data("SCRIPT1\n".utf8)))
        #expect(exported != checkpoint)
        #expect(try await store.snapshot(session: session.id, agent: "default").head == before.head)
        try await source.close(); try await target.close(); try await store.close()
    }

    @Test func cancellingRunningCustomWorkLeavesQueuedWorkRunnable() async throws {
        let store = try FxSessionStore()
        let agent = try FxAgent(harness: ScriptedSessionHarness(stepDuration: .milliseconds(80)), store: store)
        let session = try await agent.session(id: "cancellation")
        let first = try await session.prompt("first", id: "first")
        let second = try await session.prompt("second", id: "second")
        var started = false
        for _ in 0..<100 {
            let entries = try await store.entries(session: session.id, agent: "default", after: 0)
            if entries.contains(where: { if case .update("first", .text) = $0.event { return true }; return false }) { started = true; break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(started)
        try await first.cancel()
        #expect(try await first.result.stopReason == .cancelled)
        #expect(try await second.result.stopReason == .endTurn)
        try await agent.close(); try await store.close()
    }

    @Test func opaqueMarksCommitAtomicallyAndParticipateInWriteIdentity() async throws {
        let store = try FxSessionStore()
        _ = try await store.accept(session: "marks", agent: "default", id: "input", content: [.text("hello")], options: .init())
        let lease = try #require(try await store.claim(session: "marks", agent: "default"))
        let input = try #require(try await store.next(lease))
        try await store.start(lease, input: input)
        _ = try await store.accept(session: "marks", agent: "default", id: "guide", content: [.text("guide")], options: .init(), steering: true)
        let marks: [FxSessionJournalMark] = [.accepted(FxSessionInput.runtimeID(for: "guide")), .placed(FxSessionInput.runtimeID(for: "guide")), .progress("step-1")]
        let data = Data([0, 255, 4])
        await #expect(throws: FxPersistenceError.fenced) {
            try await store.appendJournal(lease, expected: "wrong", key: "record", data: data, marks: marks)
        }
        #expect(try await store.steering(lease, owner: "input").pending.count == 1)
        let cursor = try await store.appendJournal(lease, expected: nil, key: "record", data: data, marks: marks)
        #expect(try await store.steering(lease, owner: "input").pending.isEmpty)
        #expect(try await store.appendJournal(lease, expected: nil, key: "record", data: data, marks: marks) == cursor)
        await #expect(throws: FxPersistenceError.fenced) {
            try await store.appendJournal(lease, expected: cursor, key: "record", data: data, marks: [])
        }
        try await store.finish(lease, id: "input", result: FxSessionResult(id: "input", stopReason: .endTurn, epoch: lease.epoch))
        #expect(try await store.result(session: "marks", agent: "default", id: "guide")?.stopReason == .endTurn)
        try await store.release(lease); try await store.close()
    }
}
