import Foundation
import LibFx

actor GenericHarnessDriver {
    private let relay = GenericHarnessRelay()
    private var agent: FxDurableAgent<JSONValue, JSONValue>?
    private var store: FxSessionStore?
    private var turns: [String: FxDurableTurn<JSONValue>] = [:]
    private var deliveries: [String: Task<Void, Never>] = [:]
    private var readers: [String: Task<JSONValue, any Error>] = [:]

    func run(_ value: JSONValue) async throws -> JSONValue {
        switch value["op"]?.string {
        case "genericCallbackResult": await relay.respond(value); return .null
        case "genericPersistence": return try await relay.persistence(value)
        case "genericOpen":
            let options = value["options"] ?? .null
            let storage = try FxSessionStore(url: options["sessionStorePath"]?.string.map { URL(fileURLWithPath: $0) })
            store = storage
            let policy = try options["maximumDurationMs"]?.integer.map {
                try FxDeliveryPolicy(maximumDuration: .milliseconds($0), reserve: .milliseconds(options["reserveMs"]?.integer ?? 0))
            }
            agent = try FxDurableAgent(harness: RelayedGenericHarness(relay: relay), name: options["name"]?.string ?? "default",
                store: storage, checkpointAfterBytes: nil, deliveryPolicy: policy,
                onLifecycleEvent: { event in DriverOutput.emit(.object(["genericDiagnostic": encodeLifecycleEvent(event)])) })
            return .null
        case "genericPrompt", "genericResume":
            let session = try await session(value)
            let turn: FxDurableTurn<JSONValue>
            if value["op"] == .string("genericResume") {
                guard let resumed = try await session.resume() else { throw FxError.noActiveTurn }
                turn = resumed
            } else {
                turn = try await session.submit(value["input"] ?? .null, id: value["messageId"]?.string ?? UUID().uuidString)
            }
            let token = value["turnToken"]?.string ?? turn.id
            turns[token] = turn
            DriverOutput.emit(.object(["genericAccepted": .object(["token": .string(token), "id": .string(turn.id),
                "sessionId": .string(turn.sessionID), "isRepeated": .bool(turn.isRepeated)])]))
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
            defer { readers.removeValue(forKey: token) }
            return try await read.value
        case "genericReadCancel":
            if let token = value["readToken"]?.string { readers[token]?.cancel() }
            return .null
        case "genericClose":
            for read in readers.values { read.cancel() }
            for read in Array(readers.values) { _ = await read.result }
            try await agent?.close(); agent = nil
            for delivery in Array(deliveries.values) { await delivery.value }
            try await store?.close(); store = nil
            return .null
        default: throw FxError.invalidInput("Unknown generic fixture operation")
        }
    }

    private func session(_ value: JSONValue) async throws -> FxDurableSession<JSONValue, JSONValue> {
        guard let agent, let id = value["sessionId"]?.string else { throw FxError.closed }
        let options = try value["options"].map { try JSONDecoder().decode(FxSessionOptions.self, from: JSONEncoder().encode($0)) } ?? .init()
        return try await agent.session(id: id, options: options)
    }

    private func encode(_ result: FxSessionResult) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(result))
    }
}
