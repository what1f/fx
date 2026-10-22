import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { mkdirSync, writeFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';

const cases = [
  'a crash during save reruns the idempotent call under the same execution id',
];
const results = [];
for (const name of cases) {
  const args = ['--no-warnings', '--loader', './swift/Tests/Conformance/loader.mjs',
    'sdk/tests/test-durable.mjs', 'local', 'native'];
  const child = spawnSync(process.execPath, args, {
    cwd: fileURLToPath(new URL('../../../', import.meta.url)), env: { ...process.env, LIBFX_TEST_ONLY: name },
    detached: true, encoding: 'utf8', timeout: 45_000, maxBuffer: 4 * 1024 * 1024,
  });
  try { process.kill(-child.pid, 'SIGKILL'); } catch {}
  results.push({ name, args, driver: process.env.LIBFX_SWIFT_DRIVER, status: child.status, signal: child.signal,
    error: child.error?.message, stdout: child.stdout, stderr: child.stderr });
  const report = new URL('../../.build/generic-durable-additions-results.json', import.meta.url);
  mkdirSync(new URL('.', report), { recursive: true });
  writeFileSync(report, JSON.stringify(results, null, 2) + '\n');
  process.stdout.write(child.stdout ?? '');
  process.stderr.write(child.stderr ?? '');
  assert.ifError(child.error);
  assert.equal(child.status, 0);
  assert.equal(child.signal, null);
  assert.equal(child.stderr, '');
  assert.ok(child.stdout.includes('1/1 durable tests passed (local, native)'));
}
