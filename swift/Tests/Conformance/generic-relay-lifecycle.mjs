import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';

// The protocol has nonthrowing async state properties. A failed callback must
// fail the host process instead of looking like a session with no open turn.
const adapter = new URL('./generic-adapter.mjs', import.meta.url).href;
const child = spawnSync(process.execPath, ['--input-type=module', '-e', `
  import { createDurableAgentFactory, memory } from ${JSON.stringify(adapter)};
  let reads = 0;
  const create = createDurableAgentFactory({
    harness: () => ({ open: async () => ({
      get openTurn() {
        if (++reads > 1) throw new Error('state getter fixture failed');
        return null;
      },
      close: async () => {},
    }) }),
    defaultDurability: () => memory(),
  });
  const agent = create();
  await agent.session().prompt('fixture').result;
  await agent.close();
`], { env: process.env, encoding: 'utf8', timeout: 10_000 });
assert.ifError(child.error);
assert.notEqual(child.status, 0);
assert.equal(child.signal, null);
assert.match(child.stderr, /state getter fixture failed/);
console.log('Generic relay lifecycle passed: a failed state callback fails the process');
