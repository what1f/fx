import Foundation

/// Metadata for a core HTTP request. Bodies and credential headers are excluded.
public enum FxTransportEvent: Sendable {
    public struct Request: Sendable {
        public let id: UUID
        /// Starts at one for each turn and counts retries as separate requests.
        public let number: Int
        public let sessionID: String?
        public let method: String
        /// Excludes URL credentials, query parameters, and fragments.
        public let endpoint: URL?
        public let modelID: String?
    }

    public struct Response: Sendable {
        public let statusCode: Int
        public let elapsed: Duration
        public let requestID: String?
        public let generationID: String?
        public let modelID: String?
        public let provider: String?
    }

    public enum Failure: String, Sendable {
        case cancelled, credentials, invalidRequest, requestFailed
    }

    case started(Request)
    case response(Request, Response)
    case failed(Request, elapsed: Duration, reason: Failure)
    case retrying(Request)
}

func boundedTransportText(_ value: String?) -> String? {
    guard let value else { return nil }
    var bytes = value.utf8.prefix(512)
    while !bytes.isEmpty {
        if let result = String(bytes: bytes, encoding: .utf8) { return result }
        bytes = bytes.dropLast()
    }
    return ""
}

func transportEndpoint(_ url: URL?) -> URL? {
    var components = url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }
    components?.user = nil
    components?.password = nil
    components?.query = nil
    components?.fragment = nil
    return components?.url
}

extension FxHTTPResponse {
    func withDiagnosticSecrets(_ secrets: [String]) -> Self {
        var copy = self
        let selected = ["x-vercel-id", "x-generation-id", "x-model-id", "x-vercel-ai-gateway-provider", "x-ai-gateway-provider"]
        copy.diagnosticHeaders = headers.filter { selected.contains($0.key) }.mapValues { value in
            var value = value
            for secret in secrets where !secret.isEmpty {
                let encoded = (try? JSONEncoder().encode(secret)).map { String(decoding: $0, as: UTF8.self) }
                for form in [secret, encoded.map { String($0.dropFirst().dropLast()) }].compactMap({ $0 }) {
                    value = value.replacingOccurrences(of: form, with: "[redacted]")
                }
            }
            return boundedTransportText(value) ?? ""
        }
        return copy
    }
}
