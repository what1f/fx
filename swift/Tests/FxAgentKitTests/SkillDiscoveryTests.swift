import Foundation
import Testing
import FxAgentKit

private func writeSkill(_ root: URL, _ path: String, _ text: String) throws {
    let file = root.appendingPathComponent(path)
    try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    try text.write(to: file, atomically: true, encoding: .utf8)
}

@Test func discoveryUsesYAMLMetadataAndHandlesDuplicatesInvalidFilesAndCycles() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try writeSkill(root, "a/SKILL.md", "---\nname: example\ndescription: >-\n  Read & write\n  records\n---\nBODY_ONLY")
    try writeSkill(root, "b/SKILL.md", "---\nname: example\ndescription: duplicate\n---\nother")
    try writeSkill(root, "c/SKILL.md", "---\nname: hidden\ndescription: Explicit only\ndisable-model-invocation: true\n---\nhidden")
    try writeSkill(root, "d/SKILL.md", "---\nname: invalid\n---\nmissing description")
    try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("loop"), withDestinationURL: root)
    let catalog = FxSkillDiscovery(roots: [root]).discover()
    #expect(catalog.skills.map(\.name) == ["example", "hidden"])
    #expect(catalog.diagnostics.count == 2)
    #expect(catalog.prompt.contains("Read &amp; write records"))
    #expect(!catalog.prompt.contains("BODY_ONLY") && !catalog.prompt.contains("Explicit only"))
}


private enum WatchFailure: Error { case timeout }
private func catalogMatching(_ service: FxSkillCatalog, _ predicate: @escaping @Sendable (FxSkillDiscovery.Catalog) -> Bool) async throws -> FxSkillDiscovery.Catalog {
    try await withThrowingTaskGroup(of: FxSkillDiscovery.Catalog.self) { group in
        group.addTask {
            for await catalog in service.updates { if predicate(catalog) { return catalog } }
            throw WatchFailure.timeout
        }
        group.addTask { try await Task.sleep(for: .seconds(10)); throw WatchFailure.timeout }
        defer { group.cancelAll() }
        return try await group.next()!
    }
}

@Test func skillWatcherDetectsCreationAtomicEditsRemovalAndExternalSymlinks() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let skills = root.appendingPathComponent("workspace/.dora/skills")
    let service = try await FxSkillCatalog.open(roots: [skills])
    #expect(await service.current().skills.isEmpty)
    try writeSkill(skills, "sample/SKILL.md", "---\nname: sample\ndescription: Original\n---\nBody")
    let first = try await catalogMatching(service) { $0.skills.first?.description == "Original" }
    try writeSkill(skills, "sample/SKILL.md", "---\nname: sample\ndescription: Edited\n---\nBody")
    let edited = try await catalogMatching(service) { $0.skills.first?.description == "Edited" }
    #expect(first.skills.first?.revision != edited.skills.first?.revision)
    try FileManager.default.removeItem(at: skills)
    _ = try await catalogMatching(service) { $0.skills.isEmpty }
    try writeSkill(skills, "restored/SKILL.md", "---\nname: restored\ndescription: Restored\n---\nBody")
    _ = try await catalogMatching(service) { $0.skills.first?.name == "restored" }
    let external = root.appendingPathComponent("external")
    try writeSkill(external, "linked/SKILL.md", "---\nname: linked\ndescription: External\n---\nBody")
    try FileManager.default.createSymbolicLink(at: skills.appendingPathComponent("linked"), withDestinationURL: external.appendingPathComponent("linked"))
    _ = try await catalogMatching(service) { $0.skills.contains { $0.name == "linked" } }
    try writeSkill(external, "linked/SKILL.md", "---\nname: linked\ndescription: External edited\n---\nBody")
    _ = try await catalogMatching(service) { $0.skills.contains { $0.description == "External edited" } }
    await service.close()
    #expect(await service.current().skills.count == 2)
}
