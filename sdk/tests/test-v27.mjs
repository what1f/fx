#!/usr/bin/env node
import assert from "node:assert/strict";

import { check } from "../../tests/v27/eve-v27.mjs";
import { commitLine, foldCommits, withCommit } from "../durable/v27.mjs";

const first = withCommit({ k: "input", messageId: "message_1" }, 0);
const second = withCommit({ k: "ended", messageId: "message_1" }, 1);
const lines = [first, second].map(({ v27 }) => ({
  at: new Date(v27.ts).toISOString(),
  facts: v27.facts,
}));
assert.deepEqual(check(lines), []);
assert.deepEqual(foldCommits([
  { cursor: "1", entry: first },
  { cursor: "2", entry: second },
]), {
  position: 2,
  records: [
    { k: "input", messageId: "message_1" },
    { k: "ended", messageId: "message_1" },
  ],
  started: true,
});
assert.match(commitLine(0, {}, { started: true }).crc, /^[0-9a-f]{8}$/);
console.log("libfx v27 durable lines passed");
