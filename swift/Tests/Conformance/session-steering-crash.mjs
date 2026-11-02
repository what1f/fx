import { strict as assert } from 'node:assert';
import { createFxAgent, memory } from './adapter.mjs';

const frame = value => `data: ${JSON.stringify(value)}\n\n`;
const finish = reason => frame({ type: 'finish', finishReason: { unified: reason, raw: reason } }) + 'data: [DONE]\n\n';
const answer = frame({ type: 'text-delta', delta: 'completed' }) + finish('stop');
async function until(check) {
  const deadline = Date.now() + 10_000;
  while (!await check()) {
    assert.ok(Date.now() < deadline, 'timed out waiting for persisted steering');
    await new Promise(resolve => setTimeout(resolve, 10));
  }
}
async function through(session, messageId) {
  const reader = session.stream().getReader(), decoder = new TextDecoder(), events = [];
  let buffer = '';
  try {
    while (!events.some(event => event.type === 'turn_end' && event.messageId === messageId)) {
      const { value, done } = await reader.read();
      assert.equal(done, false);
      buffer += decoder.decode(value, { stream: true });
      for (let end; (end = buffer.indexOf('\n')) >= 0;) {
        events.push(JSON.parse(buffer.slice(0, end))); buffer = buffer.slice(end + 1);
      }
    }
  } finally { await reader.cancel(); }
  return events;
}

for (const boundary of ['accepted', 'placed']) {
  const durability = memory(), sessionID = `steering-crash-${boundary}`, requests = [], executions = [];
  let phase = 'interrupted', releaseTool;
  const options = {
    durability, checkpointAfterBytes: null, apiKey: 'steering-crash-test-key', model: 'fixture/steering',
    tools: [{ name: 'lookup', description: 'Look up', inputSchema: { type: 'object' }, idempotent: true,
      execute(_input, context) {
        executions.push(context.executionId);
        if (phase === 'recovery') return 'safe replay';
        return new Promise(resolve => { releaseTool = resolve; });
      },
    }],
    async fetch(_url, init) {
      if (init.method === 'GET') return Response.json({ data: [{ id: 'fixture/steering', type: 'language', tags: ['tool-use'] }] });
      const body = JSON.parse(new TextDecoder().decode(init.body)); requests.push(body);
      if (phase === 'recovery') assert.equal(JSON.stringify(body).split('persisted guidance').length - 1, 1, 'steering is placed exactly once');
      if (requests.length === 1) return new Response(frame({ type: 'tool-call', toolCallId: 'stable-call', toolName: 'lookup', input: {} }) + finish('tool-calls'));
      if (phase === 'interrupted') return new Response(new ReadableStream({ start(controller) {
        controller.enqueue(new TextEncoder().encode(frame({ type: 'text-delta', delta: 'partial' })));
      } }));
      return new Response(answer);
    },
  };
  let agent = createFxAgent(options);
  try {
    const session = agent.session(sessionID);
    const original = session.prompt('original request', { messageId: 'original' });
    original.result.catch(() => {});
    await until(() => releaseTool !== undefined);
    await session.steer('persisted guidance', { messageId: 'guide' });
    await until(async () => {
      const store = await durability.create().session(sessionID);
      const records = await store.readSince(0);
      return records.some(bytes => {
        const record = JSON.parse(new TextDecoder().decode(bytes));
        return record.format === 'libfx-journal-v1' && record.events.some(event => event.type === 'input_accepted' && event.data?.text === 'persisted guidance');
      });
    });
    if (boundary === 'placed') {
      releaseTool('original result');
      await until(() => requests.length === 2);
    }
    assert.equal((await agent.__killForTest()).signal, 'SIGKILL');
    phase = 'recovery';
    agent = createFxAgent(options);
    const restored = agent.session(sessionID);
    const resumed = restored.resume();
    await restored.steer('ignored duplicate', { messageId: 'guide' });
    assert.equal((await resumed.accepted).messageId, 'original');
    assert.equal((await resumed.result).stopReason, 'end_turn');
    const after = restored.prompt('after recovery', { messageId: 'after' });
    assert.equal((await after.result).stopReason, 'end_turn');
    const events = await through(restored, 'after');
    assert.deepEqual(events.filter(event => event.type === 'turn_start').map(event => event.messageId), ['original', 'after']);
    assert.equal(executions.length, boundary === 'accepted' ? 2 : 1);
    assert.equal(new Set(executions).size, 1);
    assert.ok(!JSON.stringify(requests).includes('ignored duplicate'));
    await agent.close();
    console.log(`Swift durable steering SIGKILL recovery passed after ${boundary}: one placement, stable turn and call IDs`);
  } finally { await agent.close(); }
}
