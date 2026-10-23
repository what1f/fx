#!/usr/bin/env bash
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
task_tmp="$(mktemp -d)"
trap 'rm -rf "$task_tmp"' EXIT
mkdir -p "$task_tmp/Sources/ToolApprovalSmoke"
cat > "$task_tmp/Package.swift" <<'SWIFT'
// swift-tools-version: 6.2
import Foundation
import PackageDescription
let package = Package(
    name: "ToolApprovalSmoke", platforms: [.macOS(.v14)],
    dependencies: [.package(name: "LibFx", path: ProcessInfo.processInfo.environment["LIBFX_SWIFT_PACKAGE"]!)],
    targets: [.executableTarget(name: "ToolApprovalSmoke", dependencies: [.product(name: "FxAgentKit", package: "LibFx"), .product(name: "LibFx", package: "LibFx")])]
)
SWIFT
cat > "$task_tmp/Sources/ToolApprovalSmoke/Smoke.swift" <<'SWIFT'
import Foundation
import LibFx
import FxAgentKit

struct SmokeFailure: Error {
    let message: String
}
func require(_ condition: Bool, _ message: String) throws {
    if !condition { throw SmokeFailure(message: message) }
}

actor FixtureHTTP: FxHTTPClient {
    private var requests = 0
    private(set) var output: JSONValue?

    func send(_ request: URLRequest) throws -> FxHTTPResponse {
        requests += 1
        let events: [JSONValue]
        if requests == 1 {
            events = [
                .object(["type": .string("tool-call"), "toolCallId": .string("approval-call"),
                         "toolName": .string("save"), "input": .object(["value": .string("fixture")])]),
                .object(["type": .string("finish"), "finishReason": .object([
                    "unified": .string("tool-calls"), "raw": .string("tool-calls"),
                ])]),
            ]
        } else {
            try require(requests == 2, "Unexpected model request")
            let body = try JSONDecoder().decode(JSONValue.self, from: request.httpBody ?? Data())
            if case .array(let messages) = body["prompt"] {
                let results = messages.flatMap { message -> [JSONValue] in
                    guard case .array(let content) = message["content"] else { return [] }
                    return content.filter { $0["type"] == .string("tool-result") }
                }
                try require(results.count == 1, "Expected one tool result")
                output = results.first?["output"]
            }
            events = [
                .object(["type": .string("text-delta"), "delta": .string("handled")]),
                .object(["type": .string("finish"), "finishReason": .object([
                    "unified": .string("stop"), "raw": .string("stop"),
                ])]),
            ]
        }
        let payload = try events.map { "data: \(String(decoding: try JSONEncoder().encode($0), as: UTF8.self))\n\n" }.joined() + "data: [DONE]\n\n"
        return FxHTTPResponse(statusCode: 200, body: AsyncThrowingStream {
            $0.yield(Data(payload.utf8)); $0.finish()
        })
    }
}

actor Calls {
    private(set) var approvals: [FxToolApproval.Request] = []
    private(set) var executions = 0
    func approve(_ request: FxToolApproval.Request, allow: Bool) -> FxToolApproval.Decision {
        approvals.append(request)
        return allow ? .allowOnce : .deny
    }
    func execute(at file: URL) throws -> FxToolResult {
        executions += 1
        try Data("saved".utf8).write(to: file)
        return "saved"
    }
}

@main struct ToolApprovalSmoke {
    static func main() async throws {
        for allow in [true, false] {
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("approval-smoke-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: file) }
            let calls = Calls(), http = FixtureHTTP()
            let approval = FxToolApproval { await calls.approve($0, allow: allow) }
            let original = FxTool(name: "save", description: "Save a value", inputSchema: .object([
                "type": .string("object"), "properties": .object(["value": .object(["type": .string("string")])]),
            ]), isIdempotent: false, writes: true) { _, _ in try await calls.execute(at: file) }
            let tool = approval.wrap(tool: original, pluginID: "notes", effect: .write)
            var configuration = FxConfiguration(apiKey: "fixture", model: "swift/approval-smoke", tools: [tool], httpClient: http)
            configuration.modelCatalog = try FxModelCatalog(response: Data(#"{"data":[{"id":"swift/approval-smoke","type":"language","tags":["tool-use"]}]}"#.utf8))
            let engine = try await FxEngine.open(configuration: configuration)
            do {
                let turn = try await engine.prompt("save the fixture", id: "approval-turn")
                var text = "", finishes = 0
                for try await event in turn {
                    if case .text(let delta) = event { text += delta }
                    if case .toolFinished("approval-call", "save", _, let isError) = event {
                        finishes += 1
                        try require(isError == !allow, "Wrong tool result status")
                    }
                }
                try require(try await turn.result.stopReason == .endTurn, "Turn did not finish")
                try require(text == "handled" && finishes == 1, "Model did not handle the result")
                try await engine.close()
            } catch {
                try? await engine.close()
                throw error
            }
            let requests = await calls.approvals
            try require(requests.count == 1, "Expected one host approval")
            let request = requests[0]
            try require(request.pluginID == "notes" && request.toolName == "save" && request.effect == .write,
                        "Approval identity changed")
            try require(request.input == .object(["value": .string("fixture")]), "Approval input changed")
            try require(request.context.executionID == "approval-call" && request.context.turnID == "approval-turn"
                        && request.context.sessionID == engine.sessionID, "Approval context changed")
            try require(await calls.executions == (allow ? 1 : 0), "Wrong execution count")
            try require(FileManager.default.fileExists(atPath: file.path) == allow, "Wrong file side effect")
            if allow { try require(try String(contentsOf: file, encoding: .utf8) == "saved", "Wrong file content") }
            try require(await http.output?["type"] == .string(allow ? "text" : "error-text"), "Wrong model tool result")
            try require(await approval.allowedPlugins.isEmpty, "Unexpected persistent grant")
            print(allow ? "PASS: native FxEngine allowed host closure and wrote the file once"
                        : "PASS: native FxEngine denied host closure without a file side effect")
        }
    }
}
SWIFT
LIBFX_SWIFT_PACKAGE="$repo_root/swift" swift build --package-path "$task_tmp" --product ToolApprovalSmoke
FX_SOUND=0 "$task_tmp/.build/debug/ToolApprovalSmoke" 2> "$task_tmp/runtime.stderr"
if [[ -s "$task_tmp/runtime.stderr" ]]; then
    cat "$task_tmp/runtime.stderr" >&2
    exit 1
fi
