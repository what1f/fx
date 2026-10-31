import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { mkdirSync, writeFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';

// Original local branches use actual files and model requests. The memory
// branches' JavaScript log/image inspection hooks are not qualified here.
const cases = [
  'a durable session saves each image once, and a new agent sends it again',
  "a durable session saves a tool's image once, its log only names it, and a new agent sends it again",
  'a durable steer saves its image once, and its log entry only names it',
];
if (process.argv[2] === '--list') {
  console.log(JSON.stringify({ owner: 'sdk/tests/test-durable.mjs', durability: 'local', backend: 'native', cases }, null, 2));
} else {
  assert.ok(process.env.LIBFX_SWIFT_DRIVER, 'Set LIBFX_SWIFT_DRIVER to the built Swift driver');
  const cwd = fileURLToPath(new URL('../../../', import.meta.url));
  const report = new URL('../../.build/generic-durable-images-results.json', import.meta.url);
  const results = [];
  for (const name of cases) {
    const args = ['--no-warnings', '--loader', './swift/Tests/Conformance/loader.mjs',
      'sdk/tests/test-durable.mjs', 'local', 'native'];
    const child = spawn(process.execPath, args, { cwd, detached: true,
      env: { ...process.env, LIBFX_TEST_ONLY: name }, stdio: ['ignore', 'pipe', 'pipe'] });
    let stdout = '', stderr = '', error;
    const killGroup = () => { try { process.kill(-child.pid, 'SIGKILL'); } catch {} };
    const timer = setTimeout(() => { error ??= 'Original durable image case exceeded 45000 ms'; killGroup(); }, 45_000);
    child.stdout.setEncoding('utf8'); child.stderr.setEncoding('utf8');
    child.stdout.on('data', data => { stdout += data; });
    child.stderr.on('data', data => { stderr += data; });
    child.on('error', failure => { error = failure.message; });
    const { status, signal } = await new Promise(resolve => child.once('close', (status, signal) => resolve({ status, signal })));
    clearTimeout(timer);
    killGroup();
    results.push({ name, args, driver: process.env.LIBFX_SWIFT_DRIVER, status, signal, error, stdout, stderr });
    mkdirSync(new URL('.', report), { recursive: true });
    writeFileSync(report, JSON.stringify(results, null, 2) + '\n');
    process.stdout.write(stdout); process.stderr.write(stderr);
    assert.equal(error, undefined);
    assert.equal(status, 0);
    assert.equal(signal, null);
    assert.equal(stderr, '');
    assert.ok(stdout.includes(`ok ${name} (`), 'The exact original case ran');
    assert.ok(stdout.includes('1/1 durable tests passed (local, native)'), 'Exactly one original case passed');
  }
}
