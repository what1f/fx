import { spawn, execFileSync } from 'node:child_process';
import { createInterface } from 'node:readline';
import { fileURLToPath } from 'node:url';
import { join } from 'node:path';

const provider = new URL(import.meta.url).searchParams.get('provider') ?? 'grok';
const defaultDriver = process.env.LIBFX_SWIFT_DRIVER || join(execFileSync('swift', [
  'build', '--package-path', fileURLToPath(new URL('../..', import.meta.url)), '--show-bin-path',
], { encoding: 'utf8' }).trim(), 'FxSwiftDriver');
const driver = () => process.env.LIBFX_SWIFT_DRIVER || defaultDriver;
function nativeError(value) {
  return Object.assign(new (value.category === 'type' ? TypeError : Error)(value.message),
    Object.fromEntries(['code', 'status', 'reason'].filter(key => value[key] !== undefined).map(key => [key, value[key]])));
}

async function call(action, args = {}, { fetch: hostFetch = globalThis.fetch, signal } = {}) {
  signal?.throwIfAborted();
  const child = spawn(driver(), [], { stdio: ['pipe', 'pipe', 'pipe'] });
  const lines = createInterface({ input: child.stdout });
  let sequence = 0, stderr = '', spawnFailure;
  const pending = new Map(), fetches = new Map(), tasks = new Set();
  const exited = new Promise(resolve => child.on('close', (code, signal) => resolve({ code, signal })));
  const fail = error => { for (const waiter of pending.values()) waiter.reject(error); pending.clear(); };
  child.on('error', error => { spawnFailure = error; fail(error); });
  child.stdin.on('error', fail);
  child.stderr.on('data', chunk => { stderr += chunk; });
  child.on('close', (code, signal) => fail(new Error(`Sign-in driver exited: ${code ?? signal}${stderr ? '\n' + stderr : ''}`)));
  function request(op, fields = {}) {
    if (child.stdin.destroyed || child.stdin.writableEnded) return Promise.reject(new Error('Sign-in driver input is closed'));
    const id = ++sequence;
    return new Promise((resolve, reject) => {
      pending.set(id, { resolve, reject });
      child.stdin.write(JSON.stringify({ id, op, ...fields }) + '\n', error => {
        if (error) { pending.delete(id); reject(error); }
      });
    });
  }
  lines.on('line', line => {
    const value = JSON.parse(line);
    if (value.fetchRequest) {
      const wire = value.fetchRequest, controller = new AbortController();
      fetches.set(wire.id, controller);
      const task = (async () => {
        let reader;
        const cancel = () => { void reader?.cancel().catch(() => {}); };
        controller.signal.addEventListener('abort', cancel, { once: true });
        try {
          const response = await hostFetch(wire.url, { method: wire.method, headers: wire.headers,
            ...(wire.method === 'GET' ? {} : { body: Buffer.from(wire.body, 'base64').toString() }), signal: controller.signal });
          controller.signal.throwIfAborted();
          await request('fetchStart', { fetchID: wire.id, status: response.status, headers: Object.fromEntries(response.headers) });
          if (controller.signal.aborted) { await response.body?.cancel(); return; }
          reader = response.body?.getReader();
          while (reader && !controller.signal.aborted) {
            const next = await reader.read();
            if (next.done || controller.signal.aborted) break;
            await request('fetchChunk', { fetchID: wire.id, data: Buffer.from(next.value).toString('base64') });
          }
          if (!controller.signal.aborted) await request('fetchEnd', { fetchID: wire.id });
        } catch (error) {
          if (!controller.signal.aborted) await request('fetchFailure', { fetchID: wire.id, error: error.message }).catch(() => {});
        } finally {
          controller.signal.removeEventListener('abort', cancel);
          fetches.delete(wire.id);
        }
      })();
      tasks.add(task); void task.finally(() => tasks.delete(task));
    } else if (value.fetchCancelled !== undefined) fetches.get(value.fetchCancelled)?.abort();
    else if (value.id !== undefined) {
      const waiter = pending.get(value.id); pending.delete(value.id);
      if (value.error) waiter?.reject(nativeError(value.error)); else waiter?.resolve(value.result);
    }
  });
  const abort = () => { void request('signInCancel').catch(() => {}); };
  signal?.addEventListener('abort', abort, { once: true });
  let result, failure;
  try {
    const operation = request('signIn', { provider, action, args });
    if (signal?.aborted) abort();
    result = await operation;
  } catch (error) { failure = signal?.aborted ? signal.reason : error; }
  finally {
    signal?.removeEventListener('abort', abort);
    try { await request('close'); } catch (error) { failure ??= error; }
    for (const controller of fetches.values()) controller.abort();
    await Promise.allSettled(tasks);
    child.stdin.end();
    const { code, signal: exitSignal } = await exited;
    lines.close();
    if (spawnFailure) failure = spawnFailure;
    else if (code !== 0 || exitSignal || stderr) failure = new Error(`Sign-in driver exited: ${code ?? exitSignal}${stderr ? '\n' + stderr : ''}`);
  }
  if (failure) throw failure;
  return result;
}

export const startSignIn = () => call('start');
export const finishSignIn = (authorization, address, options) => call('finish', { authorization, address }, options);
export const startDeviceSignIn = options => call('startDevice', {}, options);
export const pollDeviceSignIn = (device, options) => call('pollDevice', { device }, options);
export const completeDeviceSignIn = (device, options) => call('completeDevice', { device }, options);
export const refreshCredentials = (credentials, options) => call('refresh', { credentials }, options);

export function normalizeGrokCredentials(credentials) {
  const value = JSON.parse(execFileSync(driver(), ['check-prompt'], { encoding: 'utf8',
    input: JSON.stringify({ id: 1, op: 'signIn', provider: 'grok', action: 'normalize', args: { credentials } }),
  }));
  if (value.error) throw nativeError(value.error);
  return value.result;
}
