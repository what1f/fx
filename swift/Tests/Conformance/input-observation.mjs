import { strict as assert } from 'node:assert';
import { fileURLToPath } from 'node:url';
import { createFxEngine as createSwiftEngine } from './adapter.mjs';
import { createFxEngine as createJSEngine } from '../../../sdk/node.js';

const nativeAddon = fileURLToPath(new URL('../../../zig-out/lib/libfx.node', import.meta.url));
function gateway(withTool) {
  let requests = 0;
  return async (_url, init) => {
    if (init.method === 'GET') return Response.json({ data: [{ id: 'fixture/input', type: 'language', tags: ['tool-use'] }] });
    const tool = withTool && requests++ === 0;
    const frames = tool ? [{ type: 'tool-call', toolCallId: 'input-call', toolName: 'inputs', input: {} }]
      : [{ type: 'text-delta', delta: 'finished' }];
    frames.push({ type: 'finish', finishReason: { unified: tool ? 'tool-calls' : 'stop', raw: 'stop' } });
    return new Response(frames.map(value => `data: ${JSON.stringify(value)}\n\n`).join('') + 'data: [DONE]\n\n');
  };
}
const base = { backend: 'native', nativeAddon, apiKey: 'fixture-input', model: 'fixture/input' };
async function drain(turn) {
  for await (const _ of turn) {}
  return turn.result;
}

async function inputs(create, captureContent, throwObserver) {
  const events = [], observerErrors = [];
  let effects = 0;
  const accepted = { outcome: 'accepted', answers: ['private-answer'], value: 42 };
  accepted.self = accepted;
  const failure = new Error('private-failure'), timeout = Object.assign(new Error('private-timeout'), { name: 'TimeoutError' });
  const engine = await create({ ...base, fetch: gateway(true), hooks: {
    captureContent,
    onEvent(event) { events.push(event); if (throwObserver && event.type.startsWith('wait.')) throw new Error('observer failed'); },
    onError: error => observerErrors.push(error),
  }, tools: [{ name: 'inputs', description: 'Input fixture', inputSchema: { type: 'object' }, async execute(_input, context) {
    assert.ok(context.observation);
    assert.equal(await context.observation.wait({ kind: 'approval', prompt: 'private-prompt' }, () => { effects++; return accepted; }), accepted);
    const denied = { outcome: 'denied', answers: ['no'] };
    assert.equal(await context.observation.wait({ kind: 'question', questions: [{ question: 'Continue?', options: [{ label: 'no' }] }] },
      () => { effects++; return denied; }), denied);
    for (const error of [failure, timeout]) {
      await assert.rejects(context.observation.wait({ kind: 'question', prompt: 'private-question' }, () => { effects++; throw error; }),
        observed => observed === error);
    }
    const child = await create({ ...base, fetch: gateway(false), hooks: context.observation.childHooks() });
    try { assert.equal((await drain(child.prompt('child input', { turnId: 'child-turn' }))).stopReason, 'end_turn'); }
    finally { await child.close(); }
    return 'input handled';
  } }] });
  try { assert.equal((await drain(engine.prompt('run', { turnId: 'parent-turn' }))).stopReason, 'end_turn'); }
  finally { await engine.close(); }
  assert.equal(effects, 4);
  const waits = events.filter(event => event.type.startsWith('wait.'));
  assert.equal(waits.length, 8);
  assert.equal(observerErrors.length, throwObserver ? 8 : 0);
  const starts = waits.filter(event => event.type === 'wait.start'), ends = waits.filter(event => event.type === 'wait.end');
  assert.equal(new Set(starts.map(event => event.data.requestId)).size, 4);
  assert.deepEqual(ends.map(event => event.data.outcome), ['accepted', 'denied', 'failed', 'timed_out']);
  for (let index = 0; index < 4; index++) {
    assert.equal(starts[index].data.requestId, ends[index].data.requestId);
    assert.equal(starts[index].data.callId, 'input-call');
  }
  for (const event of waits) {
    assert.equal(event.sessionId, engine.sessionId);
    assert.equal(event.rootSessionId, engine.sessionId);
    assert.equal(event.turnId, 'parent-turn');
    assert.equal(event.contentCaptured, captureContent);
  }
  const child = events.find(event => event.type === 'turn.start' && event.turnId === 'child-turn');
  assert.ok(child);
  assert.notEqual(child.sessionId, engine.sessionId);
  assert.equal(child.rootSessionId, engine.sessionId);
  assert.equal(child.parentSessionId, engine.sessionId);
  assert.equal(child.parentTurnId, 'parent-turn');
  assert.equal(child.parentCallId, 'input-call');
  assert.equal(JSON.stringify(waits).includes('private-prompt'), captureContent);
  assert.equal(JSON.stringify(waits).includes('private-answer'), captureContent);
  assert.ok(!JSON.stringify(waits).includes('private-failure'));
  assert.ok(!JSON.stringify(waits).includes('private-timeout'));
  return waits.map(event => {
    const { requestId, ...data } = event.data;
    return { type: event.type, data: JSON.parse(JSON.stringify(data)), contentCaptured: event.contentCaptured, contentTruncated: event.contentTruncated };
  });
}

async function cancellation(create) {
  const entered = Promise.withResolvers(), answer = Promise.withResolvers(), returned = Promise.withResolvers(), events = [];
  const accepted = { outcome: 'accepted', answers: ['late answer'] };
  const engine = await create({ ...base, fetch: gateway(true), hooks: { captureContent: true, onEvent: event => events.push(event) },
    tools: [{ name: 'inputs', description: 'Input cancellation', inputSchema: { type: 'object' }, async execute(_input, context) {
      try {
        const value = await context.observation.wait({ kind: 'approval', prompt: 'Approve?' }, () => { entered.resolve(); return answer.promise; });
        returned.resolve(value);
        return 'late tool result';
      } catch (error) { returned.reject(error); throw error; }
    } }],
  });
  try {
    const turn = engine.prompt('run');
    const completed = drain(turn);
    await entered.promise;
    await turn.cancel();
    const endings = () => events.filter(event => event.type === 'wait.end');
    assert.equal(endings().length, 1);
    assert.equal(endings()[0].data.outcome, 'cancelled');
    answer.resolve(accepted);
    assert.equal(await returned.promise, accepted);
    assert.equal((await completed).stopReason, 'cancelled');
    assert.equal(endings().length, 1);
  } finally { answer.resolve(accepted); await engine.close(); }
}

for (const capture of [false, true]) {
  for (const throwObserver of [false, true]) {
    const reference = await inputs(createJSEngine, capture, throwObserver);
    assert.deepEqual(await inputs(createSwiftEngine, capture, throwObserver), reference);
  }
}
await cancellation(createJSEngine);
await cancellation(createSwiftEngine);
console.log('Input observation parity passed: original values/errors, decisions, observer failures, child identity and late cancellation');
