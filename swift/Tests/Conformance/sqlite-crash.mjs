import { strict as assert } from 'node:assert';
import { mkdtemp, readFile, appendFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { createFxEngine } from './adapter.mjs';

const directory = await mkdtemp(join(tmpdir(), 'libfx-swift-crash-'));
const database = join(directory, 'conversation.sqlite'), effect = join(directory, 'effects.txt');
const bodies = [];
let phase = 'first', effectStarted;
const began = new Promise(resolve => { effectStarted = resolve; });
const options = {
  apiKey: 'crash-fixture-key', model: 'fixture/crash', sqlitePath: database, checkpointAfterBytes: 0,
  tools: [{ name: 'write_once', description: 'Perform a write', writes: true, idempotent: false,
    inputSchema: { type: 'object', properties: { value: { type: 'string' } } },
    async execute({ value }) {
      await appendFile(effect, `${value}\n`);
      effectStarted();
      // The effect happened, but the core never receives its result.
      return new Promise(() => {});
    },
  }],
  async fetch(_url, init) {
    if (init.method === 'GET') return Response.json({ data: [{ id: 'fixture/crash', type: 'language', tags: ['tool-use'] }] });
    const body = JSON.parse(new TextDecoder().decode(init.body));
    bodies.push(body);
    let frames;
    if (phase === 'effect') {
      frames = [{ type: 'tool-call', toolCallId: 'effect-call', toolName: 'write_once', input: { value: 'one-write' } }];
    } else {
      if (phase === 'recovery') {
        assert.ok(JSON.stringify(body).includes('remember the disk conversation'));
        assert.ok(JSON.stringify(body).includes('persisted-answer'));
        assert.ok(JSON.stringify(body).includes('may have partly run'));
      }
      frames = [{ type: 'text-delta', delta: phase === 'first' ? 'persisted-answer' : 'recovered-answer' }];
    }
    frames.push({ type: 'finish', finishReason: { unified: phase === 'effect' ? 'tool-calls' : 'stop', raw: 'stop' } });
    return new Response(frames.map(event => `data: ${JSON.stringify(event)}\n\n`).join('') + 'data: [DONE]\n\n', {
      headers: { 'content-type': 'text/event-stream' },
    });
  },
};
let engine;
try {
  engine = await createFxEngine(options);
  const first = engine.prompt('remember the disk conversation');
  for await (const _ of first) {}
  assert.equal((await first.result).stopReason, 'end_turn');
  assert.equal((await engine.__killForTest()).signal, 'SIGKILL');

  phase = 'effect';
  engine = await createFxEngine({ ...options, checkpointAfterBytes: null });
  const interrupted = engine.prompt('perform the write');
  await Promise.race([began, interrupted.result.then(() => { throw new Error('The turn ended before the held write'); })]);
  assert.equal((await engine.__killForTest()).signal, 'SIGKILL');
  await assert.rejects(interrupted.result, /Swift driver exited/);

  phase = 'recovery';
  engine = await createFxEngine(options);
  const resumed = engine.resume();
  assert.ok(resumed, 'the disk journal lost its interrupted turn');
  const events = [];
  for await (const event of resumed) events.push(event);
  assert.equal((await resumed.result).stopReason, 'end_turn');
  assert.ok(events.some(event => event.type === 'tool_end' && event.isError && event.content.includes('may have partly run')));
  assert.equal(await readFile(effect, 'utf8'), 'one-write\n');
  assert.equal(bodies.length, 3, 'recovery replayed an extra model request');
  await engine.close();
  console.log('SQLite crash recovery passed: SIGKILL after snapshot and after external write, with no ambiguous write replay');
} finally {
  await engine?.close();
  await rm(directory, { recursive: true, force: true });
}
