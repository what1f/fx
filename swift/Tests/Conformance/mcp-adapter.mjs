import { spawn } from 'node:child_process';
import { createInterface } from 'node:readline';
import { randomUUID } from 'node:crypto';

// Forward the fixture client's transport operations. Catalog processing, naming,
// context composition, result conversion, and cancellation run in Swift.
export async function createMcpAdapter(client, options, driver) {
  const child = spawn(driver, [], { stdio: ['pipe', 'pipe', 'pipe'] });
  const lines = createInterface({ input: child.stdout });
  const pending = new Map(), remoteCalls = new Map();
  let nextID = 1, stderr = '', closePromise;
  child.stderr.on('data', data => { stderr += data; });
  const exited = new Promise(resolve => child.once('exit', resolve));
  function request(op, args = {}) {
    const id = nextID++;
    return new Promise((resolve, reject) => {
      pending.set(id, { resolve, reject });
      child.stdin.write(JSON.stringify({ id, op, ...args }) + '\n', error => {
        if (error) { pending.delete(id); reject(error); }
      });
    });
  }
  child.on('exit', code => {
    for (const waiter of pending.values()) waiter.reject(new Error(`MCP driver exited (${code}): ${stderr}`));
    pending.clear();
  });
  child.stdin.on('error', error => {
    for (const waiter of pending.values()) waiter.reject(error);
    pending.clear();
  });
  lines.on('line', line => {
    const value = JSON.parse(line);
    if (value.mcpSend) {
      const message = value.mcpSend;
      if (message.method === 'notifications/cancelled') {
        remoteCalls.get(message.params.requestId)?.abort();
        return;
      }
      if (message.id === undefined) return;
      const controller = new AbortController();
      remoteCalls.set(message.id, controller);
      Promise.resolve().then(() => {
        switch (message.method) {
          case 'initialize': return client.initialize();
          case 'tools/list': return client.listTools(message.params);
          case 'tools/call': return client.callTool(message.params, undefined, { signal: controller.signal });
          case 'resources/read': return client.readResource(message.params);
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
    if (value.error) waiter?.reject(new Error(value.error.message));
    else waiter?.resolve(value.result);
  });
  try {
    const opened = await request('mcpOpen', { options });
    return {
      instructions: opened.instructions,
      tools: opened.tools.map(tool => ({ ...tool, async execute(input, context = {}) {
        const token = randomUUID();
        if (context.signal?.aborted) throw context.signal.reason;
        const cancel = () => { void request('mcpCancel', { token }).catch(() => {}); };
        context.signal?.addEventListener('abort', cancel, { once: true });
        try { return await request('mcpExecute', { token, name: tool.name, input,
          executionId: context.executionId, sessionId: context.sessionId, turnId: context.turnId, context: context.context }); }
        finally { context.signal?.removeEventListener('abort', cancel); }
      } })),
      close() {
        return closePromise ??= (async () => {
          await request('mcpClose');
          await client.close?.();
          child.stdin.end();
          await exited;
        })();
      },
    };
  } catch (error) {
    await request('mcpClose').catch(() => {});
    await client.close?.();
    child.stdin.end();
    await exited;
    throw error;
  }
}
