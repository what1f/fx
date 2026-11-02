import Foundation
import Yams

public enum FxSkillFileError: Error, Sendable, Equatable {
    case notFileURL
    case invalidUTF8
    case unterminatedFrontmatter
    case invalidMetadata
}

extension FxSkill {
    /// Read a local Markdown skill. Resources and tools are supplied by the host.
    public static func load(from url: URL, resources: [Resource] = [], tools: [FxTool] = []) async throws -> FxSkill {
        guard url.isFileURL else { throw FxSkillFileError.notFileURL }
        try Task.checkCancellation()
        let data = try Data(contentsOf: url)
        try Task.checkCancellation()
        guard let source = String(data: data, encoding: .utf8) else { throw FxSkillFileError.invalidUTF8 }
        let skill = try parse(source, fallbackName: url.deletingPathExtension().lastPathComponent,
                              resources: resources, tools: tools)
        try Task.checkCancellation()
        return skill
    }

    static func parse(_ source: String, fallbackName: String, resources: [Resource] = [], tools: [FxTool] = []) throws -> FxSkill {
        // Normalize line endings only for a document with frontmatter. A plain
        // Markdown file retains its original text, including surrounding space.
        let normalized = source.replacingOccurrences(of: "\r\n", with: "\n")
        let document = normalized.hasPrefix("\u{FEFF}") ? String(normalized.dropFirst()) : normalized
        guard document.hasPrefix("---\n") else {
            return FxSkill(name: fallbackName, instructions: source, resources: resources, tools: tools)
        }
        let lines = document.split(separator: "\n", omittingEmptySubsequences: false)
        guard let end = lines.indices.dropFirst().first(where: { lines[$0] == "---" }) else {
            throw FxSkillFileError.unterminatedFrontmatter
        }
        struct Metadata: Decodable {
            let name: String?
            let description: String?
        }
        let yaml = lines[1..<end].joined(separator: "\n")
        let metadata: Metadata
        do { metadata = try YAMLDecoder().decode(Metadata.self, from: yaml.isEmpty ? "{}" : yaml) }
        catch { throw FxSkillFileError.invalidMetadata }
        let body = lines.dropFirst(end + 1).joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return FxSkill(name: metadata.name.flatMap { $0.isEmpty ? nil : $0 } ?? fallbackName,
                       description: metadata.description ?? "", instructions: body, resources: resources, tools: tools)
    }
}
