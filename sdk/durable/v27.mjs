// The eve v27 envelope used inside each durable World log entry. The World
// still indexes its own lease record, while `v27` is the portable session
// commit that readers fold.

const encoder = new TextEncoder();

function crc32c(text) {
  let crc = 0xffffffff;
  for (const byte of encoder.encode(text)) {
    crc ^= byte;
    for (let bit = 0; bit < 8; bit += 1) crc = (crc >>> 1) ^ ((crc & 1) ? 0x82f63b78 : 0);
  }
  return (~crc) >>> 0;
}

export function commitLine(position, entry, { started = false, at = new Date().toISOString() } = {}) {
  const facts = started
    ? [{ type: "session.started", data: {} }]
    : [{ type: "libfx.record", data: {} }];
  const base = {
    v: 3,
    seq: position + 1,
    ts: Date.parse(at),
    kind: "commit",
    pos: position,
    facts,
    private: [{ kind: "model_context", data: entry }],
  };
  const payload = JSON.stringify(base).slice(0, -1);
  return { ...base, crc: crc32c(payload).toString(16).padStart(8, "0") };
}

export function withCommit(entry, position) {
  if (entry?.v27?.v === 3) return entry;
  return { ...entry, v27: commitLine(position, entry, { started: position === 0 }) };
}

export function foldCommits(entries) {
  const view = { position: 0, records: [], started: false };
  for (const { entry } of entries) {
    const line = entry?.v27;
    if (line?.v !== 3 || line.kind !== "commit" || line.pos < view.position) continue;
    view.position = line.pos + 1;
    if (line.facts?.some((fact) => fact?.type === "session.started")) view.started = true;
    view.records.push(line.private?.[0]?.data ?? null);
  }
  return view;
}
