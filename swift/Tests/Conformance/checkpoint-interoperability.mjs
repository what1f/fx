import { strict as assert } from 'node:assert';
import { fileURLToPath } from 'node:url';
import { createFxEngine as createSwiftEngine } from './adapter.mjs';
import { createFxEngine as createJSEngine } from '../../../sdk/node.js';

const requests = [];
const fetch = async (_url, init = {}) => {
  if ((init.method ?? 'GET').toUpperCase() === 'GET') {
    return Response.json({ data: [{ id: 'swift/interop', type: 'language', tags: ['vision'] }] });
  }
  const body = JSON.parse(new TextDecoder().decode(init.body));
  requests.push(body);
  return new Response([
    'data: {"type":"text-delta","delta":"saved answer"}',
    'data: {"type":"finish","finishReason":{"unified":"stop","raw":"stop"}}',
    'data: [DONE]', '',
  ].join('\n\n'), { headers: { 'content-type': 'text/event-stream' } });
};
const options = { backend: 'native', nativeAddon: fileURLToPath(new URL('../../../zig-out/lib/libfx.node', import.meta.url)),
  apiKey: 'interop-test-key', model: 'swift/interop', fetch };
const png = 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jP0cAAAAASUVORK5CYII=';
let engine;
try {
  engine = await createJSEngine(options);
  let turn = engine.prompt([{ type: 'text', text: 'JS original turn' }, { type: 'image', mimeType: 'image/png', data: png }]);
  for await (const _ of turn) {}
  assert.equal((await turn.result).stopReason, 'end_turn');
  let checkpoint = await engine.checkpoint();
  await engine.close();
  engine = await createSwiftEngine({ ...options, checkpoint });
  turn = engine.prompt('Swift continuation');
  for await (const _ of turn) {}
  assert.equal((await turn.result).stopReason, 'end_turn');
  assert.ok(JSON.stringify(requests.at(-1)).includes('JS original turn'));
  assert.ok(JSON.stringify(requests.at(-1)).includes(png));
  checkpoint = await engine.checkpoint();
  await engine.close();
  engine = await createJSEngine({ ...options, checkpoint });
  turn = engine.prompt('JS final turn');
  for await (const _ of turn) {}
  assert.equal((await turn.result).stopReason, 'end_turn');
  const final = JSON.stringify(requests.at(-1));
  for (const text of ['JS original turn', 'Swift continuation', 'JS final turn', png]) assert.ok(final.includes(text), `missing ${text}`);
  console.log('Checkpoint interoperability passed: JS → Swift → JS, with history and image bytes');
} finally { await engine?.close(); }
