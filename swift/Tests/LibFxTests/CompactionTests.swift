import Foundation
import Testing
@testable import LibFx

@Suite struct CompactionTests {
    @Test(.timeLimit(.minutes(1))) func nativeAutomaticCompactionPersistsAndContinues() async throws {
        let proof = try await runCompactionProbe()
        #expect(proof.summaryRequests > 0)
        #expect(proof.replacementRecords > 0)
        #expect(proof.afterBytes < proof.beforeBytes)
        var pending: String?
        var ids: Set<String> = []
        var completed = 0
        for event in proof.events {
            if case .compaction(let id, let state) = event {
                #expect(try JSONDecoder().decode(FxEvent.self, from: JSONEncoder().encode(event)) == event)
                if state == .started {
                    #expect(pending == nil)
                    #expect(ids.insert(id).inserted)
                    pending = id
                } else {
                    #expect(state == .completed)
                    #expect(pending == id)
                    pending = nil; completed += 1
                }
            } else if case .text = event { #expect(pending == nil) }
        }
        #expect(pending == nil)
        #expect(completed == proof.summaryRequests)
    }
}

@Test func compactionConfigurationValidatesAndSerializes() throws {
    var config = FxConfiguration(apiKey: "fixture")
    #expect(try config.nativeOptions["autoCompact"] == nil)
    config.autoCompaction = .tokens(131072)
    #expect(try config.nativeOptions["autoCompact"] == .object(["tokens": .number(131072)]))
    for value in [10, 80] {
        config.autoCompaction = .percent(value)
        #expect(try config.nativeOptions["autoCompact"] == .object(["percent": .number(Double(value))]))
    }
    for trigger: FxAutoCompaction in [.percent(9), .percent(81), .tokens(0), .tokens(-1), .tokens(Int.max)] {
        config.autoCompaction = trigger
        #expect(throws: FxError.self) { _ = try config.nativeOptions }
    }
}

@Test(.timeLimit(.minutes(1))) func nativeTokenCompactionRunsBeforeDefaultWindowTrigger() async throws {
    let token = try await runCompactionProbe(trigger: .tokens(3000))
    let percent = try await runCompactionProbe(trigger: .percent(80))
    #expect(token.summaryRequests > 0)
    #expect(token.replacementRecords > 0)
    #expect(token.beforeBytes < percent.beforeBytes)
    #expect(token.afterBytes < token.beforeBytes)
}

@Test(.timeLimit(.minutes(1))) func failedAutomaticCompactionEndsItsEventPair() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let provider = try FxCustomProvider(name: "compactionfixture", baseURL: URL(string: "https://compaction.example/v1")!,
        models: ["small": .init(contextWindow: 8192, maxOutputTokens: 1024)])
    let http = CompactionHTTP(failSummary: true)
    let lookup = FxTool(name: "fixture_lookup", description: "Look up the project code", inputSchema: .object(["type": .string("object")]),
        isIdempotent: true) { _, _ in "Project code: alpha42" }
    var config = FxConfiguration(provider: .custom(provider), model: "small", tools: [lookup], workspace: root, httpClient: http)
    config.autoCompaction = .tokens(3000)
    let engine = try await FxEngine.open(configuration: config)
    var compacted: [(String, FxCompactionState)] = []
    do {
        for index in 0..<16 {
            let turn = try await engine.prompt("Turn \(index). Give the next fixture reply.")
            for try await event in turn {
                if case .compaction(let id, let state) = event { compacted.append((id, state)) }
            }
            _ = try await turn.result
            if index == 0 { #expect(compacted.isEmpty) }
            if !compacted.isEmpty { break }
        }
    } catch { #expect(!compacted.isEmpty) }
    #expect(compacted.count == 2)
    if compacted.count == 2 {
        #expect(compacted[0].0 == compacted[1].0)
        #expect(compacted[0].1 == .started)
        #expect(compacted[1].1 == .failed)
    }
    try await engine.close()
}
