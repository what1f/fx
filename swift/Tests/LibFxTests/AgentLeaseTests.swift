import Foundation
import Testing
@testable import LibFx

extension SessionStorageProxy: FxRenewableSessionStorage {
    nonisolated var leasePolicy: FxSessionLeasePolicy? { base.leasePolicy }
    func renew(_ lease: FxSessionLease) async throws {
        try await beforeLeaseRenewal?()
        try await base.renew(lease)
    }
}

private actor AgentLeaseRenewals {
    enum Mode { case normal, fail, held }
    private var mode = Mode.normal
    private(set) var count = 0
    let intercepted = AsyncResult<Void>()
    private var held: CheckedContinuation<Void, Never>?
    private var counts: [(Int, AsyncResult<Void>)] = []
    func arm(_ mode: Mode) { self.mode = mode }
    func call() async throws {
        count += 1
        for (target, signal) in counts where count >= target { await signal.resolve(.success(())) }
        counts.removeAll { count >= $0.0 }
        switch mode {
        case .normal: return
        case .fail:
            await intercepted.resolve(.success(()))
            throw FxPersistenceError.fenced
        case .held:
            await withCheckedContinuation { held in
                self.held = held
                Task { await self.intercepted.resolve(.success(())) }
            }
        }
    }
    func waitForCount(_ target: Int) async throws {
        guard count < target else { return }
        let signal = AsyncResult<Void>()
        counts.append((target, signal))
        try await signal.wait()
    }
    func release() { held?.resume(); held = nil }
}

private actor LeaseEffects {
    private(set) var count = 0
    func run() -> FxToolResult { count += 1; return FxToolResult(text: "sent once") }
}

private actor AgentLeaseHTTP: FxHTTPClient {
    enum Mode { case toolThenHeldBody, heldBody, immediate }
    private let mode: Mode
    let held = AsyncResult<Void>()
    let cancelled = AsyncResult<Void>()
    private(set) var requests = 0
    private var body: AsyncThrowingStream<Data, any Error>.Continuation?
    init(_ mode: Mode) { self.mode = mode }
    func send(_ request: URLRequest) async throws -> FxHTTPResponse {
        if request.httpMethod == "GET" {
            return Self.response(#"{"data":[{"id":"swift/lease","type":"language","tags":["tool-use"]}]}"#)
        }
        requests += 1
        if mode == .toolThenHeldBody && requests == 1 {
            return Self.response("data: {\"type\":\"tool-call\",\"toolCallId\":\"send-once\",\"toolName\":\"send\",\"input\":{}}\n\ndata: {\"type\":\"finish\",\"finishReason\":{\"unified\":\"tool-calls\",\"raw\":\"tool-calls\"}}\n\ndata: [DONE]\n\n")
        }
        if mode == .immediate { return Self.response(Self.answer) }
        let (stream, continuation) = AsyncThrowingStream<Data, any Error>.makeStream()
        body = continuation
        await held.resolve(.success(()))
        return FxHTTPResponse(statusCode: 200, body: stream, cancel: {
            continuation.finish(throwing: CancellationError())
            Task { await self.cancelled.resolve(.success(())) }
        })
    }
    func finish() { body?.yield(Data(Self.answer.utf8)); body?.finish(); body = nil }
    private static let answer = "data: {\"type\":\"text-delta\",\"delta\":\"done\"}\n\ndata: {\"type\":\"finish\",\"finishReason\":{\"unified\":\"stop\",\"raw\":\"stop\"}}\n\ndata: [DONE]\n\n"
    private static func response(_ text: String) -> FxHTTPResponse {
        FxHTTPResponse(statusCode: 200, body: AsyncThrowingStream { $0.yield(Data(text.utf8)); $0.finish() })
    }
}

@Suite(.timeLimit(.minutes(1))) struct AgentLeaseTests {
    private func location() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("lease.sqlite")
    }
    private func agent(_ store: any FxSessionStorage, http: AgentLeaseHTTP, effects: LeaseEffects) throws -> FxAgent {
        let send = FxTool(name: "send", description: "Send", inputSchema: .object(["type": .string("object")]), isIdempotent: false, writes: true) { _, _ in await effects.run() }
        return try FxAgent(configuration: FxConfiguration(apiKey: "fixture", model: "swift/lease", tools: [send], httpClient: http), store: store, checkpointAfterBytes: nil)
    }

    @Test(arguments: [false, true])
    func lostRenewalCancelsNativeHTTPAndSuccessorResumesWithoutRepeatingAnEffect(stalled: Bool) async throws {
        let url = location(), renewals = AgentLeaseRenewals(), effects = LeaseEffects()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let policy = try FxSessionLeasePolicy(duration: .seconds(2), renewalInterval: .milliseconds(50))
        let firstStore = try FxSessionStore(url: url, leasePolicy: policy)
        let secondStore = try FxSessionStore(url: url, leasePolicy: policy)
        let proxy = SessionStorageProxy(firstStore, beforeLeaseRenewal: { try await renewals.call() })
        let http = AgentLeaseHTTP(.toolThenHeldBody)
        let first = try agent(proxy, http: http, effects: effects)
        let session = try await first.session(id: "lease-loss")
        let turn = try await session.prompt("send then wait", id: "original")
        try await http.held.wait()
        #expect(await effects.count == 1)
        // Fault only renewals. Ordinary reads, writes and HTTP remain healthy.
        await renewals.arm(stalled ? .held : .fail)
        try await renewals.intercepted.wait()
        try await http.cancelled.wait()
        await #expect(throws: FxPersistenceError.fenced) { _ = try await turn.result }
        #expect(try await firstStore.result(session: session.id, agent: "default", id: "original") == nil)
        #expect(try await firstStore.entries(session: session.id, agent: "default", after: 0).allSatisfy {
            if case .ended = $0.event { return false }; return true
        })
        await renewals.release()
        await #expect(throws: FxPersistenceError.fenced) { try await first.close() }
        let secondHTTP = AgentLeaseHTTP(.immediate)
        let second = try agent(secondStore, http: secondHTTP, effects: effects)
        let recovered = try #require(try await second.session(id: session.id).resume())
        #expect(try await recovered.result.stopReason == .endTurn)
        #expect(recovered.id == "original")
        #expect(await effects.count == 1)
        #expect(await secondHTTP.requests == 1)
        let ends = try await secondStore.entries(session: session.id, agent: "default", after: 0).filter { if case .ended = $0.event { return true }; return false }
        #expect(ends.count == 1)
        try await second.close()
        try await firstStore.close(); try await secondStore.close()
    }

    @Test func heldNativeHTTPRemainsOwnedAcrossSeveralLeaseDurations() async throws {
        let url = location(), renewals = AgentLeaseRenewals(), effects = LeaseEffects()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let policy = try FxSessionLeasePolicy(duration: .milliseconds(500), renewalInterval: .milliseconds(50))
        let store = try FxSessionStore(url: url, leasePolicy: policy)
        let other = try FxSessionStore(url: url, leasePolicy: policy)
        let proxy = SessionStorageProxy(store, beforeLeaseRenewal: { try await renewals.call() })
        let http = AgentLeaseHTTP(.heldBody), first = try agent(proxy, http: http, effects: effects)
        let session = try await first.session(id: "long-http")
        let turn = try await session.prompt("wait", id: "one")
        try await http.held.wait()
        let baseline = await renewals.count
        // Each renewal is scheduled by the actual monotonic policy clock.
        // 22 further renewal intervals span more than two full TTLs.
        try await renewals.waitForCount(baseline + 22)
        #expect(try await other.claim(session: session.id, agent: "default") == nil)
        #expect(try await store.result(session: session.id, agent: "default", id: "one") == nil)
        #expect(await http.requests == 1)
        await http.finish()
        #expect(try await turn.result.stopReason == .endTurn)
        #expect(await effects.count == 0)
        try await first.close()
        try await store.close(); try await other.close()
    }
}
