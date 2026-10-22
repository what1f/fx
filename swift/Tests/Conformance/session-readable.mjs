import assert from 'node:assert/strict';
import { createFxAgent } from './adapter.mjs';

let requests = 0;
const agent = createFxAgent({ apiKey: 'test-key', model: 'swift/readable',
  fetch(_url, init) {
    if (init.method === 'GET') return Response.json({ data: [{ id: 'swift/readable', type: 'language' }] });
    requests++;
    return new Response('data: {"type":"text-delta","delta":"answer"}\n\ndata: {"type":"finish","finishReason":{"unified":"stop","raw":"stop"}}\n\ndata: [DONE]\n\n', {
      headers: { 'content-type': 'text/event-stream' },
    });
  },
});
async function lines(stream) {
  const events = [];
  for await (const bytes of stream) events.push(JSON.parse(new TextDecoder().decode(bytes)));
  return events;
}
try {
  const session = agent.session();
  await session.prompt('previous', { messageId: 'previous' }).result;
  const turn = session.prompt('current', { messageId: 'current' });
  const events = await lines(turn.readable);
  assert.deepEqual(events.map(event => event.type), ['turn_start', 'text_delta', 'turn_end']);
  assert.ok(events.every(event => event.messageId === 'current'));
  assert.deepEqual(events.map(event => event.cursor), [4, 5, 6]);
  assert.equal(events[0].input, 'current');
  assert.equal(events[1].delta, 'answer');
  assert.equal((await turn.result).stopReason, 'end_turn');

  const dropped = session.prompt('keep running', { messageId: 'dropped-view' });
  const reader = dropped.readable.getReader();
  assert.equal(JSON.parse(new TextDecoder().decode((await reader.read()).value)).type, 'turn_start');
  await reader.cancel();
  assert.equal((await dropped.result).stopReason, 'end_turn', 'dropping a readable view must not cancel the durable turn');
  const duplicate = session.prompt('replacement', { messageId: 'dropped-view' });
  const repeated = await lines(duplicate.readable);
  assert.equal(repeated.length, 1);
  assert.equal(repeated[0].type, 'turn_end');
  assert.equal(repeated[0].repeated, true);
  assert.equal(requests, 3, 'duplicate intake must not reach the model');
  console.log('Swift session readable passed: native cursors, turn filtering, detached views and duplicate outcomes');
} finally { await agent.close(); }
