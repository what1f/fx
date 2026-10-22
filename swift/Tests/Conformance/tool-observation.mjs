import assert from 'node:assert/strict';
import { toolObservation as javascript } from '../../../sdk/tool-observation.js';
import { toolObservation as swift } from './adapter.mjs';
import { swiftObservationScope } from './observation-scope.mjs';

const scope = { version: 1, sessionId: 'fixture', rootSessionId: 'fixture', parentSessionId: null,
  sourceSessionId: null, workId: null, turnId: 'turn', executionId: 'execution', stepIndex: 1 };
const request = { kind: 'approval', prompt: 'Approve?' };
for (const [name, create] of [['JavaScript', javascript], ['Swift', swift]]) {
  for (const mode of ['late-answer', 'already-cancelled', 'host-error']) {
    const events = [], controller = new AbortController(), started = Promise.withResolvers();
    if (mode === 'already-cancelled') controller.abort();
    const onEvent = () => {};
    const observer = await create(scope, 'call', { captureContent: true, onEvent },
      event => events.push(event), controller.signal);
    try {
      await observer.flush?.();
      if (name === 'Swift') assert.equal(observer[swiftObservationScope].active, mode !== 'already-cancelled');
      assert.deepEqual(observer.childHooks().parent,
        { rootSessionId: 'fixture', sessionId: 'fixture', turnId: 'turn', callId: 'call' });
      assert.equal(observer.childHooks().onEvent, onEvent);
      let calls = 0;
      const original = { outcome: 'accepted', answers: ['late answer'] };
      original.self = original;
      if (mode === 'late-answer') {
        const answer = Promise.withResolvers();
        const pending = observer.wait(request, () => { calls++; started.resolve(); return answer.promise; });
        await started.promise;
        controller.abort();
        await observer.flush?.();
        if (name === 'Swift') assert.equal(observer[swiftObservationScope].active, false);
        assert.equal(events.filter(event => event.type === 'wait.end')[0].data.outcome, 'cancelled');
        answer.resolve(original);
        assert.equal(await pending, original);
        assert.equal(events.filter(event => event.type === 'wait.end').length, 1);
      } else if (mode === 'already-cancelled') {
        assert.equal(await observer.wait(request, () => { calls++; return original; }), original);
        assert.equal(events.length, 0);
      } else {
        const failure = new Error('host failure');
        await assert.rejects(observer.wait(request, () => { calls++; throw failure; }), error => error === failure);
        const ended = events.filter(event => event.type === 'wait.end');
        assert.equal(ended.length, 1);
        assert.equal(ended[0].data.outcome, 'failed');
      }
      assert.equal(calls, 1);
      console.log(`${name} standalone tool observation passed: ${mode}`);
    } finally { await observer.close?.(); }
  }
}
