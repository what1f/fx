import Foundation
import CryptoKit
import Yams

/// Host-selected roots only. Discovery reads metadata; bodies stay on disk for read.
public struct FxSkillDiscovery: Sendable {
    public struct Entry: Sendable, Equatable {
        public let name: String
        public let description: String
        public let location: URL
        public let revision: String
        public let disableModelInvocation: Bool
    }
    public struct Catalog: Sendable {
        public let skills: [Entry]
        public let diagnostics: [String]
        public var prompt: String {
            let visible = skills.filter { !$0.disableModelInvocation }
            return """
            # Skills
            Use read to load a skill's SKILL.md when the task matches its description, before doing the work.
            Resolve relative references against that skill's directory. Read remaining ranges when output is truncated.
            This is the current catalog. Reload a previously read skill when its revision changes. Removed skills are unavailable.
            <available_skills>
            \(visible.map { "<skill><name>\(xml($0.name))</name><description>\(xml($0.description))</description><location>\(xml($0.location.path))</location><revision>\($0.revision)</revision></skill>" }.joined(separator: "\n"))
            </available_skills>
            """
        }
        private func xml(_ text: String) -> String {
            text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
                .replacingOccurrences(of: "'", with: "&apos;")
        }
    }
    public let roots: [URL]
    public init(roots: [URL]) { self.roots = roots }

    /// Rescan on each model request, including after tool execution. No session reset or watcher lifetime.
    public func discover() -> Catalog {
        var visited: Set<String> = [], names: Set<String> = []
        var skills: [Entry] = [], diagnostics: [String] = []
        func load(_ file: URL) {
            do {
                let values = try file.resourceValues(forKeys: [.fileSizeKey])
                guard (values.fileSize ?? 0) <= 1_048_576 else { throw FxSkillFileError.invalidMetadata }
                let data = try Data(contentsOf: file)
                guard let source = String(data: data, encoding: .utf8) else { throw FxSkillFileError.invalidUTF8 }
                let lines = source.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false)
                guard lines.first == "---", let end = lines.indices.dropFirst().first(where: { lines[$0] == "---" }) else {
                    throw FxSkillFileError.unterminatedFrontmatter
                }
                struct Metadata: Decodable {
                    let name: String?
                    let description: String
                    let disabled: Bool?
                    enum CodingKeys: String, CodingKey { case name, description; case disabled = "disable-model-invocation" }
                }
                let metadata = try YAMLDecoder().decode(Metadata.self, from: lines[1..<end].joined(separator: "\n"))
                let name = metadata.name ?? (file.lastPathComponent == "SKILL.md" ? file.deletingLastPathComponent().lastPathComponent : file.deletingPathExtension().lastPathComponent)
                guard name.range(of: "^[a-z0-9]+(?:-[a-z0-9]+)*$", options: .regularExpression) != nil,
                      name.count <= 64, !metadata.description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      metadata.description.count <= 1024 else { throw FxSkillFileError.invalidMetadata }
                guard names.insert(name).inserted else { diagnostics.append("Duplicate skill \(name): \(file.path)"); return }
                skills.append(Entry(name: name, description: metadata.description, location: file,
                    revision: SHA256.hash(data: data).prefix(8).map { String(format: "%02x", $0) }.joined(),
                    disableModelInvocation: metadata.disabled ?? false))
            } catch { diagnostics.append("\(file.path): \(error)") }
        }
        func scan(_ directory: URL, root: Bool) {
            let canonical = directory.resolvingSymlinksInPath().standardizedFileURL
            guard visited.insert(canonical.path).inserted else { return }
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: canonical.path, isDirectory: &isDirectory) else { return }
            if !isDirectory.boolValue { if canonical.pathExtension == "md" { load(canonical) }; return }
            let entry = canonical.appendingPathComponent("SKILL.md")
            if FileManager.default.fileExists(atPath: entry.path) { load(entry); return }
            do {
                for child in try FileManager.default.contentsOfDirectory(at: canonical, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]).sorted(by: { $0.path < $1.path }) {
                    do {
                        let values = try child.resolvingSymlinksInPath().resourceValues(forKeys: [.isDirectoryKey])
                        if values.isDirectory == true { scan(child, root: false) }
                        else if root && child.pathExtension == "md" { load(child) }
                    } catch { diagnostics.append("\(child.path): \(error)") }
                }
            } catch { diagnostics.append("\(canonical.path): \(error)") }
        }
        for root in roots { scan(root, root: true) }
        return Catalog(skills: skills.sorted { $0.name < $1.name }, diagnostics: diagnostics)
    }
}
