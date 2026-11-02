import { strict as assert } from 'node:assert';
import { fileURLToPath } from 'node:url';
import { createFxEngine as createSwiftEngine, createMcpAdapter as createSwiftAdapter } from './adapter.mjs';
import { createFxEngine as createJSEngine } from '../../../sdk/node.js';
import { createMcpAdapter as createJSAdapter } from '../../../sdk/mcp.js';

const base = { backend: 'native', nativeAddon: fileURLToPath(new URL('../../../zig-out/lib/libfx.node', import.meta.url)),
  apiKey: 'mcp-observation-key', model: 'fixture/mcp-observation' };
function gateway(name) {
  let requests = 0;
  return async (_url, init) => {
    if (init.method === 'GET') return Response.json({ data: [{ id: base.model, type: 'language', tags: ['tool-use'] }] });
    const tool = requests++ === 0;
    const frames = tool ? [{ type: 'tool-call', toolCallId: 'remote-call', toolName: name, input: { secret: 'private-input' } }]
      : [{ type: 'text-delta', delta: 'complete' }];
    frames.push({ type: 'finish', finishReason: { unified: tool ? 'tool-calls' : 'stop', raw: 'stop' } });
    return new Response(frames.map(value => `data: ${JSON.stringify(value)}\n\n`).join('') + 'data: [DONE]\n\n');
  };
}
async function drain(turn) { for await (const _ of turn) {} return turn.result; }
const parent = { rootSessionId: 'outer-root', sessionId: 'outer-session', turnId: 'outer-turn', callId: 'outer-call' };

async function exercise(createEngine, createAdapter, correlation, isError, throwObserver) {
  const events = [], errors = [], remote = [];
  const adapter = await createAdapter({
    // Also exercise a client with its own handshake and a different advertised
    // name, so the configured observation identity must come from Swift options.
    ...(correlation ? { initialize: async () => ({ protocolVersion: '2025-11-25', capabilities: { tools: {} },
      serverInfo: { name: 'advertised-server', version: 'fixture' } }) } : {}),
    listTools: async () => ({ tools: [{ name: 'remote.echo', description: 'Echo', inputSchema: { type: 'object' } }] }),
    async callTool(params) { remote.push(params); return { content: [{ type: 'text', text: 'private-result' }], isError }; },
  }, { prefix: 'fixture_', serverName: 'original-server', propagateCorrelation: correlation });
  let retained;
  const tool = adapter.tools[0];
  const engine = await createEngine({ ...base, fetch: gateway(tool.name),
    tools: [{ ...tool, async execute(input, context) { retained = context; return tool.execute(input, context); } }],
    hooks: { parent, captureContent: throwObserver,
      onEvent(event) { events.push(event); if (throwObserver && event.type.startsWith('mcp.')) throw new Error('observer failed'); },
      onError: error => errors.push(error),
    },
  });
  try {
    assert.equal((await drain(engine.prompt('call remote', { turnId: 'public-turn' }))).stopReason, 'end_turn');
    assert.equal(remote.length, 1);
    const spans = events.filter(event => event.type.startsWith('mcp.'));
    assert.deepEqual(spans.map(event => event.type), correlation ? ['mcp.start', 'mcp.request', 'mcp.end'] : ['mcp.start', 'mcp.end']);
    const start = spans[0], end = spans.at(-1);
    assert.equal(start.data.server, 'original-server');
    assert.equal(start.data.tool, 'remote.echo');
    assert.equal(start.data.callId, 'remote-call');
    assert.equal(end.data.status, isError ? 'failure' : 'success');
    assert.equal(end.data.operationId, start.data.operationId);
    for (const event of spans) {
      assert.equal(event.rootSessionId, parent.rootSessionId);
      assert.equal(event.parentSessionId, parent.sessionId);
      assert.equal(event.parentTurnId, parent.turnId);
      assert.equal(event.parentCallId, parent.callId);
      assert.equal(event.sessionId, engine.sessionId);
      assert.equal(event.turnId, 'public-turn');
      assert.equal(event.executionId, start.executionId);
      assert.equal(event.contentCaptured, throwObserver);
    }
    assert.ok(!JSON.stringify(spans).includes('private-input'));
    assert.ok(!JSON.stringify(spans).includes('private-result'));
    assert.equal(errors.length, throwObserver ? spans.length : 0);
    if (correlation) {
      const token = remote[0]._meta['libfx/correlationId'];
      assert.match(token, /^[0-9a-f-]{36}$/);
      assert.equal(remote[0]._meta.progressToken, undefined);
      assert.equal(spans[1].data.requestId, token);
      assert.equal(spans[1].data.requestIdKind, 'correlation');
    } else assert.equal(remote[0]._meta, undefined);
    const completed = events.findIndex(event => event.type === 'tool.end');
    assert.ok(events.indexOf(end) < completed);
    // Swift's ownership guarantee is an additional native requirement. The JS
    // helper retains an active observer after successful tool completion.
    if (createEngine === createSwiftEngine) {
      try { await tool.execute({}, retained); } catch (error) { if (!isError) throw error; }
      assert.equal(remote.length, 2);
      assert.equal(events.filter(event => event.type.startsWith('mcp.')).length, spans.length);
    }
    return spans.map(event => {
      const { operationId, requestId, ...data } = event.data;
      return { type: event.type, data: JSON.parse(JSON.stringify(data)), contentCaptured: event.contentCaptured };
    });
  } finally { await engine.close(); await adapter.close(); }
}

async function cancellation(createEngine, createAdapter) {
  const entered = Promise.withResolvers(), answer = Promise.withResolvers(), cancelled = Promise.withResolvers();
  const terminal = Promise.withResolvers(), events = [];
  let remoteCalls = 0;
  const adapter = await createAdapter({
    listTools: async () => ({ tools: [{ name: 'remote.echo', inputSchema: { type: 'object' } }] }),
    async callTool(_params, _schema, options) {
      remoteCalls++;
      options.signal.addEventListener('abort', () => cancelled.resolve(), { once: true });
      entered.resolve();
      return answer.promise;
    },
  }, { serverName: 'original-server', propagateCorrelation: true });
  const engine = await createEngine({ ...base, fetch: gateway(adapter.tools[0].name), tools: adapter.tools,
    hooks: { onEvent(event) { events.push(event); if (event.type === 'mcp.end') terminal.resolve(); } },
  });
  try {
    const turn = engine.prompt('cancel remote');
    const result = drain(turn);
    await entered.promise;
    await turn.cancel();
    await Promise.all([terminal.promise, cancelled.promise]);
    assert.equal((await result).stopReason, 'cancelled');
    const endings = () => events.filter(event => event.type === 'mcp.end');
    assert.equal(endings().length, 1);
    assert.equal(endings()[0].data.status, 'cancelled');
    answer.resolve({ content: [{ type: 'text', text: 'late result' }] });
    await engine.close();
    await adapter.close();
    assert.equal(endings().length, 1);
    assert.equal(remoteCalls, 1);
  } finally {
    answer.resolve({ content: [] });
    await engine.close(); await adapter.close();
  }
}

for (const correlation of [false, true]) for (const isError of [false, true]) for (const throwObserver of [false, true]) {
  const expected = await exercise(createJSEngine, createJSAdapter, correlation, isError, throwObserver);
  assert.deepEqual(await exercise(createSwiftEngine, createSwiftAdapter, correlation, isError, throwObserver), expected);
}
await cancellation(createJSEngine, createJSAdapter);
await cancellation(createSwiftEngine, createSwiftAdapter);
console.log('MCP observation parity passed: remote identity, correlation, parent scopes, observer failures, inactive scopes and late cancellation');
