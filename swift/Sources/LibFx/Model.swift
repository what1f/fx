/// A model identifier and the options requested for its calls.
/// The core validates support against the provider's model capabilities.
public struct FxModel: Sendable, Equatable, Codable, ExpressibleByStringLiteral {
    public var id: String
    public var reasoningEffort: String?
    public var fast: Bool?
    public var ultrafast: Bool?

    public init(
        id: String,
        reasoningEffort: String? = nil,
        fast: Bool? = nil,
        ultrafast: Bool? = nil
    ) {
        self.id = id
        self.reasoningEffort = reasoningEffort
        self.fast = fast
        self.ultrafast = ultrafast
    }

    public init(stringLiteral value: String) { self.init(id: value) }
}
