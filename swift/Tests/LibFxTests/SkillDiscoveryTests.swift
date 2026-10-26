import Foundation
import Testing
import LibFx

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

@Test(arguments: [FxCustomProvider.APIProtocol.responses, .chatCompletions, .anthropicMessages])
func skillRequestsRefreshAddEditDeleteWithoutDuplicatingSystemSections(api: FxCustomProvider.APIProtocol) throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let discovery = FxSkillDiscovery(roots: [root])
    try writeSkill(root, "sample/SKILL.md", "---\nname: sample\ndescription: First description\n---\nBODY_ONLY")
    let first = discovery.discover().skills[0].revision
    var request = URLRequest(url: URL(string: "https://fixture.invalid")!)
    let body: [String: Any] = switch api {
    case .responses: ["instructions": "Stable prefix", "input": [["role": "user", "content": "Question"]]]
    case .chatCompletions: ["messages": [["role": "system", "content": "Stable prefix"], ["role": "user", "content": "Question"]]]
    case .anthropicMessages: ["system": [["type": "text", "text": "Stable prefix"]], "messages": [["role": "user", "content": "Question"]]]
    }
    request.httpBody = try JSONSerialization.data(withJSONObject: body)
    request = try discovery.prepare(request, api: api)
    let initial = String(decoding: request.httpBody!, as: UTF8.self)
    #expect(initial.contains("First description") && !initial.contains("BODY_ONLY"))
    try writeSkill(root, "sample/SKILL.md", "---\nname: sample\ndescription: Updated description\n---\nnew body")
    #expect(discovery.discover().skills[0].revision != first)
    request = try discovery.prepare(request, api: api)
    let updated = String(decoding: request.httpBody!, as: UTF8.self)
    #expect(updated.contains("Updated description") && !updated.contains("First description"))
    #expect(updated.components(separatedBy: "<available_skills>").count == 2)
    try FileManager.default.removeItem(at: root.appendingPathComponent("sample"))
    request = try discovery.prepare(request, api: api)
    let removed = String(decoding: request.httpBody!, as: UTF8.self)
    #expect(!removed.contains("Updated description") && removed.contains("Stable prefix") && removed.contains("Question"))
}
