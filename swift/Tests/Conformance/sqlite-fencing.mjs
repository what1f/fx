import { strict as assert } from 'node:assert';
import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { createFxEngine } from './adapter.mjs';

const directory = await mkdtemp(join(tmpdir(), 'libfx-swift-fencing-'));
let requests = 0;
const options = {
  apiKey: 'fencing-fixture-key', model: 'fixture/fencing', sqlitePath: join(directory, 'conversation.sqlite'),
  async fetch(_url, init) {
    if (init.method === 'GET') return Response.json({ data: [{ id: 'fixture/fencing', type: 'language' }] });
    requests++;
    return new Response('data: {"type":"text-delta","delta":"one writer"}\n\ndata: {"type":"finish","finishReason":{"unified":"stop","raw":"stop"}}\n\ndata: [DONE]\n\n', {
      headers: { 'content-type': 'text/event-stream' },
    });
  },
};
const engines = [];
try {
  engines.push(await createFxEngine(options));
  engines.push(await createFxEngine(options));
  const results = await Promise.allSettled(engines.map(async (engine, index) => {
    const turn = engine.prompt(`competing writer ${index}`);
    for await (const _ of turn) {}
    return turn.result;
  }));
  assert.equal(results.filter(result => result.status === 'fulfilled').length, 1);
  const rejected = results.filter(result => result.status === 'rejected');
  assert.equal(rejected.length, 1);
  assert.match(String(rejected[0].reason), /fenced/);
  assert.equal(requests, 1, 'the fenced process reached the model');
  console.log('SQLite process fencing passed: one writer proceeds; the stale writer stops before its model request');
} finally {
  await Promise.allSettled(engines.map(engine => engine.close()));
  await rm(directory, { recursive: true, force: true });
}
