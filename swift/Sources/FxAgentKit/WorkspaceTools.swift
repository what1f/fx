import Foundation
import LibFx
import Darwin

/// Optional host tools. The workspace is a path base and working directory, not a sandbox.
public struct FxWorkspaceTools: Sendable {
    public let workspace: URL
    private let approval: FxToolApproval
    private let pluginID: String
    private static let fileLimit = 4 * 1024 * 1024
    private static let outputLimit = 50 * 1024

    public enum Tool: Sendable {
        case readFile, writeFile, editFile, shell
    }

    /// Every returned tool uses this approval policy before it executes.
    public init(workspace: URL, approval: FxToolApproval, pluginID: String) {
        self.workspace = workspace.standardizedFileURL
        self.approval = approval
        self.pluginID = pluginID
    }

    public func tools(_ selected: [Tool]) -> [FxTool] {
        selected.map { selection in
            switch selection {
            case .readFile: readFile
            case .writeFile: writeFile
            case .editFile: editFile
            case .shell: shell
            }
        }
    }

    private var readFile: FxTool {
        tool("read", description: "Read a text file or image. Text has numbered lines, limited to 400 lines and 50 KiB; use offset and limit to continue. Paths may be relative to the workspace or absolute.",
             properties: ["path": Self.stringSchema, "offset": Self.positiveIntegerSchema,
                          "limit": Self.positiveIntegerSchema], required: ["path"], effect: .readOnly) { input, _ in
            let path = try resolve(input)
            if let image = try workspaceImage(at: path) { return image }
            let start = try Self.positiveInteger(input, "offset", default: 1)
            let count = min(try Self.positiveInteger(input, "limit", default: 400), 400)
            let text = try Self.read(path)
            let lines = text.components(separatedBy: "\n")
            let upper = min(lines.count, start - 1 + count)
            var output = ""
            if start <= lines.count {
                for index in (start - 1)..<upper {
                    output += "\(index + 1): \(lines[index])\n"
                    if output.utf8.count > Self.outputLimit { break }
                }
            }
            let truncated = output.utf8.count > Self.outputLimit || upper < lines.count
            output = Self.prefix(output, bytes: Self.outputLimit)
            if truncated { output += "\n[Output truncated. Use offset and limit to read another range.]" }
            return FxToolResult(text: output)
        }
    }

    private var writeFile: FxTool {
        tool("write", description: "Create or overwrite a UTF-8 file with complete content. Missing parent directories are created.",
             properties: ["path": Self.stringSchema, "content": Self.stringSchema],
             required: ["path", "content"], effect: .write) { input, _ in
            let path = try resolve(input)
            let content = try Self.string(input, "content")
            guard content.utf8.count <= Self.fileLimit else { throw FxError.invalidInput("File content exceeds 4 MiB") }
            try Task.checkCancellation()
            try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(content.utf8).write(to: path, options: .atomic)
            return FxToolResult(text: "Wrote \(content.utf8.count) bytes")
        }
    }

    private var editFile: FxTool {
        tool("edit", description: "Replace one exact, unique oldText occurrence with newText in a UTF-8 file. Read the file before editing. Ambiguous matches are rejected.",
             properties: ["path": Self.stringSchema, "oldText": Self.stringSchema, "newText": Self.stringSchema],
             required: ["path", "oldText", "newText"], effect: .write) { input, _ in
            let path = try resolve(input)
            let old = try Self.string(input, "oldText"), new = try Self.string(input, "newText")
            guard !old.isEmpty else { throw FxError.invalidInput("oldText must not be empty") }
            let text = try Self.read(path)
            // Literal UTF-8 matching preserves line endings and rejects overlapping matches too.
            let data = Data(text.utf8), needle = Data(old.utf8)
            guard let match = data.range(of: needle) else { throw FxError.invalidInput("oldText was not found") }
            if data.range(of: needle, in: (match.lowerBound + 1)..<data.count) != nil {
                throw FxError.invalidInput("oldText matches more than once")
            }
            var edited = data
            edited.replaceSubrange(match, with: new.utf8)
            guard edited.count <= Self.fileLimit else { throw FxError.invalidInput("File content exceeds 4 MiB") }
            try Task.checkCancellation()
            try edited.write(to: path, options: .atomic)
            return FxToolResult(text: "Edited one occurrence")
        }
    }

    private var shell: FxTool {
        tool("bash", description: "Run a foreground command with /bin/bash in the workspace. Optional timeout is in seconds. No TTY or background handles. stdout and stderr are combined and limited to 50 KiB. Nonzero exit codes report failure.",
             properties: ["command": Self.stringSchema, "timeout": .object(["type": .string("number"), "exclusiveMinimum": .number(0), "maximum": .number(86400)])], required: ["command"], effect: .dangerous) { input, _ in
            let command = try Self.string(input, "command")
            guard !command.isEmpty, !command.utf8.contains(0), command.utf8.count <= 64 * 1024 else {
                throw FxError.invalidInput("Command must contain 1 to 65536 bytes without NUL")
            }
            let execution = WorkspaceCommand(command: command, workspace: workspace, limit: Self.outputLimit)
            if let value = input["timeout"] {
                guard case .number(let timeout) = value, timeout.isFinite, timeout > 0, timeout <= 86400 else {
                    throw FxError.invalidInput("timeout must be between 0 and 86400 seconds")
                }
                return try await withThrowingTaskGroup(of: FxToolResult.self) { group in
                    group.addTask { try await execution.run() }
                    group.addTask { try await Task.sleep(for: .seconds(timeout)); throw FxError.transport("Command timed out") }
                    defer { group.cancelAll() }
                    return try await group.next()!
                }
            }
            return try await execution.run()
        }
    }

    private func tool(_ name: String, description: String, properties: [String: JSONValue], required: [String],
                      effect: FxToolEffect,
                      execute: @escaping @Sendable (JSONValue, FxToolContext) async throws -> FxToolResult) -> FxTool {
        let tool = FxTool(name: name, description: description, inputSchema: .object([
            "type": .string("object"), "properties": .object(properties),
            "required": .array(required.map(JSONValue.string)), "additionalProperties": .bool(false),
        ]), isIdempotent: effect == .readOnly, writes: effect != .readOnly, execute: execute)
        return approval.wrap(tool: tool, pluginID: pluginID, effect: effect)
    }

    private func resolve(_ input: JSONValue) throws -> URL {
        let path = try Self.string(input, "path")
        guard workspace.isFileURL, !path.isEmpty, !path.utf8.contains(0) else {
            throw FxError.invalidInput("A file URL workspace and a nonempty path are required")
        }
        if path == "~" || path.hasPrefix("~/") { return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(String(path.dropFirst(min(2, path.count)))).standardizedFileURL }
        if path.hasPrefix("/") { return URL(fileURLWithPath: path).standardizedFileURL }
        return workspace.appendingPathComponent(path).standardizedFileURL
    }

    private static let stringSchema: JSONValue = .object(["type": .string("string")])
    private static let positiveIntegerSchema: JSONValue = .object(["type": .string("integer"), "minimum": .number(1)])

    private static func string(_ input: JSONValue, _ key: String) throws -> String {
        guard let value = input[key]?.string else { throw FxError.invalidInput("\(key) must be a string") }
        return value
    }

    private static func positiveInteger(_ input: JSONValue, _ key: String, default fallback: Int) throws -> Int {
        guard let value = input[key] else { return fallback }
        guard let number = value.integer, number > 0, number <= Int.max - 400 else {
            throw FxError.invalidInput("\(key) must be a positive integer")
        }
        return number
    }

    private static func read(_ url: URL) throws -> String {
        try Task.checkCancellation()
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        var data = Data()
        while data.count <= fileLimit {
            try Task.checkCancellation()
            let chunk = try file.read(upToCount: min(64 * 1024, fileLimit + 1 - data.count)) ?? Data()
            if chunk.isEmpty { break }
            data.append(chunk)
        }
        guard data.count <= fileLimit else { throw FxError.invalidInput("File exceeds 4 MiB") }
        guard let text = String(data: data, encoding: .utf8), !data.contains(0) else {
            throw FxError.invalidInput("File must be UTF-8 text without NUL")
        }
        return text
    }

    private static func prefix(_ text: String, bytes: Int) -> String {
        var data = Data(text.utf8.prefix(bytes))
        while String(data: data, encoding: .utf8) == nil { data.removeLast() }
        return String(decoding: data, as: UTF8.self)
    }
}

// One owner joins the process and drains its pipe even after the retained output fills.
private final class WorkspaceCommand: @unchecked Sendable {
    private let lock = NSLock()
    private let process = Process()
    private let pipe = Pipe()
    private let launch = Pipe()
    private let limit: Int
    private var cancelled = false
    private var processGroup: pid_t?
    private let cancellationFinished = DispatchGroup()
    private var cancellationScheduled = false

    init(command: String, workspace: URL, limit: Int) {
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        // Wait until the owner has verified the group, then replace this shell.
        process.arguments = ["-c", "IFS= read -r launch || exit; exec /bin/bash -c \"$1\"", "workspace-shell", command]
        process.currentDirectoryURL = workspace
        process.standardInput = launch
        process.standardOutput = pipe
        process.standardError = pipe
        self.limit = limit
    }

    func run() async throws -> FxToolResult {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global().async {
                    do { continuation.resume(returning: try self.execute()) }
                    catch { continuation.resume(throwing: error) }
                }
            }
        } onCancel: { self.cancel() }
    }

    private func cancel() {
        lock.withLock {
            cancelled = true
            guard let group = processGroup, !cancellationScheduled else { return }
            cancellationScheduled = true
            cancellationFinished.enter()
            _ = Darwin.kill(-group, SIGTERM)
            DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(500)) {
                // Descendants can outlive the shell. Escalate against the recorded
                // group even when Foundation has already reaped its leader.
                _ = Darwin.kill(-group, SIGKILL)
                self.cancellationFinished.leave()
            }
        }
    }

    private func execute() throws -> FxToolResult {
        defer {
            try? pipe.fileHandleForReading.close(); try? pipe.fileHandleForWriting.close()
            try? launch.fileHandleForReading.close(); try? launch.fileHandleForWriting.close()
        }
        try lock.withLock {
            if cancelled { throw CancellationError() }
            try process.run()
            let pid = process.processIdentifier
            guard getpgid(pid) == pid else {
                process.terminate()
                process.waitUntilExit()
                throw FxError.transport("Shell process group is unavailable")
            }
            processGroup = pid
            try launch.fileHandleForWriting.write(contentsOf: Data([10]))
            try launch.fileHandleForWriting.close()
        }
        try pipe.fileHandleForWriting.close()
        var output = Data(), truncated = false, buffer = [UInt8](repeating: 0, count: 16 * 1024)
        let fd = pipe.fileHandleForReading.fileDescriptor
        while true {
            var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ready = poll(&descriptor, 1, 100)
            if ready < 0 {
                if errno == EINTR { continue }
                cancel()
                break
            }
            if ready == 0 {
                if !process.isRunning { break }
                continue
            }
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count <= 0 {
                if count < 0 && errno == EINTR { continue }
                break
            }
            let retained = min(count, limit - output.count)
            output.append(contentsOf: buffer.prefix(retained))
            if retained < count { truncated = true }
        }
        process.waitUntilExit()
        if lock.withLock({ cancelled }) {
            cancellationFinished.wait()
            throw CancellationError()
        }
        // Lossy decoding is intentional for command output, unlike editable files.
        var text = String(decoding: output, as: UTF8.self)
        if truncated { text += "\n[Output truncated]" }
        let result = JSONValue.object([
            "exit_code": .number(Double(process.terminationStatus)), "output": .string(text),
            "output_truncated": .bool(truncated),
        ])
        return FxToolResult(text: String(decoding: try JSONEncoder().encode(result), as: UTF8.self),
                            isError: process.terminationStatus != 0)
    }
}
