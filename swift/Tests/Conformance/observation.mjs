import { strict as assert } from 'node:assert';
import { fileURLToPath } from 'node:url';
import { createFxEngine as createSwiftEngine } from './adapter.mjs';
import { createFxEngine as createJSEngine, createMemoryPersistence } from '../../../sdk/node.js';

const nativeAddon = fileURLToPath(new URL('../../../zig-out/lib/libfx.node', import.meta.url));
async function exercise(create, captureContent) {
  const events = [], errors = [], persistence = createMemoryPersistence();
  let requests = 0;
  const engine = await create({
    backend: 'native', nativeAddon, persistence,
    apiKey: 'observation-credential', model: 'fixture/observation', instructions: 'private-instruction',
    hooks: { captureContent, onEvent: event => events.push(event), onError: error => errors.push(error) },
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
    assert.equal(event.rootSessionId, engine.sessionId);
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
  const reference = await exercise(createJSEngine, capture);
  assert.deepEqual(await exercise(createSwiftEngine, capture), reference);
}
console.log('Observation parity passed: tool causality, scopes, content opt-in, errors and committed cursors');
