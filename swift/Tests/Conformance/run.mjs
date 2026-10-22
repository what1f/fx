import { spawn } from 'node:child_process';
import { mkdirSync, writeFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';

const root = fileURLToPath(new URL('../../../', import.meta.url));
const checks = [
  { name: 'upstream/test-core-output-control', expected: 'core output framing passed:', args: [
    '--no-warnings', '--loader', './swift/Tests/Conformance/loader.mjs', 'sdk/tests/test-core-output.mjs',
  ] },
  { name: 'upstream/test-durable-provider-crash', expected: 'Node native durable provider crash passed', args: [
    '--no-warnings', '--loader', './swift/Tests/Conformance/loader.mjs', 'sdk/tests/test-durable-provider-crash.mjs', 'native',
  ] },
  ...['chatgpt', 'grok'].map(provider => ({ name: `upstream/test-${provider}-sign-in`,
    expected: provider === 'chatgpt' ? 'ChatGPT sign-in passed' : 'Grok sign-in passed',
    args: ['--no-warnings', '--loader', './swift/Tests/Conformance/loader.mjs', `sdk/tests/test-${provider}-sign-in.mjs`],
  })),
  { name: 'upstream/test-agent-images', expected: 'native agent image prompts passed', args: [
    '--no-warnings', '--loader', './swift/Tests/Conformance/loader.mjs', 'sdk/tests/test-agent-images.mjs', 'native',
  ] },
  { name: 'upstream/test-instruction-limits', expected: 'native instruction limits passed', args: [
    '--no-warnings', '--loader', './swift/Tests/Conformance/loader.mjs', 'sdk/tests/test-instruction-limits.mjs', 'native',
  ] },
  { name: 'upstream/test-native-core-image-framing', expected: 'native image framing passed:', args: [
    '--no-warnings', '--loader', './swift/Tests/Conformance/loader.mjs', 'sdk/tests/test-native-core-image-framing.mjs',
  ] },
  { name: 'upstream/test-hooks', args: [
    '--no-warnings', '--loader', './swift/Tests/Conformance/loader.mjs', 'sdk/tests/test-hooks.mjs', 'native',
  ] },
  ...[
    ['stdio', undefined], ['http', undefined], ['http', 'images'], ['http', 'images-error'], ['http', 'image-only'],
  ].map(([transport, mode]) => ({ name: `upstream/test-mcp-adapter-${transport}-${mode ?? 'text'}`, args: [
    '--no-warnings', '--loader', './swift/Tests/Conformance/loader.mjs', 'sdk/tests/test-mcp-adapter.mjs', transport, 'native', ...(mode ? [mode] : []),
  ] })),
  { name: 'upstream/test-skills-adapter-records', args: [
    '--no-warnings', '--loader', './swift/Tests/Conformance/loader.mjs', 'sdk/tests/test-skills-adapter.mjs', 'records', 'native',
  ] },
  { name: 'upstream/test-skills-adapter-disk', args: [
    '--no-warnings', '--loader', './swift/Tests/Conformance/loader.mjs', 'sdk/tests/test-skills-adapter.mjs', 'disk', 'native',
  ] },
  ...['test-minimal-api', 'test-native-core-config-isolation', 'test-native-core-cancel', 'test-native-core-fetch-failure', 'test-native-core-stream', 'test-native-host-tool-late-settle', 'test-checkpoint', 'test-journal', 'test-host-tools', 'test-tool-contract', 'test-agent-step-limit', 'test-host-tool-cancel', 'test-agent-steering', 'test-list-models', 'test-agent-effort', 'test-agent-fast', 'test-agent-provider-tools', 'test-agent-ultrafast-options', 'test-agent-request-context', 'test-agent-bootstrap', 'test-agent-transport-retry', 'test-agent-tool-start', 'test-agent-reserved-tool-names'].map(name => ({
    name: `upstream/${name}`, args: ['--no-warnings', '--loader', './swift/Tests/Conformance/loader.mjs', `sdk/tests/${name}.mjs`, 'native', ...(['test-journal', 'test-checkpoint'].includes(name) ? ['native'] : [])],
  })),
  { name: 'upstream/test-agent-steering-hooks', args: [
    '--no-warnings', '--loader', './swift/Tests/Conformance/loader.mjs', 'sdk/tests/test-agent-steering.mjs', 'native', '--hooks',
  ] },
  ...[
    ['replay', 'a prompt streams its turn, and the session replays from any cursor'],
    ['isolation', "each session's stream holds only its own turns"],
    ['dedup', 'a retried prompt with the same messageId runs its turn once'],
    ['ordering', 'two servers prompting one session run its turns one at a time, in one history'],
    ['context', 'each agent.session() call carries its own context to the tools'],
    ['options', "a session object's model and instructions reach its model requests, over the agent's"],
    ['cancel', 'cancel stops the running turn; dropping its view does not'],
    ['images', "a durable prompt's images reach the model as the base64 it was given"],
    ['image-snapshot', "a durable prompt checks the copy its log holds, so a getter can't pass one image and store another"],
    ['backend-error', 'an option the backend rejects fails the first turn once'],
    ['idempotent', 'createFxAgent() refuses a host tool that does not say whether it is idempotent'],
  ].map(([kind, test]) => ({ name: `upstream/test-durable-session-${kind}`, expected: '1/1 durable tests passed', env: { LIBFX_TEST_ONLY: test }, args: [
    '--no-warnings', '--loader', './swift/Tests/Conformance/loader.mjs', 'sdk/tests/test-durable.mjs', 'memory', 'native',
  ] })),
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
  ...[
    ['accepted-crash', 'a prompt accepted just before a crash still runs'],
    ['send-crash', 'a crash during send never sends twice, and the turn goes on'],
  ].map(([kind, test]) => ({ name: `upstream/test-durable-delivery-${kind}`, expected: '1/1 durable tests passed', env: { LIBFX_TEST_ONLY: test }, args: [
    '--no-warnings', '--loader', './swift/Tests/Conformance/loader.mjs', 'sdk/tests/test-durable.mjs', 'local', 'native',
  ] })),
  ...['admission-cache', 'session-readable', 'http-cleanup', 'persistence-errors', 'driver-lifecycle', 'generic-relay-lifecycle', 'generic-core', 'generic-result', 'generic-routing', 'generic-fresh-host', 'generic-durable-additions', 'smoke', 'checkpoint-interoperability', 'journal-interoperability', 'recovery', 'turn-control', 'observation', 'input-observation', 'tool-observation', 'mcp-observation', 'automatic-checkpoint', 'sqlite-crash', 'sqlite-fencing', 'turn-identity', 'handoff', 'follow-up', 'custom-provider', 'provider-suites', 'agent-crash', 'session-checkpoint', 'session-steering-crash'].map(name => ({
    name, args: [`swift/Tests/Conformance/${name}.mjs`],
  })),
];
const results = [];
const output = new URL('../../.build/conformance-results.json', import.meta.url);
mkdirSync(new URL('.', output), { recursive: true });
for (const check of checks) {
  const started = Date.now();
  process.stdout.write(`START ${check.name}\n`);
  const child = spawn(process.execPath, check.args, { cwd: root, env: { ...process.env, ...check.env }, timeout: 60_000 });
  let stdout = '', stderr = '', error;
  child.stdout.setEncoding('utf8');
  child.stderr.setEncoding('utf8');
  child.stdout.on('data', chunk => { stdout += chunk; process.stdout.write(chunk); });
  child.stderr.on('data', chunk => { stderr += chunk; process.stderr.write(chunk); });
  child.on('error', failure => { error = failure.message; });
  const { status, signal } = await new Promise(resolve => child.on('close', (status, signal) => resolve({ status, signal })));
  if (child.killed && signal === 'SIGTERM') error ??= 'Conformance process exceeded its 60000 ms deadline';
  const passed = status === 0 && !signal && !stderr && !error && (!check.expected || stdout.includes(check.expected));
  results.push({ name: check.name, passed, elapsedMs: Date.now() - started,
    stdout, stderr, status, signal, error });
  process.stdout.write(`${passed ? 'PASS' : 'FAIL'} ${check.name} (${Date.now() - started} ms; status=${status}; signal=${signal ?? 'none'})${error ? ': ' + error : ''}\n`);
  writeFileSync(output, JSON.stringify({ node: process.version, platform: process.platform, arch: process.arch, results }, null, 2) + '\n');
}
if (results.some(result => !result.passed)) process.exitCode = 1;
