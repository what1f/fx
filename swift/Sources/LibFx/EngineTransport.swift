import Foundation

// Package-only injection keeps protocol fixtures on the production engine path.
package protocol EngineTransport: CoreTransport {
    func start() async throws
    func setContext(sessionID: String, modelID: String) async
    func beginTurn() async
    func putAttachment(_ data: Data, id: UInt32) async throws
    func takeAttachment(id: UInt32) async throws -> Data
    func discardAttachments() async
    func abortEffects() async
}
