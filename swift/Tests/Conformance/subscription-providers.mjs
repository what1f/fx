import { strict as assert } from 'node:assert';
import { readFileSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

// Keep upstream engine assertions unchanged. The later sections require the
// agent/session surface, which remains a separate acceptance gate.
const root = fileURLToPath(new URL('../../../', import.meta.url));
for (const provider of ['codex', 'grok']) {
  const source = readFileSync(new URL(`../../../sdk/tests/test-agent-${provider}.mjs`, import.meta.url), 'utf8');
  const marker = '// 5. A durable session';
  assert.ok(source.includes(marker));
  const engineCases = source.slice(0, source.indexOf(marker));
  for (const backend of ['JavaScript', 'Swift']) {
    const sdk = new URL(backend === 'Swift' ? './adapter.mjs' : '../../../sdk/node.js', import.meta.url).href;
    const code = engineCases.replace('{ createFxAgent, createFxEngine, memory, supportsJspi }', '{ createFxEngine, supportsJspi }').replace('from "../node.js"', `from ${JSON.stringify(sdk)}`)
      .replace('resolve(scriptDir, "../../zig-out/lib/libfx.node")', JSON.stringify(`${root}zig-out/lib/libfx.node`));
    const result = spawnSync(process.execPath, ['--input-type=module', '-e', code], { cwd: root, encoding: 'utf8', timeout: 30000 });
    assert.equal(result.status, 0, `${backend} ${provider}: ${result.stderr}\n${result.stdout}`);
    console.log(`${backend} ${provider}: unchanged upstream engine assertions passed`);
  }
}
