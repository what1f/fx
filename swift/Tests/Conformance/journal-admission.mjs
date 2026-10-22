import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import assert from 'node:assert/strict';

// Named selections retain the complete original test bodies and assertions.
// Normal conformance runs the complete journal owner. Sanitizers use bounded groups.
const cases = {
  "image-storage": [
    "a store keeps each prompt image once, and records and checkpoints only name it",
    "a session whose store lost an image is refused, naming it",
    "a persistence without an image store keeps writing images inline",
    "an image turn that crashed after a delta reopens with its image",
    "a session keeps its newest images within its window of images, and an older one leaves as a note",
    "a session keeps its newest images within its window of bytes, and an older one leaves as a note",
    "a turn that fails before it enters the history drops no image"
  ],
  "image-limits": [
    "a turn that crashed with a full image window reopens with all of its images",
    "a failed image write fails the prompt before it is sent",
    "a session saved inline opens behind an image store, and only new images are stored",
    "images too large for a checkpoint are named instead",
    "a session holds more images than a checkpoint could, turn after turn"
  ],
  "tool-images": [
    "a store keeps each tool image once, and records and checkpoints only name it",
    "a tool image leaves the window oldest first, as a note, and stays out after a reopen",
    "a tool image the store refuses stays in the session inline",
    "a turn that crashed after its screenshot's progress reopens with the screenshot",
    "a turn that crashed right after its screenshot's result reopens with the screenshot, without running the tool again",
    "a tool image the store refused leaves the window like any other, as a note",
    "a turn whose tools returned more images than a window and a prompt hold reopens with all of them"
  ],
  "checkpoints": [
    "a journal past the turn limit is refused by name",
    "a host session id reaches the gateway and stays the same across a restore",
    "a session id must be safe to send as a header",
    "a checkpoint is saved after a turn, and a restore reads it and only the records after it",
    "a checkpoint after a turn counts the records still being stored",
    "a failed checkpoint save is reported and the records still restore the session",
    "a retried prompt with the same turn id continues its open turn instead of adding the prompt again"
  ],
  "turn-identity": [
    "a retried prompt with the id of a turn that ended does not run it again",
    "a tool receives the model's call id as its execution id, and its session's id",
    "a yielded turn resumed in place after its checkpoint reopens from any cut"
  ],
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
  ],
  "continuation": [
    "a turn whose end fails to store rejects its result",
    "a resumed turn answers a call a crash left running instead of running it again",
    "a host that knows a running call never ran has the resumed turn run it again",
    "a resumed turn keeps what the model wrote before the calls a crash left running",
    "a new prompt instead of resume ends the crashed turn as interrupted",
    "each turn appends its own events, not the whole history",
    "a slow store receives one opaque record at a time, each naming the cursor before it"
  ],
  "cancellation": [
    "a turn handed off mid-tool stays open for the next agent",
    "a handoff needs persistence and takes no other reason",
    "a long tool turn stores each step once in its progress, and a crash late in it restores",
    "a turn that fails ends in the journal and is not resumed",
    "a follow-up cancelled as its turn starts never runs again",
    "a cancel during a slow journal's barrier ends the turn as the agent does",
    "a resumed turn cancelled during a slow journal's barrier is committed once"
  ],
  "image-recovery": [
    "an image prompt after a crashed image turn gets the next image id"
  ],
  "inputs": [
    "a steer is stored before the model request that carries it",
    "a steer withdrawn before its boundary never reaches the model",
    "a steer accepted before a crash reaches the model when the turn resumes",
    "a follow-up queued during a turn runs after it as its own turn",
    "a follow-up the journal holds runs when the session resumes",
    "a held follow-up waits for resume() without holding up the agent's own",
    "a follow-up on an idle agent runs at once"
  ],
  "versions": [
    "a turn left open resumes under the tools the new agent has",
    "a journal from a newer libfx is refused",
    "a checkpoint from a newer libfx is refused with the journal's typed error",
    "a v1 journal from the first journaled libfx still resumes",
    "a checkpoint saved by the previous published libfx restores in this one",
    "each progress event names the model its request goes to"
  ],
  "failures": [
    "a second agent on the same store fences the first",
    "a journal that does not fold is refused",
    "a failed append fails the turn and stops the agent",
    "persistence options are checked before the core starts",
    "a session taken over mid-turn fences the first agent, which stops at once",
    "a takeover does not run a running call again and records one outcome for it"
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
