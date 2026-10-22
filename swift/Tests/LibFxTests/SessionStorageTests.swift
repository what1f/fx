import Foundation
import Testing
import LibFx

private actor StorageHTTP: FxHTTPClient {
    func send(_ request: URLRequest) async throws -> FxHTTPResponse {
        let text = request.httpMethod == "GET"
            ? #"{"data":[{"id":"swift/storage","type":"language"}]}"#
            : "data: {\"type\":\"text-delta\",\"delta\":\"stored\"}\n\ndata: {\"type\":\"finish\",\"finishReason\":{\"unified\":\"stop\",\"raw\":\"stop\"}}\n\ndata: [DONE]\n\n"
        return FxHTTPResponse(statusCode: 200, body: AsyncThrowingStream { $0.yield(Data(text.utf8)); $0.finish() })
    }
}

@Suite(.serialized, .timeLimit(.minutes(1))) struct SessionStorageTests {
    private func agent(_ store: any FxSessionStorage) throws -> FxAgent {
        try FxAgent(configuration: FxConfiguration(apiKey: "fixture", model: .init(id: "swift/storage"),
                                                  httpClient: StorageHTTP()), store: store, checkpointAfterBytes: nil)
    }

    @Test func hostStorageRunsTurnsAndReopensAcceptedHistory() async throws {
        let database = try FxSessionStore(), storage = SessionStorageProxy(database)
        let first = try agent(storage), session = try await first.session(id: "host-storage")
        let turn = try await session.prompt("hello", id: "input")
        #expect(try await turn.result.stopReason == .endTurn)
        try await first.close()
        let next = try agent(storage), reopened = try await next.session(id: session.id)
        let repeated = try await reopened.prompt("ignored retry", id: "input")
        #expect(repeated.isRepeated)
        #expect(try await repeated.result.stopReason == .endTurn)
        let calls = await storage.calls
        #expect(calls.contains("claim") && calls.contains("loadJournal") && calls.contains("appendJournal"))
        #expect(calls.contains("appendEvent") && calls.contains("finish") && calls.contains("release"))
        try await next.close()
        try await database.close()
    }

    @Test(arguments: ["loadJournal", "appendJournal", "appendEvent", "finish"])
    func storageFailuresRetainIdentityAndLeaveIntakeRecoverable(operation: String) async throws {
        let database = try FxSessionStore(), storage = SessionStorageProxy(database), failure = SessionStorageTestFailure()
        await storage.failNext(operation, with: failure)
        let first = try agent(storage), session = try await first.session(id: "host-failure")
        let turn = try await session.prompt("hello", id: "input")
        do { _ = try await turn.result; Issue.record("Storage failure became a turn result") }
        catch { #expect((error as? SessionStorageTestFailure) === failure) }
        do { try await first.close(); Issue.record("Close lost the storage failure") }
        catch { #expect((error as? SessionStorageTestFailure) === failure) }
        #expect(try await storage.result(session: session.id, agent: "default", id: "input") == nil)
        let next = try agent(storage), reopened = try await next.session(id: session.id)
        let resumed = try #require(try await reopened.resume())
        let result = try await resumed.result
        if operation == "finish" { #expect(result.stopReason == .unknown) }
        else { #expect(result.stopReason == .endTurn || result.stopReason == .unknown) }
        #expect(result.id == "input")
        #expect(result.error == nil)
        try await next.close()
        try await database.close()
    }

    @Test func invalidIntakeIsRejectedBeforeCallingHostStorage() async throws {
        let database = try FxSessionStore(), storage = SessionStorageProxy(database)
        let agent = try agent(storage), session = try await agent.session(id: "admission")
        await #expect(throws: FxError.self) { try await session.prompt("hello", id: "invalid id") }
        await #expect(throws: FxError.self) { try await session.steer(String(repeating: "x", count: 65_537)) }
        #expect(await storage.calls.isEmpty)
        try await agent.close()
        try await database.close()
    }

    @Test func journalMarksRetainOrderWithoutExposingTheirEncodingToTheHost() throws {
        let id = FxSessionInput.runtimeID(for: "steer")
        let record: JSONValue = .object(["events": .array([
            .object(["type": .string("input_accepted"), "data": .object(["id": .string(id)])]),
            .object(["type": .string("turn_progress"), "steps": .number(2), "data": .object(["tool_state": .string("running")]), "inputs": .array([.string(id)])]),
            .object(["type": .string("input_withdrawn"), "data": .object(["id": .string(id)])]),
        ])])
        #expect(try FxSessionJournalMark.decode(JSONEncoder().encode(record)) == [.accepted(id), .progress("2:running"), .placed(id), .withdrawn(id)])
        #expect(throws: FxPersistenceError.invalidJournal) { try FxSessionJournalMark.decode(Data("{}".utf8)) }
    }
}
