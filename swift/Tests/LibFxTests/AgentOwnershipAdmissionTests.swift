import Foundation
import Testing
@testable import LibFx

private final class OwnershipBackendClock: @unchecked Sendable {
    private let lock = NSLock()
    private var date = Date(timeIntervalSince1970: 1_000)
    var now: Date { lock.withLock { date } }
    func expireGrant() { lock.withLock { date = date.addingTimeInterval(60) } }
}

/// Holds delivery of an already successful backend response, not its transaction.
private actor OwnershipReplyGate {
    enum Target: Sendable { case claim, http, tool }
    let target: Target
    let entered = AsyncResult<ContinuousClock.Instant>()
    let cancelled = AsyncResult<Void>()
    private(set) var lease: FxSessionLease?
    private var reply: CheckedContinuation<Void, Never>?
    private var skippedChecks: Int?
    private var used = false

    init(_ target: Target) {
        self.target = target
        skippedChecks = target == .http ? 0 : nil
    }
    func claimed(_ lease: FxSessionLease?) async {
        self.lease = lease
        guard target == .claim, lease != nil else { return }
        await hold()
    }
    func modelResponded() { if target == .tool { skippedChecks = 1 } }
    func checked(_ lease: FxSessionLease) async {
        guard !used, let skippedChecks else { return }
        if skippedChecks > 0 { self.skippedChecks = skippedChecks - 1; return }
        await hold()
    }
    private func hold() async {
        guard !used else { return }
        used = true
        await withTaskCancellationHandler {
            await withCheckedContinuation { reply in
                self.reply = reply
                Task { await self.entered.resolve(.success(ContinuousClock.now)) }
            }
        } onCancel: {
            Task { await self.cancelled.resolve(.success(())) }
        }
    }
    func release() { reply?.resume(); reply = nil }
}

private actor OwnershipAdmissionHTTP: FxHTTPClient {
    let gate: OwnershipReplyGate
    private(set) var calls = 0
    private(set) var modelCalls = 0
    init(_ gate: OwnershipReplyGate) { self.gate = gate }
    func send(_ request: URLRequest) async throws -> FxHTTPResponse {
        calls += 1
        if request.httpMethod == "GET" {
            return response(#"{"data":[{"id":"swift/ownership","type":"language","tags":["tool-use"]}]}"#)
        }
        modelCalls += 1
        await gate.modelResponded()
        return response("data: {\"type\":\"tool-call\",\"toolCallId\":\"owned-call\",\"toolName\":\"effect\",\"input\":{}}\n\ndata: {\"type\":\"finish\",\"finishReason\":{\"unified\":\"tool-calls\",\"raw\":\"tool-calls\"}}\n\ndata: [DONE]\n\n")
    }
    private func response(_ text: String) -> FxHTTPResponse {
        FxHTTPResponse(statusCode: 200, body: AsyncThrowingStream { $0.yield(Data(text.utf8)); $0.finish() })
    }
}

private actor OwnershipAdmissionEffects {
    private(set) var count = 0
    func run() -> FxToolResult { count += 1; return FxToolResult(text: "effect") }
}

@Suite(.serialized, .timeLimit(.minutes(1))) struct AgentOwnershipAdmissionTests {
    @Test(arguments: [OwnershipReplyGate.Target.claim, .http, .tool])
    fileprivate func staleSuccessfulOwnershipReplyCannotAdmitEffectsOrWrites(target: OwnershipReplyGate.Target) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("ownership.sqlite")
        let clock = OwnershipBackendClock(), gate = OwnershipReplyGate(target)
        let duration: Duration = target == .claim ? .milliseconds(100) : .seconds(5)
        let policy = try FxSessionLeasePolicy(duration: duration, renewalInterval: .milliseconds(25))
        let original = try FxSessionStore(url: url, leasePolicy: policy, leaseNow: { clock.now })
        let successor = try FxSessionStore(url: url, leasePolicy: policy, leaseNow: { clock.now })
        let proxy = SessionStorageProxy(original, afterClaim: { await gate.claimed($0) },
                                        afterLeaseCheck: { await gate.checked($0) })
        let http = OwnershipAdmissionHTTP(gate), effects = OwnershipAdmissionEffects()
        let tool = FxTool(name: "effect", description: "Perform an effect", inputSchema: .object(["type": .string("object")]),
                          isIdempotent: false, writes: true) { _, _ in await effects.run() }
        let agent = try FxAgent(configuration: FxConfiguration(apiKey: "fixture", model: "swift/ownership", tools: [tool], httpClient: http),
                                store: proxy, checkpointAfterBytes: nil)
        let session = try await agent.session(id: "stale-owner")
        let turn = try await session.prompt("perform effect", id: "input")
        let heldAt = try await gate.entered.wait()
        let callsBeforeTakeover = await http.calls
        let modelsBeforeTakeover = await http.modelCalls
        clock.expireGrant()
        let replacement = try #require(try await successor.claim(session: session.id, agent: "default"))
        let originalLease = try #require(await gate.lease)
        #expect(replacement.epoch == originalLease.epoch + 1)
        #expect(replacement.owner != originalLease.owner)
        try await successor.appendEvent(replacement, .update(id: turn.id, .text("successor write")))
        let entries = try await successor.entries(session: session.id, agent: "default", after: 0)
        let snapshot = try await successor.loadJournal(replacement)
        if target == .claim {
            // The guard starts only when claim returns. Its budget began before
            // that call, so the reply is already too old to authorize opening.
            try await ContinuousClock().sleep(until: heldAt.advanced(by: duration))
        } else {
            // Renewal observes the successor epoch and irreversibly loses local
            // authority while the previous successful check reply is still held.
            try await gate.cancelled.wait()
        }
        await gate.release()
        await #expect(throws: FxPersistenceError.fenced) { _ = try await turn.result }
        await #expect(throws: FxPersistenceError.fenced) { try await agent.close() }
        #expect(await effects.count == 0)
        #expect(await http.calls == callsBeforeTakeover)
        #expect(await http.modelCalls == modelsBeforeTakeover)
        #expect(target == .tool ? modelsBeforeTakeover == 1 : callsBeforeTakeover == 0)
        #expect(try await successor.entries(session: session.id, agent: "default", after: 0) == entries)
        let after = try await successor.loadJournal(replacement)
        #expect(after.head == snapshot.head)
        #expect(after.journal == snapshot.journal)
        #expect(after.checkpoint == snapshot.checkpoint)
        #expect(after.completedTurnID == snapshot.completedTurnID)
        #expect(try await successor.result(session: session.id, agent: "default", id: turn.id) == nil)
        try await successor.checkLease(replacement)
        try await successor.release(replacement)
        try await original.close(); try await successor.close()
    }
}
