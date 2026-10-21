import Foundation

public enum FxModelCatalogError: Error, Sendable, Equatable, LocalizedError {
    case invalidAPIKey
    case httpStatus(Int)
    case malformedResponse
    case byteLimit
    case entryLimit

    public var errorDescription: String? {
        switch self {
        case .invalidAPIKey: return "apiKey must contain a valid API key"
        case .httpStatus(let status): return "Model catalog request failed with HTTP \(status)"
        case .malformedResponse: return "The model catalog response is malformed"
        case .byteLimit: return "The model catalog exceeds the 4194304 byte limit"
        case .entryLimit: return "The model catalog exceeds the 10000 entry limit"
        }
    }
}

extension FxModel {
    /// Fetches the gateway's current language models without creating an engine.
    public static func available(
        apiKey: String, httpClient: any FxHTTPClient = FxURLSessionHTTPClient()
    ) async throws -> [FxModel] {
        guard !apiKey.isEmpty, apiKey.utf8.count <= 64 * 1024,
              !apiKey.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else {
            throw FxModelCatalogError.invalidAPIKey
        }
        var request = URLRequest(url: URL(string: "https://ai-gateway.vercel.sh/coding-agent/v1/models")!)
        request.httpMethod = "GET"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        try Task.checkCancellation()
        let response = try await httpClient.send(request)
        defer { response.cancel() }
        guard (200..<300).contains(response.statusCode) else { throw FxModelCatalogError.httpStatus(response.statusCode) }
        let limit = 4 * 1024 * 1024
        if let length = response.headers["content-length"].flatMap(Int.init), length > limit {
            throw FxModelCatalogError.byteLimit
        }
        var data = Data()
        for try await chunk in response.body {
            try Task.checkCancellation()
            guard chunk.count <= limit - data.count else { throw FxModelCatalogError.byteLimit }
            data.append(chunk)
        }
        try Task.checkCancellation()
        let catalog: JSONValue
        do { catalog = try JSONDecoder().decode(JSONValue.self, from: data) }
        catch { throw FxModelCatalogError.malformedResponse }
        guard case .array(let entries) = catalog["data"] else { throw FxModelCatalogError.malformedResponse }
        guard entries.count <= 10_000 else { throw FxModelCatalogError.entryLimit }
        let ids = Set(entries.compactMap { entry -> String? in
            if let type = entry["type"]?.string, type.lowercased() != "language" { return nil }
            guard let id = entry["id"]?.string, !id.isEmpty, id.utf8.count <= 1024 else { return nil }
            return id
        })
        return ids.sorted().map { FxModel(id: $0) }
    }
}
