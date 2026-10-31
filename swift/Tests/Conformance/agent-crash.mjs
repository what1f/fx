import { strict as assert } from 'node:assert';
import { createFxAgent, memory } from './adapter.mjs';

const frame = value => `data: ${JSON.stringify(value)}\n\n`;
const reply = text => frame({ choices: [{ index: 0, delta: { role: 'assistant', content: text }, finish_reason: null }] }) +
  frame({ choices: [{ index: 0, delta: {}, finish_reason: 'stop' }] }) + 'data: [DONE]\n\n';
const toolCall = frame({ choices: [{ index: 0, delta: { role: 'assistant', tool_calls: [
  { index: 0, id: 'crash-call', type: 'function', function: { name: 'lookup', arguments: '{}' } },
] }, finish_reason: null }] }) + frame({ choices: [{ index: 0, delta: {}, finish_reason: 'tool_calls' }] }) + 'data: [DONE]\n\n';

for (const boundary of ['model', 'write', 'idempotent']) {
  const durability = memory(), sessionID = `crash-${boundary}`, requests = [], executions = [];
  let phase = 'history', toolStarted;
  const started = new Promise(resolve => { toolStarted = resolve; });
  const options = key => ({
    durability, checkpointAfterBytes: 0,
    provider: { name: 'local', baseUrl: 'https://crash.example/v1', models: {
      'crash-model': { contextWindow: 32768, maxOutputTokens: 4096, supportsToolUse: true },
    } },
    model: 'crash-model', credentials: () => ({ apiKey: key }),
    tools: [{ name: 'lookup', description: 'Look up a record', inputSchema: { type: 'object' },
      idempotent: boundary === 'idempotent', writes: boundary === 'write',
      execute(_value, context) {
        executions.push(context.executionId);
        assert.equal(context.sessionId, sessionID);
        toolStarted();
        return phase === 'recovery' ? 'replayed lookup result' : new Promise(() => {});
      },
    }],
    async fetch(input, init) {
      assert.equal(String(input), 'https://crash.example/v1/chat/completions');
      const body = JSON.parse(new TextDecoder().decode(init.body));
      requests.push({ body, authorization: new Headers(init.headers).get('authorization') });
      if (phase === 'recovery') {
        const history = JSON.stringify(body);
        assert.match(history, /remember the conversation/);
        assert.match(history, /saved answer/);
        assert.match(history, /interrupted input/);
        if (boundary === 'write') assert.match(history, /may have partly run/);
        if (boundary === 'idempotent') assert.match(history, /replayed lookup result/);
      }
      let response;
      if (phase === 'interrupted' && boundary === 'model') {
        response = new ReadableStream({ start(controller) {
          controller.enqueue(new TextEncoder().encode(frame({ choices: [{ index: 0,
            delta: { role: 'assistant', content: 'partial output' }, finish_reason: null }] })));
        } });
      } else response = phase === 'interrupted' ? toolCall : reply(phase === 'history' ? 'saved answer' : 'recovered answer');
      return new Response(response, { headers: { 'content-type': 'text/event-stream' } });
    },
  });
  let agent = createFxAgent(options('old-private-key'));
  try {
    const session = agent.session(sessionID);
    const history = session.prompt('remember the conversation', { id: 'history' });
    assert.equal((await history.result).stopReason, 'end_turn');
    phase = 'interrupted';
    const interrupted = session.prompt('interrupted input', { id: 'interrupted-message' });
    await interrupted.accepted;
    if (boundary === 'model') {
      const iterator = interrupted[Symbol.asyncIterator]();
      let sawPartial = false;
      while (!sawPartial) {
        const { value, done } = await iterator.next();
        assert.equal(done, false);
        sawPartial = value.type === 'text_delta' && value.delta.includes('partial output');
      }
    } else await started;
    assert.equal((await agent.__killForTest()).signal, 'SIGKILL');
    phase = 'recovery';
    agent = createFxAgent(options('new-private-key'));
    const resumed = agent.session(sessionID).resume();
    const receipt = await resumed.accepted;
    assert.equal(receipt.id, 'interrupted-message');
    let text = '';
    for await (const event of resumed) if (event.type === 'text_delta') text += event.delta;
    assert.equal((await resumed.result).stopReason, 'end_turn');
    assert.ok(text.endsWith('recovered answer'));
    if (boundary === 'write') assert.deepEqual(executions, ['crash-call'], 'ambiguous write is not repeated');
    if (boundary === 'idempotent') assert.deepEqual(executions, ['crash-call', 'crash-call'], 'safe rerun preserves execution identity');
    assert.equal(requests.at(-1).authorization, 'Bearer new-private-key');
    const calls = requests.length;
    const duplicate = agent.session(sessionID).prompt('ignored retry', { id: 'interrupted-message' });
    assert.equal((await duplicate.result).isRepeated, true);
    assert.equal(requests.length, calls);
    await agent.close();
    const stored = await durability.create().session(sessionID);
    const bytes = await stored.readSince(0);
    const all = bytes.map(data => Buffer.from(data).toString('utf8')).join('\n');
    for (const key of ['old-private-key', 'new-private-key']) assert.equal(all.includes(key), false);
    console.log(`Swift durable agent SIGKILL recovery passed: ${boundary}`);
  } finally { await agent.close(); }
}

// A synchronous JavaScript prompt is an asynchronous Swift acceptance call.
// Closing must preserve that call order across the test transport.
{
  const agent = createFxAgent({ apiKey: 'close-order-key', model: 'fixture/close', fetch: async (_input, init) =>
    init.method === 'GET' ? Response.json({ data: [{ id: 'fixture/close', type: 'language' }] }) :
      new Response('data: {"type":"text-delta","delta":"drained"}\n\ndata: {"type":"finish","finishReason":{"unified":"stop","raw":"stop"}}\n\ndata: [DONE]\n\n',
        { headers: { 'content-type': 'text/event-stream' } }),
  });
  const turn = agent.session().prompt('accepted before close');
  await agent.close();
  assert.equal((await turn.result).stopReason, 'end_turn');
  console.log('Swift durable agent close drains prior intake and delivers its result');
}
