import assert from 'node:assert/strict';
import { spawn, spawnSync } from 'node:child_process';
import { mkdtemp, mkdir, writeFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';

// Direct native acceptance proof, not original World-fixture qualification.
// JS builds/starts/kills workers and observes committed SQLite lease expiry.
// Acceptance, queue publishing, delivery,
// recovery, model parsing, tool admission and replay all execute inside Swift.
const directory = await mkdtemp(join(tmpdir(), 'libfx-native-steer-redelivery-'));
const packageRoot = join(directory, 'consumer');
const packagePath = fileURLToPath(new URL('../..', import.meta.url));
const reports = [];
const leaseMilliseconds = 3_000;
const source = String.raw`
import Foundation
import LibFx

func emit(_ fields: [String: JSONValue]) throws {
    var bytes = try JSONEncoder().encode(JSONValue.object(fields)); bytes.append(10)
    try FileHandle.standardOutput.write(contentsOf: bytes)
}

actor FileWakeQueue: FxSessionQueue {
    let file: URL
    init(_ file: URL) { self.file = file }
    func enqueue(_ wakeup: FxSessionWakeup) throws {
        try JSONEncoder().encode(wakeup).write(to: file, options: .atomic)
    }
}

actor Lookup {
    let mode: String
    private var held: CheckedContinuation<Void, Never>?
    private(set) var executions: [String] = []
    init(_ mode: String) { self.mode = mode }
    func execute(_ context: FxToolContext) async throws -> FxToolResult {
        executions.append(context.executionID)
        try emit(["execution": .string(context.executionID), "executedAt": .number((Date().timeIntervalSince1970 * 1_000).rounded(.down))])
        if mode == "crash" { await withCheckedContinuation { held = $0 } }
        return FxToolResult(text: "recovered lookup")
    }
}

actor Gateway: FxHTTPClient {
    let mode: String, image: Bool
    private(set) var requests = 0
    init(_ mode: String, image: Bool) { self.mode = mode; self.image = image }
    func send(_ request: URLRequest) throws -> FxHTTPResponse {
        requests += 1
        let body = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
        guard body.components(separatedBy: "persisted guidance").count - 1 == 1 else {
            throw FxError.invalidInput("Guidance was not placed exactly once")
        }
        if image && !body.contains("image/png") { throw FxError.invalidInput("Saved image was lost") }
        let events: [JSONValue]
        if mode == "crash" {
            guard requests == 1 else { throw FxError.invalidInput("Unexpected request before crash") }
            events = [
                .object(["type": .string("tool-call"), "toolCallId": .string("stable-lookup"), "toolName": .string("lookup"), "input": .object([:])]),
                .object(["type": .string("finish"), "finishReason": .object(["unified": .string("tool-calls"), "raw": .string("tool-calls")])]),
            ]
        } else {
            guard requests == 1, body.contains("recovered lookup") else {
                throw FxError.invalidInput("Recovery did not continue the original tool")
            }
            events = [
                .object(["type": .string("text-delta"), "delta": .string("completed")]),
                .object(["type": .string("finish"), "finishReason": .object(["unified": .string("stop"), "raw": .string("stop")])]),
            ]
        }
        let data = try events.map { "data: \(String(decoding: try JSONEncoder().encode($0), as: UTF8.self))\n\n" }.joined() + "data: [DONE]\n\n"
        return FxHTTPResponse(statusCode: 200, body: AsyncThrowingStream { $0.yield(Data(data.utf8)); $0.finish() })
    }
}

@main struct Worker {
    static func main() async throws {
        let mode = CommandLine.arguments[1], image = CommandLine.arguments[2] == "image"
        let directory = URL(fileURLWithPath: CommandLine.arguments[3])
        let leasePolicy = try FxSessionLeasePolicy(duration: .seconds(3), renewalInterval: .milliseconds(300))
        let store = try FxSessionStore(url: directory.appendingPathComponent("sessions.sqlite"), leasePolicy: leasePolicy)
        let queue = FileWakeQueue(directory.appendingPathComponent("wakeup.json"))
        let lookup = Lookup(mode), http = Gateway(mode, image: image)
        let tool = FxTool(name: "lookup", description: "Read safely", inputSchema: .object(["type": .string("object")]), isIdempotent: true) { _, context in
            try await lookup.execute(context)
        }
        var configuration = FxConfiguration(apiKey: "fixture", model: "swift/redelivery", tools: [tool], httpClient: http)
        configuration.modelCatalog = try FxModelCatalog(response: Data(#"{"data":[{"id":"swift/redelivery","type":"language","tags":["tool-use","vision","file-input"]}]}"#.utf8))
        let agent = try FxAgent(configuration: configuration, store: store, checkpointAfterBytes: nil, queue: queue)
        let session = try await agent.session(id: "steer-started-turn")
        if mode == "crash" {
            var input: [FxPromptContent] = [.text("persisted guidance")]
            if image {
                let bytes = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jP0cAAAAASUVORK5CYII=")!
                input.append(.image(FxImage(data: bytes, format: .png, sourceReference: "host:saved-guidance")))
            }
            _ = try await session.steer(input, id: "guidance")
        }
        let wakeup = try JSONDecoder().decode(FxSessionWakeup.self, from: Data(contentsOf: directory.appendingPathComponent("wakeup.json")))
        guard wakeup == FxSessionWakeup(agent: "default", sessionID: session.id, inputID: "guidance") else { throw FxError.invalidInput("Wrong persisted wakeup") }
        let deliveryPolicy = try FxDeliveryPolicy(maximumDuration: .seconds(30), reserve: .seconds(1))
        var outcome = try await agent.deliver(wakeup, policy: deliveryPolicy)
        if mode == "recover" {
            guard case .retry = outcome else { throw FxError.invalidInput("Fresh worker bypassed the unexpired lease") }
            try emit(["waitingForLease": .bool(true)])
            while case .retry(let delay) = outcome {
                try await Task.sleep(for: delay)
                outcome = try await agent.deliver(wakeup, policy: deliveryPolicy)
            }
        }
        guard outcome == .complete else { throw FxError.busy }
        guard mode == "recover" else { throw FxError.invalidInput("Crash worker unexpectedly finished") }
        guard try await agent.deliver(wakeup) == .complete else { throw FxError.busy }
        guard let result = try await store.result(session: session.id, agent: "default", id: "guidance"), result.stopReason == .endTurn else {
            throw FxError.invalidInput("Missing recovered completion")
        }
        let entries = try await store.entries(session: session.id, agent: "default", after: 0)
        let starts = entries.filter { if case .started(let id, _, _) = $0.event { return id == "guidance" }; return false }.count
        let ends = entries.filter { if case .ended(let result) = $0.event { return result.id == "guidance" }; return false }.count
        guard starts == 1, ends == 1, await lookup.executions == ["stable-lookup"], await http.requests == 1 else {
            throw FxError.invalidInput("Redelivery duplicated accepted work")
        }
        guard let accepted = entries.first(where: { if case .started = $0.event { return true }; return false }),
              case .started(_, _, let input) = accepted.event,
              input.contains(.text("persisted guidance")), input.count == (image ? 2 : 1) else {
            throw FxError.invalidInput("Original accepted input changed")
        }
        try await agent.close(); try await store.close()
        try emit(["completed": .bool(true), "starts": .number(Double(starts)), "ends": .number(Double(ends)), "requests": .number(1)])
    }
}
`;

async function child(command, args, { marker = false, afterMarker, kind } = {}) {
  const process = spawn(command, args, { detached: true, stdio: ['ignore', 'pipe', 'pipe'] });
  const report = { kind, stdout: '', stderr: '' }; reports.push(report);
  let signalMarker;
  const marked = new Promise(resolve => { signalMarker = resolve; });
  process.stdout.on('data', bytes => { report.stdout += bytes; if (report.stdout.includes('"execution"')) signalMarker(); });
  process.stderr.on('data', bytes => { report.stderr += bytes; });
  const kill = () => { try { globalThis.process.kill(-process.pid, 'SIGKILL'); } catch {} };
  const exited = new Promise(resolve => process.once('close', (status, signal) => { Object.assign(report, { status, signal }); resolve(); }));
  const timer = setTimeout(() => { report.timedOut = true; kill(); }, kind === 'build' ? 120_000 : 15_000);
  try {
    if (marker) { await Promise.race([marked, exited]); if (afterMarker && process.exitCode === null && process.signalCode === null) await afterMarker(report); kill(); }
    await exited;
    assert.equal(report.timedOut, undefined, JSON.stringify(report));
    if (marker) assert.equal(report.signal, 'SIGKILL', JSON.stringify(report));
    else assert.equal(report.status, 0, report.stdout + report.stderr);
    if (marker || kind !== 'build') assert.equal(report.stderr, '');
    return report;
  } finally { clearTimeout(timer); kill(); }
}
try {
  await mkdir(join(packageRoot, 'Sources', 'Worker'), { recursive: true });
  await writeFile(join(packageRoot, 'Package.swift'), `// swift-tools-version: 6.2\nimport PackageDescription\nlet package = Package(name: "NativeSteerRecovery", platforms: [.macOS(.v14)], dependencies: [.package(path: ${JSON.stringify(packagePath)})], targets: [.executableTarget(name: "Worker", dependencies: [.product(name: "LibFx", package: "swift")])])\n`);
  await writeFile(join(packageRoot, 'Sources', 'Worker', 'Worker.swift'), source);
  const scratch = join(directory, 'build');
  console.log('Building isolated native steering queue worker');
  await child('swift', ['build', '--package-path', packageRoot, '--scratch-path', scratch, '--product', 'Worker'], { kind: 'build' });
  const path = await child('swift', ['build', '--package-path', packageRoot, '--scratch-path', scratch, '--show-bin-path'], { kind: 'build' });
  const binary = join(path.stdout.trim(), 'Worker');
  for (const kind of ['text', 'image']) {
    const store = join(directory, kind); await mkdir(store);
    // Observe SQLite after commit: a strictly larger expiry proves a successful
    // native renewal, rather than merely observing a renewal attempt callback.
    const expiry = () => {
      const query = spawnSync('/usr/bin/sqlite3', ['-readonly', join(store, 'sessions.sqlite'), "SELECT lease_until FROM fx_sessions WHERE id='steer-started-turn'"], { encoding: 'utf8' });
      assert.equal(query.status, 0, query.stderr);
      const value = Number(query.stdout.trim()); assert.ok(value > Date.now()); return value;
    };
    const killed = await child(binary, ['crash', kind, store], { marker: true, kind: `${kind}-crash`, afterMarker: async report => {
      const initial = expiry(), deadline = Date.now() + leaseMilliseconds * 3;
      let renewed = initial;
      while (renewed <= initial) {
        assert.ok(Date.now() < deadline, 'Native timed owner did not commit a renewal');
        await new Promise(resolve => setTimeout(resolve, 20));
        renewed = expiry();
      }
      report.renewal = { initialExpiry: initial, renewedExpiry: renewed };
    } });
    const lastExpiry = expiry();
    const recovered = await child(binary, ['recover', kind, store], { kind: `${kind}-recover` });
    const before = killed.stdout.trim().split('\n').map(JSON.parse), after = recovered.stdout.trim().split('\n').map(JSON.parse);
    assert.deepEqual(before.map(({ executedAt, ...fields }) => fields), [{ execution: 'stable-lookup' }]);
    assert.deepEqual(after.map(({ executedAt, ...fields }) => fields), [{ waitingForLease: true }, { execution: 'stable-lookup' }, { completed: true, starts: 1, ends: 1, requests: 1 }]);
    assert.ok(after[1].executedAt >= lastExpiry, 'Fresh worker admitted its tool before the last renewed lease expired');
    // Allow three lease durations for process startup, the queue's returned
    // retry delay and native execution; this is below the 30 s delivery limit.
    assert.ok(Date.now() < lastExpiry + leaseMilliseconds * 3, 'Recovery exceeded the lease-derived window');
    recovered.recovery = { lastExpiry, completedAt: Date.now(), toolExecutedAt: after[1].executedAt, deliveryMaximumMilliseconds: 30_000 };
    console.log(`Native ${kind} steer SIGKILL queue redelivery passed: renewed lease expired, stable tool id, one guidance, one end`);
  }
} finally {
  const report = new URL('../../.build/native-steer-redelivery-results.json', import.meta.url);
  await mkdir(new URL('.', report), { recursive: true });
  await writeFile(report, JSON.stringify({ reports }, null, 2) + '\n');
  await rm(directory, { recursive: true, force: true });
}
