import Foundation
import Testing
import LibFx
import FxAgentKit

private let context = FxToolContext(executionID: "call", sessionID: "session", turnID: "turn", observation: nil)

private struct WorkspaceFixture {
    let url: URL
    init() throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
    func close() { try? FileManager.default.removeItem(at: url) }
    func tool(_ selection: FxWorkspaceTools.Tool, approval: FxToolApproval = FxToolApproval { _ in .allowOnce }) -> FxTool {
        FxWorkspaceTools(workspace: url, approval: approval, pluginID: "fixture").tools([selection])[0]
    }
}

private func input(_ fields: [String: String]) -> JSONValue { .object(fields.mapValues(JSONValue.string)) }

@Suite(.serialized, .timeLimit(.minutes(1))) struct WorkspaceToolsTests {
    @Test func fileToolsReadWriteAndEditLiteralBytes() async throws {
        let fixture = try WorkspaceFixture()
        defer { fixture.close() }
        _ = try await fixture.tool(.writeFile).execute(input(["path": "note.txt", "content": "one\r\ntwo\r\n"]), context)
        let read = try await fixture.tool(.readFile).execute(input(["path": "note.txt"]), context)
        #expect(read.text.contains("1: one\r\n"))
        _ = try await fixture.tool(.editFile).execute(input(["path": "note.txt", "old_string": "two", "new_string": "three"]), context)
        #expect(try String(contentsOf: fixture.url.appendingPathComponent("note.txt"), encoding: .utf8) == "one\r\nthree\r\n")
    }

    @Test(arguments: ["aa", "missing", ""])
    func editRejectsAmbiguousOverlappingMissingAndEmptyMatches(old: String) async throws {
        let fixture = try WorkspaceFixture()
        defer { fixture.close() }
        let file = fixture.url.appendingPathComponent("note.txt")
        try Data("aaa".utf8).write(to: file)
        await #expect(throws: (any Error).self) {
            _ = try await fixture.tool(.editFile).execute(input(["path": "note.txt", "old_string": old, "new_string": "changed"]), context)
        }
        #expect(try String(contentsOf: file, encoding: .utf8) == "aaa")
    }

    @Test func deniedMutationsAndShellHaveNoSideEffects() async throws {
        let fixture = try WorkspaceFixture()
        defer { fixture.close() }
        let deny = FxToolApproval { _ in .deny }
        try Data("keep".utf8).write(to: fixture.url.appendingPathComponent("keep.txt"))
        for (selection, args) in [
            (FxWorkspaceTools.Tool.writeFile, input(["path": "new.txt", "content": "bad"])),
            (.editFile, input(["path": "keep.txt", "old_string": "keep", "new_string": "bad"])),
            (.shell, input(["command": "printf bad > shell.txt"])),
        ] {
            await #expect(throws: FxToolApproval.Failure.denied) {
                _ = try await fixture.tool(selection, approval: deny).execute(args, context)
            }
        }
        #expect(!FileManager.default.fileExists(atPath: fixture.url.appendingPathComponent("new.txt").path))
        #expect(!FileManager.default.fileExists(atPath: fixture.url.appendingPathComponent("shell.txt").path))
        #expect(try String(contentsOf: fixture.url.appendingPathComponent("keep.txt"), encoding: .utf8) == "keep")
        let read = try await fixture.tool(.readFile, approval: deny).execute(input(["path": "keep.txt"]), context)
        #expect(read.text.contains("keep"))
    }

    @Test func shellUsesWorkspaceDrainsBothStreamsAndReportsExitCode() async throws {
        let fixture = try WorkspaceFixture()
        defer { fixture.close() }
        let result = try await fixture.tool(.shell).execute(input([
            "command": "pwd; printf stderr-marker >&2; i=0; while [ $i -lt 16000 ]; do printf 'abcdefghij'; printf 'abcdefghij' >&2; i=$((i+1)); done; printf done > finished; exit 7",
        ]), context)
        let value = try JSONDecoder().decode(JSONValue.self, from: Data(result.text.utf8))
        #expect(value["exit_code"] == .number(7) && result.isError)
        #expect(value["output_truncated"] == .bool(true))
        #expect(value["output"]?.string?.contains("stderr-marker") == true)
        #expect((value["output"]?.string?.utf8.count ?? 0) < 52 * 1024)
        #expect(try String(contentsOf: fixture.url.appendingPathComponent("finished"), encoding: .utf8) == "done")
    }

    @Test func cancellationTerminatesAndJoinsTheOwnedShell() async throws {
        let fixture = try WorkspaceFixture()
        defer { fixture.close() }
        let shell = fixture.tool(.shell)
        let task = Task {
            try await shell.execute(input(["command": "echo $$ > pid; trap '' TERM; while :; do :; done"]), context)
        }
        let pidFile = fixture.url.appendingPathComponent("pid")
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !FileManager.default.fileExists(atPath: pidFile.path) {
            guard ContinuousClock.now < deadline else { task.cancel(); throw FxError.transport("Shell did not start") }
            try await Task.sleep(for: .milliseconds(10))
        }
        let pid = try #require(Int32(String(contentsOf: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
        task.cancel()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        #expect(kill(pid, 0) == -1 && errno == ESRCH)
    }

    @Test func cancelledApprovalCannotStartShell() async throws {
        let fixture = try WorkspaceFixture()
        defer { fixture.close() }
        let approval = FxToolApproval { _ in
            try await Task.sleep(for: .seconds(30))
            return .allowOnce
        }
        let task = Task {
            try await fixture.tool(.shell, approval: approval).execute(input(["command": "touch forbidden"]), context)
        }
        task.cancel()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        #expect(!FileManager.default.fileExists(atPath: fixture.url.appendingPathComponent("forbidden").path))
    }

    @Test func readRangeAndOutputAreBounded() async throws {
        let fixture = try WorkspaceFixture()
        defer { fixture.close() }
        try Data((1...600).map { "line-\($0)" }.joined(separator: "\n").utf8).write(to: fixture.url.appendingPathComponent("lines"))
        let range = try await fixture.tool(.readFile).execute(.object([
            "path": .string("lines"), "start_line": .number(500), "line_count": .number(2),
        ]), context)
        #expect(range.text.hasPrefix("500: line-500\n501: line-501\n"))
        try Data(String(repeating: "中", count: 30000).utf8).write(to: fixture.url.appendingPathComponent("long"))
        let long = try await fixture.tool(.readFile).execute(input(["path": "long"]), context)
        #expect(long.text.utf8.count < 52 * 1024 && !long.text.contains("�"))
    }
}

extension WorkspaceToolsTests {
    @Test func cancellationKillsATermIgnoringChildAfterTheShellExits() async throws {
        let fixture = try WorkspaceFixture()
        defer { fixture.close() }
        // The child must remain alive after TERM and would write after cancellation.
        let task = Task {
            try await fixture.tool(.shell).execute(input([
                "command": "/bin/sh -c 'trap \"\" TERM; echo $$ > child-pid; sleep 2; printf escaped > delayed-marker; while :; do sleep 1; done' & echo $$ > parent-pid; wait",
            ]), context)
        }
        let childFile = fixture.url.appendingPathComponent("child-pid")
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !FileManager.default.fileExists(atPath: childFile.path) {
            guard ContinuousClock.now < deadline else { task.cancel(); throw FxError.transport("Child did not start") }
            try await Task.sleep(for: .milliseconds(10))
        }
        let child = try #require(Int32(String(contentsOf: childFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
        let parent = try #require(Int32(String(contentsOf: fixture.url.appendingPathComponent("parent-pid"), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
        #expect(getpgid(parent) == parent)
        #expect(getpgid(child) == parent)
        task.cancel()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        // Allow the OS to reap the orphaned child, then check its actual PID.
        let reapDeadline = ContinuousClock.now.advanced(by: .seconds(3))
        while kill(child, 0) == 0 && ContinuousClock.now < reapDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(kill(child, 0) == -1 && errno == ESRCH)
        #expect(kill(parent, 0) == -1 && errno == ESRCH)
        try await Task.sleep(for: .seconds(2))
        #expect(!FileManager.default.fileExists(atPath: fixture.url.appendingPathComponent("delayed-marker").path))
    }
}

extension WorkspaceToolsTests {
    @Test func fastCommandsNeverFailProcessGroupAdmission() async throws {
        let fixture = try WorkspaceFixture()
        defer { fixture.close() }
        let shell = fixture.tool(.shell)
        for _ in 0..<50 {
            for command in ["true", "printf fast"] {
                let result = try await shell.execute(input(["command": command]), context)
                let value = try JSONDecoder().decode(JSONValue.self, from: Data(result.text.utf8))
                #expect(value["exit_code"] == .number(0) && !result.isError)
                #expect(value["output"] == .string(command == "true" ? "" : "fast"))
            }
        }
    }
}

extension WorkspaceToolsTests {
    @Test func fileReadRejectsOversizedAndNonTextInputs() async throws {
        let fixture = try WorkspaceFixture()
        defer { fixture.close() }
        let read = fixture.tool(.readFile)
        for (name, bytes) in [
            ("too-large", Data(repeating: 97, count: 4 * 1024 * 1024 + 1)),
            ("invalid-utf8", Data([0xff, 0xfe])),
            ("nul", Data([97, 0, 98])),
        ] {
            try bytes.write(to: fixture.url.appendingPathComponent(name))
            await #expect(throws: (any Error).self) { _ = try await read.execute(input(["path": name]), context) }
        }
    }
}
