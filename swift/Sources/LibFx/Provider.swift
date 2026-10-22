import Foundation

public struct FxCredentialRequest: Sendable {
    public let provider: String
    public let sessionID: String?
}

public enum FxProvider: Sendable {
    case gateway(apiKey: String)
    case subscription(FxSubscription)
    case custom(FxCustomProvider, credentials: (@Sendable (FxCredentialRequest) async throws -> String)? = nil)
}

/// An OpenAI Chat Completions service. Credentials belong to the host, not its definition.
public struct FxCustomProvider: Sendable {
    public struct ModelCapabilities: Sendable {
        public var contextWindow: UInt32?
        public var maxOutputTokens: UInt32?
        public var supportsToolUse: Bool?
        public var supportsVision: Bool?

        public init(contextWindow: UInt32? = nil, maxOutputTokens: UInt32? = nil,
                    supportsToolUse: Bool? = nil, supportsVision: Bool? = nil) {
            self.contextWindow = contextWindow
            self.maxOutputTokens = maxOutputTokens
            self.supportsToolUse = supportsToolUse
            self.supportsVision = supportsVision
        }

        var json: JSONValue {
            var fields: [String: JSONValue] = [:]
            if let contextWindow { fields["context_window"] = .number(Double(contextWindow)) }
            if let maxOutputTokens { fields["max_output_tokens"] = .number(Double(maxOutputTokens)) }
            if let supportsToolUse { fields["supports_tool_use"] = .bool(supportsToolUse) }
            if let supportsVision { fields["supports_vision"] = .bool(supportsVision) }
            return .object(fields)
        }
    }

    public let name: String
    public let baseURL: URL
    public let models: [String: ModelCapabilities]
    let chatURL: URL

    public init(name: String, baseURL: URL, models: [String: ModelCapabilities] = [:]) throws {
        let letters = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ"
        let allowed = letters + "0123456789_-"
        guard (1...64).contains(name.utf8.count), let first = name.first, letters.contains(first),
              name.allSatisfy({ allowed.contains($0) }),
              !["gateway", "codex", "grok"].contains(name.lowercased()) else {
            throw FxError.invalidInput("Invalid provider name")
        }
        guard let components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false),
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil,
              components.scheme == "https" || (components.scheme == "http" && ["localhost", "127.0.0.1", "[::1]"].contains(host)),
              baseURL.absoluteString.utf8.count <= 2048 else {
            throw FxError.invalidInput("Provider URL must use HTTPS or local HTTP, without credentials, query, or fragment")
        }
        guard models.count <= 256 else { throw FxError.invalidInput("Too many provider models") }
        for (id, limits) in models {
            guard !id.isEmpty, id.utf8.count <= 1024,
                  id == id.trimmingCharacters(in: .whitespacesAndNewlines),
                  !id.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }),
                  limits.contextWindow != 0, limits.maxOutputTokens != 0 else {
                throw FxError.invalidInput("Invalid provider model capabilities")
            }
            if let context = limits.contextWindow, let output = limits.maxOutputTokens, output >= context {
                throw FxError.invalidInput("Output token limit must be less than the context window")
            }
        }
        self.name = name
        self.baseURL = baseURL
        self.models = models
        let base = baseURL.absoluteString
        guard let chatURL = URL(string: (base.hasSuffix("/") ? String(base.dropLast()) : base) + "/chat/completions") else {
            throw FxError.invalidInput("Invalid provider URL")
        }
        self.chatURL = chatURL
    }

    var definition: JSONValue {
        .object([name: .object([
            "protocol": .string("openai-chat-completions"),
            "base_url": .string(baseURL.absoluteString),
            "auth": .object(["type": .string("none")]),
            "model_metadata": .object(models.mapValues(\.json)),
        ])])
    }
}

/// Mutable session identity is confined to this actor; keys never enter core options.
actor ProviderHTTPClient: FxHTTPClient {
    private let client: any FxHTTPClient
    private let provider: FxProvider
    private var sessionID: String?

    init(client: any FxHTTPClient, provider: FxProvider) {
        self.client = client
        self.provider = provider
    }

    func setSessionID(_ id: String) { sessionID = id }

    func send(_ request: URLRequest) async throws -> FxHTTPResponse {
        if case .subscription(let subscription) = provider {
            return try await subscription.send(request, sessionID: sessionID, client: client)
        }
        var request = request
        var credential: String?
        if case .custom(let definition, let credentials) = provider,
           request.url == definition.chatURL, let credentials {
            guard let sessionID else { throw FxError.invalidInput("Provider session is unavailable") }
            let key = try await credentials(FxCredentialRequest(provider: definition.name, sessionID: sessionID))
            try Task.checkCancellation()
            guard !key.isEmpty, key.utf8.count <= 64 * 1024,
                  !key.unicodeScalars.contains(where: { $0.value <= 32 || $0.value == 127 }) else {
                throw FxError.invalidInput("Invalid provider credentials")
            }
            credential = key
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        let response = try await client.send(request)
        if let credential {
            return try await redactingProviderResponse(response, secrets: [credential]).withDiagnosticSecrets([credential])
        }
        if case .gateway(let key) = provider { return response.withDiagnosticSecrets([key]) }
        return response
    }
}

func redactingProviderResponse(_ response: FxHTTPResponse, secrets: [String]) async throws -> FxHTTPResponse {
    guard response.statusCode >= 400 else { return response }
    // Normalize JSON before masking, so Unicode escapes cannot hide the key.
    defer { response.cancel() }
    var data = Data()
    var body = "Provider error details are unavailable"
    var exceeded = false
    do {
        for try await chunk in response.body {
            try Task.checkCancellation()
            guard chunk.count <= 64 * 1024 - data.count else { exceeded = true; break }
            data.append(chunk)
        }
        if !exceeded {
            body = String(decoding: data, as: UTF8.self)
            if let first = body.first(where: { !$0.isWhitespace }), ["[", "{", "\""].contains(String(first)) {
                if let json = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
                   let normalized = try? JSONSerialization.data(withJSONObject: json, options: [.fragmentsAllowed, .withoutEscapingSlashes]) {
                    body = String(decoding: normalized, as: UTF8.self)
                } else { body = "Provider error details could not be decoded" }
            }
        }
    } catch {
        try Task.checkCancellation()
        // Headers arrived: a failed body must not trigger a request replay.
    }
    for credential in secrets {
        let encoded = String(decoding: try JSONSerialization.data(withJSONObject: credential, options: [.fragmentsAllowed, .withoutEscapingSlashes]), as: UTF8.self)
        for form in [credential, String(encoded.dropFirst().dropLast())] {
            body = body.replacingOccurrences(of: form, with: String(repeating: "*", count: form.count))
        }
    }
    var headers = response.headers
    headers.removeValue(forKey: "content-length")
    headers.removeValue(forKey: "content-encoding")
    let redacted = Data(body.utf8)
    return FxHTTPResponse(statusCode: response.statusCode, headers: headers, body: AsyncThrowingStream {
        $0.yield(redacted); $0.finish()
    })
}
