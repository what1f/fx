import Foundation
import Testing
@testable import LibFx

@Test func skillsPreserveOrderedContentAndEscapeAttributes() throws {
    let skills = try FxSkills([
        FxSkill(name: "one&\"<", description: "Use this", instructions: "First\nline",
                resources: [.init(uri: "memory://x&\"<", text: "Resource\nbody")]),
        FxSkill(name: "two", instructions: "Second"),
    ])
    #expect(skills.instructions == """
    <skill name="one&amp;&quot;&lt;">
    <description>Use this</description>
    First
    line
    <resource uri="memory://x&amp;&quot;&lt;">
    Resource
    body
    </resource>
    </skill>

    <skill name="two">
    Second
    </skill>
    """)
    #expect(try FxSkills([]).instructions.isEmpty)
    #expect(skills.tools.isEmpty)
}

@Test func skillsRejectDuplicateNamesAndTooManyRecords() throws {
    #expect(throws: FxSkillError.duplicateName("one")) {
        try FxSkills([FxSkill(name: "one", instructions: ""), FxSkill(name: "one", instructions: "")])
    }
    #expect(try FxSkills((0..<64).map { FxSkill(name: String($0), instructions: "") }).tools.isEmpty)
    #expect(throws: FxSkillError.tooManySkills) {
        try FxSkills((0..<65).map { FxSkill(name: String($0), instructions: "") })
    }
}

@Test(arguments: [-1, 0, 1])
func skillsLimitIncludesUTF8ResourcesAndSectionFraming(extra: Int) throws {
    let empty = try FxSkills([FxSkill(name: "中", instructions: "", resources: [.init(uri: "memory://😀", text: "")])])
    let size = 64 * 1024 - empty.instructions.utf8.count + extra
    let skill = FxSkill(name: "中", instructions: "", resources: [.init(uri: "memory://😀", text: String(repeating: "x", count: size))])
    if extra <= 0 { #expect(try FxSkills([skill]).instructions.utf8.count == 64 * 1024 + extra) }
    else { #expect(throws: FxSkillError.instructionsTooLarge) { try FxSkills([skill]) } }
    let first = try FxSkills([FxSkill(name: "a", instructions: "x")]).instructions
    #expect(throws: FxSkillError.instructionsTooLarge) {
        try FxSkills([FxSkill(name: "a", instructions: String(repeating: "x", count: 64 * 1024 - first.utf8.count + 1)),
                      FxSkill(name: "b", instructions: "")])
    }
}

@Test func skillsKeepOriginalToolClosuresAndDescriptors() async throws {
    let tool = FxTool(name: "lookup", description: "Look up", inputSchema: .object(["type": .string("object")]), isIdempotent: true) { _, context in
        FxToolResult(text: "original:\(context.turnID)")
    }
    let skills = try FxSkills([FxSkill(name: "one", instructions: "", tools: [tool]),
                               FxSkill(name: "two", instructions: "", tools: [tool])])
    #expect(skills.tools.map(\.name) == ["lookup", "lookup"])
    #expect(skills.tools.first?.descriptor == tool.descriptor)
    // Tool-name admission remains the engine's responsibility, as with direct configuration.
    #expect(skills.tools.first?.isIdempotent == true)
    let result = try await skills.tools[0].execute(.object([:]), FxToolContext(executionID: "call", sessionID: "session", turnID: "turn"))
    #expect(result == FxToolResult(text: "original:turn"))
}
