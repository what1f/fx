import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import assert from 'node:assert/strict';

// Named selections retain the complete original test bodies and assertions.
// The full journal owner remains pending in inventory.json.
const cases = {
  "admission": [
    "a journaled session restores on another backend",
    "a tool turn records progress before each model request",
    "a tool call starts only after its intent is stored",
    "an idempotent writer's call starts only after its intent is stored",
    "an idempotent call that does not write starts before its intent is stored",
    "events that arrive while an append is in flight go out as one record, and only waited-for records are barriers",
    "a progress after the turn's first carries only what is new, and folds back into the whole turn"
  ],
  "recovery": [
    "a call that finished before a crash is answered with its result, not as possibly run",
    "a call that a crash cut off is answered as possibly run, and its turn shows that",
    "a crash before a response's calls are stored asks the model again",
    "resume continues a crashed turn and tells the model",
    "a crash after the final reply, before its turn ends, delivers the saved reply without asking the model again",
    "a resume that restarts a reply the last process had started sends that start first",
    "a turn's result waits until its end is stored"
  ]
};
const group = process.argv[2] ?? 'admission';
const selected = Object.hasOwn(cases, group) ? cases[group] : undefined;
assert.ok(selected, 'Unknown journal group');
const child = spawnSync(process.execPath, [
  '--no-warnings', '--loader', './swift/Tests/Conformance/loader.mjs',
  'sdk/tests/test-journal.mjs', 'native', 'native',
], {
  cwd: fileURLToPath(new URL('../../../', import.meta.url)),
  env: { ...process.env, LIBFX_SWIFT_JOURNAL_CASES: JSON.stringify(selected) },
  encoding: 'utf8', timeout: 55_000,
});
process.stdout.write(child.stdout ?? '');
process.stderr.write(child.stderr ?? '');
assert.ifError(child.error);
assert.equal(child.status, 0);
assert.ok(child.stdout.includes(`selected journal cases passed: ${selected.length}`));
