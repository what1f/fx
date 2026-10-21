import { strict as assert } from 'node:assert';
import { createFxEngine } from './adapter.mjs';

const encoder = new TextEncoder();
const finish = { type: 'finish', finishReason: { unified: 'stop', raw: 'stop' } };
const frame = value => encoder.encode(`data: ${JSON.stringify(value)}\n\n`);
const response = events => new Response(new ReadableStream({ start(controller) {
  for (const event of events) controller.enqueue(frame(event));
  controller.enqueue(encoder.encode('data: [DONE]\n\n')); controller.close();
} }));
let releaseTool, toolStarted, newStarted, newController;
const heldTool = new Promise(resolve => { releaseTool = resolve; });
const toolRunning = new Promise(resolve => { toolStarted = resolve; });
const newRunning = new Promise(resolve => { newStarted = resolve; });
const bodies = [];
const engine = await createFxEngine({
  apiKey: 'test-key', model: 'swift/control',
  fetch: async (_url, init) => {
    if (init.method === 'GET') return Response.json({ data: [{ id: 'swift/control', type: 'language', tags: ['tool-use'] }] });
    bodies.push(JSON.parse(new TextDecoder().decode(init.body)));
    if (bodies.length === 1) return response([
      { type: 'tool-call', toolCallId: 'held-1', toolName: 'hold', input: {} },
      { type: 'finish', finishReason: { unified: 'tool-calls', raw: 'tool-calls' } },
    ]);
    if (bodies.length === 2) return response([{ type: 'text-delta', delta: 'finished first' }, finish]);
    return new Response(new ReadableStream({ start(controller) {
      newController = controller; controller.enqueue(frame({ type: 'text-delta', delta: 'new turn' })); newStarted();
    } }));
  },
  tools: [{ name: 'hold', description: 'Hold until released', inputSchema: { type: 'object' }, idempotent: true,
    async execute() { toolStarted(); await heldTool; return 'released'; } }],
});
try {
  const first = engine.prompt('first');
  await toolRunning;
  const receipt = await first.steer('withdraw this before the next model step', 'steer-1');
  assert.equal(receipt.id, 'steer-1');
  assert.equal(await first.withdraw(receipt.id), 'withdrawn');
  releaseTool();
  for await (const _ of first) {}
  assert.equal((await first.result).stopReason, 'end_turn');
  assert.ok(!JSON.stringify(bodies[1]).includes('withdraw this'));
  const next = engine.prompt('second');
  await newRunning;
  await assert.rejects(first.steer('stale steer'), /no prompt is running/);
  assert.equal(await first.withdraw('steer-1'), 'already_placed');
  first.cancel();
  newController.enqueue(frame(finish));
  newController.enqueue(encoder.encode('data: [DONE]\n\n')); newController.close();
  for await (const _ of next) {}
  assert.equal((await next.result).stopReason, 'end_turn');
  console.log('Turn control passed: withdrawal before placement and stale-turn isolation');
} finally { releaseTool(); await engine.close(); }
