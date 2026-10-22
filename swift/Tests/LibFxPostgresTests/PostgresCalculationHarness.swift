import Foundation
import LibFx

// A public-API executor. PostgreSQL stores these records as opaque bytes;
// scheduling, event persistence, retries and ownership remain in FxDurableAgent.
struct PostgresCalculationInput: Codable, Sendable, Equatable {
    let values: [Int]
    let label: String
    let attachment: Data
}
struct PostgresCalculationUpdate: Codable, Sendable, Equatable {
    let index: Int
    let total: Int
    let input: PostgresCalculationInput
}
actor PostgresCalculationGate {
    var open = false
    var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async { if open { return }; await withCheckedContinuation { waiters.append($0) } }
    func release() { open = true; let pending = waiters; waiters = []; for item in pending { item.resume() } }
}
actor PostgresCalculationCounts {
    var submits = 0, resumes = 0, updates = 0, cancellations = 0
    let held = PostgresCalculationGate(), release = PostgresCalculationGate(), cancelled = PostgresCalculationGate()
    func submitted() { submits += 1 }
    func resumed() { resumes += 1 }
    func updated() { updates += 1 }
    func cancelledTurn() async { cancellations += 1; await cancelled.release() }
}
struct PostgresCalculationHarness: FxDurableHarness {
    typealias Input = PostgresCalculationInput
    typealias Update = PostgresCalculationUpdate
    let counts: PostgresCalculationCounts
    var delay: Duration = .milliseconds(1)
    var holdAfterFirst = false
    func validate(_ input: Input, options: FxSessionOptions) throws {
        guard !input.values.isEmpty else { throw FxError.invalidInput("Values are required") }
    }
    func prepareCheckpoint(_ data: Data, options: FxSessionOptions) throws -> Data {
        _ = try JSONDecoder().decode([PostgresCalculationRecord].self, from: data)
        return data
    }
    func open(_ context: FxHarnessContext) async throws -> any FxDurableHarnessSession<Input, Update> {
        try await PostgresCalculationSession(context: context, harness: self)
    }
}
private struct PostgresCalculationRecord: Codable, Sendable {
    let id: String
    let input: PostgresCalculationInput
    let step: Int
    let ended: Bool
}
private actor PostgresCalculationControl {
    enum Mode { case running, yielded, cancelled }
    var mode = Mode.running
    var outcome: FxTurnResult?
    var waiters: [CheckedContinuation<FxTurnResult, Never>] = []
    func stop(_ mode: Mode) { self.mode = mode }
    func finish(_ outcome: FxTurnResult) {
        guard self.outcome == nil else { return }
        self.outcome = outcome
        for waiter in waiters { waiter.resume(returning: outcome) }
        waiters = []
    }
    func result() async -> FxTurnResult {
        if let outcome { return outcome }
        return await withCheckedContinuation { waiters.append($0) }
    }
}
private struct PostgresCalculationTurn: FxDurableHarnessTurn {
    let events: AsyncThrowingStream<PostgresCalculationUpdate, any Error>
    let control: PostgresCalculationControl
    let counts: PostgresCalculationCounts
    var result: FxTurnResult { get async { await control.result() } }
    func cancel() async { await control.stop(.cancelled); await counts.cancelledTurn() }
    func handoff() async { await control.stop(.yielded) }
    func endForSteering() async { await cancel() }
}
private actor PostgresCalculationSession: FxDurableHarnessSession {
    typealias Input = PostgresCalculationInput
    typealias Update = PostgresCalculationUpdate
    let context: FxHarnessContext
    let harness: PostgresCalculationHarness
    var records: [PostgresCalculationRecord]
    var head: String?
    init(context: FxHarnessContext, harness: PostgresCalculationHarness) async throws {
        self.context = context; self.harness = harness
        let snapshot = try await context.persistence.load()
        var restored = try snapshot.checkpoint.map { try JSONDecoder().decode([PostgresCalculationRecord].self, from: $0.data) } ?? []
        for row in snapshot.journal { restored.append(try JSONDecoder().decode(PostgresCalculationRecord.self, from: row.data)) }
        records = restored; head = snapshot.head
    }
    var recoveryState: FxRecoveryState? {
        records.last.flatMap { $0.ended ? nil : FxRecoveryState(turnID: $0.id) }
    }
    var completedTurnID: String? { records.last.flatMap { $0.ended ? $0.id : nil } }
    func submit(_ input: Input, id: String, yieldAt: Date?) async throws -> any FxDurableHarnessTurn<Update> {
        await harness.counts.submitted()
        try await append(.init(id: id, input: input, step: 0, ended: false), marks: [])
        return turn(id: id, input: input, yieldAt: yieldAt)
    }
    func resume(rerunning: Bool, yieldAt: Date?) async -> (any FxDurableHarnessTurn<Update>)? {
        guard let last = records.last, !last.ended else { return nil }
        await harness.counts.resumed()
        return turn(id: last.id, input: last.input, yieldAt: yieldAt)
    }
    private func turn(id: String, input: Input, yieldAt: Date?) -> PostgresCalculationTurn {
        let control = PostgresCalculationControl()
        return .init(events: AsyncThrowingStream(unfolding: {
            try await self.next(id: id, input: input, control: control, yieldAt: yieldAt)
        }), control: control, counts: harness.counts)
    }
    private func next(id: String, input: Input, control: PostgresCalculationControl, yieldAt: Date?) async throws -> Update? {
        guard await control.outcome == nil else { return nil }
        try await Task.sleep(for: harness.delay)
        let step = records.last?.step ?? 0
        if harness.holdAfterFirst && step == 1 {
            await harness.counts.held.release(); await harness.counts.release.wait()
        }
        switch await control.mode {
        case .cancelled:
            try await append(.init(id: id, input: input, step: step, ended: true), marks: [.completed(id)])
            try await saveCheckpoint()
            await control.finish(.init(stopReason: .cancelled)); return nil
        case .yielded:
            await control.finish(.init(stopReason: .yielded)); return nil
        case .running: break
        }
        if step > 0 && yieldAt.map({ Date() >= $0 }) == true {
            await control.finish(.init(stopReason: .yielded)); return nil
        }
        try await context.checkOwnership()
        let ended = step + 1 == input.values.count
        var marks: [FxSessionJournalMark] = [.progress(String(step + 1))]
        if ended { marks.append(.completed(id)) }
        try await append(.init(id: id, input: input, step: step + 1, ended: ended), marks: marks)
        await harness.counts.updated()
        if ended { try await saveCheckpoint(); await control.finish(.init(stopReason: .endTurn)) }
        return .init(index: step, total: input.values.prefix(step + 1).reduce(0, +), input: input)
    }
    private func append(_ record: PostgresCalculationRecord, marks: [FxSessionJournalMark]) async throws {
        head = try await context.persistence.append(expected: head, idempotencyKey: UUID().uuidString,
            data: JSONEncoder().encode(record), marks: marks, barrier: true)
        records.append(record)
    }
    func checkpoint() throws -> Data { try JSONEncoder().encode(records) }
    func saveCheckpoint() async throws {
        if let head { try await context.persistence.saveCheckpoint(.init(through: head, data: checkpoint())) }
    }
    func close() {}
}
