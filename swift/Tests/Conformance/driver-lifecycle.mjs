import assert from 'node:assert/strict';
import { mkdtemp, writeFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { createFxEngine } from './adapter.mjs';

// This tests the conformance runner's failure detection, not SDK behavior.
const directory = await mkdtemp(join(tmpdir(), 'libfx-driver-lifecycle-'));
const driver = join(directory, 'driver.cjs');
const saved = { driver: process.env.LIBFX_SWIFT_DRIVER, mode: process.env.LIBFX_FIXTURE_TERMINATION };
try {
  await writeFile(driver, `#!/usr/bin/env node
const { createInterface } = require('node:readline');
const { writeSync } = require('node:fs');
const { spawn } = require('node:child_process');
const lines = createInterface({ input: process.stdin });
lines.on('line', line => {
  const { id, op } = JSON.parse(line);
  let result = null;
  if (op === 'open' || op === 'openAgent') result = { sessionId: 'fixture', resumable: false, runningCalls: [] };
  if (op === 'observationOpen') result = { scope: {}, parent: {}, captureContent: false };
  process.stdout.write(JSON.stringify({ id, result }) + '\\n');
});
lines.on('close', () => {
  const mode = process.env.LIBFX_FIXTURE_TERMINATION;
  if (mode === 'exit') process.exit(17);
  if (mode === 'signal') process.kill(process.pid, 'SIGTERM');
  if (mode === 'stderr') writeSync(2, 'fixture diagnostic\\n');
  if (mode === 'late-stderr') {
    const late = spawn(process.execPath, ['-e', "setTimeout(() => require('node:fs').writeSync(2, 'fixture diagnostic' + String.fromCharCode(10)), 40)"],
      { stdio: ['ignore', 'ignore', 2] });
    late.unref();
  }
  process.exit(0);
});
`, { mode: 0o755 });
  process.env.LIBFX_SWIFT_DRIVER = driver;
  for (const surface of ['engine', 'agent', 'observation', 'inspect', 'models']) {
    for (const mode of ['success', 'exit', 'signal', 'stderr', 'late-stderr']) {
      process.env.LIBFX_FIXTURE_TERMINATION = mode;
      const exercise = async () => {
        const options = surface === 'agent' ? { __agent: true } : surface === 'inspect' ? { __inspect: true }
          : surface === 'models' ? { __listModels: true } : surface === 'observation'
            ? { hooks: { onEvent() {} }, __observationFixture: { scope: {}, callID: 'call', signal: new AbortController().signal } } : {};
        const engine = await createFxEngine(options);
        if (surface !== 'inspect' && surface !== 'models') await engine.close();
      };
      if (mode === 'success') await exercise();
      else await assert.rejects(exercise(), { message: mode === 'exit' ? /^Swift driver exited: 17$/
        : mode === 'signal' ? /^Swift driver exited: SIGTERM$/ : /^Swift driver exited: 0\nfixture diagnostic\n$/ });
    }
  }
  process.env.LIBFX_SWIFT_DRIVER = join(directory, 'missing');
  await assert.rejects(createFxEngine(), /ENOENT|closed|EPIPE/);
  console.log('Conformance driver lifecycle passed: all surfaces reject abnormal exit, signals and drained stderr; failed spawn settles');
} finally {
  for (const [key, value] of [['LIBFX_SWIFT_DRIVER', saved.driver], ['LIBFX_FIXTURE_TERMINATION', saved.mode]]) {
    if (value === undefined) delete process.env[key]; else process.env[key] = value;
  }
  await rm(directory, { recursive: true, force: true });
}
