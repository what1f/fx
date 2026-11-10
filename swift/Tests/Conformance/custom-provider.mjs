import { strict as assert } from 'node:assert';
import { fileURLToPath } from 'node:url';
import { createFxEngine as swift } from './adapter.mjs';
import { createFxEngine as javascript } from '../../../sdk/node.js';

const provider = { name: 'local', baseUrl: 'https://models.example/v1/', models: {
  'local-model': { contextWindow: 32768, maxOutputTokens: 4096, supportsToolUse: true },
} };
const chatURL = 'https://models.example/v1/chat/completions';
const nativeAddon = fileURLToPath(new URL('../../../zig-out/lib/libfx.node', import.meta.url));
const sse = (...chunks) => chunks.map(chunk => `data: ${JSON.stringify(chunk)}\n\n`).join('') + 'data: [DONE]\n\n';
const answer = sse({ choices: [{ index: 0, delta: { role: 'assistant', content: 'provider reply' }, finish_reason: null }] },
  { choices: [{ index: 0, delta: {}, finish_reason: 'stop' }] });
const tool = sse({ choices: [{ index: 0, delta: { role: 'assistant', tool_calls: [{ index: 0, id: 'lookup-1', type: 'function',
  function: { name: 'lookup', arguments: '{"key":"alpha"}' } }] }, finish_reason: null }] },
  { choices: [{ index: 0, delta: {}, finish_reason: 'tool_calls' }] });
async function drain(turn) {
  let text = '';
  for await (const event of turn) if (event.type === 'text_delta') text += event.delta;
  return { text, result: await turn.result };
}

for (const [name, create] of [['JavaScript', javascript], ['Swift', swift]]) {
  for (const scenario of ['anonymous', 'tool', 'rejected', 'echoed']) {
    const requests = [], credentials = [], events = [];
    let calls = 0;
    const key = 'test-provider-secret';
    const engine = await create({ backend: 'native', nativeAddon, provider, model: 'local-model',
      ...(scenario === 'anonymous' ? {} : { credentials(request) { credentials.push(request); return { apiKey: key }; } }),
      onEvent: event => events.push(event),
      tools: [{ name: 'lookup', description: 'Look up a key', inputSchema: { type: 'object' }, idempotent: true,
        execute(input) { calls++; assert.equal(input.key, 'alpha'); return 'alpha is beta'; } }],
      async fetch(url, init) {
        assert.equal(String(url), chatURL, `${name} sent a request outside the provider chat endpoint`);
        assert.equal(init.method, 'POST');
        const headers = new Headers(init.headers), body = JSON.parse(new TextDecoder().decode(init.body));
        requests.push({ headers, body });
        assert.equal(body.model, 'local-model'); assert.equal(body.stream, true);
        assert.equal(headers.get('authorization'), scenario === 'anonymous' ? null : `Bearer ${key}`);
        if (scenario === 'rejected') return Response.json({ error: { message: 'invalid api key' } }, { status: 401 });
        if (scenario === 'echoed') {
          const escaped = [...key].map(char => `\\u${char.charCodeAt(0).toString(16).padStart(4, '0')}`).join('');
          return new Response(`{"error":{"message":"bad Bearer ${key}","escaped":"${escaped}"}}`,
            { status: 403, headers: { 'content-type': 'application/json' } });
        }
        return new Response(scenario === 'tool' && requests.length === 1 ? tool : answer,
          { headers: { 'content-type': 'text/event-stream' } });
      },
    });
    try {
      const outcome = await drain(engine.prompt('lookup alpha')).catch(error => ({ error }));
      if (scenario === 'rejected' || scenario === 'echoed') {
        assert.ok(outcome.error || outcome.result.stopReason !== 'end_turn');
        assert.equal(requests.length, 1);
      } else {
        assert.equal(outcome.text, 'provider reply'); assert.equal(outcome.result.stopReason, 'end_turn');
      }
      if (scenario === 'tool') {
        assert.equal(calls, 1); assert.equal(requests.length, 2);
        const messages = requests[1].body.messages;
        assert.equal(messages.find(message => message.role === 'tool').tool_call_id, 'lookup-1');
        assert.match(JSON.stringify(messages), /alpha is beta/);
      }
      for (const request of credentials) {
        assert.equal(request.provider, 'local'); assert.equal(request.sessionId, engine.sessionId);
      }
      assert.equal(JSON.stringify({ outcome, events }).includes(key), false);
      const checkpoint = await engine.checkpoint();
      assert.equal(Buffer.from(checkpoint).includes(Buffer.from(key)), false);
    } finally { await engine.close(); }
  }
  console.log(`${name}: custom provider requests, host tools, credentials, rejected keys and error redaction passed`);
}
