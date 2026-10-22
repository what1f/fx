import Foundation
import LibFx

actor GenericHarnessDriver {
    private var relays: [String: GenericHarnessRelay] = [:]
    private var agents: [String: FxDurableAgent<JSONValue, JSONValue>] = [:]
    private var router: FxAgentRouter?
    private var store: FxSessionStore?
    private var storePath: String?
    private var turns: [String: FxDurableTurn<JSONValue>] = [:]
    private var deliveries: [String: Task<Void, Never>] = [:]
    private var readers: [String: Task<JSONValue, any Error>] = [:]
    private var readerAgents: [String: String] = [:]
    private var deliveryAgents: [String: String] = [:]

    func run(_ value: JSONValue) async throws -> JSONValue {
        let agentToken = value["agentToken"]?.string ?? "default"
        switch value["op"]?.string {
        case "genericCallbackResult":
            guard let relay = relays[agentToken] else { throw FxError.closed }
            await relay.respond(value); return .null
        case "genericPersistence":
            guard let relay = relays[agentToken] else { throw FxError.closed }
            return try await relay.persistence(value)
        case "genericOpen":
            let options = value["options"] ?? .null
            guard agents[agentToken] == nil else { throw FxError.invalidInput("Duplicate agent token") }
            let requestedPath = options["sessionStorePath"]?.string
            guard store == nil || storePath == requestedPath else { throw FxError.invalidInput("Driver connection belongs to another store") }
            if store == nil {
                let storage = try FxSessionStore(url: requestedPath.map { URL(fileURLWithPath: $0) })
                store = storage
                storePath = requestedPath
                router = FxAgentRouter(store: storage)
            }
            guard let router else { throw FxError.closed }
            let relay = GenericHarnessRelay(agentToken: agentToken)
            relays[agentToken] = relay
            let policy = try options["maximumDurationMs"]?.integer.map {
                try FxDeliveryPolicy(maximumDuration: .milliseconds($0), reserve: .milliseconds(options["reserveMs"]?.integer ?? 0))
            }
            do {
                agents[agentToken] = try await router.makeAgent(harness: RelayedGenericHarness(relay: relay), name: options["name"]?.string ?? "default",
                    checkpointAfterBytes: nil, deliveryPolicy: policy,
                    onLifecycleEvent: { event in DriverOutput.emit(.object(["genericDiagnostic": encodeLifecycleEvent(event), "agentToken": .string(agentToken)])) })
            } catch { relays.removeValue(forKey: agentToken); throw error }
            return .null
        case "genericPrompt", "genericResume", "genericSteer":
            let session = try await session(value)
            let turn: FxDurableTurn<JSONValue>
            if value["op"] == .string("genericResume") {
                guard let resumed = try await session.resume() else { throw FxError.noActiveTurn }
                turn = resumed
            } else if value["op"] == .string("genericSteer") {
                turn = try await session.steer(value["input"] ?? .null, id: value["messageId"]?.string ?? UUID().uuidString)
            } else {
                turn = try await session.submit(value["input"] ?? .null, id: value["messageId"]?.string ?? UUID().uuidString)
            }
            let token = value["turnToken"]?.string ?? turn.id
            turns[token] = turn
            DriverOutput.emit(.object(["genericAccepted": .object(["token": .string(token), "id": .string(turn.id),
                "sessionId": .string(turn.sessionID), "isRepeated": .bool(turn.isRepeated)])]))
            deliveryAgents[token] = agentToken
            deliveries[token] = Task {
                do {
                    for try await event in turn {
                        DriverOutput.emit(.object(["genericEvent": event, "turnToken": .string(token)]))
                    }
                    let result = try await turn.result
                    DriverOutput.emit(.object(["genericCompleted": try self.encode(result), "turnToken": .string(token)]))
                } catch {
                    DriverOutput.emit(.object(["genericFailed": .object(["message": .string(String(describing: error))]), "turnToken": .string(token)]))
                }
                turns.removeValue(forKey: token)
                deliveries.removeValue(forKey: token)
                deliveryAgents.removeValue(forKey: token)
            }
            return .null
        case "genericCancel": try await session(value).cancel(); return .null
        case "genericTurnCancel":
            if let token = value["turnToken"]?.string { try await turns[token]?.cancel() }
            return .null
        case "genericCheckpoint": return .string(try await session(value).checkpoint().base64EncodedString())
        case "genericNextEvent":
            let session = try await session(value)
            guard let token = value["readToken"]?.string else { throw FxError.invalidInput("Missing read token") }
            let read = Task {
                var iterator = session.events(after: Int64(value["cursor"]?.integer ?? 0)).makeAsyncIterator()
                guard let entry = try await iterator.next() else { return JSONValue.null }
                var fields: [String: JSONValue] = ["cursor": .number(Double(entry.cursor)), "epoch": .number(Double(entry.epoch))]
                switch entry.event {
                case .started(let id, let sessionID, let input):
                    fields["type"] = .string("turn_start"); fields["messageId"] = .string(id)
                    fields["sessionId"] = .string(sessionID); fields["input"] = input
                case .resumed(let id, let sessionID):
                    fields["type"] = .string("turn_resume"); fields["messageId"] = .string(id); fields["sessionId"] = .string(sessionID)
                case .yielded(let id): fields["type"] = .string("turn_yield"); fields["messageId"] = .string(id)
                case .update(let id, let update):
                    guard case .object(let values) = update else { throw FxError.protocolViolation("Scripted fixture update must be an object") }
                    fields.merge(values) { _, new in new }; fields["messageId"] = .string(id)
                case .ended(let result):
                    if case .object(let values) = try encode(result) { fields.merge(values) { _, new in new } }
                    fields["type"] = .string("turn_end"); fields["messageId"] = .string(result.id)
                }
                return JSONValue.object(fields)
            }
            readers[token] = read
            readerAgents[token] = agentToken
            defer { readers.removeValue(forKey: token); readerAgents.removeValue(forKey: token) }
            return try await read.value
        case "genericReadCancel":
            if let token = value["readToken"]?.string { readers[token]?.cancel() }
            return .null
        case "genericClose":
            let ownedReaders = readers.filter { readerAgents[$0.key] == agentToken }.map(\.value)
            for read in ownedReaders { read.cancel() }
            for read in ownedReaders { _ = await read.result }
            try await agents[agentToken]?.close()
            for delivery in deliveries.filter({ deliveryAgents[$0.key] == agentToken }).map(\.value) { await delivery.value }
            agents.removeValue(forKey: agentToken)
            relays.removeValue(forKey: agentToken)
            if agents.isEmpty { try await store?.close(); store = nil; storePath = nil; router = nil }
            return .null
        default: throw FxError.invalidInput("Unknown generic fixture operation")
        }
    }

    private func session(_ value: JSONValue) async throws -> FxDurableSession<JSONValue, JSONValue> {
        guard let agent = agents[value["agentToken"]?.string ?? "default"], let id = value["sessionId"]?.string else { throw FxError.closed }
        let options = try value["options"].map { try JSONDecoder().decode(FxSessionOptions.self, from: JSONEncoder().encode($0)) } ?? .init()
        return try await agent.session(id: id, options: options)
    }

    private func encode(_ result: FxSessionResult) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(result))
    }
}
