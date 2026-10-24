import Testing
@testable import LibFx

@Suite struct CompactionTests {
    @Test(.timeLimit(.minutes(1))) func nativeAutomaticCompactionPersistsAndContinues() async throws {
        let proof = try await runCompactionProbe()
        #expect(proof.summaryRequests > 0)
        #expect(proof.replacementRecords > 0)
        #expect(proof.afterBytes < proof.beforeBytes)
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
