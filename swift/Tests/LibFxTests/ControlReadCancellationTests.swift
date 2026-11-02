import Foundation
import Testing
@testable import LibFx

private actor ControlReadGate {
    let entered = AsyncResult<Void>()
    private let pending = AsyncResult<Void>()
    private var first = true

    func pauseFirstRead() async throws {
        guard first else { return }
        first = false
        await entered.resolve(.success(()))
        try await pending.wait()
    }
}

private actor ControlReadHTTP: FxHTTPClient {
    let entered = AsyncResult<Void>()
    let release = AsyncResult<Void>()
    private(set) var requests = 0

    func send(_ request: URLRequest) async throws -> FxHTTPResponse {
        #expect(request.httpMethod == "POST")
        requests += 1
        if requests == 1 {
            await entered.resolve(.success(()))
            try await release.wait()
        }
        let wire = "data: {\"type\":\"text-delta\",\"delta\":\"ok\"}\n\ndata: {\"type\":\"finish\",\"finishReason\":{\"unified\":\"stop\",\"raw\":\"stop\"}}\n\ndata: [DONE]\n\n"
        return FxHTTPResponse(statusCode: 200, body: AsyncThrowingStream {
            $0.yield(Data(wire.utf8))
            $0.finish()
        })
    }
}

@Suite(.serialized, .timeLimit(.minutes(1)))
struct ControlReadCancellationTests {
    @Test func completingATurnCancelsItsStoragePollWithoutFailingTheNextInput() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let base = try FxSessionStore(url: directory.appendingPathComponent("sessions.sqlite"))
        let gate = ControlReadGate()
        let store = SessionStorageProxy(base, beforeCancellationRead: { try await gate.pauseFirstRead() })
        let http = ControlReadHTTP()
        var configuration = FxConfiguration(apiKey: "fixture", model: "swift/control-read", httpClient: http)
        configuration.modelCatalog = try FxModelCatalog(response: Data(#"{"data":[{"id":"swift/control-read","type":"language"}]}"#.utf8))
        let agent = try FxAgent(configuration: configuration, store: store)
        do {
            let session = try await agent.session(id: "control-read")
            let first = try await session.prompt("first", id: "first")
            try await gate.entered.wait()
            try await http.entered.wait()
            let second = try await session.prompt("second", id: "second")
            await http.release.resolve(.success(()))
            #expect(try await first.result.stopReason == .endTurn)
            #expect(try await second.result.stopReason == .endTurn)
            #expect(await http.requests == 2)
            #expect(try await base.result(session: "control-read", agent: "default", id: "second")?.stopReason == .endTurn)
            try await agent.close()
            try await base.close()
        } catch {
            try? await agent.close()
            try? await base.close()
            throw error
        }
    }
}
