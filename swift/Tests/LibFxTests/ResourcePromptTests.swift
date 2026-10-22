import Foundation
import Testing
@testable import LibFx

private actor ResourceHTTP: FxHTTPClient {
    private(set) var requests: [String] = []
    func send(_ request: URLRequest) throws -> FxHTTPResponse {
        #expect(request.httpMethod == "POST")
        requests.append(String(decoding: request.httpBody ?? Data(), as: UTF8.self))
        let text = "data: {\"type\":\"text-delta\",\"delta\":\"resource answer\"}\n\ndata: {\"type\":\"finish\",\"finishReason\":{\"unified\":\"stop\",\"raw\":\"stop\"}}\n\ndata: [DONE]\n\n"
        return FxHTTPResponse(statusCode: 200, body: AsyncThrowingStream {
            $0.yield(Data(text.utf8))
            $0.finish()
        })
    }
}

private actor ResourceQueue: FxSessionQueue {
    func enqueue(_ wakeup: FxSessionWakeup) {}
}

@Suite(.serialized, .timeLimit(.minutes(1))) struct ResourcePromptTests {
    private func configuration(_ http: ResourceHTTP, workspace: URL? = nil) throws -> FxConfiguration {
        var configuration = FxConfiguration(apiKey: "fixture", model: "swift/resource", httpClient: http)
        configuration.modelCatalog = try FxModelCatalog(response: Data(#"{"data":[{"id":"swift/resource","type":"language"}]}"#.utf8))
        if let workspace { configuration.workspace = workspace }
        return configuration
    }

    @Test func nativeResourceURIsAndTextSurviveCheckpointRestore() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("Resource File.txt")
        try Data("LOCAL_FILE_RESOURCE_SENTINEL\n".utf8).write(to: file)
        let http = ResourceHTTP(), configuration = try configuration(http, workspace: directory)
        let first = try await FxEngine.open(configuration: configuration)
        let turn = try await first.prompt([
            .text("Summarize these resources"),
            .resource(uri: file.absoluteString, text: "LOCAL_EMBEDDED_資料"),
            .resource(uri: "memory://reference", text: "REMOTE_EMBEDDED_SENTINEL"),
        ])
        #expect(try await turn.result.stopReason == .endTurn)
        let request = try #require(await http.requests.first)
        #expect(request.contains("LOCAL_EMBEDDED_資料"))
        #expect(request.contains("REMOTE_EMBEDDED_SENTINEL"))
        #expect(request.contains("Resource%20File.txt"))
        let checkpoint = try await first.checkpoint()
        try await first.close()

        let restored = try await FxEngine.open(configuration: configuration, checkpoint: checkpoint)
        let next = try await restored.prompt("Continue")
        #expect(try await next.result.stopReason == .endTurn)
        let replay = try #require(await http.requests.last)
        #expect(replay.contains("LOCAL_EMBEDDED_資料"))
        #expect(replay.contains("REMOTE_EMBEDDED_SENTINEL"))
        #expect(replay.contains("Resource%20File.txt"))
        try await restored.close()
    }

    @Test func durableResourceInputReopensAndReplaysWithoutChangingItsIdentity() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("resources.sqlite")
        let http = ResourceHTTP(), configuration = try configuration(http)
        let input: [FxPromptContent] = [.text("Read this"), .resource(uri: "memory://durable/資料", text: "DURABLE_RESOURCE_SENTINEL")]
        let steered: [FxPromptContent] = [.text("Read next"), .resource(uri: "memory://next", text: "STEER_RESOURCE_SENTINEL")]
        let firstStore = try FxSessionStore(url: url)
        let queue = ResourceQueue()
        let first = try FxAgent(configuration: configuration, store: firstStore, queue: queue)
        let session = try await first.session(id: "resources")
        let original = try await session.prompt(input, id: "original")
        let wakeup = FxSessionWakeup(agent: "default", sessionID: session.id)
        #expect(try await first.deliver(wakeup) == .complete)
        #expect(try await original.result.stopReason == .endTurn)
        _ = try await session.steer(steered, id: "steered")
        try await first.close()
        try await firstStore.close()

        let secondStore = try FxSessionStore(url: url)
        let second = try FxAgent(configuration: configuration, store: secondStore, queue: queue)
        let reopened = try await second.session(id: "resources")
        let repeated = try await reopened.prompt("must not replace resource", id: "original")
        #expect(try await second.deliver(wakeup) == .complete)
        #expect(try await second.deliver(wakeup) == .complete)
        #expect(try await secondStore.result(session: "resources", agent: "default", id: "steered")?.stopReason == .endTurn)
        #expect(repeated.isRepeated)
        #expect(try await repeated.result.stopReason == .endTurn)
        let entries = try await secondStore.entries(session: "resources", agent: "default", after: 0)
        let starts = entries.compactMap { entry -> (String, [FxPromptContent])? in
            if case .started(let id, _, let content) = entry.event { return (id, content) }
            return nil
        }
        #expect(starts.map(\.0) == ["original", "steered"])
        #expect(starts.first?.1 == input)
        #expect(starts.last?.1 == steered)
        #expect(await http.requests.count == 2)
        #expect(await http.requests.first?.contains("DURABLE_RESOURCE_SENTINEL") == true)
        #expect(await http.requests.last?.contains("STEER_RESOURCE_SENTINEL") == true)
        try await second.close()
        try await secondStore.close()
    }

    @Test func resourceAdmissionCountsURIAndTextInBothBudgets() throws {
        let uri = "memory://資料/\"reference"
        let content: [FxPromptContent] = [.text("Read"), .resource(uri: uri, text: "embedded\n資料")]
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        let logical: JSONValue = .array([
            .object(["type": .string("text"), "text": .string("Read")]),
            .object(["type": .string("resource"), "resource": .object(["uri": .string(uri), "text": .string("embedded\n資料")])]),
        ])
        let bytes = try encoder.encode(logical).count
        let settings = String(repeating: "x", count: SessionInputAdmission.maximumBytes - bytes - 2)
        try SessionInputAdmission.validate(content, options: .init(settings: .string(settings)))
        #expect(throws: FxError.self) {
            try SessionInputAdmission.validate(content, options: .init(settings: .string(settings + "x")))
        }
        let configuration = FxConfiguration(apiKey: "fixture")
        try configuration.validatePrompt([.text("Read"), .resource(uri: "file:///tmp/reference")])
        #expect(throws: FxError.self) { try configuration.validatePrompt([.resource(uri: "memory://reference", text: "text")]) }
        #expect(throws: FxError.self) {
            try configuration.validatePrompt([.text("Read"), .resource(uri: "memory://large", text: String(repeating: "x", count: 8 * 1024 * 1024))])
        }
        #expect(try JSONDecoder().decode([FxPromptContent].self, from: encoder.encode(content)) == content)
    }
}
