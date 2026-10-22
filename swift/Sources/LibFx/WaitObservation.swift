import Foundation

/// Describes an input wait owned by the host. This value does not request or authorize input.
public struct FxWaitRequest: Sendable, Equatable {
    public enum Kind: String, Sendable {
        case approval, question
        case mcpForm = "mcp_form", mcpURL = "mcp_url"
    }

    public struct Option: Sendable, Equatable {
        public var label: String
        public var description: String?
        public init(label: String, description: String? = nil) {
            self.label = label
            self.description = description
        }
    }

    public struct Question: Sendable, Equatable {
        public var text: String
        public var options: [Option]
        public init(_ text: String, options: [Option] = []) {
            self.text = text
            self.options = options
        }
    }

    public var kind: Kind
    public var externalID: String?
    public var server: String?
    public var schemaJSON: String?
    public var prompt: String?
    public var questions: [Question]

    public init(kind: Kind, externalID: String? = nil, server: String? = nil, schemaJSON: String? = nil,
                prompt: String? = nil, questions: [Question] = []) {
        self.kind = kind
        self.externalID = externalID
        self.server = server
        self.schemaJSON = schemaJSON
        self.prompt = prompt
        self.questions = questions
    }

    func observed(captureContent: Bool) -> (data: [String: JSONValue], truncated: Bool) {
        var capture = WaitContentCapture(enabled: captureContent)
        capture.truncated = questions.count > 128 || questions.prefix(128).contains { $0.options.count > 128 }
        var data: [String: JSONValue] = [
            "kind": .string(kind.rawValue), "externalId": externalID.map(JSONValue.string) ?? .null,
            "server": server.map(JSONValue.string) ?? .null, "questionCount": .number(Double(questions.count)),
        ]
        data["schemaJson"] = capture.text(schemaJSON)
        data["prompt"] = capture.text(prompt)
        if captureContent {
            data["questions"] = .array(questions.prefix(128).map { question in
                var fields: [String: JSONValue] = [:]
                fields["question"] = capture.text(question.text)
                fields["options"] = .array(question.options.prefix(128).map { option in
                    var fields: [String: JSONValue] = [:]
                    fields["label"] = capture.text(option.label)
                    fields["description"] = capture.text(option.description)
                    return .object(fields)
                })
                return .object(fields)
            })
        }
        return (data, capture.truncated)
    }
}

/// Observation metadata for an effect's result. The effect still returns its original value.
public struct FxWaitResolution: Sendable, Equatable {
    public enum Outcome: String, Sendable {
        case accepted, denied, failed, cancelled
        case timedOut = "timed_out"
    }

    public var outcome: Outcome
    public var answers: [String]
    public init(outcome: Outcome = .accepted, answers: [String] = []) {
        self.outcome = outcome
        self.answers = answers
    }

    func observed(captureContent: Bool, error: String?) -> (data: [String: JSONValue], truncated: Bool) {
        var capture = WaitContentCapture(enabled: captureContent)
        capture.truncated = answers.count > 128
        var data: [String: JSONValue] = ["outcome": .string(outcome.rawValue), "error": error.map(JSONValue.string) ?? .null]
        if captureContent { data["answers"] = .array(answers.prefix(128).compactMap { capture.text($0) }) }
        return (data, capture.truncated)
    }
}

private struct WaitContentCapture {
    let enabled: Bool
    var truncated = false
    private var remaining = 64 * 1024

    init(enabled: Bool) { self.enabled = enabled }

    mutating func text(_ value: String?) -> JSONValue? {
        guard enabled, let value else { return nil }
        var bytes = Array(value.utf8.prefix(remaining))
        // A byte prefix can cut a scalar. At most three trailing bytes need removal.
        while String(bytes: bytes, encoding: .utf8) == nil { bytes.removeLast() }
        remaining -= bytes.count
        truncated = truncated || bytes.count < value.utf8.count
        return .string(String(decoding: bytes, as: UTF8.self))
    }
}
