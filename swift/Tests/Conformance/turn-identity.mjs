import { strict as assert } from 'node:assert';
import { fileURLToPath } from 'node:url';
import { createFxEngine as createSwiftEngine } from './adapter.mjs';
import { createFxEngine as createJSEngine, createMemoryPersistence } from '../../../sdk/node.js';

async function drain(turn) {
  const events = [];
  for await (const event of turn) events.push(event);
  return { events, result: await turn.result };
}

async function exercise(create, alternate) {
  const persistence = createMemoryPersistence(), bodies = [], calls = [];
  const implementations = [create, alternate ?? create, create, alternate ?? create];
  let generation = 0;
  const options = {
    backend: 'native', nativeAddon: fileURLToPath(new URL('../../../zig-out/lib/libfx.node', import.meta.url)),
    apiKey: 'turn-identity-key', model: 'fixture/identity', persistence, checkpointAfterBytes: 0,
    tools: [{ name: 'step', description: 'Run a step', idempotent: true, inputSchema: { type: 'object', properties: {} },
      async execute(_input, context) { calls.push(context.executionId); return 'step completed'; },
    }],
    async fetch(_url, init) {
      if (init.method === 'GET') return Response.json({ data: [{ id: 'fixture/identity', type: 'language', tags: ['tool-use'] }] });
      bodies.push(JSON.parse(new TextDecoder().decode(init.body)));
      const frames = bodies.length <= 2 ? [{
        type: 'tool-call', toolCallId: `step-${bodies.length}`, toolName: 'step', input: {},
      }] : [{ type: 'text-delta', delta: 'saved answer' }];
      frames.push({ type: 'finish', finishReason: { unified: bodies.length <= 2 ? 'tool-calls' : 'stop', raw: 'stop' } });
      return new Response(frames.map(event => `data: ${JSON.stringify(event)}\n\n`).join('') + 'data: [DONE]\n\n', {
        headers: { 'content-type': 'text/event-stream' },
      });
    },
  };
  let engine;
  try {
    engine = await implementations[generation++](options);
    const first = engine.prompt('original identity input', { turnId: 'stable-turn', yieldAt: Date.now() - 1 });
    assert.equal(first.id, 'stable-turn');
    assert.equal((await drain(first)).result.stopReason, 'yielded');
    assert.equal(bodies.length, 1, 'each invocation must make one model request before yielding');
    await engine.close();

    engine = await implementations[generation++](options);
    const repeated = engine.prompt('ignored retried input', { turnId: 'stable-turn', yieldAt: Date.now() - 1 });
    assert.equal((await drain(repeated)).result.stopReason, 'yielded');
    assert.equal(bodies.length, 2);
    await engine.close();

    engine = await implementations[generation++](options);
    const resumed = engine.resume();
    assert.ok(resumed);
    assert.equal(resumed.id, 'stable-turn');
    assert.equal((await drain(resumed)).result.stopReason, 'end_turn');
    assert.deepEqual(calls, ['step-1', 'step-2'], 'resuming replayed completed tools');
    const latest = JSON.stringify(bodies.at(-1));
    assert.equal(latest.split('original identity input').length - 1, 1);
    assert.ok(!latest.includes('ignored retried input'));
    const same = await drain(engine.prompt('ignored completed input', { turnId: 'stable-turn' }));
    assert.equal(same.events.length, 0);
    assert.equal(same.result.stopReason, 'end_turn');
    assert.equal(bodies.length, 3);
    await engine.close();

    engine = await implementations[generation++](options);
    const restored = engine.prompt('ignored restored input', { turnId: 'stable-turn' });
    assert.equal(restored.id, 'stable-turn');
    assert.equal((await drain(restored)).result.stopReason, 'end_turn');
    assert.equal(bodies.length, 3);
    await drain(engine.prompt('next input', { turnId: 'next-turn' }));
    assert.equal(bodies.length, 4);
    await engine.close();
    return { requests: bodies.length, tools: calls };
  } finally { await engine?.close(); }
}

const reference = await exercise(createJSEngine);
assert.deepEqual(await exercise(createSwiftEngine), reference);
assert.deepEqual(await exercise(createSwiftEngine, createJSEngine), reference);
assert.deepEqual(await exercise(createJSEngine, createSwiftEngine), reference);
console.log('Turn identity parity passed: repeated yields across Swift/JS snapshots, completed retry deduplication and no tool replay');
