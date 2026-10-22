import { strict as assert } from 'node:assert';
import { fileURLToPath } from 'node:url';
import { createFxEngine as createSwiftEngine } from './adapter.mjs';
import { createFxEngine as createJSEngine, createMemoryPersistence } from '../../../sdk/node.js';

const nativeAddon = fileURLToPath(new URL('../../../zig-out/lib/libfx.node', import.meta.url));
async function exercise(create, captureContent, parent) {
  const events = [], errors = [], persistence = createMemoryPersistence();
  let requests = 0;
  const engine = await create({
    backend: 'native', nativeAddon, persistence,
    apiKey: 'observation-credential', model: 'fixture/observation', instructions: 'private-instruction',
    hooks: { captureContent, ...(parent ? { parent } : {}), onEvent: event => events.push(event), onError: error => errors.push(error) },
    tools: [{ name: 'lookup', description: 'Find a value', idempotent: true,
      inputSchema: { type: 'object', properties: { key: { type: 'string' } } },
      async execute({ key }) { if (key === 'beta') throw new Error('private-failure'); return 'private-value'; },
    }],
    async fetch(_url, init) {
      if (init.method === 'GET') return Response.json({ data: [{ id: 'fixture/observation', type: 'language', tags: ['tool-use'] }] });
      requests++;
      const frames = requests === 1 ? ['alpha', 'beta'].map(key => ({
        type: 'tool-call', toolCallId: `call-${key}`, toolName: 'lookup', input: { key },
      })) : [{ type: 'text-delta', delta: 'private-answer' }];
      frames.push({ type: 'finish', finishReason: { unified: requests === 1 ? 'tool-calls' : 'stop', raw: 'stop' } });
      return new Response(frames.map(event => `data: ${JSON.stringify(event)}\n\n`).join('') + 'data: [DONE]\n\n', {
        headers: { 'content-type': 'text/event-stream' },
      });
    },
  });
  try {
    const turn = engine.prompt('private-prompt');
    for await (const _ of turn) {}
    assert.equal((await turn.result).stopReason, 'end_turn');
  } finally { await engine.close(); }
  assert.equal(errors.length, 0);
  const runtime = events.filter(event => !event.type.startsWith('journal.'));
  assert.equal(runtime[0].type, 'turn.start');
  assert.equal(runtime.at(-1).type, 'turn.end');
  assert.equal(new Set(runtime.map(event => event.executionId)).size, 1);
  assert.equal(new Set(runtime.map(event => event.turnId)).size, 1);
  for (const event of events) {
    assert.equal(event.version, 1);
    assert.equal(event.sessionId, engine.sessionId);
    assert.equal(event.rootSessionId, parent?.rootSessionId ?? engine.sessionId);
    if (parent) {
      assert.equal(event.parentSessionId, parent.sessionId);
      assert.equal(event.parentTurnId, parent.turnId);
      assert.equal(event.parentCallId, parent.callId);
    }
    assert.ok(Number.isSafeInteger(event.timestamp));
  }
  for (const id of ['call-alpha', 'call-beta']) {
    const ordered = ['tool.start', 'tool.end', 'tool.result'].map(type => events.findIndex(event => event.type === type && event.data.call.callId === id));
    assert.ok(ordered[0] >= 0 && ordered[0] < ordered[1] && ordered[1] < ordered[2]);
  }
  const results = events.filter(event => event.type === 'tool.result');
  assert.equal(results.find(event => event.data.call.callId === 'call-beta').data.status, 'failure');
  assert.equal(results.find(event => event.data.call.callId === 'call-alpha').data.status, 'success');
  const serialized = JSON.stringify(events);
  assert.ok(!serialized.includes('observation-credential'));
  for (const text of ['private-prompt', 'private-answer', 'private-instruction', 'private-value', 'private-failure']) {
    assert.equal(serialized.includes(text), captureContent, text);
  }
  const commits = events.filter(event => event.type === 'journal.commit');
  assert.equal(commits.length, persistence.records.length);
  assert.deepEqual(commits.map(event => event.data.cursor), persistence.records.map(record => record.cursor));
  return runtime.map(event => `${event.type}:${event.stepIndex}`).sort();
}

for (const capture of [false, true]) {
  for (const parent of [undefined, { rootSessionId: 'outer-root', sessionId: 'outer', turnId: 'outer-turn', callId: 'outer-call' }]) {
    const reference = await exercise(createJSEngine, capture, parent);
    assert.deepEqual(await exercise(createSwiftEngine, capture, parent), reference);
  }
}
// Keep the persistence checks runnable even while the complete hooks owner has
// unrelated gaps. Both implementations use the same failing host store.
async function fencing(create, wrapped) {
  const events = [];
  let modelRequests = 0;
  const engine = await create({ backend: 'native', nativeAddon, apiKey: 'observation-credential', model: 'fixture/observation',
    persistence: {
      load: async () => ({}),
      append: async () => {
        const error = Object.assign(new Error('fenced'), { code: 'FX_FENCED' });
        throw wrapped ? new Error('wrapped', { cause: error }) : error;
      },
    },
    hooks: { onEvent: event => events.push(event) },
    async fetch(_url, init) {
      if (init.method === 'GET') return Response.json({ data: [{ id: 'fixture/observation', type: 'language' }] });
      modelRequests++;
      throw new Error('Fenced input must not reach the model');
    },
  });
  try {
    await assert.rejects((async () => {
      const turn = engine.prompt('never delivered');
      for await (const _ of turn) {}
      return turn.result;
    })(), /journal|append/i);
    assert.equal(modelRequests, 0);
    assert.equal(events.filter(event => event.type === 'journal.commit').length, 0);
    assert.equal(events.filter(event => event.type === 'model.start').length, 0);
    const failures = events.filter(event => event.type === 'journal.error');
    assert.equal(failures.length, 1);
    assert.equal(failures[0].data.fenced, true);
  } finally { await engine.close().catch(() => {}); }
}
for (const wrapped of [false, true]) {
  await fencing(createJSEngine, wrapped);
  await fencing(createSwiftEngine, wrapped);
}
console.log('Observation parity passed: tool causality, parent scopes, content opt-in, errors, committed cursors and fenced writes');
