import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { writeFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';

const selections = [
  ['memory', "a prompt to another agent's session runs on that session's agent"],
  ['local', "agents on one durability, each on a World of its own, still send each other's prompts on"],
];
const results = [];
for (const [kind, name] of selections) {
  const child = spawnSync(process.execPath, ['--no-warnings', '--loader', './swift/Tests/Conformance/loader.mjs',
    'sdk/tests/test-durable-core.mjs', kind], {
    cwd: fileURLToPath(new URL('../../../', import.meta.url)), env: { ...process.env, LIBFX_SWIFT_GENERIC_CASES: JSON.stringify([name]) },
    encoding: 'utf8', timeout: 30_000, maxBuffer: 4 * 1024 * 1024,
  });
  results.push({ kind, name, driver: process.env.LIBFX_SWIFT_DRIVER, status: child.status, signal: child.signal,
    stdout: child.stdout, stderr: child.stderr, error: child.error?.message });
  writeFileSync(new URL('../../.build/generic-routing-results.json', import.meta.url), JSON.stringify(results, null, 2) + '\n');
  process.stdout.write(child.stdout ?? '');
  process.stderr.write(child.stderr ?? '');
  assert.ifError(child.error);
  assert.equal(child.status, 0);
  assert.equal(child.signal, null);
  assert.equal(child.stderr, '');
  assert.ok(child.stdout.includes(`1/1 selected core tests passed (${kind})`));
}
console.log('Generic routing passed: original executor ownership and cross-agent forwarding');
