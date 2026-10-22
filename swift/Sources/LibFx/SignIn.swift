import CryptoKit
import Foundation

public enum FxSignInError: Error, Sendable, Equatable {
    case invalidAuthorization
    case invalidAddress
    case stateMismatch
    case denied(reason: String)
    case expired(statusCode: Int)
    case deviceUnavailable(statusCode: Int?)
    case deviceExpired
    case accountUnavailable(statusCode: Int?)
    case failed(statusCode: Int?)
}

/// Subscription authorization without browser or credential-store ownership.
public struct FxSignIn: Sendable {
    /// Keep this value private. Its encoded form contains the PKCE verifier.
    public struct Authorization: Sendable, Codable, CustomDebugStringConvertible {
        public let provider: FxSubscriptionProvider
        public let url: URL
        package let state: String
        package let verifier: String
        package let redirectURL: URL
        public var debugDescription: String { "FxSignIn.Authorization(\(provider.rawValue))" }

        package init(provider: FxSubscriptionProvider, url: URL, state: String, verifier: String, redirectURL: URL) {
            self.provider = provider; self.url = url; self.state = state; self.verifier = verifier; self.redirectURL = redirectURL
        }
    }

    /// May be encoded and restored between requests. Contains a private device code.
    public struct DeviceAuthorization: Sendable, Codable, CustomDebugStringConvertible {
        public let provider: FxSubscriptionProvider
        public let verificationURL: URL
        public let userCode: String
        public let pollInterval: TimeInterval
        public let expiresAt: Date
        package let deviceCode: String
        public var debugDescription: String { "FxSignIn.DeviceAuthorization(\(provider.rawValue))" }

        package init(provider: FxSubscriptionProvider, verificationURL: URL, userCode: String,
                     pollInterval: TimeInterval, expiresAt: Date, deviceCode: String) {
            self.provider = provider; self.verificationURL = verificationURL; self.userCode = userCode
            self.pollInterval = pollInterval; self.expiresAt = expiresAt; self.deviceCode = deviceCode
        }
    }

    public let provider: FxSubscriptionProvider
    private let client: any FxHTTPClient

    public init(provider: FxSubscriptionProvider, httpClient: any FxHTTPClient = FxURLSessionHTTPClient()) {
        self.provider = provider
        self.client = httpClient
    }

    private var issuer: String { provider == .codex ? "https://auth.openai.com" : "https://auth.x.ai" }
    private var clientID: String { provider == .codex ? "app_EMoamEEZ73f0CkXaXp7hrann" : "b1a00492-073a-47ea-816f-4c329264a828" }
    private var scope: String {
        provider == .codex ? "openid profile email offline_access api.connectors.read api.connectors.invoke"
            : "openid profile email offline_access grok-cli:access api:access"
    }
    private var tokenPath: String { provider == .codex ? "/oauth/token" : "/oauth2/token" }

    public func startAuthorization() throws -> Authorization {
        try Task.checkCancellation()
        let verifier = Self.secret(), state = Self.secret()
        let redirect = provider == .codex ? "http://localhost:1455/auth/callback"
            : "http://127.0.0.1:\(Int.random(in: 1024...65535))/callback"
        let challenge = Self.base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
        var fields = ["response_type": "code", "client_id": clientID, "redirect_uri": redirect,
                      "scope": scope, "code_challenge": challenge, "code_challenge_method": "S256", "state": state]
        if provider == .codex {
            fields["id_token_add_organizations"] = "true"
            fields["codex_cli_simplified_flow"] = "true"
            fields["originator"] = "fx"
        } else { fields["referrer"] = "fx" }
        var url = URLComponents(string: issuer + (provider == .codex ? "/oauth/authorize" : "/oauth2/authorize"))!
        url.queryItems = fields.sorted(by: { $0.key < $1.key }).map { URLQueryItem(name: $0.key, value: $0.value) }
        return Authorization(provider: provider, url: url.url!, state: state, verifier: verifier, redirectURL: URL(string: redirect)!)
    }

    public func completeAuthorization(_ authorization: Authorization, callback address: String) async throws -> FxSubscriptionCredentials {
        try Task.checkCancellation()
        guard authorization.provider == provider, !authorization.state.isEmpty, !authorization.verifier.isEmpty,
              authorization.state.utf8.count <= 1024, authorization.verifier.utf8.count <= 1024 else {
            throw FxSignInError.invalidAuthorization
        }
        guard address.utf8.count <= 16 * 1024 else { throw FxSignInError.invalidAddress }
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "`'\"<>")))
        let query: String
        if let url = URLComponents(string: trimmed), url.scheme != nil { query = url.percentEncodedQuery ?? "" }
        else { query = trimmed.firstIndex(of: "?").map { String(trimmed[trimmed.index(after: $0)...]) } ?? trimmed }
        let parts = URLComponents(string: "https://localhost/?" + query.replacingOccurrences(of: "+", with: "%20"))
        let fields = Dictionary((parts?.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { first, _ in first })
        if let reason = fields["error"], !reason.isEmpty { throw FxSignInError.denied(reason: reason) }
        guard let code = fields["code"], !code.isEmpty else { throw FxSignInError.invalidAddress }
        guard fields["state"] == authorization.state else { throw FxSignInError.stateMismatch }
        // A decoded authorization may carry an arbitrary redirect. Use only the registered loopback shapes.
        let redirect = authorization.redirectURL
        let validRedirect = provider == .codex ? redirect.absoluteString == "http://localhost:1455/auth/callback"
            : redirect.scheme == "http" && redirect.host == "127.0.0.1" && redirect.path == "/callback"
                && (1024...65535).contains(redirect.port ?? 0) && redirect.query == nil && redirect.fragment == nil
                && redirect.user == nil && redirect.password == nil
        guard validRedirect else { throw FxSignInError.invalidAuthorization }
        return try await exchangeCode(code, verifier: authorization.verifier, redirect: redirect.absoluteString)
    }

    public func startDeviceAuthorization() async throws -> DeviceAuthorization {
        let fields = provider == .codex ? ["client_id": clientID] : ["client_id": clientID, "scope": scope]
        let (status, body) = try await request(provider == .codex ? "/api/accounts/deviceauth/usercode" : "/oauth2/device/code",
                                             fields: fields, json: provider == .codex)
        guard (200..<300).contains(status) else { throw FxSignInError.deviceUnavailable(statusCode: status) }
        guard let code = body?[provider == .codex ? "device_auth_id" : "device_code"]?.string, !code.isEmpty,
              let user = body?["user_code"]?.string, !user.isEmpty else { throw FxSignInError.deviceUnavailable(statusCode: nil) }
        let address = provider == .codex ? issuer + "/codex/device"
            : body?["verification_uri_complete"]?.string ?? body?["verification_uri"]?.string
        let seconds: Double? = provider == .codex ? 900 : Self.number(body?["expires_in"])
        guard let address, let url = URL(string: address), url.scheme == "https", url.host != nil,
              url.user == nil, url.password == nil, let seconds, seconds.isFinite,
              Date().addingTimeInterval(seconds).timeIntervalSince1970.isFinite else {
            throw FxSignInError.deviceUnavailable(statusCode: nil)
        }
        let interval = max(Self.number(body?["interval"]) ?? 5, 1)
        guard interval <= Double(Int64.max) / 1_000_000_000 else { throw FxSignInError.deviceUnavailable(statusCode: nil) }
        return DeviceAuthorization(provider: provider, verificationURL: url, userCode: user,
                                   pollInterval: interval, expiresAt: Date().addingTimeInterval(seconds), deviceCode: code)
    }

    /// Checks once. A pending authorization returns nil.
    public func pollDeviceAuthorization(_ device: DeviceAuthorization) async throws -> FxSubscriptionCredentials? {
        try await poll(device).credentials
    }

    /// Waits between polls. Cancelling the task stops both polling and HTTP work.
    public func completeDeviceAuthorization(_ device: DeviceAuthorization) async throws -> FxSubscriptionCredentials {
        var interval = device.pollInterval
        while true {
            let result = try await poll(device)
            if let credentials = result.credentials { return credentials }
            if result.slowDown { interval += 5 }
            let remaining = device.expiresAt.timeIntervalSinceNow
            guard remaining > 0 else { throw FxSignInError.deviceExpired }
            try await Task.sleep(for: .seconds(min(interval, remaining)))
        }
    }

    public func refreshCredentials(_ credentials: FxSubscriptionCredentials) async throws -> FxSubscriptionCredentials {
        try Task.checkCancellation()
        return try await FxSubscription.exchange(credentials.normalized(for: provider), provider: provider, client: client)
    }

    private func poll(_ device: DeviceAuthorization) async throws -> (credentials: FxSubscriptionCredentials?, slowDown: Bool) {
        try Task.checkCancellation()
        guard device.provider == provider, !device.deviceCode.isEmpty, !device.userCode.isEmpty,
              device.deviceCode.utf8.count <= 16 * 1024, device.userCode.utf8.count <= 16 * 1024,
              device.pollInterval.isFinite, device.pollInterval >= 0,
              device.pollInterval <= Double(Int64.max) / 1_000_000_000,
              device.expiresAt.timeIntervalSince1970.isFinite else { throw FxSignInError.invalidAuthorization }
        guard device.expiresAt >= Date() else { throw FxSignInError.deviceExpired }
        let fields = provider == .codex ? ["device_auth_id": device.deviceCode, "user_code": device.userCode]
            : ["grant_type": "urn:ietf:params:oauth:grant-type:device_code", "device_code": device.deviceCode, "client_id": clientID]
        let (status, body) = try await request(provider == .codex ? "/api/accounts/deviceauth/token" : tokenPath,
                                             fields: fields, json: provider == .codex, readErrors: provider == .grok)
        if provider == .codex {
            if status == 403 || status == 404 { return (nil, false) }
            guard (200..<300).contains(status), let code = body?["authorization_code"]?.string,
                  let verifier = body?["code_verifier"]?.string else { throw FxSignInError.failed(statusCode: status) }
            return (try await exchangeCode(code, verifier: verifier, redirect: issuer + "/deviceauth/callback"), false)
        }
        if (200..<300).contains(status) { return (try await credentials(body), false) }
        switch body?["error"]?.string {
        case "authorization_pending": return (nil, false)
        case "slow_down": return (nil, true)
        case "expired_token": throw FxSignInError.deviceExpired
        case "access_denied": throw FxSignInError.denied(reason: "access_denied")
        default: throw FxSignInError.failed(statusCode: status)
        }
    }

    private func exchangeCode(_ code: String, verifier: String, redirect: String) async throws -> FxSubscriptionCredentials {
        let (status, body) = try await request(tokenPath, fields: ["grant_type": "authorization_code", "client_id": clientID,
                                                                "code": code, "code_verifier": verifier, "redirect_uri": redirect])
        if status == 400 || status == 401 { throw FxSignInError.expired(statusCode: status) }
        guard (200..<300).contains(status) else { throw FxSignInError.failed(statusCode: status) }
        return try await credentials(body)
    }

    private func credentials(_ body: JSONValue?) async throws -> FxSubscriptionCredentials {
        guard let access = body?["access_token"]?.string else { throw FxSignInError.failed(statusCode: nil) }
        do { _ = try FxSubscriptionCredentials(accessToken: access, refreshToken: body?["refresh_token"]?.string) }
        catch { throw FxSignInError.failed(statusCode: nil) }
        let account: String?
        if provider == .grok {
            let (status, info) = try await request("/oauth2/userinfo", bearer: access)
            guard (200..<300).contains(status) else { throw FxSignInError.accountUnavailable(statusCode: status) }
            guard let id = info?["sub"]?.string, !id.isEmpty else { throw FxSignInError.accountUnavailable(statusCode: nil) }
            account = id
        } else { account = nil }
        let expiry = Self.number(body?["expires_in"]).map { Date().addingTimeInterval($0) }
        do {
            if let token = body?["refresh_token"], token != .null, token.string == nil { throw FxSubscriptionError.invalidCredentials }
            return try FxSubscriptionCredentials(accessToken: access, refreshToken: body?["refresh_token"]?.string,
                                                 accountID: account, expiresAt: expiry).normalized(for: provider)
        } catch { throw FxSignInError.failed(statusCode: nil) }
    }

    private func request(_ path: String, fields: [String: String] = [:], json: Bool = false,
                         bearer: String? = nil, readErrors: Bool = false) async throws -> (Int, JSONValue?) {
        try Task.checkCancellation()
        var request = URLRequest(url: URL(string: issuer + path)!)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let bearer { request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization") }
        else {
            request.httpMethod = "POST"
            request.setValue(json ? "application/json" : "application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            if json { request.httpBody = try JSONEncoder().encode(fields) }
            else {
                let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
                request.httpBody = Data(fields.sorted(by: { $0.key < $1.key }).map {
                    $0.key.addingPercentEncoding(withAllowedCharacters: allowed)! + "=" + $0.value.addingPercentEncoding(withAllowedCharacters: allowed)!
                }.joined(separator: "&").utf8)
            }
        }
        do {
            let response = try await client.send(request)
            defer { response.cancel() }
            if !(200..<300).contains(response.statusCode), !readErrors { return (response.statusCode, nil) }
            var data = Data()
            for try await chunk in response.body {
                try Task.checkCancellation()
                guard chunk.count <= 64 * 1024 - data.count else { throw FxSignInError.failed(statusCode: nil) }
                data.append(chunk)
            }
            try Task.checkCancellation()
            return (response.statusCode, try? JSONDecoder().decode(JSONValue.self, from: data))
        } catch {
            try Task.checkCancellation()
            if let failure = error as? FxSignInError { throw failure }
            throw FxSignInError.failed(statusCode: nil)
        }
    }

    private static func number(_ value: JSONValue?) -> Double? {
        let number: Double?
        switch value {
        case .number(let value): number = value
        case .string(let value): number = Double(value)
        default: number = nil
        }
        return number?.isFinite == true ? number : nil
    }

    private static func secret() -> String {
        var generator = SystemRandomNumberGenerator()
        return base64URL(Data((0..<32).map { _ in UInt8.random(in: .min ... .max, using: &generator) }))
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}
