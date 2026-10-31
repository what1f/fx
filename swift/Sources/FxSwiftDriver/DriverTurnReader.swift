import Foundation
import LibFx

// One JavaScript pull transfers exclusive access to the actual Swift iterator.
// There is no forwarding task or second event queue at this boundary.
final class DriverTurnReader: @unchecked Sendable {
    private let lock = NSLock()
    private var iterator: FxTurn.AsyncIterator?

    init(_ turn: FxTurn) { iterator = turn.makeAsyncIterator() }

    func next() async throws -> FxEvent? {
        var iterator = try lock.withLock {
            guard let iterator = self.iterator else {
                throw FxError.protocolViolation("Concurrent turn iteration")
            }
            self.iterator = nil
            return iterator
        }
        defer { lock.withLock { self.iterator = iterator } }
        return try await iterator.next()
    }
}
