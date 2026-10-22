import Foundation
import Testing
@testable import LibFx

// The held operation is accept, not the worker's lease-scoped image store.
private actor IntakeStorage: FxSessionStorage {
    let base: FxSessionStore
    let afterCommit: Bool
    let entered = AsyncResult<Void>()
    private let release = AsyncResult<Void>()
    private var holdsNext = true
    private var committedWaiter: CheckedContinuation<Void, Never>?

    init(_ base: FxSessionStore, afterCommit: Bool) {
        self.base = base
        self.afterCommit = afterCommit
    }
    func owner(session: String) async throws -> String? {
        return try await base.owner(session: session)
    }
    func accept(session: String, agent: String, id: String, content: [FxPromptContent], options: FxSessionOptions, checkpoint: Data?, steering: Bool, deferringImageLimits: Bool) async throws -> Bool {
        let hold = holdsNext
        holdsNext = false
        if hold && !afterCommit {
            // Models cancellable host I/O before the storage transaction.
            await entered.resolve(.success(()))
            try await release.wait()
        }
        let repeated = try await base.accept(session: session, agent: agent, id: id, content: content,
                                            options: options, checkpoint: checkpoint, steering: steering,
                                            deferringImageLimits: deferringImageLimits)
        if hold && afterCommit {
            // Once committed, cancellation cannot turn acceptance into withdrawal.
            await withCheckedContinuation { continuation in
                committedWaiter = continuation
                Task { await self.entered.resolve(.success(())) }
            }
        }
        return repeated
    }
    func releaseAdmission() async {
        committedWaiter?.resume()
        committedWaiter = nil
        await release.resolve(.success(()))
    }
    func resumePoint(session: String, agent: String) async throws -> (id: String, cursor: Int64)? {
        return try await base.resumePoint(session: session, agent: agent)
    }
    func hasWork(session: String, agent: String) async throws -> Bool {
        return try await base.hasWork(session: session, agent: agent)
    }
    func claim(session: String, agent: String) async throws -> FxSessionLease? {
        return try await base.claim(session: session, agent: agent)
    }
    func release(_ lease: FxSessionLease) async throws {
        return try await base.release(lease)
    }
    func checkLease(_ lease: FxSessionLease) async throws {
        return try await base.checkLease(lease)
    }
    func next(_ lease: FxSessionLease) async throws -> FxSessionInput? {
        return try await base.next(lease)
    }
    func start(_ lease: FxSessionLease, input: FxSessionInput) async throws {
        return try await base.start(lease, input: input)
    }
    func appendEvent(_ lease: FxSessionLease, _ event: FxSessionEvent) async throws {
        return try await base.appendEvent(lease, event)
    }
    func finish(_ lease: FxSessionLease, id: String, result: FxSessionResult) async throws {
        return try await base.finish(lease, id: id, result: result)
    }
    func cancel(session: String, agent: String, id: String?) async throws {
        return try await base.cancel(session: session, agent: agent, id: id)
    }
    func cancelled(_ lease: FxSessionLease, id: String) async throws -> Bool {
        return try await base.cancelled(lease, id: id)
    }
    func result(session: String, agent: String, id: String) async throws -> FxSessionResult? {
        return try await base.result(session: session, agent: agent, id: id)
    }
    func entries(session: String, agent: String, after cursor: Int64) async throws -> [FxSessionEntry] {
        return try await base.entries(session: session, agent: agent, after: cursor)
    }
    func snapshot(session: String, agent: String) async throws -> FxPersistenceSnapshot {
        return try await base.snapshot(session: session, agent: agent)
    }
    func loadJournal(_ lease: FxSessionLease) async throws -> FxPersistenceSnapshot {
        return try await base.loadJournal(lease)
    }
    func appendJournal(_ lease: FxSessionLease, expected: String?, key: String, data: Data, barrier: Bool, marks: [FxSessionJournalMark]?) async throws -> String {
        return try await base.appendJournal(lease, expected: expected, key: key, data: data, barrier: barrier, marks: marks)
    }
    func saveJournalCheckpoint(_ lease: FxSessionLease, _ checkpoint: FxStoredCheckpoint) async throws {
        return try await base.saveJournalCheckpoint(lease, checkpoint)
    }
    func storeImage(_ data: Data, named name: String, lease: FxSessionLease) async throws {
        return try await base.storeImage(data, named: name, lease: lease)
    }
    func loadImage(named name: String, lease: FxSessionLease) async throws -> Data? {
        return try await base.loadImage(named: name, lease: lease)
    }
    func loadImage(named name: String, session: String, agent: String) async throws -> Data? {
        return try await base.loadImage(named: name, session: session, agent: agent)
    }
    func steering(_ lease: FxSessionLease, owner: String) async throws -> (pending: [FxSessionSteeringInput], ends: Bool) {
        return try await base.steering(lease, owner: owner)
    }
    func publicInputID(_ coreID: String, session: String) async throws -> String? {
        return try await base.publicInputID(coreID, session: session)
    }
    func deliveryCutoffs(_ lease: FxSessionLease, id: String) async throws -> Int {
        return try await base.deliveryCutoffs(lease, id: id)
    }
    func cutOffDelivery(_ lease: FxSessionLease, id: String) async throws -> Int {
        return try await base.cutOffDelivery(lease, id: id)
    }
    func harnessFailureState(_ lease: FxSessionLease, id: String) async throws -> FxHarnessFailureState {
        return try await base.harnessFailureState(lease, id: id)
    }
    func recordHarnessStop(_ lease: FxSessionLease, id: String) async throws -> Int {
        return try await base.recordHarnessStop(lease, id: id)
    }
    func halt(_ lease: FxSessionLease) async throws {
        try await base.halt(lease)
    }
    func input(_ lease: FxSessionLease, id: String) async throws -> FxSessionInput? {
        return try await base.input(lease, id: id)
    }

    func harnessRecoveryInput(_ lease: FxSessionLease) async throws -> FxSessionInput? {
        return try await base.harnessRecoveryInput(lease)
    }
    func setHarnessRecoveryInput(_ lease: FxSessionLease, id: String?) async throws {
        try await base.setHarnessRecoveryInput(lease, id: id)
    }

}

private actor IntakeQueue: FxSessionQueue {
    private(set) var messages: [FxSessionWakeup] = []
    func enqueue(_ wakeup: FxSessionWakeup) { messages.append(wakeup) }
}

private actor IntakeHTTP: FxHTTPClient {
    private(set) var requests: [String] = []
    func send(_ request: URLRequest) throws -> FxHTTPResponse {
        #expect(request.httpMethod == "POST")
        requests.append(String(decoding: request.httpBody ?? Data(), as: UTF8.self))
        let text = "data: {\"type\":\"text-delta\",\"delta\":\"accepted\"}\n\ndata: {\"type\":\"finish\",\"finishReason\":{\"unified\":\"stop\",\"raw\":\"stop\"}}\n\ndata: [DONE]\n\n"
        return FxHTTPResponse(statusCode: 200, body: AsyncThrowingStream {
            $0.yield(Data(text.utf8))
            $0.finish()
        })
    }
}

@Suite(.serialized, .timeLimit(.minutes(1))) struct IntakeCancellationTests {
    private let image = FxImage(data: Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jP0cAAAAASUVORK5CYII=")!, format: .png)

    private func agent(_ store: IntakeStorage, queue: IntakeQueue, http: IntakeHTTP) throws -> FxAgent {
        var configuration = FxConfiguration(apiKey: "fixture", model: "swift/intake", httpClient: http)
        configuration.modelCatalog = try FxModelCatalog(response: Data(#"{"data":[{"id":"swift/intake","type":"language","tags":["vision","file-input"]}]}"#.utf8))
        return try FxAgent(configuration: configuration, store: store, checkpointAfterBytes: nil, queue: queue)
    }

    private func accept(_ content: [FxPromptContent], session: FxSession, steering: Bool) async throws {
        if steering { _ = try await session.steer(content, id: "input") }
        else { _ = try await session.prompt(content, id: "input") }
    }

    @Test(arguments: [false, true])
    func cancellationBeforeCommitLeavesTheIDReusable(steering: Bool) async throws {
        let database = try FxSessionStore(), storage = IntakeStorage(database, afterCommit: false)
        let queue = IntakeQueue(), http = IntakeHTTP(), agent = try agent(storage, queue: queue, http: http)
        let session = try await agent.session(id: "withdrawn-intake")
        let pending = Task { try await accept([.text("withdrawn image"), .image(image)], session: session, steering: steering) }
        try await storage.entered.wait()
        pending.cancel()
        await #expect(throws: CancellationError.self) { try await pending.value }
        #expect(try await database.owner(session: session.id) == nil)
        #expect(await queue.messages.isEmpty)
        #expect(await http.requests.isEmpty)

        // Releasing a late I/O completion cannot create the withdrawn input.
        await storage.releaseAdmission()
        #expect(try await database.owner(session: session.id) == nil)
        try await accept([.text("replacement")], session: session, steering: steering)
        let wakeup = try #require(await queue.messages.first)
        #expect(await queue.messages.count == 1)
        #expect(try await agent.deliver(wakeup) == .complete)
        #expect(try await database.result(session: session.id, agent: "default", id: "input")?.stopReason == .endTurn)
        let entries = try await database.entries(session: session.id, agent: "default", after: 0)
        #expect(entries.filter { if case .started = $0.event { return true }; return false }.count == 1)
        #expect(entries.filter { if case .ended = $0.event { return true }; return false }.count == 1)
        #expect(await http.requests.count == 1)
        #expect(await http.requests.first?.contains("replacement") == true)
        #expect(await http.requests.first?.contains("withdrawn image") == false)
        try await agent.close()
        try await database.close()
    }

    @Test(arguments: [false, true])
    func cancellationAfterCommitPreservesAcceptedInput(steering: Bool) async throws {
        let database = try FxSessionStore(), storage = IntakeStorage(database, afterCommit: true)
        let queue = IntakeQueue(), http = IntakeHTTP(), agent = try agent(storage, queue: queue, http: http)
        let session = try await agent.session(id: "committed-intake")
        let original: [FxPromptContent] = [.text("original image"), .image(image)]
        let pending = Task { try await accept(original, session: session, steering: steering) }
        try await storage.entered.wait()
        #expect(try await database.owner(session: session.id) == "default")
        #expect(try await database.pendingID(session: session.id, agent: "default") == "input")
        #expect(await queue.messages.isEmpty)
        pending.cancel()
        await storage.releaseAdmission()
        try await pending.value
        #expect(await queue.messages.count == 1)

        // A retry must retain the committed picture and execute it exactly once.
        try await accept([.text("ignored replacement")], session: session, steering: steering)
        let lease = try #require(try await database.claim(session: session.id, agent: "default"))
        let stored = try #require(try await database.input(lease, id: "input"))
        #expect(stored.content == original)
        #expect(!stored.cancelRequested)
        try await database.release(lease)
        let wakeup = try #require(await queue.messages.first)
        #expect(try await agent.deliver(wakeup) == .complete)
        #expect(try await agent.deliver(wakeup) == .complete)
        #expect(try await database.result(session: session.id, agent: "default", id: "input")?.stopReason == .endTurn)
        #expect(await http.requests.count == 1)
        #expect(await http.requests.first?.contains("original image") == true)
        #expect(await http.requests.first?.contains("ignored replacement") == false)
        #expect(await http.requests.first?.contains(image.data!.base64EncodedString()) == true)
        try await agent.close()
        try await database.close()
    }
}
