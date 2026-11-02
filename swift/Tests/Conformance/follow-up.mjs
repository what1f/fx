import { strict as assert } from 'node:assert';
import { fileURLToPath } from 'node:url';
import { createFxEngine as createSwiftEngine } from './adapter.mjs';
import { createFxEngine as createJSEngine, createMemoryPersistence } from '../../../sdk/node.js';

async function drain(turn) {
  const events = [];
  for await (const event of turn) events.push(event);
  return { events, result: await turn.result };
}
function userText(body) {
  return body.prompt.filter(message => message.role === 'user').at(-1)?.content.map(part => part.text ?? '').join('');
}

async function exercise(source, target, handoff) {
  const persistence = createMemoryPersistence(), requests = [];
  let started, release, calls = 0;
  const toolStarted = new Promise(resolve => { started = resolve; });
  const options = {
    backend: 'native', nativeAddon: fileURLToPath(new URL('../../../zig-out/lib/libfx.node', import.meta.url)),
    apiKey: 'follow-up-key', model: 'fixture/follow-up', persistence,
    tools: [{ name: 'hold', description: 'Wait', inputSchema: { type: 'object' }, idempotent: true,
      execute(_input, context) {
        calls++;
        started();
        return new Promise(resolve => {
          release = () => resolve('released');
          if (context.signal.aborted) resolve('cancelled');
          else context.signal.addEventListener('abort', () => resolve('cancelled'), { once: true });
        });
      },
    }],
    async fetch(_url, init) {
      if (init.method === 'GET') return Response.json({ data: [{ id: 'fixture/follow-up', type: 'language', tags: ['tool-use'] }] });
      requests.push(JSON.parse(new TextDecoder().decode(init.body)));
      const first = requests.length === 1;
      const frames = first ? [{ type: 'tool-call', toolCallId: 'hold-1', toolName: 'hold', input: {} }]
        : [{ type: 'text-delta', delta: userText(requests.at(-1)) }];
      frames.push({ type: 'finish', finishReason: { unified: first ? 'tool-calls' : 'stop', raw: 'stop' } });
      return new Response(frames.map(event => `data: ${JSON.stringify(event)}\n\n`).join('') + 'data: [DONE]\n\n');
    },
  };
  let engine;
  try {
    engine = await source(options);
    const first = engine.prompt('hold'), firstDone = drain(first);
    await toolStarted;
    const one = engine.followUp('one'), two = engine.followUp('two');
    void one.catch(() => {}); void two.catch(() => {});
    await one.accepted; await two.accepted;
    assert.equal(requests.length, 1, 'a follow-up ran before the active turn ended');
    const ids = [one.id, two.id];
    if (handoff) {
      await first.cancel({ reason: 'handoff' });
      await firstDone;
      await assert.rejects(one); await assert.rejects(two);
      await engine.close();
      engine = await target(options);
      assert.equal((await drain(engine.resume())).result.stopReason, 'end_turn');
      const own = engine.followUp('own');
      assert.equal((await drain(await own)).result.stopReason, 'end_turn');
      for (const id of ids) {
        const held = engine.resume();
        assert.ok(held);
        assert.equal((await drain(held)).result.stopReason, 'end_turn');
        assert.equal(held.id, id);
      }
    } else {
      release();
      assert.equal((await firstDone).result.stopReason, 'end_turn');
      for (const pending of [one, two]) {
        const turn = await pending;
        const done = await drain(turn);
        assert.equal(done.result.stopReason, 'end_turn');
        assert.equal(turn.id, pending.id);
      }
    }
    assert.equal(engine.resume(), null);
    await engine.close();
    const events = persistence.records.flatMap(record => JSON.parse(new TextDecoder().decode(record.data)).events);
    for (const id of ids) {
      assert.equal(events.filter(event => event.type === 'input_accepted' && event.data.id === id).length, 1);
      assert.equal(events.filter(event => event.type === 'turn_progress' && event.inputs?.includes(id)).length, 1);
    }
    const inputs = requests.map(userText);
    if (handoff) {
      assert.equal(inputs.length, 5);
      assert.equal(inputs[0], 'hold');
      assert.ok(JSON.stringify(requests[1]).includes('hold'), 'resuming lost the original input');
      assert.deepEqual(inputs.slice(2), ['own', 'one', 'two']);
    } else { assert.deepEqual(inputs, ['hold', 'hold', 'one', 'two']); }
    assert.equal(calls, 1);
    return inputs;
  } finally { release?.(); await engine?.close(); }
}

const ordinary = await exercise(createJSEngine, createJSEngine, false);
assert.deepEqual(await exercise(createSwiftEngine, createSwiftEngine, false), ordinary);
const recovery = await exercise(createJSEngine, createJSEngine, true);
assert.deepEqual(await exercise(createSwiftEngine, createSwiftEngine, true), recovery);
assert.deepEqual(await exercise(createSwiftEngine, createJSEngine, true), recovery);
assert.deepEqual(await exercise(createJSEngine, createSwiftEngine, true), recovery);
console.log('Follow-up parity passed: ordered durable acceptance, automatic turns, explicit held-input recovery and independent current inputs across Swift/JS');
