import Foundation

extension FxSkillDiscovery {
    /// Refresh only the skill section in the provider's system lane. Conversation and tool results stay intact.
    public func prepare(_ request: URLRequest, api: FxCustomProvider.APIProtocol) throws -> URLRequest {
        guard let data = request.httpBody,
              var body = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return request }
        let start = "<fx_skill_catalog>", end = "</fx_skill_catalog>"
        let current = "\(start)\n\(discover().prompt)\n\(end)"
        func replace(_ text: String) -> String {
            if let first = text.range(of: start), let last = text.range(of: end, range: first.upperBound..<text.endIndex) {
                return String(text[..<first.lowerBound]) + current + String(text[last.upperBound...])
            }
            return text + "\n\n" + current
        }
        switch api {
        case .responses:
            body["instructions"] = replace(body["instructions"] as? String ?? "")
        case .anthropicMessages:
            if let text = body["system"] as? String { body["system"] = replace(text) }
            else {
                var blocks = body["system"] as? [[String: Any]] ?? []
                if let index = blocks.firstIndex(where: { ($0["text"] as? String)?.contains(start) == true }) {
                    blocks[index]["text"] = replace(blocks[index]["text"] as? String ?? "")
                } else { blocks.append(["type": "text", "text": current]) }
                body["system"] = blocks
            }
        case .chatCompletions:
            var messages = body["messages"] as? [[String: Any]] ?? []
            if let index = messages.firstIndex(where: {
                ["system", "developer"].contains($0["role"] as? String ?? "") && ($0["content"] as? String)?.contains(start) == true
            }) { messages[index]["content"] = replace(messages[index]["content"] as? String ?? "") }
            else { messages.insert(["role": "system", "content": current], at: 0) }
            body["messages"] = messages
        }
        var result = request
        result.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        result.setValue(nil, forHTTPHeaderField: "Content-Length")
        return result
    }
}
