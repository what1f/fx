import Testing

@Suite struct CompactionTests {
    @Test(.timeLimit(.minutes(1))) func nativeAutomaticCompactionPersistsAndContinues() async throws {
        let proof = try await runCompactionProbe()
        #expect(proof.summaryRequests > 0)
        #expect(proof.replacementRecords > 0)
        #expect(proof.afterBytes < proof.beforeBytes)
    }
}
