import CryptoKit
import Foundation
import Testing
@testable import LibFx

private actor SignInServer: FxHTTPClient {
    var requests: [URLRequest] = []
    var replies: [(Int, String)]
    init(_ replies: [(Int, String)]) { self.replies = replies }
    func send(_ request: URLRequest) throws -> FxHTTPResponse {
        requests.append(request)
        let (status, text) = replies.isEmpty ? (599, "unexpected") : replies.removeFirst()
        return FxHTTPResponse(statusCode: status, body: AsyncThrowingStream { stream in
            stream.yield(Data(text.utf8)); stream.finish()
        })
    }
}

private func signInToken() -> String {
    let payload = Data(#"{"https://api.openai.com/auth":{"chatgpt_account_id":"signin-account"}}"#.utf8).base64EncodedString()
        .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    return "e30.\(payload).signature"
}

private func signInTokens(_ provider: FxSubscriptionProvider) -> String {
    "{\"access_token\":\"\(provider == .codex ? signInToken() : "opaque-token")\",\"refresh_token\":\"refresh-secret\",\"expires_in\":3600}"
}

private func signInDevice(_ provider: FxSubscriptionProvider, interval: TimeInterval = 0.01, expiry: Date = Date().addingTimeInterval(60)) -> FxSignIn.DeviceAuthorization {
    .init(provider: provider, verificationURL: URL(string: "https://example.com/device")!, userCode: "CODE",
          pollInterval: interval, expiresAt: expiry, deviceCode: "device-secret")
}

@Test(arguments: FxSubscriptionProvider.allCases)
func signInUsesIndependentPKCESecrets(_ provider: FxSubscriptionProvider) throws {
    let signIn = FxSignIn(provider: provider)
    let authorization = try signIn.startAuthorization(), other = try signIn.startAuthorization()
    let fields = Dictionary(URLComponents(url: authorization.url, resolvingAgainstBaseURL: false)!.queryItems!.map {
        ($0.name, $0.value!)
    }, uniquingKeysWith: { a, _ in a })
    let challenge = Data(SHA256.hash(data: Data(authorization.verifier.utf8))).base64EncodedString()
        .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    #expect(fields["code_challenge"] == challenge)
    #expect(fields["code_challenge_method"] == "S256")
    #expect(fields["state"] == authorization.state)
    #expect(authorization.verifier.utf8.count == 43)
    #expect(authorization.verifier != other.verifier && authorization.state != other.state)
    #expect(!authorization.url.absoluteString.contains(authorization.verifier))
    #expect(!String(reflecting: authorization).contains(authorization.verifier))
    let restored = try JSONDecoder().decode(FxSignIn.Authorization.self, from: JSONEncoder().encode(authorization))
    #expect(restored.state == authorization.state && restored.verifier == authorization.verifier)
}

@Test(arguments: FxSubscriptionProvider.allCases)
func signInCallbackExchangesCodeAndRestoresState(_ provider: FxSubscriptionProvider) async throws {
    let replies = [(200, signInTokens(provider))] + (provider == .grok ? [(200, #"{"sub":"signin-account"}"#)] : [])
    let server = SignInServer(replies)
    let signIn = FxSignIn(provider: provider, httpClient: server)
    let state = try signIn.startAuthorization()
    let credentials = try await signIn.completeAuthorization(state, callback: " `<\(state.redirectURL)?code=a%2Bb+c&state=\(state.state)>` ")
    #expect(credentials.accountID == "signin-account")
    #expect(credentials.refreshToken == "refresh-secret")
    #expect(credentials.expiresAt! > Date().addingTimeInterval(3500))
    let requests = await server.requests
    let request = try #require(requests.first)
    #expect(request.httpMethod == "POST")
    #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/x-www-form-urlencoded")
    let body = try #require(String(data: request.httpBody!, encoding: .utf8))
    #expect(body.contains("code=a%2Bb%20c"))
    #expect(body.contains("code_verifier=\(state.verifier)"))
    if provider == .grok { #expect(requests.last?.value(forHTTPHeaderField: "Authorization") == "Bearer opaque-token") }
}

@Test(arguments: FxSubscriptionProvider.allCases)
func signInRejectsCallbacksBeforeHTTP(_ provider: FxSubscriptionProvider) async throws {
    let server = SignInServer([]), signIn = FxSignIn(provider: provider, httpClient: SignInServer([]))
    let client = FxSignIn(provider: provider, httpClient: server)
    let state = try signIn.startAuthorization()
    await #expect(throws: FxSignInError.stateMismatch) { try await client.completeAuthorization(state, callback: "code=x&state=other") }
    await #expect(throws: FxSignInError.invalidAddress) { try await client.completeAuthorization(state, callback: String(repeating: "é", count: 8193)) }
    await #expect(throws: FxSignInError.invalidAddress) { try await client.completeAuthorization(state, callback: "chrome-error://chromewebdata/") }
    await #expect(throws: FxSignInError.invalidAddress) { try await client.completeAuthorization(state, callback: "%") }
    await #expect(throws: FxSignInError.denied(reason: "access_denied")) { try await client.completeAuthorization(state, callback: "error=access_denied") }
    let other = FxSignIn(provider: provider == .codex ? .grok : .codex)
    await #expect(throws: FxSignInError.invalidAuthorization) { try await other.completeAuthorization(state, callback: "code=x&state=\(state.state)") }
    #expect(await server.requests.isEmpty)
}

@Test(arguments: FxSubscriptionProvider.allCases)
func signInRejectsForgedRedirects(_ provider: FxSubscriptionProvider) async throws {
    let server = SignInServer([]), client = FxSignIn(provider: provider, httpClient: SignInServer([]))
    let original = try client.startAuthorization()
    let forged = FxSignIn.Authorization(provider: provider, url: original.url, state: original.state,
                                        verifier: original.verifier, redirectURL: URL(string: "https://example.com/callback")!)
    await #expect(throws: FxSignInError.invalidAuthorization) {
        try await FxSignIn(provider: provider, httpClient: server).completeAuthorization(forged, callback: "code=x&state=\(original.state)")
    }
    #expect(await server.requests.isEmpty)
}

@Test(arguments: FxSubscriptionProvider.allCases)
func signInReportsExchangeAndAccountFailures(_ provider: FxSubscriptionProvider) async throws {
    for status in [400, 401, 503] {
        let server = SignInServer([(status, "not JSON")]), client = FxSignIn(provider: provider, httpClient: SignInServer([]))
        let state = try client.startAuthorization()
        let expected = status == 503 ? FxSignInError.failed(statusCode: status) : .expired(statusCode: status)
        await #expect(throws: expected) {
            try await FxSignIn(provider: provider, httpClient: server).completeAuthorization(state, callback: "code=x&state=\(state.state)")
        }
    }
    let server = SignInServer([(200, #"{"access_token":"bad\ntoken"}"#)])
    let client = FxSignIn(provider: provider, httpClient: server), state = try client.startAuthorization()
    await #expect(throws: FxSignInError.failed(statusCode: nil)) { try await client.completeAuthorization(state, callback: "code=x&state=\(state.state)") }
    #expect(await server.requests.count == 1)
}

@Test(arguments: FxSubscriptionProvider.allCases)
func deviceAuthorizationCanBeSavedAndPolled(_ provider: FxSubscriptionProvider) async throws {
    let start = provider == .codex ? #"{"device_auth_id":"device-secret","user_code":"CODE","interval":"1"}"#
        : #"{"device_code":"device-secret","user_code":"CODE","verification_uri":"https://example.com/device","expires_in":1800,"interval":0}"#
    let pending = provider == .codex ? (403, "pending") : (400, #"{"error":"authorization_pending"}"#)
    let done = provider == .codex ? #"{"authorization_code":"device-code","code_verifier":"device-verifier"}"# : signInTokens(provider)
    let tail = provider == .codex ? [(200, signInTokens(provider))] : [(200, #"{"sub":"signin-account"}"#)]
    let server = SignInServer([(200, start), pending, (200, done)] + tail), client = FxSignIn(provider: provider, httpClient: SignInServer([]))
    let signIn = FxSignIn(provider: provider, httpClient: server)
    let device = try await signIn.startDeviceAuthorization()
    #expect(device.pollInterval == 1)
    #expect(!String(reflecting: device).contains("device-secret"))
    let restored = try JSONDecoder().decode(FxSignIn.DeviceAuthorization.self, from: JSONEncoder().encode(device))
    #expect(try await signIn.pollDeviceAuthorization(restored) == nil)
    #expect(try await signIn.pollDeviceAuthorization(restored)?.accountID == "signin-account")
    await #expect(throws: FxSignInError.deviceExpired) {
        try await client.pollDeviceAuthorization(signInDevice(provider, expiry: Date().addingTimeInterval(-1)))
    }
}

@Test(arguments: FxSubscriptionProvider.allCases)
func deviceAuthorizationRejectsMalformedAndOversizedResponses(_ provider: FxSubscriptionProvider) async throws {
    for body in ["not JSON", "{}", String(repeating: "x", count: 65537)] {
        let client = FxSignIn(provider: provider, httpClient: SignInServer([(200, body)]))
        do { _ = try await client.startDeviceAuthorization(); Issue.record("Malformed device response was accepted") }
        catch { #expect(error is FxSignInError) }
    }
    await #expect(throws: FxSignInError.deviceUnavailable(statusCode: 403)) {
        try await FxSignIn(provider: provider, httpClient: SignInServer([(403, "no")])).startDeviceAuthorization()
    }
}

private actor PendingSignInServer: FxHTTPClient {
    let started = AsyncResult<Void>()
    var requests = 0
    func send(_ request: URLRequest) async -> FxHTTPResponse {
        requests += 1
        await started.resolve(.success(()))
        return FxHTTPResponse(statusCode: 400, body: AsyncThrowingStream { stream in
            stream.yield(Data(#"{"error":"slow_down"}"#.utf8)); stream.finish()
        })
    }
}

private actor BlockingSignInServer: FxHTTPClient {
    let headers: Bool
    let started = AsyncResult<Void>(), cancelled = AsyncResult<Void>()
    private let response = AsyncResult<FxHTTPResponse>()
    init(headers: Bool) { self.headers = headers }
    func send(_ request: URLRequest) async throws -> FxHTTPResponse {
        await started.resolve(.success(()))
        if headers {
            return try await withTaskCancellationHandler {
                try await response.wait()
            } onCancel: { Task { await self.cancelled.resolve(.success(())) } }
        }
        return FxHTTPResponse(statusCode: 200, body: AsyncThrowingStream { _ in }, cancel: {
            Task { await self.cancelled.resolve(.success(())) }
        })
    }
}

@Test(arguments: [false, true])
func signInTaskCancellationStopsHTTP(headers: Bool) async throws {
    let server = BlockingSignInServer(headers: headers)
    let task = Task { try await FxSignIn(provider: .grok, httpClient: server).startDeviceAuthorization() }
    try await server.started.wait()
    task.cancel()
    await #expect(throws: CancellationError.self) { try await task.value }
    try await server.cancelled.wait()
}

@Test func deviceSlowDownIncreasesTheNextPollingInterval() async throws {
    let server = SignInServer([(400, #"{"error":"slow_down"}"#), (200, signInTokens(.grok)), (200, #"{"sub":"signin-account"}"#)])
    let clock = ContinuousClock(), started = ContinuousClock.now
    let credentials = try await FxSignIn(provider: .grok, httpClient: server).completeDeviceAuthorization(signInDevice(.grok))
    #expect(clock.now - started >= .seconds(5))
    #expect(credentials.accountID == "signin-account")
    #expect(await server.requests.count == 3)
}

@Test func deviceSlowDownWaitIsCancellable() async throws {
    let server = PendingSignInServer(), client = FxSignIn(provider: .grok, httpClient: PendingSignInServer())
    let signIn = FxSignIn(provider: .grok, httpClient: server)
    let task = Task { try await signIn.completeDeviceAuthorization(signInDevice(.grok)) }
    try await server.started.wait()
    task.cancel()
    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(await server.requests == 1)
    let cancelled = Task { () throws -> FxSignIn.Authorization in
        withUnsafeCurrentTask { $0?.cancel() }
        return try client.startAuthorization()
    }
    await #expect(throws: CancellationError.self) { try await cancelled.value }
}

@Test(arguments: FxSubscriptionProvider.allCases)
func deviceCompletionPollsUntilAuthorized(_ provider: FxSubscriptionProvider) async throws {
    let pending = provider == .codex ? (404, "pending") : (400, #"{"error":"authorization_pending"}"#)
    let done = provider == .codex ? #"{"authorization_code":"device-code","code_verifier":"device-verifier"}"# : signInTokens(provider)
    let tail = provider == .codex ? [(200, signInTokens(provider))] : [(200, #"{"sub":"signin-account"}"#)]
    let server = SignInServer([pending, (200, done)] + tail)
    let credentials = try await FxSignIn(provider: provider, httpClient: server).completeDeviceAuthorization(signInDevice(provider))
    #expect(credentials.accountID == "signin-account")
    #expect(await server.requests.count == 3)
}
