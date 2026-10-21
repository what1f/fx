import { spawn, execFileSync } from 'node:child_process';
import { createInterface } from 'node:readline';
import { fileURLToPath } from 'node:url';
import { join } from 'node:path';
import { randomUUID } from 'node:crypto';

const defaultDriver = process.env.LIBFX_SWIFT_DRIVER || join(execFileSync('swift', [
  'build', '--package-path', fileURLToPath(new URL('../..', import.meta.url)), '--show-bin-path',
], { encoding: 'utf8' }).trim(), 'FxSwiftDriver');

export async function createFxEngine(options = {}) {
  const child = spawn(process.env.LIBFX_SWIFT_DRIVER || defaultDriver, [], { stdio: ['pipe', 'pipe', 'pipe'] });
  const lines = createInterface({ input: child.stdout });
  const pending = new Map();
  const tools = new Map((options.tools || []).map(tool => [tool.name, tool]));
  const toolControllers = new Map();
  const turnStates = new Map(), followUps = new Map();
  const fetchControllers = new Map();
  const fetchReaders = new Map();
  let nextID = 1, turn = null, closed = false, stderr = '';
  let resumable = false, recoveryCalls = [], recoveryTurnID = null;

  child.stderr.on('data', data => { stderr += data; });
  child.stdin.on('error', error => {
    for (const waiter of pending.values()) waiter.reject(error);
    pending.clear();
    for (const state of turnStates.values()) state.fail(error);
    for (const queued of followUps.values()) { queued.rejectAccepted(error); queued.rejectTurn(error); }
  });
  function request(op, args = {}) {
    if (child.stdin.writableEnded || child.stdin.destroyed) return Promise.reject(new Error('Swift driver input is closed'));
    const id = nextID++;
    return new Promise((resolve, reject) => {
      pending.set(id, { resolve, reject });
      child.stdin.write(JSON.stringify({ id, op, ...args }) + '\n', error => {
        if (error) { pending.delete(id); reject(error); }
      });
    });
  }
  const exited = new Promise(resolve => child.once('exit', (code, signal) => {
    const error = new Error(`Swift driver exited: ${code ?? signal}${stderr ? `\n${stderr}` : ''}`);
    for (const waiter of pending.values()) waiter.reject(error);
    pending.clear();
    for (const state of turnStates.values()) state.fail(error);
    for (const queued of followUps.values()) { queued.rejectAccepted(error); queued.rejectTurn(error); }
    resolve({ code, signal });
  }));
  child.on('error', error => {
    for (const waiter of pending.values()) waiter.reject(error);
    pending.clear();
  });
  lines.on('line', line => {
    const value = JSON.parse(line);
    if (value.credentialRequest) {
      const call = value.credentialRequest;
      Promise.resolve().then(() => options.credentials({ provider: call.provider, sessionId: call.sessionId }))
        .then(value => request('credentialResult', { token: call.token, key: value?.apiKey }),
          () => request('credentialResult', { token: call.token })).catch(() => {});
    } else if (value.observation) {
      try { Promise.resolve(options.hooks?.onEvent(value.observation)).catch(error => {
        try { Promise.resolve(options.hooks?.onError?.(error)).catch(() => {}); } catch {}
      }); } catch (error) {
        try { Promise.resolve(options.hooks?.onError?.(error)).catch(() => {}); } catch {}
      }
    } else if (value.observationError) {
      try { Promise.resolve(options.hooks?.onError?.(new Error(value.observationError))).catch(() => {}); } catch {}
    } else if (value.diagnostic) { options.onEvent?.(value.diagnostic); }
    else if ('id' in value) {
      const waiter = pending.get(value.id);
      pending.delete(value.id);
      if (value.error) {
        const ErrorType = value.error.category === 'type' ? TypeError : value.error.category === 'range' ? RangeError : Error;
        const error = new ErrorType(value.error.message);
        if (value.error.data) Object.assign(error, value.error.data);
        waiter?.reject(error);
      } else waiter?.resolve(value.result);
    } else if (value.turnStarted) {
      const state = turnStates.get(value.turnStarted);
      if (state) {
        turn = state;
        state.public.id = value.turnID;
        const queued = followUps.get(value.turnStarted);
        if (queued) {
          queued.resolveTurn(state.public); queued.started = true;
          if (queued.accepted) followUps.delete(value.turnStarted);
        }
      }
    } else if (value.followUpAccepted) {
      const queued = followUps.get(value.followUpAccepted);
      if (queued) {
        queued.id = value.inputID; queued.resolveAccepted({ id: value.inputID }); queued.accepted = true;
        const state = turnStates.get(value.followUpAccepted);
        if (state) state.public.id = value.inputID;
        if (queued.started) followUps.delete(value.followUpAccepted);
      }
    } else if (value.followUpRejected) {
      followUps.get(value.followUpRejected)?.rejectAccepted(new Error(value.error));
    } else if (value.event) turnStates.get(value.turnToken)?.push(value.event);
    else if (value.completed) {
      resumable = value.recovery?.resumable ?? false;
      recoveryCalls = value.recovery?.runningCalls ?? [];
      recoveryTurnID = value.recovery?.openTurnId ?? null;
      const state = turnStates.get(value.turnToken);
      state?.cleanup?.(); state?.finish(value.completed);
      if (turn === state) turn = null;
      turnStates.delete(value.turnToken);
    } else if (value.failed) {
      const state = turnStates.get(value.turnToken);
      const error = new Error(value.failed);
      state?.cleanup?.(); state?.fail(error);
      const queued = followUps.get(value.turnToken);
      queued?.rejectTurn(error); queued?.rejectAccepted(error);
      followUps.delete(value.turnToken);
      if (turn === state) turn = null;
      turnStates.delete(value.turnToken);
    }
    else if (value.fetchCancelled) {
      fetchControllers.get(value.fetchCancelled)?.abort();
      void fetchReaders.get(value.fetchCancelled)?.cancel().catch(() => {});
      fetchControllers.delete(value.fetchCancelled);
    } else if (value.persistenceRequest) {
      const call = value.persistenceRequest;
      void (async () => {
        try {
          let result;
          if (call.kind === 'load') {
            const loaded = await options.persistence.load(), journal = [];
            for await (const record of loaded.journal ?? []) journal.push({ cursor: record.cursor, data: Buffer.from(record.data).toString('base64') });
            result = { journal, head: loaded.head,
              ...(loaded.checkpoint ? { checkpoint: { through: loaded.checkpoint.through, data: Buffer.from(loaded.checkpoint.data).toString('base64') } } : {}),
            };
          } else if (call.kind === 'saveCheckpoint') {
            await options.persistence.saveCheckpoint({ through: call.through, data: new Uint8Array(Buffer.from(call.data, 'base64')) });
            result = null;
          } else {
            const { id, kind, ...input } = call;
            result = await options.persistence.append({ ...input, data: new Uint8Array(Buffer.from(input.data, 'base64')) });
          }
          await request('persistenceResult', { persistenceID: call.id, value: result });
        } catch (error) {
          await request('persistenceResult', { persistenceID: call.id, error: String(error), code: error.code }).catch(() => {});
        }
      })();
    } else if (value.fetchRequest) {
      const call = value.fetchRequest, controller = new AbortController();
      fetchControllers.set(call.id, controller);
      void (async () => {
        try {
          const response = await (options.fetch || globalThis.fetch)(call.url, {
            method: call.method, headers: new Headers(call.headers),
            ...(call.body ? { body: new Uint8Array(Buffer.from(call.body, 'base64')) } : {}),
            signal: controller.signal,
          });
          const reader = response.body?.getReader();
          if (reader) fetchReaders.set(call.id, reader);
          try {
            await request('fetchStart', { fetchID: call.id, status: response.status, headers: Object.fromEntries(response.headers) });
            if (reader) {
              for (;;) {
                const { value: chunk, done } = await reader.read();
                if (done) break;
                await request('fetchChunk', { fetchID: call.id, data: Buffer.from(chunk).toString('base64') });
              }
            }
            await request('fetchEnd', { fetchID: call.id });
          } finally { fetchReaders.delete(call.id); reader?.releaseLock(); }
        } catch (error) {
          await request('fetchFailure', { fetchID: call.id, error: String(error) }).catch(() => {});
        } finally { fetchControllers.delete(call.id); }
      })();
    } else if (value.toolCancelled) {
      toolControllers.get(value.toolCancelled)?.abort();
      toolControllers.delete(value.toolCancelled);
    } else if (value.toolRequest) {
      const call = value.toolRequest, controller = new AbortController();
      toolControllers.set(call.id, controller);
      const owner = [...turnStates.values()].find(state => state.public.id === call.turnId);
      if (owner?.signal?.aborted) return;
      Promise.resolve().then(() => tools.get(call.name).execute(call.input, {
        signal: controller.signal, executionId: call.executionId, sessionId: call.sessionId,
      })).then(result => controller.signal.aborted ? undefined : request('toolResult', { toolID: call.id,
        ...(result?.type === 'libfx.tool-result' ? { rich: result } : {
          content: typeof result === 'string' ? result : JSON.stringify(result) ?? 'null',
        }),
      }), error => controller.signal.aborted ? undefined : request('toolResult', { toolID: call.id, error: String(error) }))
        .catch(() => {}).finally(() => toolControllers.delete(call.id));
    }
  });
  const { fetch, nativeAddon, backend, onEvent, tools: _tools, checkpoint, persistence, ...configuration } = options;
  try {
    if (options.__listModels) {
      try { return await request('listModels', { apiKey: options.apiKey }); }
      finally { child.stdin.end(); await exited; lines.close(); }
    }
    const opened = await request('open', { options: {
      ...configuration,
      hasCredentials: typeof options.credentials === 'function',
      hasPersistence: Boolean(persistence),
      hasCheckpointPersistence: typeof persistence?.saveCheckpoint === 'function',
      ...(checkpoint ? { checkpoint: Buffer.from(checkpoint).toString('base64') } : {}),
      tools: (options.tools || []).map(({ execute, ...descriptor }) => descriptor),
    } });
    resumable = opened.resumable;
    recoveryCalls = opened.runningCalls;
    recoveryTurnID = opened.openTurnId;
    function begin(op, args, promptOptions = {}) {
      if (turn) throw new Error('a prompt is already running');
      const turnToken = randomUUID();
      const control = (op, args = {}) => request(op, { ...args, turnToken });
      let ready;
      const state = createTurn(args => ready.then(() => control('cancel', args)), (input, inputID) => ready.then(() => control('steer', {
        text: Array.isArray(input) ? input.map(block => block.text).join('\n') : input, inputID,
      })), inputID => ready.then(() => control('withdraw', { inputID })));
      turnStates.set(turnToken, state);
      state.signal = promptOptions.signal;
      turn = state;
      const publicID = op === 'prompt' ? promptOptions.turnId === undefined ? randomUUID() : promptOptions.turnId : recoveryTurnID;
      state.public.id = publicID;
      ready = (op === 'prompt' ? encodePrompt(args.text).then(text => ({ text })) : Promise.resolve(args))
        .then(args => control(op, {
          ...args, ...(op === 'prompt' || publicID != null ? { turnID: publicID } : {}),
          ...(promptOptions.yieldAt === undefined ? {} : { yieldAt: promptOptions.yieldAt }),
        })).then(reply => { if (reply?.turnID) state.public.id = reply.turnID; });
      const abort = () => { void ready.then(() => control('cancel')).catch(error => state.fail(error)); };
      promptOptions.signal?.addEventListener('abort', abort, { once: true });
      state.cleanup = () => promptOptions.signal?.removeEventListener('abort', abort);
      if (promptOptions.signal?.aborted) abort();
      ready.catch(error => { state.cleanup?.(); state.fail(error); turnStates.delete(turnToken); if (turn === state) turn = null; });
      return state.public;
    }
    return {
      sessionId: opened.sessionId,
      prompt(text, promptOptions = {}) {
        return begin('prompt', { text }, promptOptions);
      },
      resume(promptOptions = {}) {
        if (!resumable) return null;
        const rerun = recoveryCalls.filter(call => promptOptions.onAmbiguous?.(call) === 'rerun').map(call => call.executionId);
        return begin('resume', { rerun }, promptOptions);
      },
      followUp(input) {
        const token = randomUUID();
        const control = (op, args = {}) => request(op, { ...args, turnToken: token });
        const state = createTurn(args => control('cancel', args), (text, inputID) => control('steer', { text, inputID }),
          inputID => control('withdraw', { inputID }));
        turnStates.set(token, state);
        let resolveTurn, rejectTurn, resolveAccepted, rejectAccepted;
        const started = new Promise((resolve, reject) => { resolveTurn = resolve; rejectTurn = reject; });
        const accepted = new Promise((resolve, reject) => { resolveAccepted = resolve; rejectAccepted = reject; });
        const queued = { id: null, started: false, accepted: false, resolveTurn, rejectTurn, resolveAccepted, rejectAccepted };
        followUps.set(token, queued);
        Object.defineProperty(started, 'id', { get: () => queued.id });
        started.accepted = accepted;
        void started.catch(() => {});
        void accepted.catch(() => {});
        request('followUp', { text: Array.isArray(input) ? input.map(block => block.text).join('\n') : input, turnToken: token })
          .then(reply => { queued.id = reply.inputID; }, error => {
            state.fail(error); rejectTurn(error); rejectAccepted(error); turnStates.delete(token); followUps.delete(token);
          });
        return started;
      },
      async checkpoint() { return new Uint8Array(Buffer.from(await request('checkpoint'), 'base64')); },
      async saveCheckpoint() { await request('saveCheckpoint'); },
      async __killForTest() {
        closed = true;
        child.kill('SIGKILL');
        const status = await exited;
        lines.close();
        if (stderr) throw new Error(stderr);
        return status;
      },
      async close() {
        if (closed) return;
        closed = true;
        try { await request('close'); } finally { child.stdin.end(); await exited; lines.close(); }
        if (stderr) throw new Error(stderr);
      },
    };
  } catch (error) { child.kill(); await exited; throw error; }
}

async function encodePrompt(input) {
  if (!Array.isArray(input)) return input;
  return Promise.all(input.map(async block => {
    if (block.type !== 'image' || block.data === undefined || typeof block.data === 'string') return block;
    const data = block.data instanceof Blob ? new Uint8Array(await block.data.arrayBuffer()) :
      block.data instanceof ArrayBuffer ? new Uint8Array(block.data) :
      new Uint8Array(block.data.buffer, block.data.byteOffset, block.data.byteLength);
    return { ...block, mimeType: block.mimeType ?? block.data.type, data: Buffer.from(data).toString('base64') };
  }));
}

function createTurn(cancel, steer, withdraw) {
  const queue = [], waiters = [];
  let done = false, failure;
  let resolveResult, rejectResult;
  const result = new Promise((resolve, reject) => { resolveResult = resolve; rejectResult = reject; });
  result.catch(() => {});
  const state = {
    push(value) { if (!done) { const waiter = waiters.shift(); if (waiter) waiter.resolve({ value, done: false }); else queue.push(value); } },
    finish(value) { done = true; resolveResult(value); while (waiters.length) waiters.shift().resolve({ done: true }); },
    fail(error) { if (done) return; done = true; failure = error; rejectResult(error); while (waiters.length) waiters.shift().reject(error); },
    public: {
      result,
      cancel(options = {}) { return cancel(options).catch(error => state.fail(error)); },
      steer(input, id = randomUUID()) {
        const receipt = steer(input, id);
        receipt.id = id;
        return receipt;
      },
      withdraw,
      [Symbol.asyncIterator]() { return {
        next() {
          if (queue.length) return Promise.resolve({ value: queue.shift(), done: false });
          if (failure) return Promise.reject(failure);
          if (done) return Promise.resolve({ done: true });
          return new Promise((resolve, reject) => waiters.push({ resolve, reject }));
        },
        return() { void cancel(); return Promise.resolve({ done: true }); },
      }; },
    },
  };
  return state;
}

export function supportsJspi() { return false; }
export function listModels(options = {}) { return createFxEngine({ ...options, __listModels: true }); }
