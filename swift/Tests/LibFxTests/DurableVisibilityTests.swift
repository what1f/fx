import Foundation
import Testing
@testable import LibFx

private actor VisibilityHTTP: FxHTTPClient {
    let entered = AsyncResult<Void>()
    private let release = AsyncResult<Void>()
    private let held: Bool
    private let chunks: Int
    private(set) var requests = 0

    init(held: Bool = false, chunks: Int = 1) { self.held = held; self.chunks = chunks }
    func send(_ request: URLRequest) async throws -> FxHTTPResponse {
        requests += 1
        await entered.resolve(.success(()))
        if held { try await release.wait() }
        let delta = "data: {\"type\":\"text-delta\",\"delta\":\"\(String(repeating: "x", count: 128))\"}\n\n"
        let frames = String(repeating: delta, count: chunks) +
            "data: {\"type\":\"finish\",\"finishReason\":{\"unified\":\"stop\",\"raw\":\"stop\"}}\n\ndata: [DONE]\n\n"
        return FxHTTPResponse(statusCode: 200, body: AsyncThrowingStream {
            $0.yield(Data(frames.utf8)); $0.finish()
        })
    }
    func finish() async { await release.resolve(.success(())) }
}

@Suite(.serialized, .timeLimit(.minutes(1))) struct DurableVisibilityTests {
    private func configuration(_ http: VisibilityHTTP) throws -> FxConfiguration {
        var configuration = FxConfiguration(apiKey: "fixture", model: "swift/visibility", httpClient: http)
        configuration.modelCatalog = try FxModelCatalog(response: Data(#"{"data":[{"id":"swift/visibility","type":"language"}]}"#.utf8))
        return configuration
    }

    private func replay(_ store: FxSessionStore, sessionID: String) async throws -> [FxSessionEntry] {
        var result: [FxSessionEntry] = [], cursor: Int64 = 0
        while true {
            let page = try await store.entries(session: sessionID, agent: "default", after: cursor)
            #expect(page.count <= 128)
            guard let last = page.last else { return result }
            result.append(contentsOf: page)
            cursor = last.cursor
        }
    }

    // Audit976: the viewer is already polling before this session has an owner.
    // Its first event must arrive while the provider is still held, not at EOF.
    @Test func subscriberBeforeIntakeSeesFirstCommitWhileProviderIsHeld() async throws {
        let database = try FxSessionStore(), storage = SessionStorageProxy(database)
        let http = VisibilityHTTP(held: true)
        let agent = try FxAgent(configuration: configuration(http), store: storage, checkpointAfterBytes: nil)
        let session = try await agent.session(id: "viewer-before-intake")
        let first = Task {
            var reader = session.events().makeAsyncIterator()
            return try await reader.next()
        }
        defer { first.cancel() }
        while !(await storage.calls.contains("entries")) { await Task.yield() }
        #expect(try await database.owner(session: session.id) == nil)
        let turn = try await session.prompt("first input", id: "first")
        try await http.entered.wait()
        let entry = try #require(try await first.value)
        #expect(entry.event == .started(id: "first", sessionID: session.id, input: [.text("first input")]))
        #expect(try await database.result(session: session.id, agent: "default", id: turn.id) == nil)
        await http.finish()
        #expect(try await turn.result.stopReason == .endTurn)
        try await agent.close()
        try await database.close()
    }

    // Audit952: any second worker journal read fails. Both public completion
    // surfaces still become visible from the original native turn's commit.
    @Test func completedResultAndEndReplayDoNotRequireAnotherJournalLoad() async throws {
        let database = try FxSessionStore(), storage = SessionStorageProxy(database)
        await storage.failNext("loadJournal", with: SessionStorageTestFailure(), after: 1, count: 100)
        let http = VisibilityHTTP()
        let agent = try FxAgent(configuration: configuration(http), store: storage, checkpointAfterBytes: nil)
        let session = try await agent.session(id: "completion-without-reload")
        let turn = try await session.prompt("complete once", id: "one")
        let result = try await turn.result
        #expect(result.stopReason == .endTurn && result.error == nil)
        var reader = session.events().makeAsyncIterator()
        var ended: FxSessionResult?
        while ended == nil {
            let entry = try #require(try await reader.next())
            if case .ended(let value) = entry.event { ended = value }
        }
        #expect(ended == result)
        #expect(await storage.calls.filter { $0 == "loadJournal" }.count == 1)
        #expect(await http.requests == 1)
        try await agent.close()
        try await database.close()
    }

    // Audit906: checkpoints prune the worker log while public event history
    // keeps growing. Reopen the actual SQLite file and execute from that state.
    @Test func checkpointedWorkerLoadsStayBoundedAcrossLongPublicHistory() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("visibility.sqlite")
        let turns = 128, chunks = 8
        let database = try FxSessionStore(url: url), http = VisibilityHTTP(chunks: chunks)
        let agent = try FxAgent(configuration: configuration(http), store: database, checkpointAfterBytes: 0)
        let session = try await agent.session(id: "long-history")
        for index in 0..<turns {
            let turn = try await session.prompt("prompt-\(index)", id: "input-\(index)")
            #expect(try await turn.result.stopReason == .endTurn)
            let snapshot = try await database.snapshot(session: session.id, agent: "default")
            #expect(snapshot.checkpoint != nil)
            #expect(snapshot.journal.isEmpty)
        }
        let before = try await replay(database, sessionID: session.id)
        #expect(before.count >= turns * 3)
        let outputBytes = before.reduce(0) { bytes, entry in
            if case .update(_, .text(let text)) = entry.event { return bytes + text.utf8.count }
            return bytes
        }
        #expect(outputBytes == turns * chunks * 128)
        try await agent.close()
        try await database.close()

        let reopened = try FxSessionStore(url: url)
        let compacted = try await reopened.snapshot(session: session.id, agent: "default")
        #expect(compacted.checkpoint != nil && compacted.journal.isEmpty)
        #expect(try await replay(reopened, sessionID: session.id) == before)
        let restored = try FxAgent(configuration: configuration(http), store: reopened, checkpointAfterBytes: 0)
        let restoredSession = try await restored.session(id: session.id)
        let next = try await restoredSession.prompt("after reopening", id: "next")
        #expect(try await next.result.stopReason == .endTurn)
        #expect(await http.requests == turns + 1)
        #expect(try await reopened.snapshot(session: session.id, agent: "default").journal.isEmpty)
        try await restored.close()
        try await reopened.close()
    }
}
