import assert from 'node:assert/strict';
import { createDurableAgentFactory, memory } from './generic-adapter.mjs';

let starts = 0;
const input = { values: [1, -2, 3], label: '界 🦉', nested: { empty: null } };
const failure = { name: 'CalculationError', message: 'Refused', code: 'CALC_REFUSED' };
const create = createDurableAgentFactory({
  defaultDurability: () => memory(),
  harness: () => ({
    async open() {
      return {
        openTurn: null,
        prompt(value) {
          starts += 1;
          return {
            result: Promise.resolve({ stopReason: 'error', error: failure, usage: { inputTokens: 4, outputTokens: 2 } }),
            async *[Symbol.asyncIterator]() { yield { type: 'answer', value }; },
            cancel() {},
          };
        },
        async close() {},
      };
    },
  }),
});
const agent = create();
try {
  const session = agent.session('typed-result');
  const turn = session.prompt(input, { messageId: 'one' });
  const updates = [];
  for await (const update of turn) updates.push(update);
  assert.deepEqual(updates, [{ type: 'answer', value: input }]);
  const result = await turn.result;
  assert.equal(result.stopReason, 'error');
  assert.deepEqual(result.error, failure);
  assert.equal(result.usage.inputTokens, 4);
  assert.equal(result.usage.outputTokens, 2);
  const repeated = await session.prompt({ changed: true }, { messageId: 'one' }).result;
  assert.equal(repeated.repeated, true);
  assert.deepEqual(repeated.error, failure);
  assert.equal(starts, 1);
} finally { await agent.close(); }
console.log('Generic result passed: typed updates, returned errors, usage and deduplication');
