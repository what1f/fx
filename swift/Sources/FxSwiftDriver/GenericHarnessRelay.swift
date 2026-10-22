import Foundation
import LibFx

/// Test-only callback transport. Scheduling and storage remain in LibFx.
actor GenericHarnessRelay {
    let agentToken: String
    init(agentToken: String) { self.agentToken = agentToken }
    private var waiters: [String: CheckedContinuation<JSONValue, any Error>] = [:]
    private var contexts: [String: FxHarnessContext] = [:]

    func call(_ method: String, _ arguments: [String: JSONValue] = [:]) async throws -> JSONValue {
        let token = UUID().uuidString
        return try await withCheckedThrowingContinuation { waiter in
            waiters[token] = waiter
            DriverOutput.emit(.object(["genericCallback": .object(arguments.merging([
                "token": .string(token), "method": .string(method), "agentToken": .string(agentToken),
            ]) { _, new in new })]))
        }
    }

    func respond(_ value: JSONValue) {
        guard let token = value["token"]?.string, let waiter = waiters.removeValue(forKey: token) else { return }
        if let error = value["error"] {
            let message = error["message"]?.string ?? "Harness callback failed"
            if error["code"] == .string("FX_HARNESS_STOPPED") { waiter.resume(throwing: FxHarnessError.stopped(message)) }
            else { waiter.resume(throwing: FxSessionFailure(message: message, name: error["name"]?.string ?? "Error", code: error["code"])) }
        } else { waiter.resume(returning: value["value"] ?? .null) }
    }

    func open(_ context: FxHarnessContext) async throws -> String {
        let id = UUID().uuidString
        contexts[id] = context
        do {
            _ = try await call("open", ["handle": .string(id), "sessionId": .string(context.sessionID),
                "inputId": context.inputID.map(JSONValue.string) ?? .null,
                "options": try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(context.options))])
            return id
        } catch { contexts.removeValue(forKey: id); throw error }
    }

    func persistence(_ value: JSONValue) async throws -> JSONValue {
        guard let id = value["handle"]?.string, let context = contexts[id] else { throw FxError.closed }
        let store = context.persistence
        switch value["method"]?.string {
        case "load":
            let snapshot = try await store.load()
            return .object(["head": snapshot.head.map(JSONValue.string) ?? .null,
                "checkpoint": snapshot.checkpoint.map { .object(["through": .string($0.through), "data": .string($0.data.base64EncodedString())]) } ?? .null,
                "journal": .array(snapshot.journal.map { .object(["cursor": .string($0.cursor), "data": .string($0.data.base64EncodedString())]) })])
        case "append":
            guard let key = value["key"]?.string, let encoded = value["data"]?.string, let data = Data(base64Encoded: encoded) else {
                throw FxError.invalidInput("Invalid harness journal append")
            }
            var marks: [FxSessionJournalMark] = []
            if case .array(let values) = value["marks"] {
                for mark in values {
                    if let start = mark["start"]?.string { marks.append(.placed(FxSessionInput.runtimeID(for: start))) }
                    if let progress = mark["progress"]?.string { marks.append(.progress(progress)) }
                }
            }
            return .string(try await store.append(expected: value["expected"]?.string, idempotencyKey: key,
                data: data, marks: marks, barrier: value["barrier"] != .bool(false)))
        case "checkpoint":
            guard let through = value["through"]?.string, let encoded = value["data"]?.string,
                  let data = Data(base64Encoded: encoded) else { throw FxError.invalidInput("Invalid harness checkpoint") }
            try await store.saveCheckpoint(.init(through: through, data: data))
            return .null
        case "ownership": try await context.checkOwnership(); return .null
        default: throw FxError.invalidInput("Unknown harness persistence method")
        }
    }

    func state(_ handle: String) async -> JSONValue {
        do { return try await call("state", ["handle": .string(handle)]) }
        catch {
            DriverOutput.emit(.object(["genericFatal": .string(String(describing: error))]))
            return .null
        }
    }
}

struct RelayedGenericHarness: FxDurableHarness {
    typealias Input = JSONValue
    typealias Update = JSONValue
    let relay: GenericHarnessRelay
    func prepareCheckpoint(_ data: Data, options: FxSessionOptions) async throws -> Data {
        throw FxError.invalidInput("Generic fixture checkpoint import is not supported")
    }
    func open(_ context: FxHarnessContext) async throws -> any FxDurableHarnessSession<JSONValue, JSONValue> {
        RelayedGenericSession(relay: relay, handle: try await relay.open(context), inputID: context.inputID)
    }
}

struct RelayedGenericSession: FxDurableHarnessSession {
    typealias Input = JSONValue
    typealias Update = JSONValue
    let relay: GenericHarnessRelay
    let handle: String
    let inputID: String?
    var recoveryState: FxRecoveryState? {
        get async {
            guard let id = await relay.state(handle)["openTurn"]?["id"]?.string else { return nil }
            return FxRecoveryState(turnID: FxSessionInput.runtimeID(for: id))
        }
    }
    var completedTurnID: String? {
        get async { await relay.state(handle)["completedTurnId"]?.string.map { FxSessionInput.runtimeID(for: $0) } }
    }
    func submit(_ input: JSONValue, id: String, yieldAt: Date?) async throws -> any FxDurableHarnessTurn<JSONValue> {
        let response = try await relay.call("prompt", ["handle": .string(handle), "input": input,
            "turnId": .string(inputID ?? id), "yieldAt": yieldAt.map { .number($0.timeIntervalSince1970 * 1000) } ?? .null])
        return try turn(response)
    }
    func resume(rerunning: Bool, yieldAt: Date?) async throws -> (any FxDurableHarnessTurn<JSONValue>)? {
        let response = try await relay.call("resume", ["handle": .string(handle), "rerunning": .bool(rerunning),
            "yieldAt": yieldAt.map { .number($0.timeIntervalSince1970 * 1000) } ?? .null])
        return response == .null ? nil : try turn(response)
    }
    private func turn(_ response: JSONValue) throws -> RelayedGenericTurn {
        guard let id = response["turn"]?.string else { throw FxError.protocolViolation("Invalid harness turn handle") }
        return RelayedGenericTurn(relay: relay, handle: id)
    }
    func saveCheckpoint() async throws { _ = try await relay.call("saveCheckpoint", ["handle": .string(handle)]) }
    func checkpoint() async throws -> Data {
        let response = try await relay.call("checkpoint", ["handle": .string(handle)])
        guard let encoded = response.string, let data = Data(base64Encoded: encoded) else { throw FxPersistenceError.invalidJournal }
        return data
    }
    func close() async throws { _ = try await relay.call("close", ["handle": .string(handle)]) }
}

struct RelayedGenericTurn: FxDurableHarnessTurn {
    typealias Update = JSONValue
    let relay: GenericHarnessRelay
    let handle: String
    var events: AsyncThrowingStream<JSONValue, any Error> {
        AsyncThrowingStream(unfolding: {
            let next = try await relay.call("turnNext", ["handle": .string(handle)])
            return next["done"] == .bool(true) ? nil : next["value"] ?? .null
        })
    }
    var result: FxTurnResult {
        get async throws {
            let response = try await relay.call("turnResult", ["handle": .string(handle)])
            guard let reason = response["stopReason"]?.string.flatMap(FxTurnResult.StopReason.init(rawValue:)) else {
                throw FxError.protocolViolation("Invalid harness turn result")
            }
            let failure = try response["error"].flatMap { value -> FxSessionFailure? in
                guard value != .null else { return nil }
                return try JSONDecoder().decode(FxSessionFailure.self, from: JSONEncoder().encode(value))
            }
            let usage = try response["usage"].flatMap { value -> FxUsage? in
                guard value != .null else { return nil }
                return try JSONDecoder().decode(FxUsage.self, from: JSONEncoder().encode(value))
            }
            return FxTurnResult(stopReason: reason, usage: usage ?? .init(), failure: failure)
        }
    }
    func cancel() async { _ = try? await relay.call("turnCancel", ["handle": .string(handle)]) }
    func handoff() async throws { _ = try await relay.call("turnHandoff", ["handle": .string(handle)]) }
    func endForSteering() async throws { _ = try await relay.call("turnCancel", ["handle": .string(handle)]) }
}
