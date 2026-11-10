import Foundation
import Testing
@testable import LibFx

private actor AppendedContexts {
    var values: [String] = []
    func receive(_ event: FxLifecycleEvent) {
        if case .contextAppended(let name, let text) = event { values.append((name ?? "anonymous") + ":" + text) }
    }
}
@Test func contextAppendEventsReportOnlyCommittedChangesAndNotRestoration() async throws {
    let events = AppendedContexts(), store = FxMemoryPersistence()
    var config = FxConfiguration(apiKey: "fixture", model: "swift/catalog", httpClient: CatalogHTTP(actions: []))
    config.onLifecycleEvent = { await events.receive($0) }
    let engine = try await FxEngine.open(configuration: config, persistence: store)
    try await engine.setContext(name: "memory", text: "one")
    try await engine.setContext(name: "memory", text: "one")
    try await engine.setContext(name: "memory", text: "two")
    try await engine.appendContext("handover")
    let before = await events.values
    #expect(before == ["memory:<system-reminder>\none\n</system-reminder>",
        "memory:<system-reminder>\ntwo\n</system-reminder>", "anonymous:<system-reminder>\nhandover\n</system-reminder>"])
    try await engine.close()
    let restored = try await FxEngine.open(configuration: config, persistence: store)
    try await restored.setContext(name: "memory", text: "two")
    #expect(await events.values == before)
    try await restored.close()
}
