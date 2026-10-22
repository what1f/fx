import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { mkdirSync, writeFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';

const cases = [
  'a prompt runs its steps, and the session replays from any cursor',
  'a prompt sent when the last turn ends starts without waiting for its engine to shut down',
  "a prompt's signal cancels its own turn, whether it runs or waits, and never another",
  "an image prompt its first worker could not start runs from the log with the same base64, once",
  "an image block is read once, so the log holds what was checked",
  "a new session's id can come before its first prompt, and null is no id",
  "each prompt's turn runs with its own caller's context, resumed or not",
  "each prompt's turn runs with its session object's settings, resumed or not",
  'a turn longer than the time limit continues in the next delivery, each step once',
  'two agents prompting one session run its turns one at a time, in one history',
  "agents with different names each run only their own sessions' turns",
  'a retried message runs its turn once',
  'a turn that ends before writing a record runs once, and the session goes on',
  'a harness that throws instead of starting a turn is replaced, and no prompt is lost',
  'a turn whose harness stops under it, and the prompts behind it, still run',
  'an engine that stops each time it starts a turn ends that turn, and the session goes on',
  'a turn whose engine stops after its end landed still ends for its viewers',
  'a started turn whose engine keeps stopping is cancelled, and the prompts behind it run',
  'an engine that cannot open again fails the open turn once, then each prompt waiting',
  'a stuck turn whose engine then cannot open is not opened forever',
  'a cancel for a turn whose engine cannot open is not retried forever',
  'an outage while a stuck turn is cancelled does not halt the session',
  'an outage while a cancel waits does not halt the session',
  'a lone started turn whose engine stops even when cancelled ends, and the session refuses more turns',
  'a turn whose end is still landing when its engine stops ends as unknown',
];
const args = ['--no-warnings', '--loader', './swift/Tests/Conformance/loader.mjs', 'sdk/tests/test-durable-core.mjs', 'memory'];
const child = spawnSync(process.execPath, args, {
  cwd: fileURLToPath(new URL('../../../', import.meta.url)), env: { ...process.env, LIBFX_SWIFT_GENERIC_CASES: JSON.stringify(cases) },
  encoding: 'utf8', timeout: 60_000, maxBuffer: 4 * 1024 * 1024,
});
const report = new URL('../../.build/generic-core-results.json', import.meta.url);
mkdirSync(new URL('.', report), { recursive: true });
writeFileSync(report, JSON.stringify({ cases, args, driver: process.env.LIBFX_SWIFT_DRIVER, status: child.status,
  signal: child.signal, error: child.error?.message, stdout: child.stdout, stderr: child.stderr }, null, 2) + '\n');
process.stdout.write(child.stdout ?? '');
process.stderr.write(child.stderr ?? '');
assert.ifError(child.error);
assert.equal(child.status, 0);
assert.equal(child.signal, null);
assert.equal(child.stderr, '');
assert.ok(child.stdout.includes(`${cases.length}/${cases.length} selected core tests passed (memory)`));
