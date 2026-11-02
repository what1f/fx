import { strict as assert } from 'node:assert';
import { fileURLToPath } from 'node:url';
import * as Swift from './adapter.mjs';
import * as JavaScript from '../../../sdk/node.js';

const png = 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jP0cAAAAASUVORK5CYII=';
const requests = [];
const fetch = async (_url, init) => {
  if (init.method === 'GET') return Response.json({ data: [{ id: 'swift/session-checkpoint', type: 'language', tags: ['vision'] }] });
  requests.push(JSON.parse(new TextDecoder().decode(init.body)));
  return new Response('data: {"type":"text-delta","delta":"saved session answer"}\n\ndata: {"type":"finish","finishReason":{"unified":"stop","raw":"stop"}}\n\ndata: [DONE]\n\n', {
    headers: { 'content-type': 'text/event-stream' },
  });
};
const options = {
  backend: 'native', nativeAddon: fileURLToPath(new URL('../../../zig-out/lib/libfx.node', import.meta.url)),
  apiKey: 'checkpoint-test-key', model: 'swift/session-checkpoint', fetch,
};
for (const [sourceName, source] of Object.entries({ JavaScript, Swift, SwiftSnapshot: Swift })) {
  const durability = source.memory();
  const agent = source.createFxAgent({ ...options, durability,
    ...(sourceName === 'SwiftSnapshot' ? { checkpointAfterBytes: 0 } : {}),
  });
  const session = agent.session();
  let checkpoint;
  try {
    const turn = session.prompt([{ type: 'text', text: `${sourceName} original session` }, { type: 'image', data: png, mimeType: 'image/png' }]);
    assert.equal((await turn.result).stopReason, 'end_turn');
    const before = requests.length;
    checkpoint = await session.checkpoint();
    assert.ok(checkpoint instanceof Uint8Array && checkpoint.byteLength > 0);
    assert.equal(requests.length, before, 'checkpoint export sends no model request');
    const repeated = await session.checkpoint();
    assert.deepEqual(repeated, checkpoint, 'read-only exports are stable');
  } finally { await agent.close(); }
  for (const [targetName, target] of Object.entries({ JavaScript, Swift })) {
    const restored = target.createFxAgent({ ...options, durability: target.memory(), checkpoint });
    try {
      const turn = restored.session().prompt(`${targetName} continuation`);
      assert.equal((await turn.result).stopReason, 'end_turn');
      const body = JSON.stringify(requests.at(-1));
      for (const expected of [`${sourceName} original session`, 'saved session answer', `${targetName} continuation`, png]) {
        assert.ok(body.includes(expected), `${sourceName} → ${targetName} lost ${expected}`);
      }
      console.log(`Durable session checkpoint passed: ${sourceName} → ${targetName}, with history and images`);
    } finally { await restored.close(); }
  }
}
