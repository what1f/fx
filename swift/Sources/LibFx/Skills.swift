import Foundation

/// Host-supplied instructions, resources, and tools for one skill.
public struct FxSkill: Sendable {
    public struct Resource: Sendable, Equatable, Codable {
        public let uri: String
        public let text: String

        public init(uri: String, text: String) {
            self.uri = uri
            self.text = text
        }
    }

    public let name: String
    public let description: String
    public let instructions: String
    public let resources: [Resource]
    public let tools: [FxTool]

    public init(name: String, description: String = "", instructions: String,
                resources: [Resource] = [], tools: [FxTool] = []) {
        self.name = name
        self.description = description
        self.instructions = instructions
        self.resources = resources
        self.tools = tools
    }
}

public enum FxSkillError: Error, Sendable, Equatable {
    case tooManySkills
    case duplicateName(String)
    case instructionsTooLarge
}

/// A validated collection to pass to `FxConfiguration` as instructions and tools.
public struct FxSkills: Sendable {
    public let instructions: String
    public let tools: [FxTool]

    public init(_ skills: [FxSkill]) throws {
        guard skills.count <= 64 else { throw FxSkillError.tooManySkills }
        var names: Set<String> = []
        var sections: [String] = []
        var tools: [FxTool] = []
        var byteCount = 0
        for skill in skills {
            guard names.insert(skill.name).inserted else { throw FxSkillError.duplicateName(skill.name) }
            var parts = ["<skill name=\"\(Self.attribute(skill.name))\">"]
            if !skill.description.isEmpty { parts.append("<description>\(skill.description)</description>") }
            if !skill.instructions.isEmpty { parts.append(skill.instructions) }
            if !skill.resources.isEmpty {
                parts.append(skill.resources.map {
                    "<resource uri=\"\(Self.attribute($0.uri))\">\n\($0.text)\n</resource>"
                }.joined(separator: "\n"))
            }
            parts.append("</skill>")
            let section = parts.joined(separator: "\n")
            byteCount += section.utf8.count + (sections.isEmpty ? 0 : 2)
            guard byteCount <= 64 * 1024 else { throw FxSkillError.instructionsTooLarge }
            sections.append(section)
            tools.append(contentsOf: skill.tools)
        }
        self.instructions = sections.joined(separator: "\n\n")
        self.tools = tools
    }

    private static func attribute(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "<", with: "&lt;")
    }
}
