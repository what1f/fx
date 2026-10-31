import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { mkdirSync, writeFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';

// Original assertions execute Swift steering, deadline and process recovery.
// The JavaScript queueDurable descriptor flag does not qualify a World queue.
const cases = [
  {
    "durability": "memory",
    "name": "on a queue that outlives the process, a steer reusing a prompt's id is refused and runs nothing"
  },
  {
    "durability": "memory",
    "name": "on a queue that outlives the process, a steer with an image that starts a turn runs it once, with the image"
  },
  {
    "durability": "memory",
    "name": "on a queue that outlives the process, a text steer that starts a turn reaches the model once"
  },
  {
    "durability": "memory",
    "name": "on a queue that outlives the process, a turn a steer started still takes the steers after it"
  },
  {
    "durability": "memory",
    "name": "on a queue that outlives the process, a cancel still ends a turn a steer started"
  },
  {
    "durability": "memory",
    "name": "on a queue that outlives the process, a turn a steer started that the deadline cuts off continues once in the next delivery"
  },
  {
    "durability": "local",
    "name": "a crash during a turn a text steer started on a queue that outlives the process goes on once on another worker, by a resume"
  },
  {
    "durability": "local",
    "name": "a crash during a turn an image steer started on a queue that outlives the process goes on once on another worker, by a resume"
  }
];
if (process.argv[2] === '--list') {
  console.log(JSON.stringify({ owner: 'sdk/tests/test-durable.mjs', backend: 'native', cases }, null, 2));
} else {
  assert.ok(process.env.LIBFX_SWIFT_DRIVER, 'Set LIBFX_SWIFT_DRIVER to the built Swift driver');
  const cwd = fileURLToPath(new URL('../../../', import.meta.url));
  const report = new URL('../../.build/generic-durable-steer-start-results.json', import.meta.url);
  const results = [];
  for (const { name, durability } of cases) {
    const args = ['--no-warnings', '--loader', './swift/Tests/Conformance/loader.mjs',
      'sdk/tests/test-durable.mjs', durability, 'native'];
    const child = spawn(process.execPath, args, { cwd, detached: true,
      env: { ...process.env, LIBFX_TEST_ONLY: name }, stdio: ['ignore', 'pipe', 'pipe'] });
    let stdout = '', stderr = '', error;
    const killGroup = () => { try { process.kill(-child.pid, 'SIGKILL'); } catch {} };
    const timer = setTimeout(() => { error ??= 'Original durable steering case exceeded 45000 ms'; killGroup(); }, 45_000);
    child.stdout.setEncoding('utf8'); child.stderr.setEncoding('utf8');
    child.stdout.on('data', data => { stdout += data; });
    child.stderr.on('data', data => { stderr += data; });
    child.on('error', failure => { error = failure.message; });
    const { status, signal } = await new Promise(resolve => child.once('close', (status, signal) => resolve({ status, signal })));
    clearTimeout(timer);
    killGroup();
    results.push({ name, durability, args, driver: process.env.LIBFX_SWIFT_DRIVER, status, signal, error, stdout, stderr });
    mkdirSync(new URL('.', report), { recursive: true });
    writeFileSync(report, JSON.stringify(results, null, 2) + '\n');
    process.stdout.write(stdout); process.stderr.write(stderr);
    assert.equal(error, undefined);
    assert.equal(status, 0);
    assert.equal(signal, null);
    assert.equal(stderr, '');
    assert.ok(stdout.includes(`ok ${name} (`), 'The exact original case ran');
    assert.ok(stdout.includes(`1/1 durable tests passed (${durability}, native)`), 'Exactly one original case passed');
  }
}
