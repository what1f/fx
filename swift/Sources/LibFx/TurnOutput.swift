import Foundation

/// One RPC producer and one iterator share a bounded queue. One indivisible event
/// may exceed the usual byte budget in an empty queue, up to the frame limit.
/// A suspended producer stops the RPC reader and preserves native pressure.
actor TurnOutput {
    struct State: Sendable {
        let bufferedBytes: Int
        let bufferedEvents: Int
        let waiting: Bool
    }
    static let byteLimit = 1024 * 1024
    static let eventLimit = 256
    private struct Entry { let event: FxEvent; let bytes: Int }
    private var entries: [Entry] = []
    private var bytes = 0
    private var ended = false
    private var error: (any Error)?
    private var reader: CheckedContinuation<FxEvent?, any Error>?
    private var producer: CheckedContinuation<Void, Never>?
    private let onCancel: @Sendable () async -> Void
    private let onPressure: @Sendable (State) async -> Void

    init(onCancel: @escaping @Sendable () async -> Void,
         onPressure: @escaping @Sendable (State) async -> Void = { _ in }) {
        self.onCancel = onCancel; self.onPressure = onPressure
    }
    var state: State { State(bufferedBytes: bytes, bufferedEvents: entries.count, waiting: producer != nil) }

    func send(_ event: FxEvent) async throws -> Bool {
        let size = try JSONEncoder().encode(event).count
        guard size <= 64 * 1024 * 1024 else { throw FxError.outputOverflow }
        var notified = false
        while !ended, reader == nil, !entries.isEmpty,
              entries.count >= Self.eventLimit || size > Self.byteLimit - bytes {
            guard producer == nil else { throw FxError.protocolViolation("Concurrent turn output producers") }
            if !notified {
                notified = true
                await onPressure(state)
                continue
            }
            await withCheckedContinuation { producer = $0 }
        }
        guard !ended else { return false }
        if let reader { self.reader = nil; reader.resume(returning: event) }
        else { entries.append(Entry(event: event, bytes: size)); bytes += size }
        return true
    }

    func next() async throws -> FxEvent? {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            if !entries.isEmpty {
                let entry = entries.removeFirst()
                bytes -= entry.bytes
                producer?.resume(); producer = nil
                return entry.event
            }
            if ended {
                if let error { throw error }
                return nil
            }
            guard reader == nil else { throw FxError.protocolViolation("Turn output already has a reader") }
            return try await withCheckedThrowingContinuation { reader = $0 }
        } onCancel: { Task { await self.cancelReader() } }
    }

    private func cancelReader() async {
        // The engine closes the queue first, preserving any known storage or
        // transport failure. Fall back to EOF if its turn is already inactive.
        await onCancel()
        finish(discarding: true)
    }

    func finish(throwing error: (any Error)? = nil, discarding: Bool = false) {
        guard !ended else { return }
        ended = true; self.error = error
        if discarding { entries.removeAll(); bytes = 0 }
        producer?.resume(); producer = nil
        if let reader {
            self.reader = nil
            if let error { reader.resume(throwing: error) }
            else { reader.resume(returning: nil) }
        }
    }
}
