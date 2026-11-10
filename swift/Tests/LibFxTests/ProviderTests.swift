import Foundation
import Testing
@testable import LibFx

private actor ProviderServer: FxHTTPClient {
    var requests: [URLRequest] = []
    let status: Int
    init(status: Int = 200) { self.status = status }
    func send(_ request: URLRequest) async throws -> FxHTTPResponse {
        requests.append(request)
        let text = status == 200
            ? "data: {\"choices\":[{\"index\":0,\"delta\":{\"role\":\"assistant\",\"content\":\"custom reply\"},\"finish_reason\":null}]}\n\ndata: {\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"stop\"}]}\n\ndata: [DONE]\n\n"
            : "{\"error\":{\"message\":\"Unauthorized\",\"type\":\"invalid_api_key\"}}"
        return FxHTTPResponse(statusCode: status, headers: ["content-type": status == 200 ? "text/event-stream" : "application/json"], body: AsyncThrowingStream {
            $0.yield(Data(text.utf8)); $0.finish()
        })
    }
}

private actor CredentialLog {
    var requests: [FxCredentialRequest] = []
    func key(_ request: FxCredentialRequest) -> String { requests.append(request); return "test-provider-key" }
    func pending(_ request: FxCredentialRequest) async throws -> String {
        requests.append(request)
        try await Task.sleep(for: .seconds(60))
        return "never-used"
    }
}

@Suite struct ProviderTests {
    @Test func messagesModeIsRuntimeOwned() throws {
        let provider = try FxCustomProvider(name: "messages", baseURL: URL(string: "https://models.example/v1")!, apiProtocol: .anthropicMessages)
        #expect(provider.definition["messages"]?["deferred_tool_mode"] == nil)
        #expect(provider.chatURL.absoluteString == "https://models.example/v1/messages")
    }

    private func provider() throws -> FxCustomProvider {
        try FxCustomProvider(name: "local", baseURL: URL(string: "https://models.example/v1/")!, models: [
            "local-model": .init(contextWindow: 32768, maxOutputTokens: 4096, supportsToolUse: true),
        ])
    }

    @Test func customProviderUsesCoreProtocolAndScopedHostCredentials() async throws {
        let server = ProviderServer(), credentials = CredentialLog()
        let config = FxConfiguration(provider: .custom(try provider(), credentials: { await credentials.key($0) }),
                                     model: "local-model", httpClient: server)
        let options = try JSONEncoder().encode(config.nativeOptions)
        #expect(!String(decoding: options, as: UTF8.self).contains("test-provider-key"))
        let engine = try await FxEngine.open(configuration: config)
        let turn = try await engine.prompt("say hello")
        var text = ""
        for try await event in turn { if case .text(let delta) = event { text += delta } }
        #expect(try await turn.result.stopReason == .endTurn)
        #expect(text == "custom reply")
        let requests = await server.requests
        #expect(requests.count == 1)
        let request = try #require(requests.first)
        #expect(request.url?.absoluteString == "https://models.example/v1/chat/completions")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-provider-key")
        let body = try JSONDecoder().decode(JSONValue.self, from: #require(request.httpBody))
        #expect(body["model"] == .string("local-model"))
        #expect(body["stream"] == .bool(true))
        let calls = await credentials.requests
        #expect(calls.count == 1)
        #expect(calls.first?.sessionID == engine.sessionID)
        #expect(calls.first?.provider == "local")
        let checkpoint = try await engine.checkpoint()
        #expect(!String(decoding: checkpoint, as: UTF8.self).contains("test-provider-key"))
        try await engine.close()
    }

    @Test func idleModelAndEffortUpdatesKeepHistoryAndRejectBusyChanges() async throws {
        let server = ProviderServer()
        let provider = try FxCustomProvider(name: "updates", baseURL: URL(string: "https://models.example/v1")!,
            models: ["first": .init(supportsToolUse: true)])
        let store = FxMemoryPersistence()
        let config = FxConfiguration(provider: .custom(provider), model: FxModel(id: "first", reasoningEffort: "high"),
                                     instructions: "Stable prefix", httpClient: server)
        let engine = try await FxEngine.open(configuration: config, persistence: store)
        let sessionID = engine.sessionID
        for index in 0..<4 {
            if index == 2 { try await engine.setModel("second"); try await engine.setReasoningEffort("low") }
            let turn = try await engine.prompt("Remember marker \(index)")
            await #expect(throws: FxError.busy) { try await engine.setModel("first") }
            for try await _ in turn {}
            _ = try await turn.result
        }
        try await engine.setReasoningEffort(nil)
        let last = try await engine.prompt("Default effort")
        for try await _ in last {}
        _ = try await last.result
        let bodies = try await server.requests.map { try JSONDecoder().decode(JSONValue.self, from: #require($0.httpBody)) }
        #expect(bodies.count == 5)
        for index in 0..<4 {
            #expect(bodies[index]["model"] == .string(index < 2 ? "first" : "second"))
            #expect(bodies[index]["reasoning_effort"] == .string(index < 2 ? "high" : "low"))
            if case .array(let messages)? = bodies[index]["messages"],
               case .array(let initial)? = bodies[0]["messages"] { #expect(messages.first == initial.first) }
            else { Issue.record("Missing messages") }
        }
        #expect(bodies[4]["reasoning_effort"] == nil)
        #expect(String(decoding: try JSONEncoder().encode(bodies[3]), as: UTF8.self).contains("Remember marker 0"))
        #expect(engine.sessionID == sessionID)
        try await engine.close()
        var restoredConfig = config
        restoredConfig.model = FxModel(id: "second")
        let restored = try await FxEngine.open(configuration: restoredConfig, sessionID: sessionID, persistence: store)
        #expect(restored.sessionID == sessionID)
        let next = try await restored.prompt("After recovery")
        for try await _ in next {}
        _ = try await next.result
        let recovered = try JSONDecoder().decode(JSONValue.self, from: #require(await server.requests.last?.httpBody))
        #expect(recovered["model"] == .string("second"))
        #expect(recovered["reasoning_effort"] == nil)
        try await restored.close()
    }

    @Test func localProviderNeedsNoKeyAndUnauthorizedIsNotRetried() async throws {
        for status in [200, 401] {
            let server = ProviderServer(status: status)
            let engine = try await FxEngine.open(configuration: FxConfiguration(
                provider: .custom(try provider()), model: "local-model", httpClient: server))
            let turn = try await engine.prompt("test")
            do {
                for try await _ in turn {}
                let result = try await turn.result
                #expect(status == 200 || result.stopReason != .endTurn)
            } catch { #expect(status == 401) }
            let requests = await server.requests
            #expect(requests.count == 1)
            #expect(requests.first?.value(forHTTPHeaderField: "Authorization") == nil)
            try await engine.close()
        }
    }

    @Test func credentialsAreNotAddedToOtherEndpoints() async throws {
        let server = ProviderServer(), credentials = CredentialLog()
        let client = ProviderHTTPClient(client: server, provider: .custom(try provider(), credentials: { await credentials.key($0) }))
        await client.setSessionID("session")
        for endpoint in ["https://elsewhere.example/v1/chat/completions", "https://models.example/v1/models", "https://models.example/v1/chat/completions?other=1"] {
            let response = try await client.send(URLRequest(url: URL(string: endpoint)!))
            response.cancel()
        }
        #expect(await credentials.requests.isEmpty)
        #expect(await server.requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == nil })
    }

    @Test func cancellingTurnCancelsCredentialLookupBeforeHTTP() async throws {
        let server = ProviderServer(), credentials = CredentialLog()
        let engine = try await FxEngine.open(configuration: FxConfiguration(
            provider: .custom(try provider(), credentials: { try await credentials.pending($0) }),
            model: "local-model", httpClient: server))
        let turn = try await engine.prompt("test")
        let deadline = ContinuousClock.now + .seconds(2)
        while await credentials.requests.isEmpty, ContinuousClock.now < deadline { await Task.yield() }
        #expect(await credentials.requests.count == 1)
        await turn.cancel()
        for try await _ in turn {}
        #expect(try await turn.result.stopReason == .cancelled)
        #expect(await server.requests.isEmpty)
        try await engine.close()
    }

    @Test func invalidCredentialsNeverReachHTTP() async throws {
        let server = ProviderServer(), credentials = CredentialLog()
        let engine = try await FxEngine.open(configuration: FxConfiguration(
            provider: .custom(try provider(), credentials: {
                _ = await credentials.key($0)
                return "key\r\nInjected: value"
            }), model: "local-model", httpClient: server))
        let turn = try await engine.prompt("test")
        do {
            for try await _ in turn {}
            #expect(try await turn.result.stopReason != .endTurn)
        } catch {
            guard case FxError.rpc = error else { throw error }
            #expect(!String(describing: error).contains("Injected"))
        }
        #expect(await server.requests.isEmpty)
        #expect(await credentials.requests.count == 1)
        try await engine.close()
    }

    @Test func errorRedactionPreservesDetailsAndMasksMixedJSONEscapes() async throws {
        let secret = "key/\"unicode雪", refresh = "refresh/\"token"
        let data = try JSONEncoder().encode(JSONValue.object([
            "error": .object(["message": .string("rejected \(secret) and \(refresh)")]),
        ]))
        let original = FxHTTPResponse(statusCode: 403, headers: ["content-length": "900", "content-encoding": "gzip"],
                                      body: AsyncThrowingStream { $0.yield(data); $0.finish() })
        let response = try await redactingProviderResponse(original, secrets: [secret, refresh])
        var redacted = Data()
        for try await chunk in response.body { redacted.append(chunk) }
        let value = try JSONDecoder().decode(JSONValue.self, from: redacted)
        let message = try #require(value["error"]?["message"]?.string)
        #expect(message.hasPrefix("rejected "))
        #expect(message.contains("*"))
        #expect(!message.contains(secret))
        #expect(!message.contains(refresh))
        #expect(response.headers["content-length"] == nil)
        #expect(response.headers["content-encoding"] == nil)
    }

    @Test func invalidDefinitionsAreRejectedBeforeStartingCore() throws {
        for name in ["", "Gateway", "1local", "a/b", String(repeating: "a", count: 65)] {
            #expect(throws: FxError.self) { try FxCustomProvider(name: name, baseURL: URL(string: "https://models.example")!) }
        }
        for url in ["http://models.example/v1", "https://user:secret@models.example/v1", "https://models.example/v1?q=x", "https://models.example/v1#x"] {
            #expect(throws: FxError.self) { try FxCustomProvider(name: "local", baseURL: URL(string: url)!) }
        }
        #expect(throws: FxError.self) {
            try FxCustomProvider(name: "local", baseURL: URL(string: "http://localhost:8000/v1")!, models: ["m": .init(contextWindow: 10, maxOutputTokens: 10)])
        }
    }
}
