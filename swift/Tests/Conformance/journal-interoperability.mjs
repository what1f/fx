import { strict as assert } from 'node:assert';
import { fileURLToPath } from 'node:url';
import { createFxEngine as createSwiftEngine } from './adapter.mjs';
import { createFxEngine as createJSEngine, createMemoryPersistence } from '../../../sdk/node.js';

const persistence = createMemoryPersistence(), requests = [];
const fetch = async (_url, init = {}) => {
  if ((init.method ?? 'GET').toUpperCase() === 'GET') return Response.json({ data: [{ id: 'swift/journal', type: 'language' }] });
  requests.push(JSON.parse(new TextDecoder().decode(init.body)));
  return new Response([
    'data: {"type":"text-delta","delta":"journal answer"}',
    'data: {"type":"finish","finishReason":{"unified":"stop","raw":"stop"}}',
    'data: [DONE]', '',
  ].join('\n\n'), { headers: { 'content-type': 'text/event-stream' } });
};
const options = { backend: 'native', nativeAddon: fileURLToPath(new URL('../../../zig-out/lib/libfx.node', import.meta.url)),
  apiKey: 'journal-test-key', model: 'swift/journal', persistence, fetch };
let engine;
try {
  for (const [create, prompt, previous] of [
    [createSwiftEngine, 'Swift first', []],
    [createJSEngine, 'JS next', ['Swift first']],
    [createSwiftEngine, 'Swift final', ['Swift first', 'JS next']],
  ]) {
    engine = await create(options);
    const turn = engine.prompt(prompt);
    for await (const _ of turn) {}
    assert.equal((await turn.result).stopReason, 'end_turn');
    const body = JSON.stringify(requests.at(-1));
    for (const text of previous) assert.ok(body.includes(text), `missing restored ${text}`);
    await engine.close();
  }
  assert.ok(persistence.records.length > 0);
  console.log('Journal interoperability passed: Swift → JS → Swift using one persistence store');
} finally { await engine?.close(); }
