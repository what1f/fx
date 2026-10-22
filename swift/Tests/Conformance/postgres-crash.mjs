import assert from 'node:assert/strict';
import { spawn, spawnSync } from 'node:child_process';
import { mkdtemp, mkdir, writeFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { createServer } from 'node:net';

// An independent public SwiftPM consumer, a real loopback PostgreSQL 17 server,
// and separate SIGKILLed/recovery processes. This does not qualify a cloud service.
const directory = await mkdtemp(join(tmpdir(), 'libfx-postgres-consumer-'));
const reportDirectory = process.env.LIBFX_POSTGRES_CONSUMER_REPORT ?? await mkdtemp(join(tmpdir(), 'libfx-postgres-consumer-report-'));
const packageRoot = join(directory, 'consumer');
const packagePath = fileURLToPath(new URL('../..', import.meta.url));
const pg = process.env.LIBFX_POSTGRES_BIN_DIR ?? '/opt/homebrew/opt/postgresql@17/bin';
const reports = [];
let started = false;
function command(binary, args, options = {}) {
  const value = spawnSync(binary, args, { encoding: 'utf8', ...options });
  reports.push({ kind: args[0], status: value.status, stdout: value.stdout, stderr: value.stderr });
  assert.equal(value.status, 0, value.stdout + value.stderr);
  return value.stdout.trim();
}
async function child(binary, args, { kind, marker } = {}) {
  const worker = spawn(binary, args, { stdio: ['ignore', 'pipe', 'pipe'] });
  const record = { kind, stdout: '', stderr: '' }; reports.push(record);
  let marked;
  const markerReached = new Promise(resolve => { marked = resolve; });
  worker.stdout.on('data', data => { record.stdout += data; if (marker && record.stdout.includes(marker)) marked(); });
  worker.stderr.on('data', data => { record.stderr += data; });
  const exited = new Promise(resolve => worker.once('close', (status, signal) => { Object.assign(record, { status, signal }); resolve(); }));
  const timer = setTimeout(() => { record.timedOut = true; worker.kill('SIGKILL'); }, kind === 'build' ? 240_000 : 30_000);
  try {
    if (marker) {
      await Promise.race([markerReached, exited]);
      assert.ok(record.stdout.includes(marker), record.stdout + record.stderr);
      worker.kill('SIGKILL');
    }
    await exited;
    assert.equal(record.timedOut, undefined, JSON.stringify(record));
    if (marker) assert.equal(record.signal, 'SIGKILL');
    else assert.equal(record.status, 0, record.stdout + record.stderr);
    return record;
  } finally { clearTimeout(timer); worker.kill('SIGKILL'); }
}
const support = String.raw`
import Foundation
import LibFx
import LibFxPostgres
import PostgresNIO

func emit(_ text: String) throws {
    try FileHandle.standardOutput.write(contentsOf: Data((text + "\n").utf8))
}
func drain(_ client: PostgresClient, _ query: PostgresQuery) async throws {
    for try await _ in try await client.query(query) {}
}
func check(_ condition: Bool, _ message: String) throws {
    guard condition else { throw FxError.invalidInput(message) }
}
func database() throws -> PostgresClient {
    let env = ProcessInfo.processInfo.environment
    return PostgresClient(configuration: .init(host: "127.0.0.1", port: Int(env["PGPORT"]!)!, username: "libfx_test", password: nil, database: "libfx_test", tls: .disable))
}
`;
const smoke = support + String.raw`
@main struct Consumer {
    static func main() async throws {
        let client = try database()
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { await client.run() }
            defer { group.cancelAll() }
            let policy = try FxSessionLeasePolicy(duration: .seconds(3), renewalInterval: .milliseconds(300))
            let store = try FxPostgresStore(client: client, namespace: "smoke", leasePolicy: policy)
            try await store.migrate()
            try emit("PUBLIC_CONSUMER_CONNECTED")
        }
    }
}
`;
const source = support + String.raw`
actor Gateway: FxHTTPClient {
    let mode: String
    let store: FxPostgresStore
    var requests = 0
    var held: CheckedContinuation<Void, Never>?
    init(mode: String, store: FxPostgresStore) { self.mode = mode; self.store = store }
    func send(_ request: URLRequest) async throws -> FxHTTPResponse {
        requests += 1
        let body = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
        var events: [JSONValue]
        if mode == "crash" && requests == 1 {
            events = [.object(["type": .string("text-delta"), "delta": .string("seed answer")]), .object(["type": .string("finish"), "finishReason": .object(["unified": .string("stop"), "raw": .string("stop")])])]
        } else if mode == "crash" && requests == 2 {
            try check(body.contains("image/png") && body.contains("seed answer"), "Seed checkpoint or image missing before effect")
            events = [.object(["type": .string("tool-call"), "toolCallId": .string("stable-write"), "toolName": .string("write_record"), "input": .object([:])]), .object(["type": .string("finish"), "finishReason": .object(["unified": .string("tool-calls"), "raw": .string("tool-calls")])])]
        } else {
            try check(body.contains("committed effect output") && body.contains("seed answer") && body.contains("image/png"), "Recovered history lost completed effect, checkpoint or image")
            if mode == "crash" {
                let snapshot = try await store.snapshot(session: "native", agent: "default")
                try check(snapshot.checkpoint != nil, "Seed checkpoint missing")
                try check(snapshot.journal.contains { String(decoding: $0.data, as: UTF8.self).contains("committed effect output") }, "Completed effect not durable in journal")
                try emit("NATIVE_TOOL_JOURNAL_COMMITTED")
                await withCheckedContinuation { held = $0 }
                throw CancellationError()
            }
            try check(mode == "recover" && requests == 1, "Recovery made unexpected model requests")
            events = [.object(["type": .string("text-delta"), "delta": .string("recovered answer")]), .object(["type": .string("finish"), "finishReason": .object(["unified": .string("stop"), "raw": .string("stop")])])]
        }
        let text = try events.map { "data: \(String(decoding: try JSONEncoder().encode($0), as: UTF8.self))\n\n" }.joined() + "data: [DONE]\n\n"
        return FxHTTPResponse(statusCode: 200, body: AsyncThrowingStream { $0.yield(Data(text.utf8)); $0.finish() })
    }
}
@main struct Consumer {
    static func main() async throws {
        let mode = CommandLine.arguments[1]
        let client = try database()
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { await client.run() }
            defer { group.cancelAll() }
            let policy = try FxSessionLeasePolicy(duration: .seconds(3), renewalInterval: .milliseconds(300))
            let store = try FxPostgresStore(client: client, namespace: mode.hasPrefix("producer") ? "producer" : "native", leasePolicy: policy)
            let queue = try FxPostgresQueue(client: client, namespace: store.namespace, visibilityDuration: .seconds(10), renewalInterval: .seconds(2))
            try await store.migrate()
            if mode == "producer" {
                _ = try await store.accept(session: "intake", agent: "default", id: "input", content: [.text("committed before explicit enqueue")], options: .init())
                try emit("PRODUCER_ACCEPT_COMMITTED")
                try await Task.sleep(for: .seconds(60))
                return
            }
            if mode == "producer-verify" {
                guard let delivery = try await queue.receive() else { throw FxError.invalidInput("Committed intake lost its wake") }
                try check(delivery.wakeup == FxSessionWakeup(agent: "default", sessionID: "intake"), "Unexpected producer wake")
                try await queue.complete(delivery)
                try emit("ATOMIC_WAKE_SURVIVED_PRODUCER_SIGKILL")
                return
            }
            if mode == "verify" {
                let snapshot = try await store.snapshot(session: "native", agent: "default")
                let result = try await store.result(session: "native", agent: "default", id: "work")
                let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jP0cAAAAASUVORK5CYII=")!
                let image = try await store.loadImage(named: FxSessionStorageValidation.imageName(for: png), session: "native", agent: "default")
                try check(snapshot.checkpoint != nil && snapshot.journal.isEmpty && result?.stopReason == .endTurn && image == png, "Fresh process lost checkpoint, image or result")
                try emit("FRESH_PROCESS_CHECKPOINT_IMAGE_RESULT_PASSED")
                return
            }
            try await drain(client, "CREATE TABLE IF NOT EXISTS consumer_effects(execution_id TEXT NOT NULL)")
            let http = Gateway(mode: mode, store: store)
            let tool = FxTool(name: "write_record", description: "Write a record", inputSchema: .object(["type": .string("object")]), isIdempotent: false, writes: true) { _, context in
                try await drain(client, "INSERT INTO consumer_effects VALUES(\(context.executionID))")
                try check(mode == "crash", "Completed non-idempotent effect was repeated")
                try check(context.executionID == "stable-write", "Execution identity changed")
                try emit("EFFECT_STABLE_EXECUTION_ID=\(context.executionID)")
                return FxToolResult(text: "committed effect output")
            }
            var configuration = FxConfiguration(apiKey: "fixture", model: "swift/postgres-crash", tools: [tool], httpClient: http)
            configuration.modelCatalog = try FxModelCatalog(response: Data(#"{"data":[{"id":"swift/postgres-crash","type":"language","tags":["tool-use","vision","file-input"]}]}"#.utf8))
            let router = FxAgentRouter(store: store)
            let agent = try await router.makeAgent(configuration: configuration, checkpointAfterBytes: 0, queue: queue)
            let session = try await agent.session(id: "native")
            if mode == "crash" {
                try emit("SEED_ACCEPT_START")
                let first = try await session.prompt("remember seed", id: "seed")
                try emit("SEED_ACCEPTED")
                guard let delivery = try await queue.receive() else { throw FxError.busy }
                try emit("SEED_DELIVER_START")
                try check(try await router.deliver(delivery.wakeup) == .complete, "Seed did not complete")
                try emit("SEED_DELIVERED")
                try await queue.complete(delivery)
                try emit("SEED_QUEUE_ACKED")
                try check(try await first.result.stopReason == .endTurn, "Seed result missing")
                let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jP0cAAAAASUVORK5CYII=")!
                try emit("WORK_ACCEPT_START")
                _ = try await session.prompt([.text("perform write"), .image(FxImage(data: png, format: .png))], id: "work")
                try emit("WORK_ACCEPTED")
            }
            let deadline = ContinuousClock.now.advanced(by: .seconds(20))
            while ContinuousClock.now < deadline {
                guard let delivery = try await queue.receive() else { try await Task.sleep(for: .milliseconds(20)); continue }
                let outcome = try await router.deliver(delivery.wakeup)
                if case .retry(let delay) = outcome { try await queue.retry(delivery, after: delay); continue }
                try await queue.complete(delivery)
                break
            }
            guard mode == "recover" else { throw FxError.invalidInput("Crash boundary was not reached") }
            let result = try await store.result(session: "native", agent: "default", id: "work")
            try check(result?.stopReason == .endTurn, "Recovery result missing")
            let snapshot = try await store.snapshot(session: "native", agent: "default")
            try check(snapshot.checkpoint != nil && snapshot.journal.isEmpty, "Recovered terminal checkpoint missing")
            let entries = try await store.entries(session: "native", agent: "default", after: 0)
            let ends = entries.filter { if case .ended(let result) = $0.event { result.id == "work" } else { false } }.count
            try check(ends == 1, "Work has duplicate terminal results")
            for try await row in try await client.query("SELECT count(*),min(execution_id) FROM consumer_effects") {
                let (count,id) = try row.decode((Int64,String?).self)
                try check(count == 1 && id == "stable-write", "Effect was lost or repeated")
            }
            try await agent.close()
            try emit("NATIVE_POSTGRES_SIGKILL_RECOVERY_PASSED")
        }
    }
}
`;
try {
  await mkdir(reportDirectory, { recursive: true });
  assert.match(command(join(pg, 'postgres'), ['--version']), /PostgreSQL\) 17\./);
  await mkdir(join(directory, 'socket'));
  command(join(pg, 'initdb'), ['-D', join(directory, 'data'), '-U', 'libfx_test', '-A', 'trust', '--no-locale', '-E', 'UTF8']);
  const port = await new Promise(resolve => { const server = createServer(); server.listen(0, '127.0.0.1', () => { const port = server.address().port; server.close(() => resolve(port)); }); });
  process.env.PGHOST = '127.0.0.1'; process.env.PGPORT = String(port); process.env.PGUSER = 'libfx_test'; process.env.PGDATABASE = 'libfx_test';
  command(join(pg, 'pg_ctl'), ['-D', join(directory, 'data'), '-l', join(reportDirectory, 'postgres.log'), '-w', 'start', '-o', `-h 127.0.0.1 -p ${port} -k ${join(directory, 'socket')} -c max_connections=40 -c shared_buffers=16MB`]); started = true;
  command(join(pg, 'createdb'), ['libfx_test']);
  await mkdir(join(packageRoot, 'Sources', 'Consumer'), { recursive: true });
  await writeFile(join(packageRoot, 'Package.swift'), `// swift-tools-version: 6.2\nimport PackageDescription\nlet package = Package(name: "PostgresPublicConsumer", platforms: [.macOS(.v14)], dependencies: [.package(path: ${JSON.stringify(packagePath)}), .package(url: "https://github.com/vapor/postgres-nio.git", from: "1.33.2")], targets: [.executableTarget(name: "Consumer", dependencies: [.product(name: "LibFx", package: "swift"), .product(name: "LibFxPostgres", package: "swift"), .product(name: "PostgresNIO", package: "postgres-nio")])])\n`);
  const sourcePath = join(packageRoot, 'Sources', 'Consumer', 'Consumer.swift');
  const scratch = process.env.LIBFX_POSTGRES_CONSUMER_SCRATCH ?? join(directory, 'build');
  const build = () => child('swift', ['build', '--package-path', packageRoot, '--scratch-path', scratch, '--product', 'Consumer'], { kind: 'build' });
  await writeFile(sourcePath, smoke); await build();
  const path = await child('swift', ['build', '--package-path', packageRoot, '--scratch-path', scratch, '--show-bin-path'], { kind: 'build' });
  const binary = join(path.stdout.trim(), 'Consumer');
  await child(binary, [], { kind: 'public-smoke' });
  console.log('Independent public SwiftPM consumer connected to PostgreSQL');
  await writeFile(sourcePath, source); await build();
  await child(binary, ['producer'], { kind: 'producer-kill', marker: 'PRODUCER_ACCEPT_COMMITTED' });
  await child(binary, ['producer-verify'], { kind: 'producer-verify' });
  await child(binary, ['crash'], { kind: 'native-kill', marker: 'NATIVE_TOOL_JOURNAL_COMMITTED' });
  assert.equal(command(join(pg, 'psql'), ['-X', '-A', '-t', '-c', "SELECT owner IS NOT NULL AND lease_until>clock_timestamp() FROM fx_pg_sessions WHERE namespace='native' AND session_id='native'"]), 't');
  const expiryQuery = [ '-X', '-A', '-t', '-c', "SELECT lease_until<=clock_timestamp() FROM fx_pg_sessions WHERE namespace='native' AND session_id='native'" ];
  const expiryDeadline = Date.now() + 6_000;
  while (command(join(pg, 'psql'), expiryQuery) !== 't') {
    assert.ok(Date.now() < expiryDeadline, 'Killed worker lease did not expire by the database clock');
    await new Promise(resolve => setTimeout(resolve, 50));
  }
  await child(binary, ['recover'], { kind: 'native-recovery' });
  await child(binary, ['verify'], { kind: 'fresh-process-verification' });
  console.log('Real PostgreSQL SIGKILL recovery passed: atomic wake, completed non-idempotent tool, stable execution ID, image, checkpoints, one result');
} finally {
  if (started) command(join(pg, 'pg_ctl'), ['-D', join(directory, 'data'), '-m', 'immediate', '-w', 'stop']);
  await writeFile(join(reportDirectory, 'results.json'), JSON.stringify({ reports }, null, 2) + '\n');
  console.log(`PostgreSQL consumer report: ${reportDirectory}`);
  await rm(directory, { recursive: true, force: true });
}
