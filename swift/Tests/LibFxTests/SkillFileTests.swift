import Foundation
import Testing
@testable import LibFx

@Test func skillFileParsesYAMLQuotesMultilineAndUnknownMetadata() throws {
    let skill = try FxSkill.parse("""
    ---
    name: 'review: focused'
    description: >-
      Review correctness
      before style.
    metadata:
      version: '1'
    ---

    Review the change.

    """, fallbackName: "fallback")
    #expect(skill.name == "review: focused")
    #expect(skill.description == "Review correctness before style.")
    #expect(skill.instructions == "Review the change.")
}

@Test(arguments: ["\n", "\r\n"])
func skillFileSupportsLineEndingsAndAnEOFDelimiter(newline: String) throws {
    for prefix in ["", "\u{FEFF}"] {
        let source = prefix + ["---", "name: review", "description: Brief", "---", "Body"].joined(separator: newline)
        let skill = try FxSkill.parse(source, fallbackName: "fallback")
        #expect(skill.name == "review")
        #expect(skill.instructions == "Body")
    }
    #expect(try FxSkill.parse(["---", "name: review", "---"].joined(separator: newline), fallbackName: "fallback").instructions.isEmpty)
}

@Test func skillFilePreservesPlainMarkdownAndUsesFilenameFallback() throws {
    let source = "  # Plain\r\n\r\nBody\r\n"
    let plain = try FxSkill.parse(source, fallbackName: "review")
    #expect(plain.name == "review")
    #expect(plain.description.isEmpty)
    #expect(plain.instructions == source)
    for yaml in ["", "description: Brief", "name: ''"] {
        let skill = try FxSkill.parse("---\n\(yaml)\n---\n body \n", fallbackName: "review")
        #expect(skill.name == "review")
        #expect(skill.instructions == "body")
    }
}

@Test func skillFileRejectsInvalidMetadataWithoutLeakingItsContents() throws {
    #expect(throws: FxSkillFileError.unterminatedFrontmatter) {
        try FxSkill.parse("---\nname: private-content", fallbackName: "fallback")
    }
    for yaml in ["name: [private-content", "- private-content", "name: {secret: private-content}", "name: first\nname: second"] {
        #expect(throws: FxSkillFileError.invalidMetadata) {
            try FxSkill.parse("---\n\(yaml)\n---\nbody", fallbackName: "fallback")
        }
    }
}

@Test func skillFileLoadsLocalUTF8WithHostResourcesAndOriginalTools() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("review.MD")
    try Data("---\ndescription: Read carefully\n---\n中文 instructions".utf8).write(to: url)
    let resource = FxSkill.Resource(uri: "memory://review", text: "Resource")
    let tool = FxTool(name: "lookup", description: "Lookup", inputSchema: .object([:]), isIdempotent: true) { _, context in
        FxToolResult(text: context.turnID)
    }
    let skill = try await FxSkill.load(from: url, resources: [resource], tools: [tool])
    #expect(skill.name == "review")
    #expect(skill.description == "Read carefully")
    #expect(skill.instructions == "中文 instructions")
    #expect(skill.resources == [resource])
    #expect(try await skill.tools[0].execute(.null, FxToolContext(executionID: "call", sessionID: "session", turnID: "turn")).text == "turn")
    let compiled = try FxSkills([skill])
    #expect(compiled.instructions.contains("中文 instructions"))
    #expect(compiled.instructions.contains("Resource"))
}

@Test func skillFileRejectsNonLocalURLsInvalidUTF8AndMissingFiles() async throws {
    await #expect(throws: FxSkillFileError.notFileURL) { try await FxSkill.load(from: URL(string: "https://example.com/SKILL.md")!) }
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".md")
    defer { try? FileManager.default.removeItem(at: url) }
    try Data([0xff, 0xfe, 0xfd]).write(to: url)
    await #expect(throws: FxSkillFileError.invalidUTF8) { try await FxSkill.load(from: url) }
    try FileManager.default.removeItem(at: url)
    await #expect(throws: CocoaError.self) { try await FxSkill.load(from: url) }
}

@Test func skillFileHonorsCancellationBeforeReading() async throws {
    let task = Task {
        withUnsafeCurrentTask { $0?.cancel() }
        return try await FxSkill.load(from: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
    }
    await #expect(throws: CancellationError.self) { try await task.value }
}
