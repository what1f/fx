import { strict as assert } from 'node:assert';
import { createFxEngine } from './adapter.mjs';
import { createMemoryPersistence } from '../../../sdk/node.js';

let calls = 0;
const requests = [];
const fetch = async (_url, init = {}) => {
  if ((init.method ?? 'GET').toUpperCase() === 'GET') return Response.json({ data: [{ id: 'swift/tool', type: 'language', tags: ['tool-use'] }] });
  const body = JSON.parse(new TextDecoder().decode(init.body));
  requests.push(body);
  const hasResult = body.prompt.some(message => Array.isArray(message.content) && message.content.some(part => part.type === 'tool-result'));
  const frames = hasResult ? [{ type: 'text-delta', delta: 'done' }] : [
    { type: 'tool-call', toolCallId: 'write-1', toolName: 'write', input: { value: 'saved' } },
  ];
  frames.push({ type: 'finish', finishReason: { unified: hasResult ? 'stop' : 'tool-calls', raw: 'stop' } });
  return new Response(frames.map(frame => `data: ${JSON.stringify(frame)}\n\n`).join('') + 'data: [DONE]\n\n');
};
const options = { apiKey: 'test-key', model: 'swift/tool', fetch,
  tools: [{ name: 'write', description: 'Write a value', writes: true, idempotent: false,
    inputSchema: { type: 'object' }, execute() { calls++; return 'stored'; } }],
};
let engine;
try {
  const original = createMemoryPersistence();
  engine = await createFxEngine({ ...options, persistence: original });
  let turn = engine.prompt('write the value');
  for await (const _ of turn) {}
  assert.equal((await turn.result).stopReason, 'end_turn');
  await engine.close();
  const events = original.records.flatMap(record => JSON.parse(new TextDecoder().decode(record.data)).events);
  const boundary = events.findIndex(event => event.type === 'tool_intent');
  assert.ok(boundary >= 0);
  const crash = events.slice(0, boundary + 1);
  for (const rerun of [false, true]) {
    const persistence = createMemoryPersistence();
    await persistence.append({ expected: null, idempotencyKey: 'seed', data: new TextEncoder().encode(JSON.stringify({ format: 'libfx-journal-v1', events: crash })), barrier: true });
    engine = await createFxEngine({ ...options, persistence });
    const before = calls, seen = [];
    const policy = [];
    turn = engine.resume({ onAmbiguous(call) { policy.push(call); return rerun ? 'rerun' : undefined; } });
    assert.ok(turn);
    for await (const event of turn) seen.push(event);
    assert.equal((await turn.result).stopReason, 'end_turn');
    assert.equal(policy[0].executionId, 'write-1');
    assert.deepEqual(policy[0].input, { value: 'saved' });
    assert.equal(calls, before + (rerun ? 1 : 0));
    if (!rerun) {
      assert.equal(seen[0].type, 'tool_end');
      assert.equal(seen[0].isError, true);
      assert.match(seen[0].content, /may have partly run/);
      assert.match(JSON.stringify(requests.at(-1)), /may have partly run/);
    }
    assert.equal(engine.resume(), null);
    await engine.close();
  }
  console.log('Recovery passed: ambiguous writes stay stopped by default; explicit rerun preserves execution ID');
} finally { await engine?.close(); }
