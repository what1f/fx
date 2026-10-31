import assert from 'node:assert/strict';
import { fileURLToPath } from 'node:url';
import { createFxEngine as createJS, createMemoryPersistence } from '../../../sdk/node.js';
import { createFxEngine as createSwift } from './adapter.mjs';

const nativeAddon = fileURLToPath(new URL('../../../zig-out/lib/libfx.node', import.meta.url));
const cyclic = new Error('disk full');
cyclic.cause = cyclic;
const empty = Object.assign(new Error(''), { name: '' });
const unprintable = { toString() { throw new Error('No printable representation'); } };
const causes = [cyclic, { message: 'opaque store rejection' }, empty, unprintable, null, undefined];
for (const create of [createJS, createSwift]) {
  for (const cause of causes) {
    let modelRequests = 0;
    const options = {
      backend: 'native', nativeAddon, apiKey: 'fixture', model: 'fixture/errors',
      async fetch(_url, request) {
        if (request.method === 'GET') return Response.json({ data: [{ id: 'fixture/errors', type: 'language' }] });
        modelRequests++;
        return new Response('data: {"type":"text-delta","delta":"reply"}\n\ndata: {"type":"finish","finishReason":{"unified":"stop","raw":"stop"}}\n\ndata: [DONE]\n\n');
      },
    };
    await assert.rejects(create({ ...options, persistence: { load() { throw cause; }, append() { assert.fail('Load failure must prevent append'); } } }),
      error => error === cause);
    assert.equal(modelRequests, 0);
    for (const phase of ['first', 'end']) {
      const store = createMemoryPersistence();
      let failures = 0;
      const engine = await create({ ...options, persistence: {
        load: () => store.load(),
        append(input) {
          const record = JSON.parse(new TextDecoder().decode(input.data));
          if (phase === 'first' || record.events.some(event => event.type === 'turn_committed')) { failures++; throw cause; }
          return store.append(input);
        },
      } });
      try {
        const before = modelRequests, turn = engine.prompt('fail storage');
        let streamed;
        try { for await (const _ of turn) {} assert.fail('Expected a stream failure'); }
        catch (error) { streamed = error; }
        assert.equal(streamed.code, 'FX_JOURNAL_APPEND_FAILED');
        assert.equal(streamed.cause, cause);
        await assert.rejects(turn.result, error => error === streamed);
        assert.throws(() => engine.prompt('must not start'), error => error === streamed);
        assert.equal(modelRequests - before, phase === 'first' ? 0 : 1);
        assert.equal(failures, 1);
        // JS reports this already-exposed append error once. Native Swift
        // separately verifies that every close still throws its original error.
        await engine.close();
      } finally { await engine.close(); }
    }
  }
}
console.log('Persistence errors match: original cyclic/object/empty/unprintable/null/undefined causes, shared failures, stopped effects and acknowledged close');
