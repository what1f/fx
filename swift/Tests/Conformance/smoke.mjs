import { strict as assert } from 'node:assert';
import { createServer } from 'node:http';
import { createFxEngine } from './adapter.mjs';

let requests = 0, calls = 0;
const png = 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jP0cAAAAASUVORK5CYII=';
const server = createServer((req, res) => {
  let body = '';
  req.setEncoding('utf8');
  req.on('data', chunk => body += chunk);
  req.on('end', () => {
    if (req.method === 'GET') {
      res.writeHead(200, { 'content-type': 'application/json' });
      res.end(JSON.stringify({ data: [{ id: 'swift/model', type: 'language', tags: ['tool-use', 'vision'] }] }));
      return;
    }
    requests++;
    assert.equal(req.headers.authorization, 'Bearer swift-test-key');
    const payload = JSON.parse(body);
    res.writeHead(200, { 'content-type': 'text/event-stream' });
    const frames = [];
    if (requests === 1) {
      assert.equal(payload.tools.find(t => t.name === 'lookup').inputSchema.type, 'object');
      frames.push({ type: 'tool-call', toolCallId: 'call_1', toolName: 'lookup', input: { key: 'alpha' } });
    } else {
      if (requests === 2) {
        assert.ok(body.includes('value:alpha'));
        assert.ok(JSON.stringify(payload).includes(png), 'tool image did not reach the next model request');
      }
      frames.push({ type: 'reasoning-delta', delta: 'think' }, { type: 'text-delta', delta: '你好 Swift' });
    }
    frames.push({ type: 'finish', finishReason: { unified: requests === 1 ? 'tool-calls' : 'stop', raw: 'stop' }, usage: { inputTokens: { total: 1 }, outputTokens: { total: 1 } } });
    res.end(frames.map(frame => `data: ${JSON.stringify(frame)}\n\n`).join('') + 'data: [DONE]\n\n');
  });
});
await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
const options = {
  apiKey: 'swift-test-key', model: 'swift/model', gatewayChatUrl: `http://127.0.0.1:${server.address().port}/chat`,
  fetch(url, init) {
    // The core's catalog endpoint is independent of the chat endpoint.
    const endpoint = (init.method ?? 'GET').toUpperCase() === 'GET' ? `http://127.0.0.1:${server.address().port}/models` : url;
    return globalThis.fetch(endpoint, init);
  },
  tools: [{ name: 'lookup', description: 'Look up a value.', idempotent: true,
    inputSchema: { type: 'object', properties: { key: { type: 'string' } }, required: ['key'] },
    async execute({ key }) {
      calls++;
      return { type: 'libfx.tool-result', text: `value:${key}`, images: [{ type: 'image', mimeType: 'image/png', data: png }] };
    },
  }],
};
let engine;
try {
  engine = await createFxEngine(options);
  let turn = engine.prompt('use lookup'), text = '';
  const events = [];
  for await (const event of turn) { events.push(event); if (event.type === 'text_delta') text += event.delta; }
  assert.equal(text, '你好 Swift');
  assert.equal(calls, 1);
  assert.equal((await turn.result).stopReason, 'end_turn');
  assert.ok(events.some(e => e.type === 'tool_start'));
  assert.ok(events.some(e => e.type === 'tool_end'));
  const checkpoint = await engine.checkpoint();
  assert.ok(checkpoint.byteLength > 0);
  await engine.close();
  await engine.close();
  engine = await createFxEngine({ ...options, checkpoint });
  turn = engine.prompt('continue');
  for await (const event of turn) {}
  assert.equal((await turn.result).stopReason, 'end_turn');
  console.log('Swift SDK smoke passed: stream, Unicode, tool, checkpoint, restore, repeated close');
} finally {
  await engine?.close();
  server.closeAllConnections();
  await new Promise(resolve => server.close(resolve));
}
