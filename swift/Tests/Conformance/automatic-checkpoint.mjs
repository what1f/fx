import { strict as assert } from 'node:assert';
import { fileURLToPath } from 'node:url';
import { createFxEngine as createSwiftEngine } from './adapter.mjs';
import { createFxEngine as createJSEngine, createMemoryPersistence } from '../../../sdk/node.js';

const persistence = createMemoryPersistence(), bodies = [];
const options = {
  backend: 'native', nativeAddon: fileURLToPath(new URL('../../../zig-out/lib/libfx.node', import.meta.url)),
  apiKey: 'automatic-checkpoint-key', model: 'fixture/checkpoint', persistence, checkpointAfterBytes: 0,
  async fetch(_url, init) {
    if (init.method === 'GET') return Response.json({ data: [{ id: 'fixture/checkpoint', type: 'language' }] });
    bodies.push(JSON.parse(new TextDecoder().decode(init.body)));
    return new Response('data: {"type":"text-delta","delta":"saved answer"}\n\ndata: {"type":"finish","finishReason":{"unified":"stop","raw":"stop"}}\n\ndata: [DONE]\n\n', {
      headers: { 'content-type': 'text/event-stream' },
    });
  },
};
let engine;
try {
  for (const [create, prompt, previous] of [
    [createSwiftEngine, 'Swift snapshot', []],
    [createJSEngine, 'JavaScript snapshot', ['Swift snapshot']],
    [createSwiftEngine, 'Swift restores both', ['Swift snapshot', 'JavaScript snapshot']],
  ]) {
    engine = await create(options);
    const turn = engine.prompt(prompt);
    for await (const _ of turn) {}
    assert.equal((await turn.result).stopReason, 'end_turn');
    for (const text of previous) assert.ok(JSON.stringify(bodies.at(-1)).includes(text));
    await engine.close();
    const loaded = await persistence.load();
    assert.ok(loaded.checkpoint);
    assert.equal(new TextDecoder().decode(loaded.checkpoint.data.subarray(0, 4)), 'FXSN');
    const tail = [];
    for await (const record of loaded.journal ?? []) tail.push(record);
    assert.equal(tail.length, 0, `${prompt}: the store returned a covered journal prefix`);
  }
  console.log('Automatic checkpoint interoperability passed: Swift → JS → Swift with covered journal prefixes excluded');
} finally { await engine?.close(); }
