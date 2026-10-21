import { strict as assert } from 'node:assert';
import { fileURLToPath } from 'node:url';
import { createFxEngine as createSwiftEngine } from './adapter.mjs';
import { createFxEngine as createJSEngine, createMemoryPersistence } from '../../../sdk/node.js';

async function drain(turn) {
  const events = [];
  for await (const event of turn) events.push(event);
  return { events, result: await turn.result };
}

async function exercise(source, target) {
  const persistence = createMemoryPersistence(), requests = [], observations = [];
  let started, calls = 0;
  const toolStarted = new Promise(resolve => { started = resolve; });
  const options = {
    backend: 'native', nativeAddon: fileURLToPath(new URL('../../../zig-out/lib/libfx.node', import.meta.url)),
    apiKey: 'handoff-key', model: 'fixture/handoff', persistence, checkpointAfterBytes: 0,
    hooks: { onEvent(event) { observations.push(event); } },
    tools: [{ name: 'write', description: 'Write a record', inputSchema: { type: 'object' }, writes: true,
      execute(_input, context) {
        calls++;
        started();
        return new Promise(resolve => {
          if (context.signal.aborted) resolve('cancelled');
          else context.signal.addEventListener('abort', () => resolve('cancelled'), { once: true });
        });
      },
    }],
    async fetch(_url, init) {
      if (init.method === 'GET') return Response.json({ data: [{ id: 'fixture/handoff', type: 'language', tags: ['tool-use'] }] });
      requests.push(JSON.parse(new TextDecoder().decode(init.body)));
      const first = requests.length === 1;
      const frames = first ? [{ type: 'tool-call', toolCallId: 'write-1', toolName: 'write', input: {} }]
        : [{ type: 'text-delta', delta: 'resumed answer' }];
      frames.push({ type: 'finish', finishReason: { unified: first ? 'tool-calls' : 'stop', raw: 'stop' } });
      return new Response(frames.map(event => `data: ${JSON.stringify(event)}\n\n`).join('') + 'data: [DONE]\n\n');
    },
  };
  let engine;
  try {
    engine = await source(options);
    const turn = engine.prompt('original handoff input', { turnId: 'handoff-turn' });
    const consumed = drain(turn);
    await toolStarted;
    await turn.steer('preserve this pending steer', 'steer-1');
    const before = persistence.records.length;
    await turn.cancel({ reason: 'handoff' });
    assert.equal((await consumed).result.stopReason, 'cancelled');
    assert.equal(persistence.records.length, before, 'the old engine wrote after handoff');
    assert.equal((await persistence.load()).checkpoint, undefined, 'the old engine snapshotted its cancelled state');
    await assert.rejects(async () => drain(engine.prompt('must not run')));
    await engine.close();
    assert.equal(persistence.records.length, before, 'closing wrote after handoff');
    const handedOffEnd = observations.find(event => event.type === 'turn.end');
    assert.equal(handedOffEnd?.data.handoff, true);

    engine = await target(options);
    const resumed = engine.resume();
    assert.ok(resumed);
    assert.equal(resumed.id, 'handoff-turn');
    const result = await drain(resumed);
    assert.equal(result.result.stopReason, 'end_turn');
    assert.equal(calls, 1, 'the ambiguous write was replayed');
    const request = JSON.stringify(requests.at(-1));
    assert.ok(request.includes('original handoff input'));
    assert.ok(request.includes('preserve this pending steer'));
    assert.ok(request.includes('may have partly run'));
    assert.equal(engine.resume(), null);
    await engine.close();
    return { requests: requests.length, calls, final: result.result.stopReason };
  } finally { await engine?.close(); }
}

const reference = await exercise(createJSEngine, createJSEngine);
assert.deepEqual(await exercise(createSwiftEngine, createSwiftEngine), reference);
assert.deepEqual(await exercise(createSwiftEngine, createJSEngine), reference);
assert.deepEqual(await exercise(createJSEngine, createSwiftEngine), reference);
console.log('Handoff parity passed: no later journal writes or snapshots, pending steer preserved, ambiguous write skipped across Swift/JS');
