import Foundation
import Testing
@testable import LibFx

private func accessToken(_ provider: FxSubscriptionProvider, label: String, account: String = "fixture-account", expiry: Date = Date().addingTimeInterval(36000)) throws -> String {
    let claims: JSONValue = .object([
        "sub": .string(account), "https://api.openai.com/auth": .object(["chatgpt_account_id": .string(account)]),
        "exp": .number(expiry.timeIntervalSince1970), "label": .string(label),
    ])
    let encoded = try JSONEncoder().encode(claims).base64EncodedString().replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    return "e30.\(encoded).fixture"
}

private actor AuthLog {
    var loads: [FxCredentialRequest] = []
    var saves: [(FxSubscriptionCredentials, FxCredentialRequest)] = []
    var value: FxSubscriptionCredentials
    init(_ value: FxSubscriptionCredentials) { self.value = value }
    func load(_ context: FxCredentialRequest) -> FxSubscriptionCredentials { loads.append(context); return value }
    func save(_ credentials: FxSubscriptionCredentials, _ context: FxCredentialRequest) {
        saves.append((credentials, context))
    }
    func persist(_ credentials: FxSubscriptionCredentials, _ context: FxCredentialRequest) {
        save(credentials, context); value = credentials
    }
}

private actor AuthServer: FxHTTPClient {
    enum Mode { case fresh, reject, wrongAccount, holdRefresh, lateRejection, failedRefresh, retainedRefresh, invalidRefresh }
    let provider: FxSubscriptionProvider
    let mode: Mode
    let next: String
    var requests: [URLRequest] = []
    var refreshes = 0
    var oldResponses = 0
    var cancelledRefreshes = 0
    let refreshGate = AsyncResult<Void>()
    private let bothSent = AsyncResult<Void>()
    private let late = AsyncResult<Void>()

    init(_ provider: FxSubscriptionProvider, mode: Mode = .fresh) throws {
        self.provider = provider; self.mode = mode
        self.next = try accessToken(provider, label: "new")
    }

    private func response(_ text: String, status: Int = 200) -> FxHTTPResponse {
        FxHTTPResponse(statusCode: status, body: AsyncThrowingStream { $0.yield(Data(text.utf8)); $0.finish() })
    }

    func send(_ request: URLRequest) async throws -> FxHTTPResponse {
        requests.append(request)
        let url = request.url!.absoluteString
        if url.contains("registry.npmjs.org") { return response("{\"version\":\"0.162.1\"}") }
        if url == "https://x.ai/cli/stable" { return response("1.0.50\n") }
        if url.contains("/codex/models") {
            return response(#"{"models":[{"slug":"gpt-6.1-sol","visibility":"list","supported_in_api":true,"priority":1,"supported_reasoning_levels":[{"effort":"low"}],"additional_speed_tiers":[],"input_modalities":["text","image"],"context_window":272000}]}"#)
        }
        if url.hasSuffix("/v1/models") {
            return response(#"{"data":[{"id":"grok-4.5","model":"grok-4.5","api_backend":"responses","context_window":500000,"supports_reasoning_effort":true,"reasoning_efforts":[{"value":"low"}]}]}"#)
        }
        if url.hasSuffix("/language-models") { return response(#"{"models":[{"id":"grok-4.5","input_modalities":["text","image"],"output_modalities":["text"]}]}"#) }
        if url.contains("/oauth/token") || url.contains("/oauth2/token") {
            refreshes += 1
            if mode == .holdRefresh {
                do { try await refreshGate.wait() }
                catch { cancelledRefreshes += 1; throw error }
            }
            if mode == .lateRejection { try await bothSent.wait() }
            if mode == .failedRefresh { return response("refresh rejected", status: 400) }
            var fields: [String: JSONValue] = ["access_token": .string(next), "expires_in": .number(36000)]
            if mode != .retainedRefresh { fields["refresh_token"] = mode == .invalidRefresh ? .number(7) : .string("refresh-new") }
            return response(String(decoding: try JSONEncoder().encode(JSONValue.object(fields)), as: UTF8.self))
        }
        if url.hasSuffix("/userinfo") { return response(mode == .wrongAccount ? #"{"sub":"other-account"}"# : #"{"sub":"fixture-account"}"#) }
        if url.hasSuffix("/responses") {
            let fresh = request.value(forHTTPHeaderField: "Authorization") == "Bearer \(next)"
            if mode == .lateRejection, !fresh {
                oldResponses += 1
                if oldResponses == 2 { await bothSent.resolve(.success(())); try await late.wait() }
                return response("token expired", status: 401)
            }
            if [.reject, .wrongAccount].contains(mode), !fresh { return response("token expired", status: 401) }
            if mode == .lateRejection, fresh { await late.resolve(.success(())) }
            return response("data: {\"type\":\"response.output_item.added\",\"output_index\":0,\"item\":{\"type\":\"message\"}}\n\ndata: {\"type\":\"response.output_text.delta\",\"output_index\":0,\"delta\":\"subscription reply\"}\n\ndata: {\"type\":\"response.completed\",\"response\":{\"status\":\"completed\",\"usage\":{\"input_tokens\":23,\"output_tokens\":7}}}\n\n")
        }
        return response("unexpected endpoint", status: 599)
    }
}

private actor SaveFailure {
    var attempts = 0
    func save() throws {
        attempts += 1
        if attempts == 1 { throw FxError.transport("Fixture save failure") }
    }
}

private actor SaveGate {
    let started = AsyncResult<Void>()
    let release = AsyncResult<Void>()
    var cancelled = false
    func save() async throws {
        await started.resolve(.success(()))
        do { try await release.wait() }
        catch { cancelled = true; throw error }
    }
}

private actor HostRefreshLock {
    private var tail: Task<FxSubscriptionCredentials, any Error>?
    func run(_ operation: @escaping FxSubscription.RefreshOperation) async throws -> FxSubscriptionCredentials {
        let previous = tail
        let task = Task { _ = try? await previous?.value; return try await operation() }
        tail = task
        return try await task.value
    }
}

@Suite struct SubscriptionTests {
    private func request(_ provider: FxSubscriptionProvider, session: String) -> URLRequest {
        var request = URLRequest(url: URL(string: provider == .codex ? "https://chatgpt.com/backend-api/codex/responses" : "https://cli-chat-proxy.grok.com/v1/responses")!)
        request.httpMethod = "POST"; request.httpBody = Data("original body".utf8)
        request.setValue(session, forHTTPHeaderField: provider == .codex ? "session-id" : "x-grok-conv-id")
        return request
    }

    @Test func realCoreUsesBothSubscriptionProtocols() async throws {
        for provider in FxSubscriptionProvider.allCases {
            let token = try accessToken(provider, label: "fresh")
            let log = AuthLog(try FxSubscriptionCredentials(accessToken: token))
            let server = try AuthServer(provider)
            let auth = FxSubscription(provider: provider, credentials: { await log.load($0) })
            let engine = try await FxEngine.open(configuration: FxConfiguration(
                provider: .subscription(auth), model: FxModel(id: provider == .codex ? "gpt-6.1-sol" : "grok-4.5"), httpClient: server))
            let turn = try await engine.prompt("say hello")
            var text = ""
            for try await event in turn { if case .text(let delta) = event { text += delta } }
            #expect(try await turn.result.stopReason == .endTurn)
            #expect(text == "subscription reply")
            let requests = await server.requests
            #expect(!requests.contains { $0.url!.host == "ai-gateway.vercel.sh" })
            let post = try #require(requests.first { $0.url!.path.hasSuffix("/responses") })
            #expect(post.value(forHTTPHeaderField: "Authorization") == "Bearer \(token)")
            #expect(post.value(forHTTPHeaderField: provider == .codex ? "chatgpt-account-id" : "x-grok-user-id") == "fixture-account")
            #expect(await log.loads.contains { $0.sessionID == engine.sessionID && $0.provider == provider.rawValue })
            #expect(await server.refreshes == 0)
            let checkpoint = try await engine.checkpoint()
            #expect(!String(decoding: checkpoint, as: UTF8.self).contains(token))
            try await engine.close()
        }
    }

    @Test func rejectedTokenRefreshesOnceAndPreservesRequest() async throws {
        for provider in FxSubscriptionProvider.allCases {
            let log = AuthLog(try FxSubscriptionCredentials(accessToken: accessToken(provider, label: "old"), refreshToken: "refresh-old"))
            let server = try AuthServer(provider, mode: .reject)
            let auth = FxSubscription(provider: provider, credentials: { await log.load($0) }, onRefresh: { await log.save($0, $1) })
            let response = try await auth.send(request(provider, session: "session-one"), sessionID: nil, client: server)
            response.cancel()
            #expect(response.statusCode == 200)
            #expect(await server.refreshes == 1)
            let posts = await server.requests.filter { $0.url!.path.hasSuffix("/responses") }
            #expect(posts.count == 2)
            #expect(posts.first?.httpBody == posts.last?.httpBody)
            #expect(posts.last?.value(forHTTPHeaderField: "Authorization") == "Bearer \(server.next)")
            #expect(await log.saves.count == 1)
            #expect(await log.saves.first?.0.refreshToken == "refresh-new")
            #expect(await log.saves.first?.1.sessionID == "session-one")
        }
    }

    @Test func nearExpiryRefreshIsSharedAndNotifiesEachSession() async throws {
        let provider = FxSubscriptionProvider.grok
        let log = AuthLog(try FxSubscriptionCredentials(accessToken: accessToken(provider, label: "expiring", expiry: Date().addingTimeInterval(60)), refreshToken: "refresh-old"))
        let server = try AuthServer(provider, mode: .holdRefresh)
        let auth = FxSubscription(provider: provider, credentials: { await log.load($0) }, onRefresh: { await log.save($0, $1) })
        let one = Task { try await auth.send(request(provider, session: "one"), sessionID: nil, client: server) }
        let two = Task { try await auth.send(request(provider, session: "two"), sessionID: nil, client: server) }
        let deadline = ContinuousClock.now + .seconds(2)
        while ContinuousClock.now < deadline {
            let loaded = await log.loads.count >= 2
            let refreshing = await server.refreshes >= 1
            if loaded && refreshing { break }
            await Task.yield()
        }
        #expect(await server.refreshes == 1)
        await server.refreshGate.resolve(.success(()))
        try await one.value.cancel(); try await two.value.cancel()
        #expect(await server.refreshes == 1)
        #expect(await Set(log.saves.map { $0.1.sessionID }) == ["one", "two"])
        #expect(await server.requests.filter { $0.url!.path.hasSuffix("/responses") }.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Bearer \(server.next)" })
    }

    @Test func cancellingOneRefreshWaiterPreservesOthersAndLastWaiterStopsHTTP() async throws {
        for cancelAll in [false, true] {
            let provider = FxSubscriptionProvider.grok
            let log = AuthLog(try FxSubscriptionCredentials(accessToken: accessToken(provider, label: "expiring", expiry: Date().addingTimeInterval(60)), refreshToken: "refresh-old"))
            let server = try AuthServer(provider, mode: .holdRefresh)
            let auth = FxSubscription(provider: provider, credentials: { await log.load($0) })
            let one = Task { try await auth.send(request(provider, session: "one"), sessionID: nil, client: server) }
            let two = Task { try await auth.send(request(provider, session: "two"), sessionID: nil, client: server) }
            let deadline = ContinuousClock.now + .seconds(2)
            while await auth.refreshWaiterCount < 2, ContinuousClock.now < deadline { await Task.yield() }
            #expect(await auth.refreshWaiterCount == 2)
            one.cancel()
            await #expect(throws: CancellationError.self) { try await one.value }
            if cancelAll {
                two.cancel()
                await #expect(throws: CancellationError.self) { try await two.value }
                let cancelled = ContinuousClock.now + .seconds(2)
                while await server.cancelledRefreshes == 0, ContinuousClock.now < cancelled { await Task.yield() }
                #expect(await server.cancelledRefreshes == 1)
                #expect(await server.requests.filter { $0.url!.path.hasSuffix("/responses") }.isEmpty)
            } else {
                #expect(await server.cancelledRefreshes == 0)
                await server.refreshGate.resolve(.success(()))
                let response = try await two.value
                #expect(response.statusCode == 200)
                response.cancel()
            }
            #expect(await server.refreshes == 1)
        }
    }

    @Test func cancellingLastWaiterStopsCredentialSaveCallback() async throws {
        let value = try FxSubscriptionCredentials(accessToken: "old", refreshToken: "refresh-old", accountID: "fixture-account", expiresAt: Date())
        let server = try AuthServer(.grok), gate = SaveGate()
        let auth = FxSubscription(provider: .grok, credentials: { _ in value }, onRefresh: { _, _ in try await gate.save() })
        let task = Task { try await auth.send(request(.grok, session: "one"), sessionID: nil, client: server) }
        try await gate.started.wait()
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        let deadline = ContinuousClock.now + .seconds(2)
        while await !gate.cancelled, ContinuousClock.now < deadline { await Task.yield() }
        #expect(await gate.cancelled)
        #expect(await server.requests.filter { $0.url!.path.hasSuffix("/responses") }.isEmpty)
    }

    @Test func rejectionWithoutRefreshTokenIsNotRetried() async throws {
        let value = try FxSubscriptionCredentials(accessToken: "old", accountID: "fixture-account")
        let server = try AuthServer(.grok, mode: .reject)
        let auth = FxSubscription(provider: .grok, credentials: { _ in value })
        let response = try await auth.send(request(.grok, session: "one"), sessionID: nil, client: server)
        #expect(response.statusCode == 401)
        response.cancel()
        #expect(await server.refreshes == 0)
        #expect(await server.requests.count == 1)
    }

    @Test func credentialsStayOffUnrelatedOrEncodedEndpoints() async throws {
        for provider in FxSubscriptionProvider.allCases {
            let log = AuthLog(try FxSubscriptionCredentials(accessToken: "secret", accountID: "fixture-account"))
            let server = try AuthServer(provider)
            let auth = FxSubscription(provider: provider, credentials: { await log.load($0) })
            for url in ["https://elsewhere.example/v1/responses", "https://cli-chat-proxy.grok.com:444/v1/responses", "https://chatgpt.com/backend-api/codex%2Fresponses", "https://api.x.ai/v1/models"] {
                let response = try await auth.send(URLRequest(url: URL(string: url)!), sessionID: nil, client: server)
                response.cancel()
            }
            #expect(await log.loads.isEmpty)
            #expect(await server.requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == nil })
        }
    }

    @Test func refreshTokenOmissionRetainsOldTokenAndMalformedRotationFails() async throws {
        for provider in FxSubscriptionProvider.allCases {
            for mode in [AuthServer.Mode.retainedRefresh, .invalidRefresh] {
                let log = AuthLog(try FxSubscriptionCredentials(accessToken: accessToken(provider, label: "expiring"),
                    refreshToken: "refresh-old", expiresAt: Date()))
                let server = try AuthServer(provider, mode: mode)
                let auth = FxSubscription(provider: provider, credentials: { await log.load($0) }, onRefresh: { await log.save($0, $1) })
                if mode == .retainedRefresh {
                    let response = try await auth.send(request(provider, session: "one"), sessionID: nil, client: server)
                    response.cancel()
                    #expect(await log.saves.first?.0.refreshToken == "refresh-old")
                } else {
                    await #expect(throws: FxSubscriptionError.refreshFailed(statusCode: nil)) {
                        try await auth.send(request(provider, session: "one"), sessionID: nil, client: server)
                    }
                    #expect(await log.saves.isEmpty)
                    #expect(await server.requests.filter { $0.url!.path.hasSuffix("/responses") }.isEmpty)
                }
            }
        }
    }

    @Test func failedSaveRetriesNotificationWithoutSpendingRefreshTokenAgain() async throws {
        let value = try FxSubscriptionCredentials(accessToken: "old", refreshToken: "refresh-old", accountID: "fixture-account", expiresAt: Date())
        let server = try AuthServer(.grok), save = SaveFailure()
        let auth = FxSubscription(provider: .grok, credentials: { _ in value }, onRefresh: { _, _ in try await save.save() })
        await #expect(throws: FxSubscriptionError.credentialSaveFailed) {
            try await auth.send(request(.grok, session: "one"), sessionID: nil, client: server)
        }
        let response = try await auth.send(request(.grok, session: "one"), sessionID: nil, client: server)
        response.cancel()
        #expect(await server.refreshes == 1)
        #expect(await save.attempts == 2)
        #expect(await server.requests.filter { $0.url!.path.hasSuffix("/responses") }.count == 1)
    }

    @Test func opaqueGrokRefreshTokenIsFormEncoded() async throws {
        let token = "refresh +&雪"
        let credentials = try FxSubscriptionCredentials(accessToken: "old", refreshToken: token, accountID: "fixture-account", expiresAt: Date())
        let server = try AuthServer(.grok)
        let auth = FxSubscription(provider: .grok, credentials: { _ in credentials })
        let response = try await auth.send(request(.grok, session: "one"), sessionID: nil, client: server)
        response.cancel()
        let refresh = try #require(await server.requests.first { $0.url!.path == "/oauth2/token" })
        let body = String(decoding: try #require(refresh.httpBody), as: UTF8.self)
        var components = URLComponents()
        components.percentEncodedQuery = body
        #expect(components.queryItems?.first { $0.name == "refresh_token" }?.value == token)
    }

    @Test func rejectedRefreshFailsWithoutSendingModelRequest() async throws {
        let log = AuthLog(try FxSubscriptionCredentials(accessToken: "old", refreshToken: "refresh-old", accountID: "fixture-account", expiresAt: Date()))
        let server = try AuthServer(.grok, mode: .failedRefresh)
        let auth = FxSubscription(provider: .grok, credentials: { await log.load($0) })
        await #expect(throws: FxSubscriptionError.refreshFailed(statusCode: 400)) {
            try await auth.send(request(.grok, session: "one"), sessionID: nil, client: server)
        }
        #expect(await server.refreshes == 1)
        #expect(await server.requests.filter { $0.url!.path.hasSuffix("/responses") }.isEmpty)
    }

    @Test func lateRejectionUsesExistingRotation() async throws {
        let provider = FxSubscriptionProvider.grok
        let log = AuthLog(try FxSubscriptionCredentials(accessToken: accessToken(provider, label: "old"), refreshToken: "refresh-old"))
        let server = try AuthServer(provider, mode: .lateRejection)
        let auth = FxSubscription(provider: provider, credentials: { await log.load($0) })
        async let one = auth.send(request(provider, session: "one"), sessionID: nil, client: server)
        async let two = auth.send(request(provider, session: "two"), sessionID: nil, client: server)
        let responses = try await [one, two]
        responses.forEach { $0.cancel() }
        #expect(await server.oldResponses == 2)
        #expect(await server.refreshes == 1)
    }

    @Test func anotherGrokAccountIsNeverSentOrSaved() async throws {
        let log = AuthLog(try FxSubscriptionCredentials(accessToken: "old", refreshToken: "refresh-old", accountID: "fixture-account"))
        let server = try AuthServer(.grok, mode: .wrongAccount)
        let auth = FxSubscription(provider: .grok, credentials: { await log.load($0) }, onRefresh: { await log.save($0, $1) })
        await #expect(throws: FxSubscriptionError.accountChanged) { try await auth.send(request(.grok, session: "one"), sessionID: nil, client: server) }
        #expect(await log.saves.isEmpty)
        #expect(await server.requests.filter { $0.url!.path.hasSuffix("/responses") }.count == 1)
    }

    @Test func rememberedRotationCannotCrossAccountBoundaries() async throws {
        let first = try FxSubscriptionCredentials(accessToken: "shared-access", refreshToken: "shared-refresh", accountID: "fixture-account", expiresAt: Date())
        let second = try FxSubscriptionCredentials(accessToken: "shared-access", refreshToken: "shared-refresh", accountID: "other-account", expiresAt: Date())
        let server = try AuthServer(.grok)
        let auth = FxSubscription(provider: .grok, credentials: { $0.sessionID == "one" ? first : second })
        let response = try await auth.send(request(.grok, session: "one"), sessionID: nil, client: server)
        response.cancel()
        await #expect(throws: FxSubscriptionError.accountChanged) {
            try await auth.send(request(.grok, session: "two"), sessionID: nil, client: server)
        }
        #expect(await server.refreshes == 2)
        #expect(await server.requests.filter { $0.url!.path.hasSuffix("/responses") }.count == 1)
    }

    @Test func independentCoordinatorsRespectHostRefreshLock() async throws {
        let provider = FxSubscriptionProvider.grok
        let log = AuthLog(try FxSubscriptionCredentials(accessToken: accessToken(provider, label: "expiring", expiry: Date().addingTimeInterval(60)), refreshToken: "refresh-old"))
        let server = try AuthServer(provider, mode: .holdRefresh), lock = HostRefreshLock()
        let make = { FxSubscription(provider: provider, credentials: { await log.load($0) },
            onRefresh: { await log.persist($0, $1) }, refreshLock: { _, operation in try await lock.run(operation) }) }
        let first = make(), second = make()
        let one = Task { try await first.send(request(provider, session: "one"), sessionID: nil, client: server) }
        let two = Task { try await second.send(request(provider, session: "two"), sessionID: nil, client: server) }
        let deadline = ContinuousClock.now + .seconds(2)
        while await log.loads.count < 3, ContinuousClock.now < deadline { await Task.yield() }
        await server.refreshGate.resolve(.success(()))
        try await one.value.cancel(); try await two.value.cancel()
        #expect(await server.refreshes == 1)
        #expect(await log.saves.count == 1)
    }
}
