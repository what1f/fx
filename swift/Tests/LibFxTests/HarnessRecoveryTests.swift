import Foundation
import Testing
import LibFx

private actor RecoveryQueue: FxSessionQueue {
    private(set) var messages: [FxSessionWakeup] = []
    func enqueue(_ wakeup: FxSessionWakeup) { messages.append(wakeup) }
}

private actor RecoveryEvents {
    private(set) var failures: [String] = []
    func record(_ event: FxLifecycleEvent) {
        if case .harnessFailed(_, _, let error) = event { failures.append(error.localizedDescription) }
    }
}

@Suite(.serialized, .timeLimit(.minutes(1))) struct HarnessRecoveryTests {
    private func state(_ store: FxSessionStore, session: String, input: String) async throws -> FxHarnessFailureState {
        let lease = try #require(try await store.claim(session: session, agent: "default"))
        let state = try await store.harnessFailureState(lease, id: input)
        try await store.release(lease)
        return state
    }

    @Test(arguments: ["flaky", "halting"]) func replacesAnExecutorThatFailsToStartOrStopsBeforeItsRecord(text: String) async throws {
        let store = try FxSessionStore(), faults = ScriptedHarnessFaults(), events = RecoveryEvents()
        let agent = try FxAgent(harness: ScriptedSessionHarness(faults: faults), store: store, onLifecycleEvent: { await events.record($0) })
        let session = try await agent.session(id: "replacement")
        let first = try await session.prompt(text, id: "input")
        let behind = try await session.prompt("after", id: "after")
        var output = ""
        for try await event in first { if case .text(let delta) = event { output += delta } }
        #expect(output == "\(text)-0 \(text)-1 \(text)-2 ")
        #expect(try await first.result.stopReason == .endTurn)
        #expect(try await behind.result.stopReason == .endTurn)
        #expect(await faults.prompts == [text, text, "after"])
        #expect(await events.failures.count == 1)
        try await agent.close()
        #expect(try await state(store, session: session.id, input: "input") == .init(stops: 1, halted: false))
        try await store.close()
    }

    @Test func threeFailedStartsEndOnlyThatInputAndLeaveTheSessionUsable() async throws {
        let store = try FxSessionStore(), faults = ScriptedHarnessFaults()
        let agent = try FxAgent(harness: ScriptedSessionHarness(faults: faults), store: store)
        let session = try await agent.session(id: "failed-start")
        let doomed = try await session.prompt("doomed", id: "doomed")
        let behind = try await session.prompt("after", id: "after")
        let result = try await doomed.result
        #expect(result.stopReason == .error && result.error?.contains("3 times") == true)
        #expect(try await behind.result.stopReason == .endTurn)
        #expect(await faults.prompts == ["doomed", "doomed", "doomed", "after"])
        let opens = await faults.opens
        #expect(try await session.prompt("replacement", id: "doomed").result.isRepeated)
        #expect(await faults.opens == opens)
        try await agent.close()
        #expect(try await state(store, session: session.id, input: "doomed") == .init(stops: 3, halted: false))
        try await store.close()
    }

    @Test func threeStoppedResumptionsCancelTheOpenTurnAndRunItsSuccessor() async throws {
        let store = try FxSessionStore(), faults = ScriptedHarnessFaults()
        let agent = try FxAgent(harness: ScriptedSessionHarness(faults: faults), store: store)
        let session = try await agent.session(id: "stuck")
        let stuck = try await session.prompt("brittle", id: "stuck")
        let behind = try await session.prompt("after", id: "after")
        #expect(try await stuck.result.stopReason == .cancelled)
        #expect(try await behind.result.stopReason == .endTurn)
        #expect(await faults.resumes == [true, true, false])
        try await agent.close()
        #expect(try await state(store, session: session.id, input: "stuck") == .init(stops: 3, halted: false))
        try await store.close()
    }

    @Test func stoppingEvenDuringCancellationPermanentlyHaltsOnlyThatSession() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("sessions.sqlite"), store = try FxSessionStore(url: url), faults = ScriptedHarnessFaults()
        let agent = try FxAgent(harness: ScriptedSessionHarness(faults: faults), store: store)
        let session = try await agent.session(id: "halted")
        let first = try await session.prompt("shattered", id: "stuck")
        let behind = try await session.prompt("after", id: "after")
        let result = try await first.result
        #expect(result.stopReason == .error && result.error?.contains("even to cancel") == true)
        #expect(try await behind.result.stopReason == .error)
        #expect(await faults.opens == 5)
        #expect(await faults.resumes == [true, true, false, false])
        let entries = try await store.entries(session: session.id, agent: "default", after: 0)
        #expect(!entries.contains { if case .started(id: "after", sessionID: _, input: _) = $0.event { return true }; return false })
        try await agent.close()
        #expect(try await state(store, session: session.id, input: "stuck") == .init(stops: 5, halted: true))
        try await store.close()
        let reopened = try FxSessionStore(url: url), nextFaults = ScriptedHarnessFaults()
        let next = try FxAgent(harness: ScriptedSessionHarness(faults: nextFaults), store: reopened)
        let old = try await next.session(id: "halted")
        #expect(try await old.prompt("later").result.stopReason == .error)
        #expect(try await old.prompt("shattered", id: "stuck").result.isRepeated)
        #expect(await nextFaults.opens == 0)
        let healthy = try await next.session(id: "healthy")
        #expect(try await healthy.prompt("healthy").result.stopReason == .endTurn)
        #expect(await nextFaults.opens == 1)
        try await next.close(); try await reopened.close()
    }

    @Test(arguments: ["omega", "late"]) func completionLandedBeforeOrDuringCloseIsUnknownAndDoesNotRerun(text: String) async throws {
        let store = try FxSessionStore(), faults = ScriptedHarnessFaults()
        let agent = try FxAgent(harness: ScriptedSessionHarness(faults: faults), store: store)
        let session = try await agent.session(id: "landed")
        let turn = try await session.prompt(text, id: "input")
        var output = ""
        for try await event in turn { if case .text(let delta) = event { output += delta } }
        #expect(output == "\(text)-0 \(text)-1 \(text)-2 ")
        #expect(try await turn.result.stopReason == .unknown)
        #expect(try await session.prompt("after").result.stopReason == .endTurn)
        #expect(await faults.prompts == [text, "after"])
        try await agent.close()
        #expect(try await state(store, session: session.id, input: "input").stops == 0)
        try await store.close()
    }

    @Test(arguments: ["doomed", "shattered"]) func stopBudgetsSurviveOwnershipAndDatabaseReopening(text: String) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("sessions.sqlite"), store = try FxSessionStore(url: url), queue = RecoveryQueue()
        let first = try FxAgent(harness: ScriptedSessionHarness(faults: ScriptedHarnessFaults()), store: store, queue: queue)
        let session = try await first.session(id: "persisted")
        _ = try await session.prompt(text, id: "input")
        let wakeup = try #require(await queue.messages.first)
        #expect(try await first.deliver(wakeup) == .retry(after: .zero))
        try await first.close(); try await store.close()
        let reopened = try FxSessionStore(url: url), faults = ScriptedHarnessFaults()
        let next = try FxAgent(harness: ScriptedSessionHarness(faults: faults), store: reopened, queue: queue)
        let limit = text == "doomed" ? 3 : 5
        for attempt in 2...limit {
            #expect(try await next.deliver(wakeup) == (attempt == limit ? .complete : .retry(after: .zero)))
        }
        #expect(try await reopened.result(session: session.id, agent: "default", id: "input")?.stopReason == .error)
        try await next.close()
        #expect(try await state(reopened, session: session.id, input: "input") == .init(stops: limit, halted: text == "shattered"))
        if text == "doomed" { #expect(await faults.prompts.count == 2) }
        else { #expect(await faults.resumes == [true, true, false, false]) }
        try await reopened.close()
    }

    @Test(arguments: [1, 3]) func openingOutageDoesNotSpendStopBudgetAndLaterWorkCleansUpWithOriginalSettings(limit: Int) async throws {
        let store = try FxSessionStore(), faults = ScriptedHarnessFaults(maximumOpens: limit)
        let agent = try FxAgent(harness: ScriptedSessionHarness(faults: faults), store: store)
        let old = try await agent.session(id: "outage", options: .init(context: .string("old")))
        let original = try await old.prompt("brittle", id: "stuck")
        let failed = try await original.result
        #expect(failed.stopReason == .error && failed.error == "no executor")
        #expect(await faults.opens == limit + 1)
        await faults.restoreOpenings()
        let fresh = try await agent.session(id: old.id, options: .init(context: .string("new")))
        #expect(try await fresh.prompt("after", id: "after").result.stopReason == .endTurn)
        #expect(try await original.result == failed)
        #expect(await faults.contexts.suffix(2).map { $0 } == [.string("old"), .string("new")])
        try await agent.close()
        #expect(try await state(store, session: old.id, input: "stuck") == .init(stops: limit, halted: false))
        try await store.close()
    }

    @Test func permanentlyUnavailableOpeningFailsEachWaitingInputOnce() async throws {
        let store = try FxSessionStore(), faults = ScriptedHarnessFaults(maximumOpens: 1)
        let agent = try FxAgent(harness: ScriptedSessionHarness(faults: faults), store: store)
        let session = try await agent.session(id: "unavailable")
        let first = try await session.prompt("shattered", id: "stuck")
        let behind = try await session.prompt("after", id: "after")
        #expect(try await first.result.error == "no executor")
        #expect(try await behind.result.error == "no executor")
        try await agent.close()
        #expect(await faults.opens == 3)
        #expect(try await state(store, session: session.id, input: "stuck") == .init(stops: 1, halted: false))
        try await store.close()
    }

    @Test func storageFailureWhileCleaningUpAnOldTurnRemainsRecoverable() async throws {
        let database = try FxSessionStore(), storage = SessionStorageProxy(database)
        let faults = ScriptedHarnessFaults(maximumOpens: 1)
        let first = try FxAgent(harness: ScriptedSessionHarness(faults: faults), store: storage)
        let session = try await first.session(id: "cleanup-storage")
        #expect(try await session.prompt("brittle", id: "old").result.error == "no executor")
        try await first.close()
        await faults.restoreOpenings()
        let failure = SessionStorageTestFailure()
        await storage.failNext("harnessFailureState", with: failure, after: 1)
        let second = try FxAgent(harness: ScriptedSessionHarness(faults: faults), store: storage)
        let reopened = try await second.session(id: session.id)
        let turn = try await reopened.prompt("after", id: "next")
        do { _ = try await turn.result; Issue.record("Storage failure became a final result") }
        catch { #expect((error as? SessionStorageTestFailure) === failure) }
        do { try await second.close(); Issue.record("Close lost the storage failure") }
        catch { #expect((error as? SessionStorageTestFailure) === failure) }
        #expect(try await database.result(session: session.id, agent: "default", id: "next") == nil)
        let third = try FxAgent(harness: ScriptedSessionHarness(faults: faults), store: storage)
        let recovered = try await third.session(id: session.id)
        let pending = try #require(try await recovered.resume())
        #expect(try await pending.result.stopReason == .endTurn)
        #expect(try await database.result(session: session.id, agent: "default", id: "old")?.error == "no executor")
        try await third.close(); try await database.close()
    }

    @Test func stopMutationsAreFencedAndIdempotentWithinAnEpoch() async throws {
        let store = try FxSessionStore()
        _ = try await store.accept(session: "fenced", agent: "default", id: "input", content: [.text("hello")], options: .init())
        let old = try #require(try await store.claim(session: "fenced", agent: "default"))
        try await store.release(old)
        let lease = try #require(try await store.claim(session: "fenced", agent: "default"))
        await #expect(throws: FxPersistenceError.fenced) { try await store.recordHarnessStop(old, id: "input") }
        await #expect(throws: FxPersistenceError.fenced) { try await store.halt(old) }
        await #expect(throws: FxPersistenceError.fenced) { try await store.setHarnessRecoveryInput(old, id: "input") }
        await #expect(throws: FxPersistenceError.fenced) { try await store.harnessRecoveryInput(old) }
        await #expect(throws: FxPersistenceError.fenced) { try await store.input(old, id: "input") }
        await #expect(throws: FxPersistenceError.fenced) { try await store.harnessFailureState(old, id: "input") }
        await #expect(throws: FxSessionError.notFound) { try await store.recordHarnessStop(lease, id: "missing") }
        #expect(try await store.harnessRecoveryInput(lease) == nil)
        #expect(try await store.recordHarnessStop(lease, id: "input") == 1)
        #expect(try await store.recordHarnessStop(lease, id: "input") == 1)
        #expect(try await store.harnessRecoveryInput(lease)?.id == "input")
        try await store.release(lease)
        let next = try #require(try await store.claim(session: "fenced", agent: "default"))
        #expect(try await store.recordHarnessStop(next, id: "input") == 2)
        try await store.release(next); try await store.close()
    }
}
