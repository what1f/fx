import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { mkdtemp, writeFile, readFile, rm, mkdir } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';

// This companion uses the original fixture and counters. It is separate from
// upstream-case coverage: neither process parses the fixture's opaque journal.
const cwd = fileURLToPath(new URL('../../../', import.meta.url));
const directory = await mkdtemp(join(tmpdir(), 'libfx-generic-fresh-host-'));
const marker = join(directory, 'completed-append');
const adapter = new URL('./generic-adapter.mjs', import.meta.url).href;
const original = new URL('../../../sdk/tests/test-durable-core.mjs', import.meta.url).href;
const reports = [];
const crashTimeoutMs = 15_000;
function launch(mode) {
  const script = `
    import assert from 'node:assert/strict';
    import { writeFile } from 'node:fs/promises';
    import { createDurableAgentFactory, local } from ${JSON.stringify(adapter)};
    import { scriptedHarness, prompted, ran } from ${JSON.stringify(original)};
    const base = scriptedHarness()();
    const harness = ${JSON.stringify(mode)} === 'crash' ? {
      open: options => base.open({ ...options, store: {
        ...options.store,
        async append(request) {
          const cursor = await options.store.append(request);
          if (request.marks?.some(mark => mark.end === true)) {
            await writeFile(${JSON.stringify(marker)}, 'native completed append acknowledged');
            await new Promise(() => {});
          }
          return cursor;
        },
      }}),
    } : base;
    const create = createDurableAgentFactory({ harness: () => harness,
      defaultDurability: () => local({ dir: ${JSON.stringify(directory)} }) });
    const agent = create();
    const session = agent.session('opaque-fresh-host');
    const turn = session.prompt('alpha', { messageId: 'turn-completed-before-crash' });
    if (${JSON.stringify(mode)} === 'crash') {
      await turn.result;
      throw new Error('crash fixture unexpectedly settled');
    }
    const result = await turn.result;
    assert.equal(result.stopReason, 'unknown');
    assert.equal(result.repeated, true);
    assert.deepEqual(prompted, [], 'fresh host never starts the completed turn again');
    assert.deepEqual(ran, [], 'fresh host never repeats a completed step');
    assert.deepEqual(JSON.parse(new TextDecoder().decode(await session.checkpoint())), ['alpha-0', 'alpha-1', 'alpha-2']);
    assert.equal((await session.prompt('beta', { messageId: 'after-recovery' }).result).stopReason, 'end_turn');
    assert.deepEqual(prompted, ['after-recovery']);
    assert.deepEqual(JSON.parse(new TextDecoder().decode(await session.checkpoint())),
      ['alpha-0', 'alpha-1', 'alpha-2', 'beta-0', 'beta-1', 'beta-2']);
    await agent.close();
    console.log('fresh-host opaque completion recovered without reexecution; next turn runs');
  `;
  const child = spawn(process.execPath, ['--no-warnings', '--loader', './swift/Tests/Conformance/loader.mjs',
    '--input-type=module', '-e', script], { cwd, detached: true,
    env: { ...process.env, LIBFX_SWIFT_GENERIC_FIXTURE_ONLY: '1' }, stdio: ['ignore', 'pipe', 'pipe'] });
  const report = { mode, stdout: '', stderr: '' };
  child.stdout.on('data', data => { report.stdout += data; });
  child.stderr.on('data', data => { report.stderr += data; });
  const exited = new Promise(resolve => child.once('close', (status, signal) => {
    Object.assign(report, { status, signal }); resolve(report);
  }));
  const kill = () => { try { process.kill(-child.pid, 'SIGKILL'); } catch {} };
  const timer = setTimeout(() => { report.timedOut = true; kill(); }, crashTimeoutMs);
  exited.finally(() => { clearTimeout(timer); kill(); });
  return { report, exited, kill };
}
try {
  const crash = launch('crash');
  const deadline = Date.now() + crashTimeoutMs;
  let acknowledged = false;
  while (Date.now() < deadline && crash.report.status === undefined && crash.report.signal === undefined) {
    try { acknowledged = (await readFile(marker, 'utf8')).includes('acknowledged'); } catch {}
    if (acknowledged) break;
    await new Promise(resolve => setTimeout(resolve, 20));
  }
  crash.kill();
  reports.push(await crash.exited);
  assert.equal(acknowledged, true, JSON.stringify(crash.report));
  assert.equal(crash.report.timedOut, undefined);
  assert.equal(crash.report.signal, 'SIGKILL');
  assert.equal(crash.report.stderr, '');
  const recovered = launch('recover');
  reports.push(await recovered.exited);
  assert.equal(recovered.report.timedOut, undefined);
  assert.equal(recovered.report.status, 0, recovered.report.stdout + recovered.report.stderr);
  assert.equal(recovered.report.signal, null);
  assert.equal(recovered.report.stderr, '');
  assert.match(recovered.report.stdout, /fresh-host opaque completion recovered without reexecution/);
  console.log('Generic fresh-host completion passed: native append acknowledged, host and driver killed, fresh process recovers without reexecution');
} finally {
  const reportURL = new URL('../../.build/generic-fresh-host-results.json', import.meta.url);
  await mkdir(new URL('.', reportURL), { recursive: true });
  await writeFile(reportURL, JSON.stringify({ driver: process.env.LIBFX_SWIFT_DRIVER, reports }, null, 2) + '\n');
  await rm(directory, { recursive: true, force: true });
}
