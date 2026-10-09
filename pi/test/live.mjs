// `convertLive` over sessions as pi writes them, and as it does not: at every step it must write the
// turns file `convert` writes for the same bytes.
//
// The test session is grown a byte at a time, so a step ends mid-line and mid-character; those in
// awkward-input/ in strides; one is rewritten under the same name; and one has its session header
// after a turn, whose cwd then belongs on the turn already written.
//
// Usage: live.mjs <work-dir>; exits 1 at the first step that differs.
import { mkdirSync, readFileSync, readdirSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { convert, convertLive } from "../convert.mjs";

const [work] = process.argv.slice(2);
const here = dirname(fileURLToPath(import.meta.url));
mkdirSync(work, { recursive: true });
const session = join(work, "live.jsonl");

function step(bytes, what) {
  writeFileSync(session, bytes);
  const live = readFileSync(convertLive(session, join(work, "live")));
  const full = readFileSync(convert(session, join(work, "full")));
  if (!live.equals(full)) {
    console.error(`pi converter, live: ${what} — not what a whole conversion writes`);
    process.exit(1);
  }
}

function grow(bytes, stride, what) {
  for (let end = 0; end <= bytes.length; end += stride) step(bytes.subarray(0, end), `${what}, ${end} bytes in`);
  step(bytes, `${what}, whole`);
}

const test = Buffer.concat([
  readFileSync(join(here, "session.jsonl")),
  Buffer.from(`{"type":"message","id":"u2","timestamp":"t","message":{"role":"user","content":[{"type":"text","text":"café — ✓"}]}}\n`),
]);
grow(test, 1, "the test session");

const awkward = join(here, "awkward-input");
for (const name of readdirSync(awkward).filter((n) => n.endsWith(".jsonl") && !n.endsWith(".funes.jsonl"))) {
  grow(readFileSync(join(awkward, name)), 61, `awkward-input/${name}`);
}

// Rewritten under the same name: shorter, then the same length with other bytes.
step(test.subarray(0, test.length >> 1), "the test session cut short");
step(Buffer.from(test.toString("latin1").replace(/how/g, "HOW"), "latin1"), "the test session rewritten");

const turn = (id) => `{"type":"message","id":"${id}","timestamp":"t","message":{"role":"user","content":[{"type":"text","text":"hi"}]}}\n`;
grow(Buffer.from(turn("a") + `{"type":"session","cwd":"/late"}\n` + turn("b")), 1, "a session header after a turn");
