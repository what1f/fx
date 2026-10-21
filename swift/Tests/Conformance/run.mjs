import { spawnSync } from 'node:child_process';
import { mkdirSync, writeFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';

const root = fileURLToPath(new URL('../../../', import.meta.url));
const checks = [
  ...['test-host-tools', 'test-agent-step-limit', 'test-host-tool-cancel', 'test-agent-steering', 'test-list-models', 'test-agent-effort', 'test-agent-fast'].map(name => ({
    name: `upstream/${name}`, args: ['--no-warnings', '--loader', './swift/Tests/Conformance/loader.mjs', `sdk/tests/${name}.mjs`, 'native'],
  })),
  { name: 'upstream/test-agent-steering-hooks', args: [
    '--no-warnings', '--loader', './swift/Tests/Conformance/loader.mjs', 'sdk/tests/test-agent-steering.mjs', 'native', '--hooks',
  ] },
  ...[
    ['automatic', "a turn's end saves a checkpoint once the records since the last reach 64 KiB, and the next turn starts from it"],
    ['tools', 'a tool that stops being idempotent changes the tools a checkpoint names'],
    ['metadata', 'a checkpoint names the libfx, tools and model that saved it, and a resume with others hears so'],
    ['text', 'a checkpoint restores the conversation in a new agent'],
    ['image', 'a checkpoint after an image prompt holds the image, and a new agent sends it'],
  ].map(([kind, test]) => ({ name: `upstream/test-durable-checkpoint-${kind}`, expected: '1/1 durable tests passed', env: { LIBFX_TEST_ONLY: test }, args: [
    '--no-warnings', '--loader', './swift/Tests/Conformance/loader.mjs', 'sdk/tests/test-durable.mjs', 'memory', 'native',
  ] })),
  ...[
    ['tool', 'a steer reaches the running turn at its next model request'],
    ['stream', 'a steer cuts a streaming reply short, and the turn goes on with it'],
    ['quiet', 'a steer cuts short a reply that has gone quiet'],
    ['image', 'a steer with an image ends the streaming turn, and runs as the next turn'],
    ['cancel', 'a cancel keeps the steer its turn never took, and it runs next'],
    ['tool-cancel', 'a cancel while the model writes a tool call keeps the steer waiting for the call, and it runs next'],
    ['dedup', "a steer's messageId makes a retry add nothing, and names no prompt"],
  ].map(([kind, test]) => ({ name: `upstream/test-durable-steering-${kind}`, expected: '1/1 durable tests passed', env: { LIBFX_TEST_ONLY: test }, args: [
    '--no-warnings', '--loader', './swift/Tests/Conformance/loader.mjs', 'sdk/tests/test-durable.mjs', 'memory', 'native',
  ] })),
  ...[
    ['yield', "a turn longer than a function's time limit continues in the next delivery"],
    ['safe-tool', 'a lookup call still running near the deadline is cut off, and the next delivery continues the turn'],
    ['write', 'a send call still running near the deadline is cut off, and the next delivery continues the turn'],
    ['repeated-tool', 'a call the deadline cuts off 3 times in a row is not run again, and the model hears it may have partly run'],
    ['repeated-model', 'a model request the deadline cuts off 3 times in a row cancels its turn'],
  ].map(([kind, test]) => ({ name: `upstream/test-durable-delivery-${kind}`, expected: '1/1 durable tests passed', env: { LIBFX_TEST_ONLY: test }, args: [
    '--no-warnings', '--loader', './swift/Tests/Conformance/loader.mjs', 'sdk/tests/test-durable.mjs', 'memory', 'native',
  ] })),
  ...['smoke', 'checkpoint-interoperability', 'journal-interoperability', 'recovery', 'turn-control', 'observation', 'automatic-checkpoint', 'sqlite-crash', 'sqlite-fencing', 'turn-identity', 'handoff', 'follow-up', 'custom-provider', 'provider-suites', 'agent-crash', 'session-checkpoint', 'session-steering-crash'].map(name => ({
    name, args: [`swift/Tests/Conformance/${name}.mjs`],
  })),
];
const results = [];
for (const check of checks) {
  const started = Date.now();
  const child = spawnSync(process.execPath, check.args, { cwd: root, env: { ...process.env, ...check.env }, encoding: 'utf8', timeout: 60_000 });
  const passed = child.status === 0 && (!check.expected || child.stdout?.includes(check.expected));
  results.push({ name: check.name, passed, elapsedMs: Date.now() - started,
    stdout: child.stdout ?? '', stderr: child.stderr ?? '', error: child.error?.message });
  process.stdout.write(`${passed ? 'PASS' : 'FAIL'} ${check.name}\n${child.stdout ?? ''}${child.stderr ?? ''}`);
}
const output = new URL('../../.build/conformance-results.json', import.meta.url);
mkdirSync(new URL('.', output), { recursive: true });
writeFileSync(output, JSON.stringify({ node: process.version, platform: process.platform, arch: process.arch, results }, null, 2) + '\n');
if (results.some(result => !result.passed)) process.exitCode = 1;
