import Foundation
import LibFx

// Public imports only: this fixture also runs in the independent package consumer.
struct CalculationInput: Codable, Sendable, Equatable {
    let values: [Int]
    let labels: [String: String]
    let attachment: Data
    init(values: [Int], labels: [String: String] = [:], attachment: Data = Data()) {
        self.values = values; self.labels = labels; self.attachment = attachment
    }
}

struct CalculationUpdate: Codable, Sendable, Equatable {
    let index: Int
    let total: Int
    let input: CalculationInput
}

struct CalculationHarness: FxDurableHarness {
    typealias Input = CalculationInput
    typealias Update = CalculationUpdate
    var delay: Duration = .milliseconds(3)
    var terminalFailure: FxSessionFailure?
    func validate(_ input: Input, options: FxSessionOptions) throws {
        guard !input.values.isEmpty, input.values.count <= 20 else { throw FxError.invalidInput("Supply 1 to 20 values") }
    }
    func prepareCheckpoint(_ data: Data, options: FxSessionOptions) throws -> Data {
        _ = try JSONDecoder().decode([CalculationRecord].self, from: data)
        return data
    }
    func open(_ context: FxHarnessContext) async throws -> any FxDurableHarnessSession<Input, Update> {
        try await CalculationSession(context: context, delay: delay, terminalFailure: terminalFailure)
    }
}

private struct CalculationRecord: Codable, Sendable {
    let id: String
    let input: CalculationInput
    let step: Int
    let ended: Bool
}

private actor CalculationControl {
    enum Mode: Sendable { case running, cancelled, yielded }
    var mode = Mode.running
    var result: FxTurnResult?
    var waiters: [CheckedContinuation<FxTurnResult, Never>] = []
    func stop(_ mode: Mode) { self.mode = mode }
    func finish(_ result: FxTurnResult) {
        guard self.result == nil else { return }
        self.result = result
        for waiter in waiters { waiter.resume(returning: result) }
        waiters.removeAll()
    }
    func value() async -> FxTurnResult {
        if let result { return result }
        return await withCheckedContinuation { waiters.append($0) }
    }
}

private struct CalculationTurn: FxDurableHarnessTurn {
    let events: AsyncThrowingStream<CalculationUpdate, any Error>
    let control: CalculationControl
    var result: FxTurnResult { get async { await control.value() } }
    func cancel() async { await control.stop(.cancelled) }
    func handoff() async { await control.stop(.yielded) }
    func endForSteering() async { await cancel() }
}

private actor CalculationSession: FxDurableHarnessSession {
    typealias Input = CalculationInput
    typealias Update = CalculationUpdate
    let context: FxHarnessContext
    let delay: Duration
    let terminalFailure: FxSessionFailure?
    var records: [CalculationRecord]
    var head: String?

    init(context: FxHarnessContext, delay: Duration, terminalFailure: FxSessionFailure?) async throws {
        self.context = context; self.delay = delay; self.terminalFailure = terminalFailure
        let snapshot = try await context.persistence.load()
        var records = try snapshot.checkpoint.map { try JSONDecoder().decode([CalculationRecord].self, from: $0.data) } ?? []
        for record in snapshot.journal { records.append(try JSONDecoder().decode(CalculationRecord.self, from: record.data)) }
        self.records = records; head = snapshot.head
    }
    var recoveryState: FxRecoveryState? {
        guard let last = records.last, !last.ended else { return nil }
        return FxRecoveryState(turnID: last.id)
    }
    var completedTurnID: String? { records.last.flatMap { $0.ended ? $0.id : nil } }

    func submit(_ input: Input, id: String, yieldAt: Date?) async throws -> any FxDurableHarnessTurn<Update> {
        try await append(CalculationRecord(id: id, input: input, step: 0, ended: false), marks: [.placed(id)])
        return turn(id: id, input: input, yieldAt: yieldAt)
    }
    func resume(rerunning: Bool, yieldAt: Date?) -> (any FxDurableHarnessTurn<Update>)? {
        guard let last = records.last, !last.ended else { return nil }
        return turn(id: last.id, input: last.input, yieldAt: yieldAt)
    }
    private func turn(id: String, input: Input, yieldAt: Date?) -> CalculationTurn {
        let control = CalculationControl()
        return CalculationTurn(events: AsyncThrowingStream(unfolding: {
            try await self.next(id: id, input: input, control: control, yieldAt: yieldAt)
        }), control: control)
    }
    private func next(id: String, input: Input, control: CalculationControl, yieldAt: Date?) async throws -> Update? {
        guard await control.result == nil else { return nil }
        try await Task.sleep(for: delay)
        let mode = await control.mode
        let step = records.last?.step ?? 0
        if mode == .cancelled {
            try await append(CalculationRecord(id: id, input: input, step: step, ended: true), marks: [])
            await control.finish(FxTurnResult(stopReason: .cancelled))
            return nil
        }
        if mode == .yielded || step > 0 && yieldAt.map({ Date() >= $0 }) == true {
            await control.finish(FxTurnResult(stopReason: .yielded))
            return nil
        }
        try await context.checkOwnership()
        let ended = step + 1 == input.values.count
        try await append(CalculationRecord(id: id, input: input, step: step + 1, ended: ended), marks: [.progress(String(step + 1))])
        if ended { await control.finish(FxTurnResult(stopReason: terminalFailure == nil ? .endTurn : .error, failure: terminalFailure)) }
        return Update(index: step, total: input.values.prefix(step + 1).reduce(0, +), input: input)
    }
    private func append(_ record: CalculationRecord, marks: [FxSessionJournalMark]) async throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(record)
        head = try await context.persistence.append(expected: head, idempotencyKey: UUID().uuidString, data: data, marks: marks, barrier: true)
        records.append(record)
    }
    func checkpoint() throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(records)
    }
    func saveCheckpoint() async throws {
        if let head { try await context.persistence.saveCheckpoint(FxStoredCheckpoint(through: head, data: checkpoint())) }
    }
    func close() {}
}
