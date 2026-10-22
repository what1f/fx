import Foundation
import LibFx

// Test transport for host input callbacks. Swift owns scopes, spans, cancellation and bounds.
actor InputObservationRelay {
    private enum FixtureErrors {
        struct Error: Swift.Error {}
        struct TimeoutError: Swift.Error {}
        struct AbortError: Swift.Error {}
    }
    private let emit: @Sendable (JSONValue) -> Void
    private var scopes: [Int: FxToolObservation] = [:]
    private var tasks: [String: (tool: Int, task: Task<Void, any Error>)] = [:]
    private var waiters: [String: CheckedContinuation<FxWaitResolution, any Error>] = [:]
    private var closed = false

    init(emit: @escaping @Sendable (JSONValue) -> Void) { self.emit = emit }

    func register(_ id: Int, scope: FxToolObservation?) throws -> JSONValue? {
        guard !closed, let scope, let parent = scope.childOptions().parent else { return nil }
        scopes[id] = scope
        return .object(["scope": try encodeObservation(scope.scope),
                        "captureContent": .bool(scope.childOptions().captureContent), "parent": .object([
            "rootSessionId": .string(parent.rootSessionID), "sessionId": .string(parent.sessionID),
            "turnId": .string(parent.turnID), "callId": .string(parent.callID),
        ])])
    }

    func observe(tool: Int, token: String, descriptor: JSONValue) async throws {
        guard !closed, let scope = scopes[tool] else { throw FxError.closed }
        guard tasks[token] == nil else { throw FxError.invalidInput("Duplicate input wait") }
        let request = try Self.request(descriptor)
        let task = Task { () throws -> Void in
            _ = try await scope.wait(request, resolution: { $0 }, failure: { error in
                if error is FixtureErrors.TimeoutError { return .timedOut }
                if error is FixtureErrors.AbortError { return .cancelled }
                return .failed
            }) { try await self.effect(token) }
        }
        tasks[token] = (tool, task)
        defer { tasks.removeValue(forKey: token) }
        try await task.value
    }

    private func effect(_ token: String) async throws -> FxWaitResolution {
        guard !closed else { throw FxError.closed }
        return try await withCheckedThrowingContinuation { waiter in
            waiters[token] = waiter
            emit(.object(["inputEffect": .string(token)]))
        }
    }

    func resolve(_ token: String, value: JSONValue, errorName: String?) {
        guard let waiter = waiters.removeValue(forKey: token) else { return }
        if let errorName {
            switch errorName {
            case "TimeoutError": waiter.resume(throwing: FixtureErrors.TimeoutError())
            case "AbortError": waiter.resume(throwing: FixtureErrors.AbortError())
            default: waiter.resume(throwing: FixtureErrors.Error())
            }
            return
        }
        do {
            guard let outcome = FxWaitResolution.Outcome(rawValue: value["outcome"]?.string ?? "accepted") else {
                throw FxError.invalidInput("Invalid input wait outcome")
            }
            let answers: [String]
            if case .array(let values) = value["answers"] {
                answers = try values.map { entry in
                    guard let text = entry.string else { throw FxError.invalidInput("Invalid input wait answer") }
                    return text
                }
            } else { answers = [] }
            waiter.resume(returning: FxWaitResolution(outcome: outcome, answers: answers))
        } catch { waiter.resume(throwing: error) }
    }

    func cancel(tool: Int) {
        for entry in tasks.values where entry.tool == tool { entry.task.cancel() }
    }

    func close() async {
        closed = true
        let running = tasks.values.map(\.task)
        for task in running { task.cancel() }
        for waiter in waiters.values { waiter.resume(throwing: FxError.closed) }
        waiters.removeAll()
        for task in running { _ = await task.result }
        scopes.removeAll()
    }

    private static func request(_ value: JSONValue) throws -> FxWaitRequest {
        guard let raw = value["kind"]?.string, let kind = FxWaitRequest.Kind(rawValue: raw) else {
            throw FxError.invalidInput("wait needs an input request and an effect")
        }
        let questions: [FxWaitRequest.Question]
        if case .array(let values) = value["questions"] {
            questions = try values.map { question in
                guard let text = question["question"]?.string else { throw FxError.invalidInput("Invalid input question") }
                let options: [FxWaitRequest.Option]
                if case .array(let values) = question["options"] {
                    options = try values.map { option in
                        guard let label = option["label"]?.string else { throw FxError.invalidInput("Invalid input option") }
                        return .init(label: label, description: option["description"]?.string)
                    }
                } else { options = [] }
                return .init(text, options: options)
            }
        } else { questions = [] }
        return FxWaitRequest(kind: kind, externalID: value["externalId"]?.string, server: value["server"]?.string,
                             schemaJSON: value["schemaJson"]?.string, prompt: value["prompt"]?.string, questions: questions)
    }
}
