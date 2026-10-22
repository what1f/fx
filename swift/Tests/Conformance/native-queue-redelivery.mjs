import assert from 'node:assert/strict';
import { spawn, spawnSync } from 'node:child_process';
import { mkdtemp, mkdir, writeFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';

// Public Swift queue-authority proof, not an unchanged JS World/provider test.
// JS launches/kills processes and inspects committed SQLite state. Acceptance,
// authenticated-context handling, native execution, journal recovery and replay
// use the public Swift SDK. The verifier represents a trusted local mock host.
const directory = await mkdtemp(join(tmpdir(), 'libfx-native-queue-redelivery-'));
const packageRoot = join(directory, 'consumer');
const packagePath = fileURLToPath(new URL('../..', import.meta.url));
const reports = [];
const source = String.raw`
import Foundation
import LibFx

func emit(_ fields: [String: JSONValue]) throws {
    var bytes = try JSONEncoder().encode(JSONValue.object(fields)); bytes.append(10)
    try FileHandle.standardOutput.write(contentsOf: bytes)
}
actor WakeQueue: FxSessionQueue {
    let file: URL
    init(_ file: URL) { self.file = file }
    func enqueue(_ wakeup: FxSessionWakeup) throws {
        try JSONEncoder().encode(wakeup).write(to: file, options: .atomic)
    }
}
struct HostReceipt: Sendable {
    let wakeup: FxSessionWakeup
    let attempt: Int64
}
actor Lookup {
    let crash: Bool
    private var held: CheckedContinuation<Void, Never>?
    private(set) var executions: [String] = []
    init(crash: Bool) { self.crash = crash }
    func execute(_ context: FxToolContext) async throws -> FxToolResult {
        executions.append(context.executionID)
        try emit(["execution": .string(context.executionID), "pid": .number(Double(ProcessInfo.processInfo.processIdentifier))])
        if crash { await withCheckedContinuation { held = $0 } }
        return FxToolResult(text: "recovered lookup")
    }
}
actor Gateway: FxHTTPClient {
    let crash: Bool
    private(set) var requests = 0
    init(crash: Bool) { self.crash = crash }
    func send(_ request: URLRequest) throws -> FxHTTPResponse {
        requests += 1
        let body = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
        guard requests == 1, body.components(separatedBy: "durable prompt").count - 1 == 1 else {
            throw FxError.invalidInput("Input was not recovered exactly once")
        }
        let events: [JSONValue]
        if crash {
            events = [
                .object(["type": .string("tool-call"), "toolCallId": .string("stable-lookup"), "toolName": .string("lookup"), "input": .object([:])]),
                .object(["type": .string("finish"), "finishReason": .object(["unified": .string("tool-calls"), "raw": .string("tool-calls")])]),
            ]
        } else {
            guard body.contains("recovered lookup") else { throw FxError.invalidInput("Original tool was not resumed") }
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
        let crash = CommandLine.arguments[1] == "crash"
        let equal = CommandLine.arguments[2] == "equal"
        let directory = URL(fileURLWithPath: CommandLine.arguments[3])
        let source = "native-queue/mock-account/test-tenant"
        let policy = try FxSessionLeasePolicy(duration: .seconds(60), renewalInterval: .seconds(20))
        let store = try FxSessionStore(url: directory.appendingPathComponent("sessions.sqlite"), leasePolicy: policy, queueSource: source)
        let queue = WakeQueue(directory.appendingPathComponent("wakeup.json"))
        let lookup = Lookup(crash: crash), http = Gateway(crash: crash)
        let tool = FxTool(name: "lookup", description: "Read safely", inputSchema: .object(["type": .string("object")]), isIdempotent: true) { _, context in
            try await lookup.execute(context)
        }
        var configuration = FxConfiguration(apiKey: "fixture", model: "swift/queue-redelivery", tools: [tool], httpClient: http)
        configuration.modelCatalog = try FxModelCatalog(response: Data(#"{"data":[{"id":"swift/queue-redelivery","type":"language","tags":["tool-use"]}]}"#.utf8))
        let authority = try FxQueueDeliveryAuthority(source: source, allowsSameAttemptRedelivery: equal) {
            (wakeup: FxSessionWakeup, metadata: HostReceipt) async throws -> FxQueueReceipt in
            guard wakeup == metadata.wakeup,
                  wakeup == FxSessionWakeup(agent: "default", sessionID: "queue-session", inputID: "request-one") else {
                throw FxQueueDeliveryError.invalidContext
            }
            return try FxQueueReceipt(messageID: "queue-message-one", attempt: metadata.attempt)
        }
        let agent = try FxAgent(configuration: configuration, store: store, checkpointAfterBytes: nil, queue: queue, queueAuthority: authority)
        let session = try await agent.session(id: "queue-session")
        if crash { _ = try await session.prompt("durable prompt", id: "request-one") }
        let wakeup = try JSONDecoder().decode(FxSessionWakeup.self, from: Data(contentsOf: directory.appendingPathComponent("wakeup.json")))
        let attempt: Int64 = crash || equal ? 1 : 2
        let deliveryPolicy = try FxDeliveryPolicy(maximumDuration: .seconds(15), reserve: .seconds(1))
        let outcome = try await agent.deliver(wakeup, context: FxQueueDeliveryContext(HostReceipt(wakeup: wakeup, attempt: attempt)), policy: deliveryPolicy)
        guard outcome == .complete, !crash else { throw FxError.invalidInput("Queue redelivery did not complete immediately") }
        // A fresh callback for an already completed input must not execute again.
        guard try await agent.deliver(wakeup, context: FxQueueDeliveryContext(HostReceipt(wakeup: wakeup, attempt: attempt + 1)), policy: deliveryPolicy) == .complete else {
            throw FxError.busy
        }
        guard let result = try await store.result(session: session.id, agent: "default", id: "request-one"),
              result.id == "request-one", result.stopReason == .endTurn else { throw FxError.invalidInput("Missing recovered result") }
        let entries = try await store.entries(session: session.id, agent: "default", after: 0)
        let starts = entries.filter { if case .started(let id, _, _) = $0.event { return id == "request-one" }; return false }.count
        let ends = entries.filter { if case .ended(let result) = $0.event { return result.id == "request-one" }; return false }.count
        guard starts == 1, ends == 1, await lookup.executions == ["stable-lookup"], await http.requests == 1,
              let first = entries.first(where: { if case .started = $0.event { return true }; return false }),
              case .started(_, _, let input) = first.event, input == [.text("durable prompt")] else {
            throw FxError.invalidInput("Recovery duplicated or changed accepted work")
        }
        try await agent.close(); try await store.close()
        try emit(["completed": .bool(true), "inputID": .string(result.id), "starts": .number(Double(starts)),
                  "ends": .number(Double(ends)), "requests": .number(1), "attempt": .number(Double(attempt))])
    }
}
`;

async function child(command, args, { crash = false, kind, beforeKill } = {}) {
  const process = spawn(command, args, { detached: true, stdio: ['ignore', 'pipe', 'pipe'] });
  const report = { kind, stdout: '', stderr: '' }; reports.push(report);
  let mark;
  const marked = new Promise(resolve => { mark = resolve; });
  process.stdout.on('data', bytes => { report.stdout += bytes; if (report.stdout.includes('"execution"')) mark(); });
  process.stderr.on('data', bytes => { report.stderr += bytes; });
  const kill = () => { try { globalThis.process.kill(-process.pid, 'SIGKILL'); } catch {} };
  const exited = new Promise(resolve => process.once('close', (status, signal) => { Object.assign(report, { status, signal }); resolve(); }));
  const timer = setTimeout(() => { report.timedOut = true; kill(); }, kind === 'build' ? 120_000 : 15_000);
  try {
    if (crash) {
      await Promise.race([marked, exited]);
      assert.ok(report.stdout.includes('"execution"'), JSON.stringify(report));
      beforeKill(report);
      kill();
    }
    await exited;
    assert.equal(report.timedOut, undefined, JSON.stringify(report));
    if (crash) assert.equal(report.signal, 'SIGKILL', JSON.stringify(report));
    else assert.equal(report.status, 0, report.stdout + report.stderr);
    if (kind !== 'build') assert.equal(report.stderr, '');
    return report;
  } finally { clearTimeout(timer); kill(); }
}
function state(directory) {
  const query = spawnSync('/usr/bin/sqlite3', ['-readonly', '-json', join(directory, 'sessions.sqlite'),
    "SELECT epoch,owner,lease_until,head,delivery_source,delivery_message,delivery_attempt,delivery_process,(SELECT count(*) FROM fx_session_records WHERE session='queue-session') AS records,(SELECT started FROM fx_inputs WHERE session='queue-session' AND id='request-one') AS started FROM fx_sessions WHERE id='queue-session'"], { encoding: 'utf8' });
  assert.equal(query.status, 0, query.stderr);
  const rows = JSON.parse(query.stdout); assert.equal(rows.length, 1); return rows[0];
}
try {
  await mkdir(join(packageRoot, 'Sources', 'Worker'), { recursive: true });
  await writeFile(join(packageRoot, 'Package.swift'), `// swift-tools-version: 6.2\nimport PackageDescription\nlet package = Package(name: "NativeQueueRecovery", platforms: [.macOS(.v14)], dependencies: [.package(path: ${JSON.stringify(packagePath)})], targets: [.executableTarget(name: "Worker", dependencies: [.product(name: "LibFx", package: "swift")])])\n`);
  await writeFile(join(packageRoot, 'Sources', 'Worker', 'Worker.swift'), source);
  const scratch = '/tmp/libfx-queue-process';
  console.log('Building isolated public Swift queue-redelivery worker');
  await child('swift', ['build', '--package-path', packageRoot, '--scratch-path', scratch, '--product', 'Worker'], { kind: 'build' });
  const path = await child('swift', ['build', '--package-path', packageRoot, '--scratch-path', scratch, '--show-bin-path'], { kind: 'build' });
  const binary = join(path.stdout.trim(), 'Worker');
  for (const scenario of ['higher', 'equal']) {
    const directoryForStore = join(directory, scenario); await mkdir(directoryForStore);
    const killed = await child(binary, ['crash', scenario, directoryForStore], { crash: true, kind: `${scenario}-crash`, beforeKill: report => {
      const committed = state(directoryForStore);
      assert.ok(committed.owner && committed.head > 0 && committed.records > 0 && committed.started === 1);
      assert.equal(committed.delivery_attempt, 1);
      assert.equal(committed.delivery_message, 'queue-message-one');
      assert.equal(committed.delivery_source, 'native-queue/mock-account/test-tenant');
      assert.ok(committed.lease_until > Date.now() + 45_000, 'Old owner no longer has its 60-second grant');
      report.committed = committed;
    } });
    const old = state(directoryForStore), started = Date.now();
    const recovered = await child(binary, ['recover', scenario, directoryForStore], { kind: `${scenario}-recover` });
    const completedAt = Date.now(), current = state(directoryForStore);
    const before = killed.stdout.trim().split('\n').map(JSON.parse), after = recovered.stdout.trim().split('\n').map(JSON.parse);
    assert.equal(before.length, 1); assert.equal(after.length, 2);
    assert.equal(before[0].execution, 'stable-lookup'); assert.equal(after[0].execution, 'stable-lookup');
    assert.notEqual(before[0].pid, after[0].pid);
    assert.deepEqual(after[1], { completed: true, inputID: 'request-one', starts: 1, ends: 1, requests: 1, attempt: scenario === 'higher' ? 2 : 1 });
    assert.ok(completedAt - started < 10_000 && completedAt < old.lease_until, 'Replacement waited for the old TTL');
    assert.ok(current.epoch > old.epoch);
    assert.notEqual(current.delivery_process, old.delivery_process);
    recovered.takeover = { previousExpiry: old.lease_until, completedAt, elapsedMilliseconds: completedAt - started,
      previousEpoch: old.epoch, replacementEpoch: current.epoch, sameAttemptOptIn: scenario === 'equal' };
    console.log(`Native ${scenario}-attempt SIGKILL queue redelivery passed: immediate takeover before 60s TTL, stable tool/input IDs, one completion`);
  }
} finally {
  const report = new URL('../../.build/native-queue-redelivery-results.json', import.meta.url);
  await mkdir(new URL('.', report), { recursive: true });
  await writeFile(report, JSON.stringify({ reports }, null, 2) + '\n');
  await rm(directory, { recursive: true, force: true });
}
