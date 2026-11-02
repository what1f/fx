import { spawn } from 'node:child_process';
import { createInterface } from 'node:readline';
import { randomUUID } from 'node:crypto';
import { swiftObservationScope } from './observation-scope.mjs';

// Forward the fixture client's transport operations. Catalog processing, naming,
// context composition, result conversion, and cancellation run in Swift.
export async function createMcpAdapter(client, options, driver) {
  const child = spawn(driver, [], { stdio: ['pipe', 'pipe', 'pipe'] });
  const lines = createInterface({ input: child.stdout });
  const pending = new Map(), remoteCalls = new Map(), observations = new Map(), cancelledRequests = new Set();
  let nextID = 1, stderr = '', closePromise, spawnFailure;
  child.stderr.on('data', data => { stderr += data; });
  const exited = new Promise(resolve => child.once('close', (code, signal) => resolve({ code, signal })));
  function request(op, args = {}) {
    if (child.stdin.writableEnded || child.stdin.destroyed) return Promise.reject(new Error('MCP driver input is closed'));
    const id = nextID++;
    return new Promise((resolve, reject) => {
      pending.set(id, { resolve, reject });
      child.stdin.write(JSON.stringify({ id, op, ...args }) + '\n', error => {
        if (error) { pending.delete(id); reject(error); }
      });
    });
  }
  child.on('close', (code, signal) => {
    for (const waiter of pending.values()) waiter.reject(new Error(`MCP driver exited: ${code ?? signal}${stderr ? `\n${stderr}` : ''}`));
    pending.clear();
  });
  child.on('error', error => {
    spawnFailure = error;
    for (const waiter of pending.values()) waiter.reject(error);
    pending.clear();
  });
  child.stdin.on('error', error => {
    for (const waiter of pending.values()) waiter.reject(error);
    pending.clear();
  });
  async function finish() {
    child.stdin.end();
    const { code, signal } = await exited;
    lines.close();
    if (spawnFailure) throw spawnFailure;
    // The official client warns when this fixture deliberately sends a late
    // response after cancellation. Allow only that warning for a request whose
    // cancellation crossed this transport; sanitizer and other output still fail.
    const unexpected = stderr.split('\n').filter(line => {
      if (!line) return false;
      const late = /^\S+ warning libfx\.conformance\.mcp: id=([A-Za-z0-9-]+) \[MCP\] Attempted to handle response for already removed request$/.exec(line);
      return !late || !cancelledRequests.has(late[1]);
    });
    if (code !== 0 || signal || unexpected.length) throw new Error(`MCP driver exited: ${code ?? signal}${stderr ? `\n${stderr}` : ''}`);
  }
  lines.on('line', line => {
    const value = JSON.parse(line);
    if (value.mcpObservation) {
      const { token, event } = value.mcpObservation;
      observations.get(token)?.notify(event);
      return;
    }
    if (value.mcpObservationError) {
      const { token, error } = value.mcpObservationError;
      observations.get(token)?.reportError(new Error(error));
      return;
    }
    if (value.mcpSend) {
      const message = value.mcpSend;
      if (message.method === 'notifications/cancelled') {
        cancelledRequests.add(String(message.params.requestId));
        remoteCalls.get(message.params.requestId)?.abort();
        return;
      }
      if (message.id === undefined) return;
      const controller = new AbortController();
      remoteCalls.set(message.id, controller);
      Promise.resolve().then(() => {
        switch (message.method) {
          case 'initialize':
            if (typeof client.initialize === 'function') return client.initialize();
            // Some upstream fixtures model an already-initialized client. Supply
            // only its protocol envelope; tool behavior still belongs to Swift.
            return { protocolVersion: message.params.protocolVersion, capabilities: { tools: {} },
              serverInfo: { name: options.serverName ?? 'fixture-client', version: 'fixture' } };
          case 'tools/list': return Promise.resolve(client.listTools(message.params)).then(result =>
            Array.isArray(result) ? { tools: result } : result);
          case 'tools/call': return client.callTool(message.params, undefined, { signal: controller.signal });
          case 'resources/read': return Promise.resolve(client.readResource(message.params)).then(result => ({
            ...result,
            // The lightweight JS client fixture can omit the URI that the
            // protocol requires. Preserve its content and requested identity.
            contents: result.contents.map(content => content.uri === undefined
              ? { ...content, uri: message.params.uri } : content),
          }));
          case 'prompts/get': return Promise.resolve(client.getPrompt(message.params)).then(result => ({
            ...result,
            // The stdio fixture returns a content array. MCP uses one content
            // block per prompt message; preserve every block and role.
            messages: result.messages.flatMap(entry => Array.isArray(entry.content)
              ? entry.content.map(content => ({ ...entry, content })) : [entry]),
          }));
          default: throw new Error(`Unsupported MCP fixture request: ${message.method}`);
        }
      }).then(result => request('mcpReceive', { message: { jsonrpc: '2.0', id: message.id, result } }),
        error => request('mcpReceive', { message: { jsonrpc: '2.0', id: message.id, error: { code: -32603, message: String(error) } } }))
        .catch(() => {}).finally(() => remoteCalls.delete(message.id));
      return;
    }
    const waiter = pending.get(value.id);
    pending.delete(value.id);
    if (value.error) waiter?.reject(new (value.error.category === 'range' ? RangeError : Error)(value.error.message));
    else waiter?.resolve(value.result);
  });
  try {
    const opened = await request('mcpOpen', { options });
    return {
      instructions: opened.instructions,
      tools: opened.tools.map(tool => ({ ...tool, async execute(input, context = {}) {
        const token = randomUUID();
        if (context.signal?.aborted) throw context.signal.reason;
        const observation = context.observation?.[swiftObservationScope];
        if (observation) observations.set(token, observation);
        const stopObserving = observation?.onInvalidate(() => { void request('mcpInvalidate', { token }).catch(() => {}); });
        const cancel = () => { void request('mcpCancel', { token }).catch(() => {}); };
        context.signal?.addEventListener('abort', cancel, { once: true });
        try { return await request('mcpExecute', { token, name: tool.name, input,
          executionId: context.executionId, sessionId: context.sessionId, turnId: context.turnId, context: context.context,
          ...(observation ? { observation: { ...observation.metadata, active: observation.active } } : {}) }); }
        finally { context.signal?.removeEventListener('abort', cancel); stopObserving?.(); observations.delete(token); }
      } })),
      close() {
        return closePromise ??= (async () => {
          try { await request('mcpClose'); }
          finally { try { await client.close?.(); } finally { await finish(); } }
        })();
      },
    };
  } catch (error) {
    try { await request('mcpClose').catch(() => {}); }
    finally { try { await client.close?.(); } finally { await finish(); } }
    throw error;
  }
}
