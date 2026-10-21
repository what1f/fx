import { strict as assert } from 'node:assert';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const root = fileURLToPath(new URL('../../../', import.meta.url));
for (const provider of ['custom', 'codex', 'grok']) {
  for (const backend of ['JavaScript', 'Swift']) {
    const fixture = `sdk/tests/test-agent-${provider}.mjs`;
    const loader = backend === 'Swift' ? ['--no-warnings', '--loader', './swift/Tests/Conformance/loader.mjs'] : [];
    const result = spawnSync(process.execPath, [...loader, fixture, 'native'], {
      cwd: root, encoding: 'utf8', timeout: 30000,
    });
    assert.equal(result.status, 0, `${backend} ${provider}: ${result.error ?? ''}\n${result.stderr}\n${result.stdout}`);
    console.log(`${backend} ${provider}: complete unchanged upstream provider file passed`);
  }
}
