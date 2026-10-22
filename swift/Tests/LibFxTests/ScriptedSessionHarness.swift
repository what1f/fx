import Foundation
import LibFx

// Public imports only. The independent package consumer also compiles this executor.
struct ScriptedSessionHarness: FxSessionHarness {
    let stepDuration: Duration
    init(stepDuration: Duration = .milliseconds(3)) { self.stepDuration = stepDuration }
    func validate(input: [FxPromptContent], options: FxSessionOptions) throws {
        guard input.allSatisfy({ if case .text = $0 { return true }; return false }) else {
            throw FxError.invalidInput("This executor accepts text")
        }
    }
    func prepareCheckpoint(_ data: Data, options: FxSessionOptions) throws -> Data {
        _ = try ScriptedHarnessSession.decode(data)
        return data
    }
    func open(_ context: FxHarnessContext) async throws -> any FxHarnessSession {
        try await ScriptedHarnessSession(context: context, stepDuration: stepDuration)
    }
}

private struct ScriptRecord: Codable {
    let id: String
    let text: String
    let step: Int
    let ended: Bool
}

private actor ScriptTurnControl {
    private(set) var handedOff = false
    func handoff() { handedOff = true }
}

private struct ScriptTurn: FxHarnessTurn {
    let events: AsyncThrowingStream<FxEvent, any Error>
    let completion: Task<FxTurnResult, any Error>
    let control: ScriptTurnControl
    var result: FxTurnResult { get async throws { try await completion.value } }
    func cancel() async { completion.cancel(); _ = await completion.result }
    func handoff() async throws {
        await control.handoff()
        completion.cancel()
        _ = await completion.result
    }
    func steer(_ text: String, id: String) async throws -> FxSteeringReceipt { throw FxError.noActiveTurn }
    func endForSteering() async throws { await cancel() }
}

private actor ScriptedHarnessSession: FxHarnessSession {
    let context: FxHarnessContext
    let stepDuration: Duration
    var records: [ScriptRecord]
    var head: String?
    var active: Task<FxTurnResult, any Error>?

    init(context: FxHarnessContext, stepDuration: Duration) async throws {
        self.context = context; self.stepDuration = stepDuration
        let snapshot = try await context.persistence.load()
        var records = try snapshot.checkpoint.map { try Self.decode($0.data) } ?? []
        for record in snapshot.journal { records.append(try JSONDecoder().decode(ScriptRecord.self, from: record.data)) }
        self.records = records; self.head = snapshot.head
    }
    static func decode(_ data: Data) throws -> [ScriptRecord] {
        let header = Data("SCRIPT1\n".utf8)
        guard data.starts(with: header) else { throw FxPersistenceError.invalidJournal }
        return try JSONDecoder().decode([ScriptRecord].self, from: data.dropFirst(header.count))
    }
    var recoveryState: FxRecoveryState? {
        guard let last = records.last, !last.ended else { return nil }
        return FxRecoveryState(turnID: last.id)
    }
    var completedTurnID: String? { records.last.flatMap { $0.ended ? $0.id : nil } }
    func prompt(_ content: [FxPromptContent], id: String, yieldAt: Date?) async throws -> any FxHarnessTurn {
        let text = content.compactMap { if case .text(let text) = $0 { return text }; return nil }.joined()
        try await append(ScriptRecord(id: id, text: text, step: 0, ended: false))
        return turn(id: id, text: text, yieldAt: yieldAt)
    }
    func resume(rerunning: Bool, yieldAt: Date?) throws -> (any FxHarnessTurn)? {
        guard let last = records.last, !last.ended else { return nil }
        return turn(id: last.id, text: last.text, yieldAt: yieldAt)
    }
    private func turn(id: String, text: String, yieldAt: Date?) -> ScriptTurn {
        let (events, continuation) = AsyncThrowingStream<FxEvent, any Error>.makeStream()
        let control = ScriptTurnControl()
        let task = Task {
            do {
                let result = try await self.run(id: id, text: text, yieldAt: yieldAt, control: control, events: continuation)
                continuation.finish()
                return result
            } catch { continuation.finish(throwing: error); throw error }
        }
        active = task
        return ScriptTurn(events: events, completion: task, control: control)
    }
    private func run(id: String, text: String, yieldAt: Date?, control: ScriptTurnControl,
                     events: AsyncThrowingStream<FxEvent, any Error>.Continuation) async throws -> FxTurnResult {
        var first = true
        do {
            let start = records.last?.step ?? 0
            for step in start..<3 {
                if !first, let yieldAt, Date() >= yieldAt { return FxTurnResult(stopReason: .yielded) }
                first = false
                try await Task.sleep(for: stepDuration)
                try await context.checkOwnership()
                try await append(ScriptRecord(id: id, text: text, step: step + 1, ended: step == 2))
                events.yield(.text("\(text)-\(step) "))
            }
            return FxTurnResult(stopReason: .endTurn)
        } catch is CancellationError {
            if !(await control.handedOff) {
                // Cancellation of work does not cancel the durable cleanup write.
                let last = records.last?.step ?? 0
                let cleanup = Task { try await self.append(ScriptRecord(id: id, text: text, step: last, ended: true)) }
                try await cleanup.value
            }
            return FxTurnResult(stopReason: .cancelled)
        }
    }
    private func append(_ record: ScriptRecord) async throws {
        head = try await context.persistence.append(expected: head, idempotencyKey: UUID().uuidString,
            data: JSONEncoder().encode(record), marks: [.progress("\(record.id):\(record.step)")], barrier: true)
        records.append(record)
    }
    func checkpoint() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return Data("SCRIPT1\n".utf8) + (try encoder.encode(records))
    }
    func saveCheckpoint() async throws {
        if let head { try await context.persistence.saveCheckpoint(FxStoredCheckpoint(through: head, data: checkpoint())) }
    }
    func close() async throws { if let active { _ = try await active.value } }
}
