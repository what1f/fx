import { spawn, execFileSync } from 'node:child_process';
import { createInterface } from 'node:readline';
import { fileURLToPath } from 'node:url';
import { join } from 'node:path';
import { randomUUID } from 'node:crypto';
import { memory, local } from './adapter.mjs';
export { memory, local };
// These upstream pure helpers are fixture utilities, not Swift coverage.
export { extendLogView, foldSessionLog, handoffEntries, wakeHandler } from '../../../sdk/durable.js';

const driver = process.env.LIBFX_SWIFT_DRIVER || join(execFileSync('swift', [
  'build', '--package-path', fileURLToPath(new URL('../..', import.meta.url)), '--show-bin-path',
], { encoding: 'utf8' }).trim(), 'FxSwiftDriver');

function deferred() {
  const value = Promise.withResolvers();
  value.promise.catch(() => {});
  return value;
}

// Connections share transport only. Native agents own session routing and scheduling.
const connections = new Set();
function connect(path, name, client) {
  const executable = process.env.LIBFX_SWIFT_DRIVER || driver;
  let connection = [...connections].find(value => value.path === path && value.executable === executable
    && !value.names.has(name) && !value.ending);
  if (!connection) {
    const child = spawn(executable, [], { stdio: ['pipe', 'pipe', 'pipe'] });
    const lines = createInterface({ input: child.stdout });
    const pending = new Map(), clients = new Map(), names = new Set();
    let serial = 0, stderr = '', failure, spawnError;
    function failPending(error) {
      failure ??= error;
      for (const waiter of pending.values()) waiter.reject(error);
      pending.clear();
      for (const client of clients.values()) client.fail(error);
    }
    child.stderr.setEncoding('utf8');
    child.stderr.on('data', value => { stderr += value; });
    const exited = new Promise(resolve => child.once('close', (code, signal) => {
      connections.delete(connection);
      failPending(new Error(`Generic Swift driver exited: ${code ?? signal}${stderr ? `\n${stderr}` : ''}`));
      resolve({ code, signal });
    }));
    child.on('error', error => { spawnError = error; failPending(error); });
    child.stdin.on('error', failPending);
    function request(op, args = {}) {
      if (failure) return Promise.reject(failure);
      const id = ++serial, waiter = deferred();
      pending.set(id, waiter);
      child.stdin.write(JSON.stringify({ id, op, ...args }) + '\n', error => {
        if (error) { pending.delete(id); waiter.reject(error); }
      });
      return waiter.promise;
    }
    lines.on('line', line => {
      const message = JSON.parse(line);
      if (message.genericCallback) {
        const call = message.genericCallback;
        const target = clients.get(call.agentToken);
        void Promise.resolve().then(() => {
          if (!target) throw new Error(`Unknown generic harness agent: ${call.agentToken}`);
          return target.callback(call);
        }).then(value => request('genericCallbackResult', { agentToken: call.agentToken, token: call.token, value }),
          error => request('genericCallbackResult', { agentToken: call.agentToken, token: call.token,
            error: { message: error?.message ?? String(error), name: error?.name ?? 'Error', code: error?.code } })).catch(failPending);
      } else if ('id' in message) {
        const waiter = pending.get(message.id);
        pending.delete(message.id);
        if (message.error) waiter?.reject(Object.assign(new Error(message.error.message), message.error.data));
        else waiter?.resolve(message.result);
      } else if (message.genericDiagnostic) {
        const token = message.agentToken ?? message.genericDiagnostic.agentToken;
        clients.get(token)?.diagnostic(message.genericDiagnostic);
      } else if (message.genericFatal) {
        const error = new Error(typeof message.genericFatal === 'string' ? message.genericFatal : message.genericFatal.message);
        failPending(error);
        throw error;
      } else {
        const token = message.genericAccepted?.token ?? message.turnToken;
        for (const client of clients.values()) {
          if (client.message(token, message)) break;
        }
      }
    });
    connection = { path, executable, names, clients, request, ending: false,
      async release(agentToken) {
        const client = clients.get(agentToken);
        clients.delete(agentToken);
        if (client) names.delete(client.name);
        if (clients.size) return;
        connection.ending = true;
        connections.delete(connection);
        child.stdin.end();
        const { code, signal } = await exited;
        lines.close();
        if (spawnError) throw spawnError;
        if (code !== 0 || signal || stderr) throw new Error(`Generic Swift driver exited: ${code ?? signal}${stderr ? `\n${stderr}` : ''}`);
      },
    };
    connections.add(connection);
  }
  connection.names.add(name);
  connection.clients.set(client.agentToken, client);
  return connection;
}

export function createDurableAgentFactory({ harness, defaultDurability, name = 'createAgent' }) {
  return (options = {}) => {
    const plugged = harness(options), agentToken = randomUUID();
    const sessions = new Map(), turns = new Map(), views = new Map();
    const intakes = new Set();
    let connection, closed = false;
    const request = (op, args = {}) => connection.request(op, { ...args, agentToken });
    async function callback(call) {
      const entry = sessions.get(call.handle);
      switch (call.method) {
        case 'open': {
          const state = { session: null, head: undefined, current: null, completed: null };
          sessions.set(call.handle, state);
          const store = {
            async load() {
              const snapshot = await request('genericPersistence', { handle: call.handle, method: 'load' });
              state.head = snapshot.head ?? undefined;
              return { head: state.head, checkpoint: snapshot.checkpoint && {
                ...snapshot.checkpoint, data: new Uint8Array(Buffer.from(snapshot.checkpoint.data, 'base64')),
              }, journal: snapshot.journal.map(record => ({ ...record, data: new Uint8Array(Buffer.from(record.data, 'base64')) })) };
            },
            async append({ idempotencyKey, data, marks = [], barrier = true }) {
              const cursor = await request('genericPersistence', { handle: call.handle, method: 'append',
                expected: state.head, key: idempotencyKey, data: Buffer.from(data).toString('base64'), marks, barrier });
              state.head = cursor;
              for (const mark of marks) {
                if (mark.start !== undefined) state.current = mark.start;
                if (mark.end) { state.completed = state.current; state.current = null; }
              }
              return cursor;
            },
            async saveCheckpoint({ through, data }) {
              return request('genericPersistence', { handle: call.handle, method: 'checkpoint', through,
                data: Buffer.from(data).toString('base64') });
            },
          };
          state.session = await plugged.open({ sessionId: call.sessionId, store, context: call.options?.context ?? null,
            model: call.options?.model, instructions: call.options?.instructions, settings: call.options?.settings });
          state.current = state.session.openTurn?.id ?? null;
          return null;
        }
        case 'state': {
          const openTurn = entry.session.openTurn ?? null;
          return { openTurn, completedTurnId: openTurn ? null : entry.completed };
        }
        case 'prompt': {
          const turn = await entry.session.prompt(call.input, { turnId: call.turnId, yieldAt: call.yieldAt ?? undefined });
          return registerTurn(turn);
        }
        case 'resume': {
          const turn = await entry.session.resume({ yieldAt: call.yieldAt ?? undefined, rerunning: call.rerunning });
          return turn == null ? null : registerTurn(turn);
        }
        case 'saveCheckpoint': await entry.session.saveCheckpoint(); return null;
        case 'checkpoint': return Buffer.from(await entry.session.exportCheckpoint()).toString('base64');
        case 'close': await entry.session.close(); return null;
        case 'turnNext': return turns.get(call.handle).iterator.next();
        case 'turnResult': return turns.get(call.handle).turn.result;
        case 'turnCancel': await turns.get(call.handle).turn.cancel(); return null;
        case 'turnHandoff': await turns.get(call.handle).turn.cancel({ reason: 'handoff' }); return null;
        default: throw new Error(`Unknown generic harness callback: ${call.method}`);
      }
    }
    function registerTurn(turn) {
      const id = randomUUID();
      turns.set(id, { turn, iterator: turn[Symbol.asyncIterator]() });
      return { turn: id };
    }
    const ready = Promise.resolve(options.durability ?? defaultDurability()).then(durability => {
      if (typeof durability.__swiftSessionPath !== 'string') throw new TypeError(`${name} needs a Swift fixture store`);
      connection = connect(durability.__swiftSessionPath, options.name ?? 'default', {
        agentToken, name: options.name ?? 'default', callback,
        diagnostic: event => options.onEvent?.(event),
        fail(error) { for (const view of views.values()) view.fail(error); },
        message(token, message) {
          const view = views.get(token);
          if (!view) return false;
          if (message.genericAccepted) {
            const { id, sessionId, isRepeated } = message.genericAccepted;
            view.accepted.resolve({ id, messageId: id, sessionId, isRepeated });
          } else if (message.genericEvent) view.push(message.genericEvent);
          else if (message.genericCompleted) view.finish(message.genericCompleted);
          else if (message.genericFailed) view.fail(new Error(message.genericFailed.message));
          return true;
        },
      });
      return request('genericOpen', { options: { name: options.name ?? 'default', sessionStorePath: durability.__swiftSessionPath,
        maximumDurationMs: durability.__swiftMaximumDurationMs, reserveMs: durability.__swiftReserveMs } });
    });
    ready.catch(() => {});

    function view(sessionId, sessionOptions, input, promptOptions = {}, operation = 'genericPrompt') {
      const id = promptOptions.messageId ?? `msg_${randomUUID()}`, token = randomUUID();
      const accepted = deferred(), outcome = deferred(), queue = [], readers = [];
      let done = false, failure;
      const state = {
        accepted,
        push(value) { const waiter = readers.shift(); if (waiter) waiter.resolve({ value, done: false }); else queue.push(value); },
        finish(value) {
          done = true;
          outcome.resolve({ ...value, messageId: value.id, ...(value.isRepeated ? { repeated: true } : {}) });
          for (const reader of readers.splice(0)) reader.resolve({ done: true });
          promptOptions.signal?.removeEventListener('abort', abort);
        },
        fail(error) {
          failure = error; done = true; accepted.reject(error); outcome.reject(error);
          for (const reader of readers.splice(0)) reader.reject(error);
        },
      };
      views.set(token, state);
      const started = ready.then(() => request(operation, {
        sessionId, input, messageId: id, options: sessionOptions, turnToken: token,
      })).catch(error => state.fail(error)).finally(() => intakes.delete(started));
      intakes.add(started);
      const cancel = () => accepted.promise.then(() => request('genericTurnCancel', { turnToken: token }));
      const abort = () => { void cancel().catch(error => state.fail(error)); };
      if (promptOptions.signal?.aborted) abort(); else promptOptions.signal?.addEventListener('abort', abort, { once: true });
      return { id, accepted: accepted.promise, result: outcome.promise, cancel,
        [Symbol.asyncIterator]() { return {
          next() {
            if (queue.length) return Promise.resolve({ value: queue.shift(), done: false });
            if (failure) return Promise.reject(failure);
            if (done) return Promise.resolve({ done: true });
            const reader = deferred(); readers.push(reader); return reader.promise;
          },
          return: async () => ({ done: true }),
        }; },
      };
    }
    let defaultSession;
    const agent = {
      name: options.name ?? 'default',
      session(sessionId = randomUUID(), sessionOptions = {}) {
        const settings = plugged.settings?.(sessionOptions);
        sessionOptions = { ...sessionOptions, ...(plugged.settings ? { settings } : {}),
          ...(typeof sessionOptions.model === 'string' ? { model: { id: sessionOptions.model } } : {}) };
        return { id: sessionId,
          prompt: (input, promptOptions) => view(sessionId, sessionOptions, input, promptOptions),
          steer: (input, promptOptions) => view(sessionId, sessionOptions, input, promptOptions, 'genericSteer').accepted,
          resume: () => view(sessionId, sessionOptions, null, {}, 'genericResume'),
          checkpoint: async () => new Uint8Array(Buffer.from(await ready.then(() => request('genericCheckpoint', { sessionId, options: sessionOptions })), 'base64')),
          cancel: async () => ready.then(() => request('genericCancel', { sessionId })),
          stream(cursor = 0) {
            const readToken = randomUUID();
            let cancelled = false;
            return new ReadableStream({
              async pull(controller) {
                await ready;
                const event = await request('genericNextEvent', { sessionId, cursor, readToken });
                if (cancelled) return;
                if (event == null) { controller.close(); return; }
                cursor = event.cursor;
                controller.enqueue(new TextEncoder().encode(JSON.stringify(event) + '\n'));
              },
              async cancel() { cancelled = true; await ready; await request('genericReadCancel', { readToken }); },
            });
          },
        };
      },
      prompt(input, promptOptions) { defaultSession ??= agent.session(); return defaultSession.prompt(input, promptOptions); },
      async close() {
        if (closed) return;
        closed = true;
        try {
          await ready;
          await Promise.allSettled([...intakes]);
          await request('genericClose');
        } finally {
          if (connection) await connection.release(agentToken);
        }
      },
    };
    return agent;
  };
}
