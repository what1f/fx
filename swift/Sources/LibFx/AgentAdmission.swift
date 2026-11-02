import Foundation

public enum FxAgentAdmissionError: Error, Sendable, Equatable {
    case incompatibleConfiguration(name: String)
}

/// Admission for live agents on one logical store in this process.
/// Share this value when separate store connections address the same store.
/// It does not compare configurations across processes or persist registrations.
public final class FxAgentAdmission: @unchecked Sendable {
    private struct Entry {
        let definition: AgentDefinition
        var members: Set<UUID>
    }
    private let lock = NSLock()
    private var entries: [String: Entry] = [:]

    public init() {}

    func register(name: String, definition: AgentDefinition) throws -> AgentRegistration {
        try lock.withLock {
            if let entry = entries[name], !entry.definition.isCompatible(with: definition) {
                throw FxAgentAdmissionError.incompatibleConfiguration(name: name)
            }
            let id = UUID()
            if entries[name] == nil { entries[name] = Entry(definition: definition, members: []) }
            entries[name]?.members.insert(id)
            return AgentRegistration(admission: self, name: name, id: id)
        }
    }

    fileprivate func release(name: String, id: UUID) {
        lock.withLock {
            entries[name]?.members.remove(id)
            if entries[name]?.members.isEmpty == true { entries[name] = nil }
        }
    }
}

final class AgentRegistration: Sendable {
    private let admission: FxAgentAdmission
    private let name: String
    private let id: UUID
    init(admission: FxAgentAdmission, name: String, id: UUID) {
        self.admission = admission; self.name = name; self.id = id
    }
    func release() { admission.release(name: name, id: id) }
    deinit { release() }
}

struct AgentDefinition: Sendable, Equatable {
    private struct Tool: Sendable, Equatable {
        let name: String
        let description: String
        let schema: JSONValue
        let idempotent: Bool
        let writes: Bool?
        let deferred: Bool
    }
    private enum Provider: Sendable, Equatable {
        case gateway(String)
        case subscription(FxSubscriptionProvider)
        case custom(JSONValue)
    }
    private struct Kernel: Sendable, Equatable {
        let provider: Provider
        let model: FxModel
        let instructions: String
        let workspace: URL
        let gatewayURL: URL
        let tools: [Tool]
        let providerTools: [FxProviderTool]
        let autoCompaction: FxAutoCompaction?
        let toolSearchEnabled: Bool
        let catalog: FxModelCatalog?
        let imageWindow: FxImageWindow?
        let checkpointAfterBytes: Int?

        init(_ configuration: FxConfiguration) {
            switch configuration.provider {
            case .gateway(let key): provider = .gateway(key)
            case .subscription(let subscription): provider = .subscription(subscription.provider)
            case .custom(let custom, _): provider = .custom(custom.definition)
            }
            model = configuration.model
            instructions = configuration.instructions
            workspace = configuration.workspace
            gatewayURL = configuration.gatewayURL
            tools = configuration.tools.map {
                Tool(name: $0.name, description: $0.description, schema: $0.inputSchema,
                     idempotent: $0.isIdempotent, writes: $0.writes, deferred: $0.deferred)
            }
            providerTools = configuration.providerTools
            autoCompaction = configuration.autoCompaction
            toolSearchEnabled = configuration.toolSearchEnabled
            catalog = configuration.modelCatalog
            imageWindow = configuration.imageWindow
            checkpointAfterBytes = configuration.checkpointAfterBytes
        }
    }

    private let kernel: Kernel?
    private let opaque: Bool
    private let compatibilityID: String?
    private let defersImageLimits: Bool
    private let checkpoint: Data?
    private let checkpointAfterBytes: Int?
    private let deliveryDuration: Duration?
    private let deliveryReserve: Duration?
    private let openingRetries: UInt?
    private let openingDelay: Duration?
    private let hasQueue: Bool
    private let queueSource: String?
    private let allowsSameAttempt: Bool?

    init(harness: any FxSessionHarness, compatibilityID: String?, checkpoint: Data?,
         checkpointAfterBytes: Int?, deliveryPolicy: FxDeliveryPolicy?,
         openingRetryPolicy: FxOpeningRetryPolicy?, hasQueue: Bool, queueAuthority: FxQueueDeliveryAuthority? = nil) throws {
        if let compatibilityID {
            guard !compatibilityID.isEmpty, compatibilityID.utf8.count <= 1024,
                  !compatibilityID.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else {
                throw FxError.invalidInput("Invalid compatibility ID")
            }
        }
        if let harness = harness as? KernelSessionHarness {
            let configuration = harness.configuration
            kernel = Kernel(configuration)
            let defaultHTTP = (configuration.httpClient as? FxURLSessionHTTPClient)?.usesDefaultSession == true
            var opaqueProvider = false
            switch configuration.provider {
            case .subscription: opaqueProvider = true
            case .custom(_, let credentials): opaqueProvider = credentials != nil
            case .gateway: break
            }
            opaque = !defaultHTTP || opaqueProvider || !configuration.tools.isEmpty
                || configuration.onPermission != nil || configuration.prepareImage != nil
                || configuration.validatePermission != nil || openingRetryPolicy != nil || hasQueue || queueAuthority != nil
        } else {
            kernel = nil
            opaque = true
        }
        self.compatibilityID = compatibilityID
        defersImageLimits = harness.defersImageLimits
        self.checkpoint = checkpoint
        self.checkpointAfterBytes = checkpointAfterBytes
        deliveryDuration = deliveryPolicy?.maximumDuration
        deliveryReserve = deliveryPolicy?.reserve
        openingRetries = openingRetryPolicy?.maxRetries
        openingDelay = openingRetryPolicy?.delay
        self.hasQueue = hasQueue
        queueSource = queueAuthority?.source
        allowsSameAttempt = queueAuthority?.allowsSameAttemptRedelivery
    }

    func isCompatible(with other: Self) -> Bool {
        self == other && (!opaque || compatibilityID != nil)
    }
}
