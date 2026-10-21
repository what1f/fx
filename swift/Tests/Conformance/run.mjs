import { spawnSync } from 'node:child_process';
import { mkdirSync, writeFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';

const root = fileURLToPath(new URL('../../../', import.meta.url));
const checks = [
  ...['test-host-tools', 'test-agent-step-limit', 'test-host-tool-cancel', 'test-agent-steering', 'test-list-models'].map(name => ({
    name: `upstream/${name}`, args: ['--no-warnings', '--loader', './swift/Tests/Conformance/loader.mjs', `sdk/tests/${name}.mjs`, 'native'],
  })),
  { name: 'upstream/test-agent-steering-hooks', args: [
    '--no-warnings', '--loader', './swift/Tests/Conformance/loader.mjs', 'sdk/tests/test-agent-steering.mjs', 'native', '--hooks',
  ] },
  ...['smoke', 'checkpoint-interoperability', 'journal-interoperability', 'recovery', 'turn-control', 'observation', 'automatic-checkpoint', 'sqlite-crash', 'sqlite-fencing', 'turn-identity'].map(name => ({
    name, args: [`swift/Tests/Conformance/${name}.mjs`],
  })),
];
const results = [];
for (const check of checks) {
  const started = Date.now();
  const child = spawnSync(process.execPath, check.args, { cwd: root, encoding: 'utf8', timeout: 60_000 });
  const passed = child.status === 0;
  results.push({ name: check.name, passed, elapsedMs: Date.now() - started,
    stdout: child.stdout ?? '', stderr: child.stderr ?? '', error: child.error?.message });
  process.stdout.write(`${passed ? 'PASS' : 'FAIL'} ${check.name}\n${child.stdout ?? ''}${child.stderr ?? ''}`);
}
const output = new URL('../../.build/conformance-results.json', import.meta.url);
mkdirSync(new URL('.', output), { recursive: true });
writeFileSync(output, JSON.stringify({ node: process.version, platform: process.platform, arch: process.arch, results }, null, 2) + '\n');
if (results.some(result => !result.passed)) process.exitCode = 1;
