import Foundation
import Testing
import LibFx

private final class TerminalCloseFailure: Error {}
private enum TerminalCleanupTimeout: Error { case nextInputBlocked }

private actor TerminalCloseGate {
    var started: Set<String> = []
    var finished: Set<String> = []
    var released: Set<String> = []
    var failures: Set<String> = []
    private var closers: [String: CheckedContinuation<Void, Never>] = [:]
    private var observers: [String: [CheckedContinuation<Void, Never>]] = [:]
    func hold(_ id: String) async {
        started.insert(id)
        for observer in observers.removeValue(forKey: id) ?? [] { observer.resume() }
        if released.contains(id) { return }
        await withCheckedContinuation { closers[id] = $0 }
    }
    func waitUntilStarted(_ id: String) async {
        if started.contains(id) { return }
        await withCheckedContinuation { observers[id, default: []].append($0) }
    }
    func release(_ id: String) { released.insert(id); closers.removeValue(forKey: id)?.resume() }
    func didFinish(_ id: String) { finished.insert(id) }
    func event(_ event: FxLifecycleEvent) {
        if case .harnessFailed(_, let id, _) = event { failures.insert(id) }
    }
}

private struct TerminalCloseHarness: FxSessionHarness {
    let gate: TerminalCloseGate
    let failure: TerminalCloseFailure?
    func prepareCheckpoint(_ data: Data, options: FxSessionOptions) throws -> Data { data }
    func open(_ context: FxHarnessContext) async throws -> any FxHarnessSession {
        TerminalCloseSession(base: try await ScriptedSessionHarness(stepDuration: .zero).open(context),
            id: context.inputID ?? "checkpoint", gate: gate, failure: failure)
    }
}

private struct TerminalCloseSession: FxHarnessSession {
    let base: any FxHarnessSession
    let id: String
    let gate: TerminalCloseGate
    let failure: TerminalCloseFailure?
    var recoveryState: FxRecoveryState? { get async { await base.recoveryState } }
    var completedTurnID: String? { get async { await base.completedTurnID } }
    func prompt(_ content: [FxPromptContent], id: String, yieldAt: Date?) async throws -> any FxHarnessTurn {
        try await base.prompt(content, id: id, yieldAt: yieldAt)
    }
    func resume(rerunning: Bool, yieldAt: Date?) async throws -> (any FxHarnessTurn)? {
        try await base.resume(rerunning: rerunning, yieldAt: yieldAt)
    }
    func saveCheckpoint() async throws { try await base.saveCheckpoint() }
    func checkpoint() async throws -> Data { try await base.checkpoint() }
    func close() async throws {
        await gate.hold(id)
        try await base.close()
        await gate.didFinish(id)
        if let failure { throw failure }
    }
}

@Suite(.serialized, .timeLimit(.minutes(1))) struct TerminalCleanupTests {
    @Test(arguments: [false, true])
    func nextInputRunsDuringTerminalCleanupAndAgentCloseJoinsEveryEngine(closeFails: Bool) async throws {
        let store = try FxSessionStore(), gate = TerminalCloseGate()
        let failure = closeFails ? TerminalCloseFailure() : nil
        let agent = try FxAgent(harness: TerminalCloseHarness(gate: gate, failure: failure), store: store,
            onLifecycleEvent: { await gate.event($0) })
        let session = try await agent.session(id: "cleanup")
        let first = try await session.prompt("first", id: "one")
        #expect(try await first.result.stopReason == .endTurn)
        await gate.waitUntilStarted("one")
        let second = try await session.prompt("second", id: "two")
        let secondResult = try await withThrowingTaskGroup(of: FxSessionResult.self) { group in
            group.addTask { try await second.result }
            group.addTask {
                try await Task.sleep(for: .seconds(2))
                // Release blocked cleanup on failure so the test leaves no running worker.
                await gate.release("one"); await gate.release("two")
                throw TerminalCleanupTimeout.nextInputBlocked
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
        #expect(secondResult.stopReason == .endTurn)
        await gate.waitUntilStarted("two")
        #expect(await gate.finished.isEmpty)
        let closing = Task {
            let result: Result<Void, any Error>
            do { try await agent.close(); result = .success(()) }
            catch { result = .failure(error) }
            #expect(await gate.finished == ["one", "two"])
            return result
        }
        // The close call has stopped admission but both cleanup gates remain held.
        while true {
            do { _ = try await agent.session(id: "probe"); await Task.yield() }
            catch FxError.closed { break }
        }
        await gate.release("one")
        await gate.release("two")
        switch await closing.value {
        case .success: #expect(!closeFails)
        case .failure(let error): #expect((error as? TerminalCloseFailure) === failure)
        }
        #expect(await gate.failures == (closeFails ? ["one", "two"] : []))
        #expect(try await first.result.stopReason == .endTurn)
        #expect(try await second.result.stopReason == .endTurn)
        try await store.close()
    }
}
