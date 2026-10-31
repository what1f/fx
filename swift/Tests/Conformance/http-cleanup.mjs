import assert from 'node:assert/strict';
import { createServer } from 'node:http';
import { fileURLToPath } from 'node:url';
import { createFxEngine as javascript } from '../../../sdk/node.js';
import { createFxEngine as swift } from './adapter.mjs';

const frame = value => `data: ${JSON.stringify(value)}\n\n`;
const completed = frame({ type: 'text-delta', delta: 'OK' }) +
  frame({ type: 'finish', finishReason: { unified: 'stop', raw: 'stop' } }) + 'data: [DONE]\n\n';
async function bounded(promise, label) {
  let timer;
  try {
    return await Promise.race([promise, new Promise((_, reject) => {
      timer = setTimeout(() => reject(new Error(`${label} timed out`)), 3000);
    })]);
  } finally { clearTimeout(timer); }
}

for (const [backend, open] of [['JavaScript', javascript], ['Swift', swift]]) {
  const sockets = new WeakMap(), timers = new Set(), records = [];
  let socketID = 0, mode = 'eof', toolRequests = 0;
  const server = createServer((request, response) => {
    request.resume();
    request.on('end', () => {
      const record = { response, socket: sockets.get(request.socket), ended: false };
      records.push(record);
      response.writeHead(200, { 'content-type': 'text/event-stream' });
      if (mode === 'tool' && toolRequests++ === 0) {
        response.write(frame({ type: 'tool-call', toolCallId: 'cleanup-tool', toolName: 'lookup', input: {} }) +
          frame({ type: 'finish', finishReason: { unified: 'tool-calls', raw: 'tool-calls' } }) + 'data: [DONE]\n\n');
      } else { response.write(completed); }
      if (mode === 'eof' || mode === 'tool') {
        const timer = setTimeout(() => {
          timers.delete(timer);
          record.ended = true;
          response.end();
        }, 30);
        timers.add(timer);
      }
    });
  });
  server.on('connection', socket => { sockets.set(socket, ++socketID); });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  const url = `http://127.0.0.1:${server.address().port}/chat`;
  let agent;
  try {
    let sharedSocket;
    for (const scenario of ['eof', 'eof', 'eof', 'stalled', 'capped', 'tool']) {
      mode = scenario;
      const fetches = [];
      agent = await open({ backend: 'native', nativeAddon: fileURLToPath(new URL('../../../zig-out/lib/libfx.node', import.meta.url)), apiKey: 'cleanup-fixture-key', model: 'fixture/cleanup', gatewayChatUrl: url,
        tools: [{ name: 'lookup', description: 'Look up a fixture value', inputSchema: { type: 'object', properties: {} }, execute: () => 'value' }],
        async fetch(input, init) {
          if (init.method === 'GET') return Response.json({ data: [{ id: 'fixture/cleanup', type: 'language' }] });
          const prior = records.at(-1);
          if (scenario === 'tool' && fetches.length) assert.equal(prior.ended, true, `${backend}: next tool step waited for EOF`);
          const record = { signal: init.signal, aborts: 0 };
          init.signal.addEventListener('abort', () => { record.aborts++; }, { once: true });
          fetches.push(record);
          return fetch(input, init);
        },
      });
      const turn = agent.prompt('hello');
      let text = '';
      await bounded((async () => { for await (const event of turn) if (event.type === 'text_delta') text += event.delta; })(), `${backend} stream`);
      assert.equal((await turn.result).stopReason, 'end_turn');
      assert.equal(text, 'OK');
      assert.ok(fetches.every(record => record.aborts === 0), `${backend}: no abort on successful consumption`);
      const response = records.at(-1);
      if (scenario === 'capped') {
        response.response.write(`: ${'x'.repeat(96 * 1024)}\n\n`);
        const timer = setTimeout(() => { timers.delete(timer); response.ended = true; response.response.end(); }, 30);
        timers.add(timer);
      }
      await bounded(agent.close(), `${backend} close`);
      agent = undefined;
      if (scenario === 'stalled' || scenario === 'capped') {
        assert.equal(fetches.at(-1).aborts, 1, `${backend}: bounded tail aborted once`);
        assert.equal(response.ended, false, `${backend}: cleanup preceded EOF`);
      } else {
        assert.ok(fetches.every(record => record.aborts === 0), `${backend}: EOF released without abort`);
        assert.equal(response.ended, true);
      }
      if (scenario === 'eof') {
        sharedSocket ??= response.socket;
        assert.equal(response.socket, sharedSocket, `${backend}: fresh engine reused the TCP connection`);
      }
    }
    assert.equal(toolRequests, 2);
    console.log(`${backend} HTTP cleanup passed: TCP reuse, bounded tails and tool-step ordering`);
  } finally {
    for (const timer of timers) clearTimeout(timer);
    server.closeAllConnections();
    await agent?.close().catch(() => {});
    await new Promise(resolve => server.close(resolve));
  }
}
