import assert from 'node:assert/strict';
import { createFxAgent } from './adapter.mjs';

const encoder = new TextEncoder();
const frame = value => encoder.encode(`data: ${JSON.stringify(value)}\n\n`);
const finish = { type: 'finish', finishReason: { unified: 'stop', raw: 'stop' } };
const held = new Map(), aborted = new Set();
let requests = 0;
const agent = createFxAgent({ apiKey: 'fixture', model: 'swift/view-detach',
  fetch(_url, init) {
    if (init.method === 'GET') return Response.json({ data: [{ id: 'swift/view-detach', type: 'language' }] });
    const index = ++requests;
    init.signal.addEventListener('abort', () => aborted.add(index), { once: true });
    return new Response(new ReadableStream({ start(controller) {
      controller.enqueue(frame({ type: 'text-delta', delta: `reply-${index}` }));
      const complete = () => {
        controller.enqueue(frame(finish));
        controller.enqueue(encoder.encode('data: [DONE]\n\n'));
        controller.close();
      };
      if (index === 1 || index === 3) held.set(index, complete);
      else complete();
    } }), { headers: { 'content-type': 'text/event-stream' } });
  },
});
try {
  const session = agent.session();
  const detached = session.prompt('detach only', { messageId: 'detached' });
  for await (const event of detached) {
    assert.equal(event.type, 'text_delta');
    break;
  }
  assert.equal(aborted.has(1), false, 'returning the durable iterator must not abort native HTTP');
  assert.equal((await detached[Symbol.asyncIterator]().next()).done, true,
    'a detached view must finish reads while its native work is still held');
  assert.equal(requests, 1);
  held.get(1)();
  assert.equal((await detached.result).stopReason, 'end_turn', 'dropping a durable iterator must not cancel its work');
  assert.equal((await session.prompt('after detach', { messageId: 'after-detach' }).result).stopReason, 'end_turn');

  const current = session.prompt('cancel current', { messageId: 'current' });
  const iterator = current[Symbol.asyncIterator]();
  assert.equal((await iterator.next()).value.delta, 'reply-3');
  const queued = session.prompt('keep queued', { messageId: 'queued' });
  await queued.accepted;
  await session.cancel();
  assert.equal((await current.result).stopReason, 'cancelled');
  await iterator.return();
  assert.equal((await iterator.next()).done, true);
  assert.equal((await queued.result).stopReason, 'end_turn', 'explicit session cancellation must leave the queued input intact');
  assert.equal(requests, 4);
  assert.equal(aborted.has(4), false);
  console.log('Swift durable view detach passed: iterator return preserves work; explicit cancel affects only the current input');
} finally {
  for (const complete of held.values()) {
    try { complete(); } catch { /* A completed or aborted fixture is already released. */ }
  }
  await agent.close();
}
