import Foundation

public enum FxSubscriptionProvider: String, Sendable, CaseIterable {
    case codex, grok

    func matches(_ url: URL?) -> Bool {
        guard let url, url.scheme == "https", url.user == nil, url.password == nil,
              url.port == nil || url.port == 443 else { return false }
        let path = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath
        switch self {
        case .codex:
            return url.host == "chatgpt.com" && ["/backend-api/codex/models", "/backend-api/codex/responses"].contains(path ?? "")
        case .grok:
            return url.host == "cli-chat-proxy.grok.com" && ["/v1/models", "/v1/responses"].contains(path ?? "")
                || url.host == "api.x.ai" && path == "/v1/language-models"
        }
    }
}

public enum FxSubscriptionError: Error, Sendable, Equatable {
    case invalidCredentials
    case refreshFailed(statusCode: Int?)
    case accountChanged
    case credentialSaveFailed
}

public struct FxSubscriptionCredentials: Sendable, Equatable {
    public let accessToken: String
    public let refreshToken: String?
    public let accountID: String?
    public let expiresAt: Date?

    public init(accessToken: String, refreshToken: String? = nil, accountID: String? = nil, expiresAt: Date? = nil) throws {
        for value in [accessToken, refreshToken, accountID].compactMap({ $0 }) {
            guard !value.isEmpty, value.utf8.count <= 64 * 1024 else { throw FxSubscriptionError.invalidCredentials }
        }
        for header in [accessToken, accountID].compactMap({ $0 }) {
            guard !header.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else {
                throw FxSubscriptionError.invalidCredentials
            }
        }
        guard expiresAt?.timeIntervalSince1970.isFinite != false else { throw FxSubscriptionError.invalidCredentials }
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.accountID = accountID
        self.expiresAt = expiresAt
    }

    func normalized(for provider: FxSubscriptionProvider) throws -> Self {
        // Claims supply routing metadata only. They do not verify the token.
        let parts = accessToken.split(separator: ".", omittingEmptySubsequences: false)
        var claims: JSONValue?
        if parts.count > 1 {
            var encoded = parts[1].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
            encoded += String(repeating: "=", count: (4 - encoded.count % 4) % 4)
            if let data = Data(base64Encoded: encoded) { claims = try? JSONDecoder().decode(JSONValue.self, from: data) }
        }
        let account = accountID ?? (provider == .codex ? claims?["https://api.openai.com/auth"]?["chatgpt_account_id"]?.string : claims?["sub"]?.string)
        guard let account else { throw FxSubscriptionError.invalidCredentials }
        var expiry = expiresAt
        if expiry == nil, case .number(let seconds) = claims?["exp"], seconds.isFinite { expiry = Date(timeIntervalSince1970: seconds) }
        return try Self(accessToken: accessToken, refreshToken: refreshToken, accountID: account, expiresAt: expiry)
    }

    var needsRefresh: Bool {
        refreshToken != nil && expiresAt.map { $0.timeIntervalSinceNow <= 300 } == true
    }
}

/// Share one instance across engines that use the same credential store.
public actor FxSubscription {
    public typealias RefreshOperation = @Sendable () async throws -> FxSubscriptionCredentials
    public typealias RefreshLock = @Sendable (FxCredentialRequest, @escaping RefreshOperation) async throws -> FxSubscriptionCredentials
    public nonisolated let provider: FxSubscriptionProvider
    private let credentials: @Sendable (FxCredentialRequest) async throws -> FxSubscriptionCredentials
    private let onRefresh: (@Sendable (FxSubscriptionCredentials, FxCredentialRequest) async throws -> Void)?
    private let refreshLock: RefreshLock?

    private struct CredentialKey: Hashable { let accountID: String?; let token: String }
    private struct Rotation: Sendable {
        let id: UUID
        let credentials: FxSubscriptionCredentials
    }
    private struct Flight<Value: Sendable> {
        let id: UUID
        let result: AsyncResult<Value>
        let task: Task<Void, Never>
        var waiters: Set<UUID>
    }
    private struct SaveKey: Hashable { let rotation: UUID; let session: String? }
    private var remembered: [CredentialKey: Rotation] = [:]
    private var order: [CredentialKey] = []
    private var refreshing: [CredentialKey: Flight<Rotation>] = [:]
    var refreshWaiterCount: Int { refreshing.values.reduce(0) { $0 + $1.waiters.count } }
    private var saved: Set<SaveKey> = []
    private var saving: [SaveKey: Flight<Void>] = [:]

    public init(
        provider: FxSubscriptionProvider,
        credentials: @escaping @Sendable (FxCredentialRequest) async throws -> FxSubscriptionCredentials,
        onRefresh: (@Sendable (FxSubscriptionCredentials, FxCredentialRequest) async throws -> Void)? = nil,
        refreshLock: RefreshLock? = nil
    ) {
        self.provider = provider
        self.credentials = credentials
        self.onRefresh = onRefresh
        self.refreshLock = refreshLock
    }

    func send(_ request: URLRequest, sessionID: String?, client: any FxHTTPClient) async throws -> FxHTTPResponse {
        guard provider.matches(request.url) else { return try await client.send(request) }
        let header = provider == .codex ? "session-id" : "x-grok-conv-id"
        let context = FxCredentialRequest(provider: provider.rawValue,
                                          sessionID: request.value(forHTTPHeaderField: header) ?? sessionID)
        let current = try await current(context, client: client)
        var used = current.rotation
        var secrets = [used.credentials.accessToken, used.credentials.refreshToken].compactMap { $0 }
        var response = try await client.send(authorize(request, with: used.credentials))
        if response.statusCode == 401, used.credentials.refreshToken != nil {
            response.cancel()
            let latest = try await self.current(context, client: client)
            if latest.rotation.credentials.accessToken != used.credentials.accessToken { used = latest.rotation }
            else { used = try await refresh(supplied: latest.supplied, current: used.credentials, context: context, client: client) }
            try Task.checkCancellation()
            secrets += [used.credentials.accessToken, used.credentials.refreshToken].compactMap { $0 }
            response = try await client.send(authorize(request, with: used.credentials))
        }
        return try await redactingProviderResponse(response, secrets: secrets).withDiagnosticSecrets(secrets)
    }

    private func authorize(_ original: URLRequest, with credentials: FxSubscriptionCredentials) -> URLRequest {
        var request = original
        request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
        if provider == .codex { request.setValue(credentials.accountID, forHTTPHeaderField: "chatgpt-account-id") }
        else if request.url?.host == "cli-chat-proxy.grok.com" {
            request.setValue(credentials.accountID, forHTTPHeaderField: request.url?.path == "/v1/models" ? "x-userid" : "x-grok-user-id")
        }
        return request
    }

    private func load(_ context: FxCredentialRequest) async throws -> FxSubscriptionCredentials {
        do {
            let value = try await credentials(context).normalized(for: provider)
            try Task.checkCancellation()
            return value
        } catch {
            try Task.checkCancellation()
            throw FxSubscriptionError.invalidCredentials
        }
    }

    private func current(_ context: FxCredentialRequest, client: any FxHTTPClient) async throws -> (supplied: FxSubscriptionCredentials, rotation: Rotation) {
        let supplied = try await load(context)
        let best = remembered[CredentialKey(accountID: supplied.accountID, token: supplied.accessToken)] ?? Rotation(id: UUID(), credentials: supplied)
        if best.credentials.needsRefresh {
            return (supplied, try await refresh(supplied: supplied, current: best.credentials, context: context, client: client))
        }
        if best.credentials != supplied { try await notify(best, context: context) }
        return (supplied, best)
    }

    private func remember(_ rotation: Rotation, tokens: [String]) {
        for token in tokens {
            let key = CredentialKey(accountID: rotation.credentials.accountID, token: token)
            order.removeAll { $0 == key }
            order.append(key)
            remembered[key] = rotation
        }
        while order.count > 256 { remembered.removeValue(forKey: order.removeFirst()) }
        let retained = Set(remembered.values.map(\.id))
        saved = saved.filter { retained.contains($0.rotation) }
    }

    private func notify(_ rotation: Rotation, context: FxCredentialRequest) async throws {
        guard let onRefresh else { return }
        let key = SaveKey(rotation: rotation.id, session: context.sessionID)
        if saved.contains(key) { return }
        let waiter = UUID()
        if saving[key] == nil {
            let id = UUID(), result = AsyncResult<Void>()
            let task = Task {
                let outcome: Result<Void, any Error>
                do { try await onRefresh(rotation.credentials, context); outcome = .success(()) }
                catch { outcome = .failure(FxSubscriptionError.credentialSaveFailed) }
                await self.finishSave(key, id: id, result: result, outcome: outcome)
            }
            saving[key] = Flight(id: id, result: result, task: task, waiters: [])
        }
        saving[key]?.waiters.insert(waiter)
        let result = saving[key]!.result
        do {
            try await result.wait()
            releaseSave(key, waiter: waiter)
        } catch {
            releaseSave(key, waiter: waiter)
            throw error
        }
    }

    private func releaseSave(_ key: SaveKey, waiter: UUID) {
        saving[key]?.waiters.remove(waiter)
        if saving[key]?.waiters.isEmpty == true { saving.removeValue(forKey: key)?.task.cancel() }
    }

    private func finishSave(_ key: SaveKey, id: UUID, result: AsyncResult<Void>, outcome: Result<Void, any Error>) async {
        if saving[key]?.id == id {
            saving.removeValue(forKey: key)
            if case .success = outcome { saved.insert(key) }
        }
        await result.resolve(outcome)
    }

    private func refresh(supplied: FxSubscriptionCredentials, current: FxSubscriptionCredentials,
                         context: FxCredentialRequest, client: any FxHTTPClient) async throws -> Rotation {
        guard let token = current.refreshToken else { throw FxSubscriptionError.invalidCredentials }
        let key = CredentialKey(accountID: current.accountID, token: token)
        let waiter = UUID()
        if refreshing[key] == nil {
            let id = UUID(), result = AsyncResult<Rotation>()
            let task = Task {
                let outcome: Result<Rotation, any Error>
                do { outcome = .success(try await self.rotate(supplied: supplied, current: current, context: context, client: client)) }
                catch { outcome = .failure(error) }
                await self.finishRefresh(key, id: id, result: result, outcome: outcome)
            }
            refreshing[key] = Flight(id: id, result: result, task: task, waiters: [])
        }
        refreshing[key]?.waiters.insert(waiter)
        let result = refreshing[key]!.result
        do {
            let rotation = try await result.wait()
            releaseRefresh(key, waiter: waiter)
            try await notify(rotation, context: context)
            return rotation
        } catch {
            releaseRefresh(key, waiter: waiter)
            throw error
        }
    }

    private func releaseRefresh(_ key: CredentialKey, waiter: UUID) {
        refreshing[key]?.waiters.remove(waiter)
        if refreshing[key]?.waiters.isEmpty == true {
            refreshing.removeValue(forKey: key)?.task.cancel()
        }
    }

    private func finishRefresh(_ key: CredentialKey, id: UUID, result: AsyncResult<Rotation>, outcome: Result<Rotation, any Error>) async {
        if refreshing[key]?.id == id { refreshing.removeValue(forKey: key) }
        await result.resolve(outcome)
    }

    private func rotate(supplied: FxSubscriptionCredentials, current: FxSubscriptionCredentials,
                        context: FxCredentialRequest, client: any FxHTTPClient) async throws -> Rotation {
        let operation: RefreshOperation = {
            if self.refreshLock != nil {
                let latest = try await self.load(context)
                guard latest.accountID == current.accountID else { throw FxSubscriptionError.accountChanged }
                if latest.accessToken != supplied.accessToken, latest.accessToken != current.accessToken, !latest.needsRefresh {
                    let rotation = Rotation(id: UUID(), credentials: latest)
                    await self.remember(rotation, tokens: [supplied.accessToken, current.accessToken])
                    await self.markSaved(rotation, context: context)
                    return latest
                }
            }
            let next = try await self.exchange(current, client: client)
            let rotation = Rotation(id: UUID(), credentials: next)
            await self.remember(rotation, tokens: [supplied.accessToken, current.accessToken])
            try await self.notify(rotation, context: context)
            return next
        }
        let next: FxSubscriptionCredentials
        do {
            if let refreshLock { next = try await refreshLock(context, operation) }
            else { next = try await operation() }
        } catch {
            try Task.checkCancellation()
            if let error = error as? FxSubscriptionError { throw error }
            throw FxSubscriptionError.refreshFailed(statusCode: nil)
        }
        try Task.checkCancellation()
        guard let rotation = remembered[CredentialKey(accountID: supplied.accountID, token: supplied.accessToken)], rotation.credentials == next else {
            throw FxSubscriptionError.invalidCredentials
        }
        return rotation
    }

    private func markSaved(_ rotation: Rotation, context: FxCredentialRequest) {
        saved.insert(SaveKey(rotation: rotation.id, session: context.sessionID))
    }

    private func exchange(_ current: FxSubscriptionCredentials, client: any FxHTTPClient) async throws -> FxSubscriptionCredentials {
        guard let refreshToken = current.refreshToken else { throw FxSubscriptionError.invalidCredentials }
        let endpoint = provider == .codex ? "https://auth.openai.com/oauth/token" : "https://auth.x.ai/oauth2/token"
        var request = URLRequest(url: URL(string: endpoint)!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if provider == .codex {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(JSONValue.object([
                "client_id": .string("app_EMoamEEZ73f0CkXaXp7hrann"), "grant_type": .string("refresh_token"), "refresh_token": .string(refreshToken),
            ]))
        } else {
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
            let encoded = refreshToken.addingPercentEncoding(withAllowedCharacters: allowed)!
            request.httpBody = Data("grant_type=refresh_token&client_id=b1a00492-073a-47ea-816f-4c329264a828&refresh_token=\(encoded)".utf8)
        }
        do {
            let tokens = try await json(request, client: client)
            guard let access = tokens["access_token"]?.string else { throw FxSubscriptionError.refreshFailed(statusCode: nil) }
            var expiry: Date?
            if case .number(let seconds) = tokens["expires_in"], seconds.isFinite { expiry = Date().addingTimeInterval(seconds) }
            let rotatedToken: String
            if let value = tokens["refresh_token"], value != .null {
                guard let token = value.string else { throw FxSubscriptionError.refreshFailed(statusCode: nil) }
                rotatedToken = token
            } else { rotatedToken = refreshToken }
            var next = try FxSubscriptionCredentials(accessToken: access, refreshToken: rotatedToken,
                                                     accountID: provider == .grok ? current.accountID : nil, expiresAt: expiry).normalized(for: provider)
            if provider == .grok {
                var check = URLRequest(url: URL(string: "https://auth.x.ai/oauth2/userinfo")!)
                check.setValue("Bearer \(next.accessToken)", forHTTPHeaderField: "Authorization")
                let account = try await json(check, client: client)
                guard account["sub"]?.string == current.accountID else { throw FxSubscriptionError.accountChanged }
            } else if next.accountID != current.accountID {
                next = try FxSubscriptionCredentials(accessToken: next.accessToken, refreshToken: next.refreshToken,
                                                     accountID: current.accountID, expiresAt: next.expiresAt)
            }
            return next
        } catch {
            try Task.checkCancellation()
            if let error = error as? FxSubscriptionError { throw error }
            throw FxSubscriptionError.refreshFailed(statusCode: nil)
        }
    }

    private func json(_ request: URLRequest, client: any FxHTTPClient) async throws -> JSONValue {
        let response = try await client.send(request)
        defer { response.cancel() }
        guard (200..<300).contains(response.statusCode) else { throw FxSubscriptionError.refreshFailed(statusCode: response.statusCode) }
        var data = Data()
        for try await chunk in response.body {
            try Task.checkCancellation()
            guard chunk.count <= 64 * 1024 - data.count else { throw FxSubscriptionError.refreshFailed(statusCode: nil) }
            data.append(chunk)
        }
        return try JSONDecoder().decode(JSONValue.self, from: data)
    }
}
