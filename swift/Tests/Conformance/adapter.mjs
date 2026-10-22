import { spawn, spawnSync, execFileSync } from 'node:child_process';
import { createInterface } from 'node:readline';
import { fileURLToPath } from 'node:url';
import { join } from 'node:path';
import { randomUUID, createHash } from 'node:crypto';
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { createMcpAdapter as bridgeMcpAdapter } from './mcp-adapter.mjs';
import { swiftObservationScope } from './observation-scope.mjs';
// Host-owned byte storage and JavaScript error identities; engine behavior remains in Swift.
import { createMemoryPersistence, FxFencedError, FxJournalVersionError } from '../../../sdk/fx-sdk.js';
export { createMemoryPersistence, FxFencedError, FxJournalVersionError };

const defaultDriver = process.env.LIBFX_SWIFT_DRIVER || join(execFileSync('swift', [
  'build', '--package-path', fileURLToPath(new URL('../..', import.meta.url)), '--show-bin-path',
], { encoding: 'utf8' }).trim(), 'FxSwiftDriver');

export function createMcpAdapter(client, options = {}) { return bridgeMcpAdapter(client, options, process.env.LIBFX_SWIFT_DRIVER || defaultDriver); }

// A fixture scope still uses Swift's child-options and input-wait implementation.
export async function toolObservation(scope, callID, hooks, emit, signal) {
  const observer = await createFxEngine({ hooks: { ...hooks, onEvent: emit },
    __observationFixture: { scope, callID, signal } });
  return { ...observer, childHooks() { return { ...hooks, parent: observer.childHooks().parent }; } };
}

export function createSkillsAdapter(records) {
  const encoded = execFileSync(defaultDriver, ['skills'], {
    input: JSON.stringify(records), encoding: 'utf8', maxBuffer: 1024 * 1024,
  });
  const result = JSON.parse(encoded);
  if (result.error) throw new RangeError(result.error.message);
  return { ...result, tools: records.flatMap(record => record.tools ?? []) };
}

export async function loadSkillFile(path, options = {}) {
  const encoded = execFileSync(defaultDriver, ['skill-file'], {
    input: JSON.stringify({ path, resources: options.resources }), encoding: 'utf8', maxBuffer: 1024 * 1024,
  });
  return { ...JSON.parse(encoded), tools: options.tools ?? [] };
}

// Normalize JavaScript-only shapes at the test boundary. The Swift SDK has one
// typed model value; capability and effort-string validation stay in its core.
function swiftModel(options) {
  const object = options.model !== null && typeof options.model === 'object';
  if (object) {
    if (['effort', 'fast', 'ultrafast'].some(key => Object.hasOwn(options, key))) {
      throw new TypeError('model options cannot be mixed with top-level effort, fast, or ultrafast');
    }
    for (const key of Object.keys(options.model)) {
      if (!['id', 'effort', 'fast', 'ultrafast'].includes(key)) throw new TypeError(`unsupported model option: ${key}`);
    }
    if (typeof options.model.id !== 'string') throw new TypeError('model.id must be a string');
  } else if (options.model !== undefined && typeof options.model !== 'string') {
    throw new TypeError('model must be a string or object');
  }
  const model = object ? options.model : { id: options.model, effort: options.effort, fast: options.fast, ultrafast: options.ultrafast };
  if (model.effort !== undefined && typeof model.effort !== 'string') throw new TypeError('effort must be a string');
  for (const key of ['fast', 'ultrafast']) {
    if (model[key] !== undefined && typeof model[key] !== 'boolean') throw new TypeError(`${key} must be a boolean`);
  }
  return model;
}

function swiftTools(value) {
  let tools;
  if (value === undefined) tools = [];
  else if (Array.isArray(value)) tools = value;
  else if (value && typeof value === 'object') tools = Object.entries(value).map(([name, tool]) => {
    if (!tool || typeof tool !== 'object') throw new TypeError(`tool ${name} must be an object`);
    if (tool.name !== undefined && tool.name !== name) throw new TypeError(`tool ${name} has a different name: ${tool.name}`);
    return { ...tool, name };
  });
  else throw new TypeError('tools must be an array or an object');
  for (const tool of tools) {
    if (tool.writes !== undefined && typeof tool.writes !== 'boolean') throw new TypeError(`tool ${tool.name} writes must be a boolean`);
  }
  return tools;
}

export async function createFxEngine(options = {}) {
  options = { ...options, tools: swiftTools(options.tools) };
  if (options.resizeImage !== undefined && typeof options.resizeImage !== 'function') throw new TypeError('resizeImage must be a function');
  // These invalid callback shapes cannot be constructed by a typed Swift caller.
  if (options.hooks !== undefined) {
    const hooks = options.hooks;
    if (!hooks || typeof hooks !== 'object' || Array.isArray(hooks) || typeof hooks.onEvent !== 'function' ||
        hooks.captureContent !== undefined && typeof hooks.captureContent !== 'boolean' ||
        hooks.onError !== undefined && typeof hooks.onError !== 'function') throw new TypeError('Invalid hooks options');
  }
  // JavaScript shapes that Swift expresses with FxPersistence, Int and typed arguments.
  if (options.persistence !== undefined) {
    const store = options.persistence;
    if (!store || typeof store !== 'object' || typeof store.load !== 'function' || typeof store.append !== 'function' ||
        store.saveCheckpoint !== undefined && typeof store.saveCheckpoint !== 'function') {
      throw new TypeError('persistence must be an object with load(), append() and, optionally, saveCheckpoint()');
    }
    if (options.checkpoint !== undefined) throw new TypeError('persistence cannot be combined with checkpoint');
  }
  const nativeStore = typeof options.sqlitePath === 'string' || options.__agent === true && typeof options.sessionStorePath === 'string';
  if (!nativeStore && options.checkpointAfterBytes !== undefined) {
    if (options.persistence === undefined) throw new TypeError('checkpointAfterBytes needs persistence');
    if (!Number.isSafeInteger(options.checkpointAfterBytes) || options.checkpointAfterBytes < 0) {
      throw new RangeError('checkpointAfterBytes must be a non-negative integer');
    }
  }
  const child = spawn(process.env.LIBFX_SWIFT_DRIVER || defaultDriver, [], { stdio: ['pipe', 'pipe', 'pipe'] });
  const lines = createInterface({ input: child.stdout });
  const pending = new Map();
  const tools = new Map((options.tools || []).map(tool => [tool.name, tool]));
  const toolControllers = new Map();
  const toolOwners = new Map();
  const turnStates = new Map(), followUps = new Map(), acceptedSessions = new Map();
  const sessionIntakes = new Set();
  const fetchControllers = new Map();
  const fetchReaders = new Map();
  const inputEffects = new Map(), toolScopes = new Map();
  let fixtureRuntime;
  const fixtureMethods = new Map();
  let nextID = 1, turn = null, closed = false, stderr = '', runtimeStarted = false, runtimeExitDelivered = false;
  let resumable = false, recoveryCalls = [], recoveryTurnID = null;

  child.stderr.on('data', data => { stderr += data; });
  child.stdin.on('error', error => {
    for (const waiter of pending.values()) waiter.reject(error);
    pending.clear();
    for (const state of turnStates.values()) state.fail(error);
    for (const waiter of acceptedSessions.values()) waiter.reject(error);
    for (const queued of followUps.values()) { queued.rejectAccepted(error); queued.rejectTurn(error); }
  });
  function request(op, args = {}) {
    if (child.stdin.writableEnded || child.stdin.destroyed) return Promise.reject(new Error('Swift driver input is closed'));
    const id = nextID++;
    return new Promise((resolve, reject) => {
      pending.set(id, { resolve, reject, op });
      child.stdin.write(JSON.stringify({ id, op, ...args }) + '\n', error => {
        if (error) { pending.delete(id); reject(error); }
      });
    });
  }
  function deliverObservation(event) {
    for (const [id, relay] of toolScopes) {
      const scope = relay.metadata.scope;
      if (scope.sessionId === event.sessionId && (event.type === 'journal.error' && event.data?.fenced === true ||
          scope.executionId === event.executionId &&
          (event.type === 'turn.end' || event.type === 'tool.end' && scope.data.call.callId === event.data.call.callId))) {
        relay.invalidate(); toolScopes.delete(id);
      }
    }
    try { Promise.resolve(options.hooks?.onEvent(event)).catch(reportObservationError); }
    catch (error) { reportObservationError(error); }
  }
  function reportObservationError(error) {
    try { Promise.resolve(options.hooks?.onError?.(error)).catch(() => {}); } catch {}
  }
  function inputObservation(call) {
    const listeners = new Set();
    const relay = {
      metadata: call.observation, active: true, notify: deliverObservation, reportError: reportObservationError,
      invalidate() { if (relay.active) { relay.active = false; for (const notify of listeners) notify(); listeners.clear(); } },
      onInvalidate(notify) { if (relay.active) listeners.add(notify); else notify(); return () => listeners.delete(notify); },
    };
    toolScopes.set(call.id, relay);
    return {
      [swiftObservationScope]: relay,
      childHooks() { return { ...options.hooks, parent: call.observation.parent }; },
      async wait(descriptor, run) {
        if (typeof run !== 'function') throw new TypeError('wait needs an input request and an effect');
        const token = randomUUID(), completed = Promise.withResolvers();
        let settled = false, failed = false, original;
        inputEffects.set(token, async () => {
          call.onEffectStarted?.();
          try { original = await run(); }
          catch (error) { failed = true; original = error; }
          settled = true;
          completed.resolve();
          let resolution;
          if (!failed) {
            try { resolution = { outcome: original?.outcome, answers: original?.answers }; }
            catch (error) {
              try { Promise.resolve(options.hooks?.onError?.(error)).catch(() => {}); } catch {}
              resolution = {};
            }
          }
          await request('inputResult', { token, ...(failed ? { errorName: original?.name ?? 'Error' } : { resolution }) });
        });
        try {
          try { await request('observeInput', { toolID: call.id, token, request: descriptor }); }
          catch (error) { if (!settled || !failed) throw error; }
          await completed.promise;
          if (failed) throw original;
          return original;
        } finally { inputEffects.delete(token); }
      },
    };
  }
  function runtimeExit(code, signal) {
    if (!runtimeStarted || runtimeExitDelivered) return;
    runtimeExitDelivered = true;
    try { options.onEvent?.({ type: 'runtime.exit', code, signal }); } catch {}
  }
  const exited = new Promise(resolve => child.once('close', (code, signal) => {
    for (const relay of toolScopes.values()) relay.invalidate();
    toolScopes.clear();
    runtimeExit(code, signal);
    const error = new Error(`Swift driver exited: ${code ?? signal}${stderr ? `\n${stderr}` : ''}`);
    for (const waiter of pending.values()) waiter.reject(error);
    pending.clear();
    for (const state of turnStates.values()) state.fail(error);
    for (const waiter of acceptedSessions.values()) waiter.reject(error);
    for (const queued of followUps.values()) { queued.rejectAccepted(error); queued.rejectTurn(error); }
    resolve({ code, signal });
  }));
  async function finish() {
    child.stdin.end();
    const status = await exited;
    lines.close();
    if (status.code !== 0 || stderr) throw new Error(`Swift driver exited: ${status.code ?? status.signal}${stderr ? `\n${stderr}` : ''}`);
  }
  function reapClosedDriver() {
    // Swift has acknowledged that its SDK resources are closed. Keep the
    // child pipes alive until exit and fail the test on any late diagnostics.
    // Sanitizer process teardown is separate from the SDK close operation.
    void finish().catch(error => queueMicrotask(() => { throw error; }));
  }
  child.on('error', error => {
    for (const waiter of pending.values()) waiter.reject(error);
    pending.clear();
  });
  const persistenceFailures = new Map();
  const imagePreparationFailures = new Map();
  const blobLoads = new Map();
  let appendFailure, reportedAppendFailure;
  function persistenceError(value) {
    if (imagePreparationFailures.has(value.imagePreparationFailure)) return { error: imagePreparationFailures.get(value.imagePreparationFailure) };
    const failure = persistenceFailures.get(value.persistenceFailureID) ??
      (value.persistenceError === 'fenced' ? appendFailure : undefined);
    if (failure) {
      if (failure.kind !== 'append') return { error: failure.error };
      failure.wrapped ??= Object.assign(new Error('libfx journal append failed', { cause: failure.error }), {
        code: 'FX_JOURNAL_APPEND_FAILED',
      });
      return { error: failure.wrapped };
    }
    const message = value.message ?? value.failed;
    if (message === 'Invalid session ID') {
      return { error: new TypeError("sessionId must be 1 to 255 letters, digits, '.', '_' or '-'") };
    }
    if (value.persistenceError === 'missingImage') {
      return { error: Object.assign(new Error(`libfx image store does not hold image ${value.imageName}`), { code: 'FX_JOURNAL_IMAGE_MISSING', image: value.imageName }) };
    }
    if (value.persistenceError === 'unsupportedVersion' || message === 'libfx journal was written by a newer fx' ||
        message === 'libfx checkpoint was written by a newer fx') {
      return { error: new FxJournalVersionError(message ?? 'libfx journal was written by a newer fx') };
    }
    if (value.persistenceError === 'invalidJournal') {
      return { error: Object.assign(new Error('Invalid libfx journal'), { code: 'FX_JOURNAL_INVALID' }) };
    }
    if (value.persistenceError === 'sizeLimit') {
      return { error: Object.assign(new Error('libfx journal is too large'), { code: 'FX_JOURNAL_TOO_LARGE' }) };
    }
    // The current core reports these journal-open failures by exact message.
    // Swift retains the RPC error; JS exposes its corresponding public code.
    const journalCodes = new Map([
      ['Invalid libfx journal', 'FX_JOURNAL_INVALID'],
      ['libfx journal events are out of order', 'FX_JOURNAL_INVALID'],
      ['libfx journal is too large', 'FX_JOURNAL_TOO_LARGE'],
      ['libfx journal holds more than 1024 turns', 'FX_JOURNAL_TOO_LARGE'],
      ['libfx journal images are too large', 'FX_JOURNAL_TOO_LARGE'],
      ['Invalid libfx journal images', 'FX_JOURNAL_INVALID'],
      ['libfx image does not match its name', 'FX_JOURNAL_IMAGE_MISSING'],
    ]);
    if (value.rpcCode !== undefined && journalCodes.has(message)) {
      return { error: Object.assign(new Error(message), { code: journalCodes.get(message) }) };
    }
    if (value.persistenceError === 'fenced') return { error: new FxFencedError(value.message ?? value.failed) };
    return undefined;
  }
  const fetchErrorNames = [];
  lines.on('line', line => {
    const value = JSON.parse(line);
    if (value.fixtureSend) {
      const message = value.fixtureSend;
      if (message.id !== undefined) fixtureMethods.set(message.id, message.method);
      let error;
      try { fixtureRuntime.write(JSON.stringify(message) + '\n'); } catch (caught) { error = caught.message ?? String(caught); }
      queueMicrotask(() => void request('fixtureWriteResult', { token: value.fixtureToken, ...(error ? { error } : {}) }).catch(() => {}));
    } else if (value.fixtureAttachment) {
      let error;
      try { fixtureRuntime.writeAttachment(value.fixtureAttachment.id, new Uint8Array(Buffer.from(value.fixtureAttachment.data, 'base64'))); }
      catch (caught) { error = caught.message ?? String(caught); }
      queueMicrotask(() => void request('fixtureWriteResult', { token: value.fixtureToken, ...(error ? { error } : {}) }).catch(() => {}));
    } else if (value.fixtureDiscard) {
      fixtureRuntime.discardAttachments?.();
    } else if (value.fixtureClosed) {
      fixtureRuntime.closeStdin();
    } else if (value.inputEffect) {
      void inputEffects.get(value.inputEffect)?.().catch(error => {
        try { options.hooks?.onError?.(error); } catch {}
      });
    } else if (value.permissionRequest) {
      const { token, ...permission } = value.permissionRequest;
      void Promise.resolve().then(() => options.onPermission?.(permission))
        .then(optionID => request('permissionResult', { token, ...(typeof optionID === 'string' ? { optionID } : {}) }),
          () => request('permissionResult', { token })).catch(() => {});
    } else if (value.refreshLockRequest) {
      const call = value.refreshLockRequest;
      Promise.resolve().then(() => options.refreshLock({ provider: call.provider, sessionId: call.sessionId },
        () => request('refreshLockedOperation', { token: call.token })))
        .then(credentials => request('refreshLockResult', { token: call.token, credentials }),
          () => request('refreshLockResult', { token: call.token })).catch(() => {});
    } else if (value.sessionAccepted) {
      acceptedSessions.get(value.sessionAccepted)?.resolve({ id: value.messageID, messageId: value.messageID, sessionId: value.sessionID });
      acceptedSessions.delete(value.sessionAccepted);
    } else if (value.credentialRequest) {
      const call = value.credentialRequest;
      Promise.resolve().then(async () => {
        const info = { provider: call.provider, sessionId: call.sessionId };
        if (call.saving) { await options.onCredentials(call.saving, info); return {}; }
        return options.credentials(info);
      }).then(value => request('credentialResult', { token: call.token, credentials: value }),
          () => request('credentialResult', { token: call.token })).catch(() => {});
    } else if (value.observation) {
      deliverObservation(value.observation);
    } else if (value.observationError) {
      try { Promise.resolve(options.hooks?.onError?.(new Error(value.observationError))).catch(() => {}); } catch {}
    } else if (value.diagnostic) {
      if (value.diagnostic.type === 'acp.send') runtimeStarted = true;
      if (value.diagnostic.type === 'transport.error' && fetchErrorNames.length) {
        value.diagnostic.error = fetchErrorNames.shift();
      }
      try { options.onEvent?.(value.diagnostic); }
      finally {
        if (value.wireDeliveryToken) void request('diagnosticAck', { token: value.wireDeliveryToken }).catch(() => {});
        if (value.diagnosticToken) {
          void Promise.resolve(turn?.cancellation).then(() => request('diagnosticAck', { token: value.diagnosticToken })).catch(() => {});
        }
      }
    }
    else if ('id' in value) {
      const waiter = pending.get(value.id);
      pending.delete(value.id);
      if (value.error) {
        let ErrorType = value.error.category === 'type' ? TypeError : value.error.category === 'range' ? RangeError : Error;
        let message = value.error.message;
        if (message === 'handedOff') message = 'This engine handed its session off';
        if (message === 'Invalid reasoning effort') {
          ErrorType = TypeError;
          message = 'effort must contain 1 to 64 letters, digits, periods, underscores or hyphens';
        }
        const translated = persistenceError(value.error);
        const error = translated ? translated.error : new ErrorType(message);
        if (value.error.data && error && typeof error === 'object') Object.assign(error, value.error.data);
        if (appendFailure && waiter?.op !== 'close' && error === appendFailure.wrapped) reportedAppendFailure = error;
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
    } else if ('failed' in value) {
      const state = turnStates.get(value.turnToken);
      const translated = persistenceError(value);
      const ErrorType = value.category === 'type' ? TypeError : value.category === 'range' ? RangeError : Error;
      const error = translated ? translated.error : new ErrorType(value.message ?? value.failed);
      if (appendFailure && error === appendFailure.wrapped) reportedAppendFailure = error;
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
    } else if (value.imagePreparationRequest) {
      const call = value.imagePreparationRequest;
      void Promise.resolve().then(async () => {
        const blob = blobLoads.get(call.data);
        const bytes = blob ? await blob.promise : new Uint8Array(Buffer.from(call.data, 'base64'));
        const image = { bytes, mimeType: call.mimeType };
        return options.resizeImage ? options.resizeImage(image) : image;
      })
        .then(image => {
          if (!image || !(image.bytes instanceof ArrayBuffer || ArrayBuffer.isView(image.bytes)) || !image.bytes.byteLength || typeof image.mimeType !== 'string') {
            throw new TypeError('resizeImage must return non-empty bytes and a mimeType');
          }
          const data = image.bytes instanceof ArrayBuffer ? Buffer.from(image.bytes) : Buffer.from(image.bytes.buffer, image.bytes.byteOffset, image.bytes.byteLength);
          return request('imagePreparationResult', { token: call.token, image: { data: data.toString('base64'), mimeType: image.mimeType } });
        }).catch(error => {
          imagePreparationFailures.set(call.token, error);
          void request('imagePreparationResult', { token: call.token, error: error?.message ?? String(error) }).catch(() => {});
        });
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
          } else if (call.kind === 'putImage') {
            await options.persistence[Symbol.for('libfx.persistenceImages')].put(call.name, new Uint8Array(Buffer.from(call.data, 'base64')));
            result = null;
          } else if (call.kind === 'getImage') {
            const bytes = await options.persistence[Symbol.for('libfx.persistenceImages')].get(call.name);
            result = bytes == null ? null : Buffer.from(bytes).toString('base64');
          } else {
            const { id, kind, ...input } = call;
            result = await options.persistence.append({ ...input, data: new Uint8Array(Buffer.from(input.data, 'base64')) });
          }
          await request('persistenceResult', { persistenceID: call.id, value: result });
        } catch (error) {
          const failure = { error, kind: call.kind };
          persistenceFailures.set(call.id, failure);
          if (call.kind === 'append') appendFailure ??= failure;
          // Swift has a typed fencing error. Unwrap the host exception at this
          // language boundary without changing the Swift persistence contract.
          const visited = new Set();
          let cause = error, code;
          while (cause && !visited.has(cause)) {
            visited.add(cause);
            if (cause.code === 'FX_FENCED') { code = cause.code; break; }
            cause = cause.cause;
          }
          let description;
          try { description = error instanceof Error ? error.message : String(error); }
          catch { description = 'Host persistence operation failed'; }
          await request('persistenceResult', { persistenceID: call.id, error: description, code }).catch(() => {});
        }
      })();
    } else if (value.fetchRequest) {
      const call = value.fetchRequest, controller = new AbortController();
      fetchControllers.set(call.id, controller);
      void (async () => {
        let receivedHeaders = false;
        try {
          const response = await (options.fetch || globalThis.fetch)(call.url, {
            method: call.method, headers: new Headers(call.headers),
            ...(call.body ? { body: new Uint8Array(Buffer.from(call.body, 'base64')) } : {}),
            signal: controller.signal,
          });
          receivedHeaders = true;
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
          if (!receivedHeaders && !controller.signal.aborted) fetchErrorNames.push(error.name || 'Error');
          await request('fetchFailure', { fetchID: call.id, error: String(error) }).catch(() => {});
        } finally { fetchControllers.delete(call.id); }
      })();
    } else if (value.toolCancelled) {
      toolScopes.get(value.toolCancelled)?.invalidate();
      toolScopes.delete(value.toolCancelled);
      toolControllers.get(value.toolCancelled)?.abort();
      toolControllers.delete(value.toolCancelled);
    } else if (value.toolRequest) {
      const call = value.toolRequest, controller = new AbortController();
      toolControllers.set(call.id, controller);
      toolOwners.set(call.id, call.turnId);
      const owner = [...turnStates.values()].find(state => state.public.id === call.turnId);
      if (owner?.signal?.aborted) return;
      Promise.resolve().then(() => tools.get(call.name).execute(call.input, {
        signal: controller.signal, executionId: call.executionId, sessionId: call.sessionId,
        ...(call.context == null ? {} : { context: call.context }),
        ...(call.observation && options.hooks ? { observation: inputObservation(call) } : {}),
      })).then(result => controller.signal.aborted ? undefined : request('toolResult', { toolID: call.id,
        ...(result?.type === 'libfx.tool-result' ? (
          Array.isArray(result.images) && result.images.some(image => typeof image?.sourceRef === 'string' && !image.sourceRef.isWellFormed())
            ? { error: 'Invalid tool image sourceRef' } : { rich: result }
        ) : {
          content: typeof result === 'string' ? result : JSON.stringify(result) ?? 'null',
        }),
      }), error => controller.signal.aborted ? undefined : request('toolResult', { toolID: call.id,
        error: error instanceof Error ? error.message : String(error) }))
        .catch(() => {}).finally(() => { toolControllers.delete(call.id); toolOwners.delete(call.id); });
    }
  });
  const { fetch, nativeAddon, backend, onEvent, tools: _tools, checkpoint, persistence, runtimeFactory, ...configuration } = options;
  try {
    if (options.__observationFixture) {
      const { scope, callID, signal } = options.__observationFixture;
      const metadata = await request('observationOpen', { scope, callID, captureContent: options.hooks.captureContent === true });
      const started = Promise.withResolvers();
      const observer = inputObservation({ id: 1, observation: metadata, onEffectStarted: started.resolve });
      let cancellation = Promise.resolve();
      const abort = () => {
        observer[swiftObservationScope].invalidate();
        cancellation = request('observationCancel');
        cancellation.catch(reportObservationError);
      };
      signal.addEventListener('abort', abort, { once: true });
      if (signal.aborted) abort();
      return { ...observer, waitUntilStarted: () => started.promise, flush: () => cancellation,
        async close() {
          if (closed) return;
          closed = true;
          signal.removeEventListener('abort', abort);
          try { await request('close'); } finally { await finish(); }
        },
      };
    }
    if (configuration.instructions !== undefined) {
      if (Array.isArray(configuration.instructions) && configuration.instructions.every(value => typeof value === 'string')) {
        configuration.instructions = configuration.instructions.filter(Boolean).join('\n\n');
      }
      if (typeof configuration.instructions !== 'string') throw new TypeError('instructions must be a string or an array of strings');
      await request('validateInstructions', { instructions: configuration.instructions });
    }
    if (runtimeFactory) {
      fixtureRuntime = await runtimeFactory({ ...options,
        hostToolExecutor: (name, input, sessionID, callID) => request('fixtureTool', { name, input, sessionID, callID }),
      });
      fixtureRuntime.setLineHandler(async message => {
        if (fixtureMethods.get(message.id) === 'libfx/new' && message.result && !message.result.configOptions) {
          // The JS fixture omits the selected model from its protocol envelope.
          // Supply that metadata only; the production Swift handshake still runs.
          message = { ...message, result: { ...message.result,
            configOptions: [{ id: 'model', currentValue: options.model ?? 'fixture/injected' }],
          } };
        }
        if (message.id !== undefined) fixtureMethods.delete(message.id);
        await request('fixtureReceive', { message });
      });
      void fixtureRuntime.exited.then(async code => {
        if (closed) return;
        await request('fixtureExit', { code });
        try { options.onEvent?.({ type: 'runtime.exit', code }); } catch {}
      }).catch(reportObservationError);
    }
    if (options.__inspect) {
      try { return await request('inspectSession', { path: options.sessionStorePath, sessionID: options.sessionID, agentName: options.name }); }
      finally { await finish(); }
    }
    if (options.__listModels) {
      try { return await request('listModels', { apiKey: options.apiKey }); }
      finally { await finish(); }
    }
    const opened = await request(options.__agent ? 'openAgent' : 'open', { options: {
      ...configuration,
      hasImagePreparation: !options.__agent || typeof options.resizeImage === 'function',
      sessionId: options.sessionId,
      model: swiftModel(options),
      ...(options.hooks ? { hooks: options.hooks } : {}),
      hasCredentials: typeof options.credentials === 'function',
      hasRefreshLock: typeof options.refreshLock === 'function',
      credentialsType: typeof options.credentials, onCredentialsType: typeof options.onCredentials,
      refreshLockType: typeof options.refreshLock,
      hasOnCredentials: typeof options.onCredentials === 'function',
      hasRuntimeFactory: Boolean(runtimeFactory),
      hasPersistence: Boolean(persistence),
      hasImagePersistence: Boolean(persistence?.[Symbol.for('libfx.persistenceImages')]),
      ...(persistence?.[Symbol.for('libfx.persistenceImages')] && options[Symbol.for('libfx.imageWindow')] ? { imageWindow: options[Symbol.for('libfx.imageWindow')] } : {}),
      hasCheckpointPersistence: typeof persistence?.saveCheckpoint === 'function',
      ...(checkpoint ? { checkpoint: Buffer.from(checkpoint).toString('base64') } : {}),
      tools: (options.tools || []).map(({ execute, ...descriptor }) => descriptor),
    } });
    if (options.__agent) return {
      sessionPrompt(sessionID, text, messageID, sessionOptions = {}, resume = false) {
        const token = randomUUID();
        const state = createTurn(() => request('cancel', { turnToken: token }),
          () => Promise.reject(new Error('Session steering is not implemented')),
          () => Promise.reject(new Error('Session withdrawal is not implemented')));
        state.public.id = messageID;
        turnStates.set(token, state);
        const accepted = new Promise((resolve, reject) => acceptedSessions.set(token, { resolve, reject }));
        state.public.accepted = accepted;
        accepted.catch(() => {});
        const intake = encodePrompt(text).then(text => request(resume ? 'sessionResume' : 'sessionPrompt', { sessionID, text, messageID,
          options: sessionOptions, turnToken: token })).catch(error => {
          acceptedSessions.get(token)?.reject(error);
          acceptedSessions.delete(token);
          state.fail(error);
          turnStates.delete(token);
        }).finally(() => sessionIntakes.delete(intake));
        sessionIntakes.add(intake);
        return state.public;
      },
      async sessionCheckpoint(sessionID, sessionOptions) {
        return new Uint8Array(Buffer.from(await request('sessionCheckpoint', { sessionID, options: sessionOptions }), 'base64'));
      },
      async sessionSteer(sessionID, input, id, sessionOptions) {
        return request('sessionSteer', { sessionID, text: input, messageID: id, options: sessionOptions });
      },
      async sessionCancel(sessionID) { return request('sessionCancel', { sessionID }); },
      sessionStream(sessionID, cursor = 0) {
        const readToken = randomUUID();
        let cancelled = false;
        return new ReadableStream({
          async pull(controller) {
            if (cancelled) return;
            const event = await request('sessionNextEvent', { sessionID, cursor, readToken });
            if (cancelled) return;
            if (!event) { controller.close(); return; }
            cursor = event.cursor;
            controller.enqueue(new TextEncoder().encode(JSON.stringify(event) + '\n'));
          },
          async cancel() { cancelled = true; await request('sessionReadCancel', { readToken }); },
        });
      },
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
        await Promise.allSettled([...sessionIntakes]);
        try { await request('close'); } finally { await finish(); }
      },
    };
    resumable = opened.resumable;
    recoveryCalls = opened.runningCalls;
    recoveryTurnID = opened.openTurnId;
    let handedOff = false;
    function begin(op, args, promptOptions = {}) {
      if (turn) throw new Error('a prompt is already running');
      const turnToken = randomUUID();
      const control = (op, args = {}) => request(op, { ...args, turnToken });
      let ready;
      const abortTools = () => {
        for (const [id, controller] of toolControllers) {
          if (toolOwners.get(id) === state.public.id) controller.abort();
        }
      };
      const state = createTurn(args => {
        if (args.reason !== undefined && args.reason !== 'handoff') throw new TypeError('reason must be "handoff"');
        if (args.reason === 'handoff' && !options.persistence && !nativeStore) throw new Error('Handoff needs persistence');
        abortTools();
        return ready.then(() => control('cancel', args)).then(reply => {
          if (args.reason === 'handoff') handedOff = reply?.handedOff === true;
          return reply;
        });
      }, (input, inputID) => ready.then(() => control('steer', {
        text: Array.isArray(input) ? input.map(block => block.text).join('\n') : input, inputID,
      })), inputID => ready.then(() => control('withdraw', { inputID })));
      turnStates.set(turnToken, state);
      state.signal = promptOptions.signal;
      turn = state;
      const publicID = op === 'prompt' ? promptOptions.turnId === undefined ? randomUUID() : promptOptions.turnId : recoveryTurnID;
      state.public.id = publicID;
      const loads = [];
      if (op === 'prompt') {
        args = { ...args, text: args.text.map(block => {
          if (!(block.data instanceof Blob)) return block;
          const data = Buffer.from('swift-blob-' + randomUUID()).toString('base64');
          const deferred = Promise.withResolvers();
          deferred.promise.catch(() => {});
          const load = { ...deferred, blob: block.data };
          blobLoads.set(data, load);
          loads.push({ data, load });
          return { ...block, data };
        }) };
      }
      ready = control(op, {
          ...args, ...(op === 'prompt' || publicID != null ? { turnID: publicID } : {}),
          ...(promptOptions.yieldAt === undefined ? {} : { yieldAt: promptOptions.yieldAt }),
        }).then(reply => { if (reply?.turnID) state.public.id = reply.turnID; });
      const abort = () => { abortTools(); state.cancellation = ready.then(() => control('cancel')).catch(error => state.fail(error)); };
      promptOptions.signal?.addEventListener('abort', abort, { once: true });
      state.cleanup = () => {
        promptOptions.signal?.removeEventListener('abort', abort);
        for (const { data } of loads) blobLoads.delete(data);
      };
      if (promptOptions.signal?.aborted) abort();
      ready.catch(error => { state.cleanup?.(); state.fail(error); turnStates.delete(turnToken); if (turn === state) turn = null; });
      for (const { load } of loads) {
        try { Promise.resolve(load.blob.arrayBuffer()).then(data => load.resolve(new Uint8Array(data)), load.reject); }
        catch (error) { load.reject(error); }
      }
      return state.public;
    }
    return {
      sessionId: opened.sessionId,
      prompt(text, promptOptions = {}) {
        if (handedOff) throw new Error('This engine handed its session off');
        if (reportedAppendFailure) throw reportedAppendFailure;
        if (promptOptions.turnId !== undefined && (typeof promptOptions.turnId !== 'string' || !/^[A-Za-z0-9._-]{1,128}$/.test(promptOptions.turnId))) {
          throw new TypeError('turnId must be 1 to 128 ASCII letters, digits, periods, underscores or hyphens');
        }
        return begin('prompt', { text: checkPromptWithSwift(text, typeof options.resizeImage === 'function', defaultDriver) }, promptOptions);
      },
      resume(promptOptions = {}) {
        if (handedOff) throw new Error('This engine handed its session off');
        if (reportedAppendFailure) throw reportedAppendFailure;
        if (promptOptions.onAmbiguous !== undefined && typeof promptOptions.onAmbiguous !== 'function') {
          throw new TypeError('onAmbiguous must be a function');
        }
        if (!resumable) return null;
        const rerun = recoveryCalls.filter(call => promptOptions.onAmbiguous?.(call) === 'rerun').map(call => call.executionId);
        return begin('resume', { rerun, replayOutput: promptOptions[Symbol.for('libfx.resumeOutputShown')] !== true }, promptOptions);
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
        started[Symbol.for('libfx.swift.followUpReceipt')] = request('followUp', { text: Array.isArray(input) ? input.map(block => block.text).join('\n') : input, turnToken: token })
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
        try {
          if (turn) {
            const active = turn;
            await active.public.cancel();
            await active.public.result.catch(() => {});
          }
          await request('close');
          runtimeExit(0, null);
        }
        catch (error) {
          // JS reports an append failure once. Swift close keeps throwing its
          // original error; normalize only that same already-exposed instance.
          if (!reportedAppendFailure || error !== reportedAppendFailure) throw error;
        } finally { reapClosedDriver(); }
      },
    };
  } catch (error) { child.stdin.end(); await exited; lines.close(); throw error; }
}

const promptAdmissions = new Map();
const blobSize = Object.getOwnPropertyDescriptor(Blob.prototype, 'size').get;

// Translate JavaScript-only shapes. Bounds, reference policy and image signatures
// are checked by the same Swift admission code used by the production engine.
function checkPromptWithSwift(input, preparing, driver) {
  const blocks = typeof input === 'string' ? [{ type: 'text', text: input }] : input;
  if (!Array.isArray(blocks)) throw new TypeError('prompt input must be a string or an array of prompt blocks');
  const descriptors = [];
  const normalized = blocks.map((block, index) => {
    if (!block || typeof block !== 'object') throw new TypeError(`prompt block ${index} must be an object`);
    if (block.type === 'text') {
      if (typeof block.text !== 'string') throw new TypeError(`text prompt block ${index} requires text`);
      const text = { type: 'text', text: block.text };
      descriptors.push(text);
      return text;
    }
    if (block.type !== 'image') throw new TypeError(`unsupported prompt block type: ${String(block.type)}`);
    if (block.sourceRef !== undefined && (typeof block.sourceRef !== 'string' || !block.sourceRef.isWellFormed())) {
      throw new TypeError(`image prompt block ${index} has an invalid sourceRef`);
    }
    let mimeType = block.mimeType;
    let byteCount, bytes, data = block.data;
    if (data instanceof Blob) {
      if (mimeType !== undefined && mimeType !== data.type) throw new TypeError(`image prompt block ${index} mimeType disagrees with Blob.type`);
      mimeType = data.type;
      byteCount = blobSize.call(data);
      if (!Number.isSafeInteger(byteCount) || byteCount <= 0) throw new TypeError(`image prompt block ${index} requires a non-empty Blob with a valid size`);
    } else if (typeof data === 'string' && data.length) {
      bytes = Buffer.from(data, 'base64');
      if (bytes.toString('base64') !== data) throw new TypeError(`image prompt block ${index} requires canonical base64 data`);
      byteCount = bytes.byteLength;
    } else if (data !== undefined || block.sourceRef === undefined) {
      bytes = data instanceof ArrayBuffer ? new Uint8Array(data) : ArrayBuffer.isView(data) ? new Uint8Array(data.buffer, data.byteOffset, data.byteLength) : null;
      if (!bytes?.byteLength) throw new TypeError(`image prompt block ${index} requires base64 data, bytes, or a Blob`);
      byteCount = bytes.byteLength;
      data = Buffer.from(bytes).toString('base64');
    }
    if (typeof mimeType !== 'string' || !mimeType.length || mimeType.length > 128) throw new TypeError(`image prompt block ${index} requires a mimeType`);
    const reference = block.sourceRef === undefined ? {} : { sourceRef: block.sourceRef };
    descriptors.push({ type: 'image', mimeType, ...reference, byteCount,
      ...(bytes ? { prefix: Buffer.from(bytes.subarray(0, 12)).toString('base64') } : {}) });
    return { type: 'image', mimeType, ...reference, ...(data === undefined ? {} : { data }) };
  });
  const request = JSON.stringify({ id: 1, op: 'validatePrompt', blocks: descriptors, preparing });
  const key = createHash('sha256').update(driver).update(request).digest('hex');
  let admitted = promptAdmissions.get(key);
  if (!admitted) {
    const process = spawnSync(driver, ['check-prompt'], { input: request, encoding: 'utf8', timeout: 30_000, maxBuffer: 16 * 1024 * 1024 });
    if (process.error) throw process.error;
    if (process.status !== 0 || process.signal || process.stderr) throw new Error(`Swift prompt admission failed: ${process.stderr || process.signal || process.status}`);
    const reply = JSON.parse(process.stdout);
    if (reply.error) {
      const ErrorType = reply.error.category === 'range' ? RangeError : reply.error.category === 'type' ? TypeError : Error;
      throw new ErrorType(reply.error.message);
    }
    if (!Array.isArray(reply.result)) throw new Error('Swift returned invalid prompt admission');
    admitted = new Set(reply.result);
    if (promptAdmissions.size >= 128) promptAdmissions.delete(promptAdmissions.keys().next().value);
    promptAdmissions.set(key, admitted);
  }
  return normalized.map((block, index) => block.type !== 'image' || admitted.has(index) ? block :
    { type: 'image', mimeType: block.mimeType, sourceRef: block.sourceRef });
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
      cancel(options = {}) {
        state.cancellation = cancel(options).catch(error => state.fail(error));
        return state.cancellation;
      },
      [Symbol.for('libfx.swift.cancellation')]() { return state.cancellation; },
      steer(input, id = `in_${randomUUID()}`) {
        const receipt = steer(input, id);
        receipt.catch(() => {});
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
        return() { void state.public.cancel(); return Promise.resolve({ done: true }); },
      }; },
    },
  };
  return state;
}

export function supportsJspi() { return false; }
export function listModels(options = {}) { return createFxEngine({ ...options, __listModels: true }); }


const temporaryStores = new Set();
process.once('exit', () => { for (const path of temporaryStores) rmSync(path, { recursive: true, force: true }); });

// Test storage descriptors only. SQLite ownership and durable behavior stay in Swift.
export function memory({ maxDurationMs, reserveMs } = {}) {
  const directory = mkdtempSync(join(tmpdir(), 'libfx-swift-session-'));
  temporaryStores.add(directory);
  const path = join(directory, 'sessions.sqlite');
  return { __swiftSessionPath: path, __swiftMaximumDurationMs: maxDurationMs, __swiftReserveMs: reserveMs,
    create() { return {
      async session(sessionID) {
        const snapshot = await createFxEngine({ __inspect: true, sessionStorePath: path, sessionID });
        return {
          async readSince(cursor) {
            if (cursor !== 0) throw new Error('Inspection supports only a complete snapshot');
            return snapshot.records.map(data => new Uint8Array(Buffer.from(data, 'base64')));
          },
          ui: {
            async length() { return snapshot.entries.length; },
            read(start = 0) { return new ReadableStream({ start(controller) {
              for (const entry of snapshot.entries.slice(start)) controller.enqueue(new TextEncoder().encode(JSON.stringify(entry) + '\n'));
              controller.close();
            } }); },
          },
        };
      },
    }; },
  };
}

export function createFxAgent(options = {}) {
  const durability = options.durability ?? memory();
  if (typeof durability.__swiftSessionPath !== 'string') throw new TypeError('Unsupported Swift conformance storage descriptor');
  const ready = createFxEngine({ ...options, __agent: true, sessionStorePath: durability.__swiftSessionPath,
    maximumDurationMs: durability.__swiftMaximumDurationMs, reserveMs: durability.__swiftReserveMs });
  ready.catch(() => {});
  function turnView(sessionID, sessionOptions, input, promptOptions = {}, resume = false) {
    let id = promptOptions.messageId ?? promptOptions.id ?? randomUUID();
    const started = ready.then(agent => agent.sessionPrompt(sessionID, input, id, sessionOptions, resume));
    const accepted = started.then(turn => turn.accepted).then(receipt => { id = receipt.id; return receipt; });
    const result = started.then(turn => turn.result);
    accepted.catch(() => {}); result.catch(() => {});
    return { get id() { return id; }, accepted, result,
      cancel: () => started.then(turn => turn.cancel()),
      async *[Symbol.asyncIterator]() { yield* await started; },
    };
  }
  let defaultSession;
  const agent = {
    get sessionId() { defaultSession ??= agent.session(); return defaultSession.id; },
    session(sessionID = randomUUID(), sessionOptions = {}) {
      return {
        id: sessionID,
        prompt(input, promptOptions) { return turnView(sessionID, sessionOptions, input, promptOptions); },
        resume() { return turnView(sessionID, sessionOptions, '', {}, true); },
        async checkpoint() { return (await ready).sessionCheckpoint(sessionID, sessionOptions); },
        async steer(input, { messageId = randomUUID() } = {}) {
          return (await ready).sessionSteer(sessionID, input, messageId, sessionOptions);
        },
        async cancel() { return (await ready).sessionCancel(sessionID); },
        stream(cursor = 0) {
          let reader;
          let cancelled = false;
          return new ReadableStream({
            async pull(controller) {
              const remote = await ready;
              if (cancelled) return;
              reader ??= remote.sessionStream(sessionID, cursor).getReader();
              const { value, done } = await reader.read();
              if (cancelled) return;
              if (done) controller.close(); else controller.enqueue(value);
            },
            async cancel() { cancelled = true; await reader?.cancel(); },
          });
        },
      };
    },
    prompt(input, promptOptions) {
      defaultSession ??= agent.session();
      return defaultSession.prompt(input, promptOptions);
    },
    async checkpoint() {
      defaultSession ??= agent.session();
      return defaultSession.checkpoint();
    },
    async __killForTest() { return (await ready).__killForTest(); },
    async close() { await (await ready).close(); },
  };
  return agent;
}
