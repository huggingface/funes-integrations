#!/usr/bin/env node
// Convert a pi native session (`~/.pi/agent/sessions/<munged-cwd>/<stem>.jsonl`) into a funes
// turns file (`<stem>.funes.jsonl`, docs/funes-jsonl.md).
//
// Usage: convert.mjs <session.jsonl | sessions-root> <spool-dir>
//
// A sessions root is converted over every core, which is what `setup` runs on a whole history.
//
// Also a module — `convert` for one session, `convertTree` for a whole store, and `convertLive`
// for the session pi is writing, which the extension calls every turn and which converts only what
// the turn added — so a session converted mid-run and one converted in bulk go through the same
// mapping. It uses nothing but the JS runtime pi already provides.
//
// `session_id` is the session file's stem, not the id on its `session` line: the stem is what funes
// keyed pi's sessions by while it parsed them itself, and changing it would re-key every session a
// memory already holds.

import {
  readFileSync,
  writeFileSync,
  renameSync,
  mkdirSync,
  readdirSync,
  statSync,
  realpathSync,
  openSync,
  closeSync,
  fstatSync,
  futimesSync,
} from "node:fs";
import { basename, dirname, join } from "node:path";
import { pathToFileURL } from "node:url";
import * as buffer from "node:buffer";
import * as os from "node:os";
import { Worker, isMainThread, parentPort, threadId, workerData } from "node:worker_threads";

const HARNESS = "pi";
const FORMAT = 1;

// Unicode White_Space, which is what Rust's `str::trim` tests. JS's own `trim` differs on two code
// points — it trims U+FEFF and does not trim U+0085 — and a block is kept or dropped on this test.
const WS = "\\t\\n\\v\\f\\r \\u0085\\u00a0\\u1680\\u2000-\\u200a\\u2028\\u2029\\u202f\\u205f\\u3000";
const BLANK = new RegExp(`^[${WS}]*$`);
const TRIM = new RegExp(`^[${WS}]+|[${WS}]+$`, "g");
const isBlank = (s) => BLANK.test(s);
const rustTrim = (s) => s.replace(TRIM, "");
// The same set by code point, so a line is handed to TRIM only when an end of it is whitespace: the
// regex tries its second branch at every position, and a session line can run to megabytes.
const isWs = (c) =>
  c === 32 ||
  (c >= 9 && c <= 13) ||
  (c >= 0x85 &&
    (c === 0x85 || c === 0xa0 || c === 0x1680 || (c >= 0x2000 && c <= 0x200a) ||
      c === 0x2028 || c === 0x2029 || c === 0x202f || c === 0x205f || c === 0x3000));

// An unpaired surrogate, which only a `\uD800`-`\uDFFF` escape can introduce. serde_json rejects
// such a line outright and funes drops it; JSON.parse accepts it.
const LONE = /[\uD800-\uDBFF](?![\uDC00-\uDFFF])|(?<![\uD800-\uDBFF])[\uDC00-\uDFFF]/;
// Whether a raw line holds a `\u` escape starting with `d`/`D`, the only way one gets in. A scan
// by `indexOf` rather than a regex, which costs more than the parse on a long line.
function maybeLone(line) {
  for (let i = line.indexOf("\\u"); i !== -1; i = line.indexOf("\\u", i + 2)) {
    const c = line.charCodeAt(i + 2);
    if (c === 100 || c === 68) return true;
  }
  return false;
}

function hasLoneSurrogate(v) {
  if (typeof v === "string") return LONE.test(v);
  if (Array.isArray(v)) return v.some(hasLoneSurrogate);
  if (v && typeof v === "object") {
    return Object.keys(v).some((k) => LONE.test(k) || hasLoneSurrogate(v[k]));
  }
  return false;
}

const isObject = (v) => typeof v === "object" && v !== null && !Array.isArray(v);
// `Value::as_str`: a string, else nothing.
const str = (v) => (typeof v === "string" ? v : undefined);

// A session that is valid UTF-8 is read as latin1, one char a byte, so its strings hold the UTF-8
// bytes of their text rather than the text: JSON.parse and JSON.stringify run several times faster
// on such one-byte strings, and the turns file is written back as latin1, the same bytes. That
// changes nothing written, because JSON.stringify escapes only `"`, `\`, control characters and
// lone surrogates, none of them past ASCII once read: each string's bytes come back out as they
// went in. What would break it is read as text instead, as before — a `\u` escape naming a
// character past ASCII (decoded, it is one char, not its bytes), and a line with a non-ASCII or
// whitespace end, where trimming must see whole characters.
const asBytes = (s) => buffer.Buffer.from(s, "utf8").toString("latin1");
const fromBytes = (s) => buffer.Buffer.from(s, "latin1").toString("utf8");

// Whether a `\u` escape names a character past ASCII. A backslash after an odd run of them is
// itself escaped, and the `u` after it a plain letter.
function hasWideEscape(text) {
  for (let i = text.indexOf("\\u"); i !== -1; i = text.indexOf("\\u", i + 2)) {
    const d = text.charCodeAt(i + 4);
    if (text.charCodeAt(i + 2) === 48 && text.charCodeAt(i + 3) === 48 && d >= 48 && d <= 55) continue;
    let run = 0;
    while (text.charCodeAt(i - run - 1) === 92) run++;
    if (run % 2 === 0) return true;
  }
  return false;
}

/** A file's bytes and its stat, through one open. */
function readSession(path) {
  const fd = openSync(path, "r");
  try {
    return { stat: fstatSync(fd), raw: readFileSync(fd) };
  } finally {
    closeSync(fd);
  }
}

/** Every parseable JSON object of a JSONL file's bytes, in file order
 * (`jsonl::read_jsonl_records`), and whether they hold bytes rather than text. */
function recordsOf(raw, asText) {
  if (!asText && typeof buffer.isUtf8 === "function" && buffer.isUtf8(raw)) {
    const text = raw.toString("latin1");
    const records = hasWideEscape(text) ? undefined : parseLines(text, true);
    if (records) return { records, bytes: true };
  }
  return { records: parseLines(raw.toString("utf8"), false), bytes: false };
}

// A file's records, or, held as bytes, nothing once a line has an end only text can trim.
function parseLines(text, bytes) {
  const records = [];
  for (let line of text.split("\n")) {
    if (line.endsWith("\r")) line = line.slice(0, -1); // Rust's `str::lines`
    if (line === "") continue;
    const first = line.charCodeAt(0);
    const last = line.charCodeAt(line.length - 1);
    if (bytes && (first >= 0x80 || last >= 0x80 || isWs(first) || isWs(last))) return undefined;
    if (isWs(first) || isWs(last)) {
      line = rustTrim(line);
      if (line === "") continue;
    }
    let value;
    try {
      value = JSON.parse(line);
    } catch {
      continue; // a partial trailing write
    }
    if (!bytes && maybeLone(line) && hasLoneSurrogate(value)) continue;
    records.push(value);
  }
  return records;
}

// Blank, for text held as bytes: whitespace past ASCII is several bytes, so it is decoded.
function isBlankBytes(t) {
  const i = t.search(/[^\t\n\v\f\r ]/);
  if (i === -1) return true;
  return t.charCodeAt(i) >= 0x80 && isBlank(fromBytes(t));
}

/** A `text`/`thinking` block, or nothing when the text is blank. */
function textLike(blockType, text, bytes) {
  return (bytes ? isBlankBytes(text) : isBlank(text)) ? undefined : { block_type: blockType, text };
}

/** A `toolCall` part as a tool_use block; `arguments` compacted, a missing one as `{}`. */
function toolUseBlock(part) {
  const block = {
    block_type: "tool_use",
    text: JSON.stringify("arguments" in part ? part.arguments : {}),
  };
  const name = str(part.name);
  if (name !== undefined) block.tool_name = name;
  const id = str(part.id);
  if (id !== undefined) block.tool_use_id = id;
  return block;
}

/** A tool result's `content` — a string, or a list of `{type:"text",text}` parts — as one string. */
function flattenToolResult(content) {
  if (typeof content === "string") return content;
  if (!Array.isArray(content)) return "";
  const parts = [];
  for (const c of content) {
    if (isObject(c)) {
      if (c.type === "text") parts.push(str(c.text) ?? "");
    } else if (typeof c === "string") {
      parts.push(c);
    }
  }
  return parts.join("\n");
}

function blocksOf(role, msg, bytes) {
  const content = Array.isArray(msg.content) ? msg.content : undefined;
  if (role === "user") {
    if (!content) return [];
    const blocks = [];
    for (const part of content) {
      if (!isObject(part) || part.type !== "text") continue;
      const b = textLike("text", str(part.text) ?? "", bytes);
      if (b) blocks.push(b);
    }
    return blocks;
  }
  if (role === "assistant") {
    if (!content) return [];
    const blocks = [];
    for (const part of content) {
      if (!isObject(part)) continue;
      if (part.type === "thinking") {
        const b = textLike("thinking", str(part.thinking) ?? "", bytes);
        if (b) blocks.push(b);
      } else if (part.type === "text") {
        const b = textLike("text", str(part.text) ?? "", bytes);
        if (b) blocks.push(b);
      } else if (part.type === "toolCall") {
        blocks.push(toolUseBlock(part));
      }
    }
    return blocks;
  }
  if (role === "toolResult") {
    const text = flattenToolResult(msg.content);
    if (bytes ? isBlankBytes(text) : isBlank(text)) return [];
    const block = { block_type: "tool_result", text };
    const name = str(msg.toolName);
    if (name !== undefined) block.tool_name = name;
    const id = str(msg.toolCallId);
    if (id !== undefined) block.tool_use_id = id;
    return [block];
  }
  return [];
}

/**
 * A record's `timestamp` as the format wants it. pi writes an ISO string; a pre-v2 session wrote
 * epoch milliseconds, which `.funes.jsonl` cannot carry as a number of digits — that line would
 * reject the whole file — so it is rendered as the instant it names.
 */
function timestamp(value) {
  if (typeof value === "string") return value;
  if (typeof value === "number" && Number.isFinite(value)) return new Date(value).toISOString();
  return "";
}

/** Where converting a session has got to, which a later part of it is converted from: its id and
 * cwd, as text, and how many turns are written. */
function start(sessionId) {
  return { id: sessionId, header: false, cwd: undefined, seq: 0 };
}

/** The turns-file bytes a span of a session's whole lines makes, converted from `at` and advancing
 * it; nothing when the span holds the session header and a turn is written already, which the
 * header's cwd belongs on. */
function convertBytes(raw, at) {
  // Text that is not well-formed has no bytes to hold it by.
  const { records, bytes } = recordsOf(raw, LONE.test(at.id) || LONE.test(at.cwd ?? ""));
  if (!at.header) {
    const header = records.find((r) => isObject(r) && r.type === "session");
    if (header) {
      if (at.seq > 0) return undefined;
      const cwd = str(header.cwd);
      at.header = true;
      at.cwd = bytes && cwd !== undefined ? fromBytes(cwd) : cwd;
    }
  }
  const id = bytes ? asBytes(at.id) : at.id;
  const cwd = bytes && at.cwd !== undefined ? asBytes(at.cwd) : at.cwd;

  let body = "";
  for (const record of records) {
    if (!isObject(record) || record.type !== "message") continue;
    const msg = record.message;
    if (!isObject(msg)) continue;
    const nativeRole = str(msg.role) ?? "";
    const blocks = blocksOf(nativeRole, msg, bytes);
    if (blocks.length === 0) continue;

    // Field order is the wire order of funes's own Turn.
    const turn = { format: FORMAT, session_id: id };
    if (cwd !== undefined) turn.cwd = cwd;
    turn.turn_uuid = str(record.id) ?? "";
    const parent = str(record.parentId);
    if (parent !== undefined) turn.parent_uuid = parent;
    turn.seq = at.seq++;
    turn.ts = timestamp(record.timestamp);
    turn.role = nativeRole === "toolResult" ? "tool" : nativeRole;
    turn.blocks = blocks;
    turn.harness = HARNESS;
    body += JSON.stringify(turn) + "\n";
  }
  return buffer.Buffer.from(body, bytes ? "latin1" : "utf8");
}

const stemOf = (sessionPath) => basename(sessionPath).replace(/\.jsonl$/, "");
const outFor = (outArg, stem) => (outArg.endsWith(".funes.jsonl") ? outArg : join(outArg, `${stem}.funes.jsonl`));

/** One session into `<spool>/<stem>.funes.jsonl`; returns the path written. */
export function convert(sessionPath, outArg) {
  const stem = stemOf(sessionPath);
  const { raw, stat } = readSession(sessionPath);
  return writeTurns(outFor(outArg, stem), convertBytes(raw, start(stem)), stat);
}

// The session pi is writing, as far as it is converted: its bytes through the last whole line, the
// turns-file bytes they make, a chunk a call, and where converting them got to.
let live;

/** Let go of the session `convertLive` holds: pi has ended it, or moved to one with no file. */
export function forgetLive() {
  live = undefined;
}

/** `convert` for the session pi is writing, which only grows: what it converts is the lines added
 * since the last call, while the turns file is still written whole, the same bytes `convert`
 * writes. A file whose start is not what was converted — another session, or this one rewritten —
 * is converted afresh. The session is held in memory for it, twice over: as read, and converted. */
export function convertLive(sessionPath, outArg) {
  const stem = stemOf(sessionPath);
  const { raw, stat } = readSession(sessionPath);
  const kept =
    live?.path === sessionPath &&
    raw.length >= live.read.length &&
    raw.compare(live.read, 0, live.read.length, 0, live.read.length) === 0;
  if (!kept) live = { path: sessionPath, read: raw.subarray(0, 0), turns: [], at: start(stem) };

  const end = raw.lastIndexOf(10) + 1;
  if (end > live.read.length) {
    const at = { ...live.at };
    const added = convertBytes(raw.subarray(live.read.length, end), at);
    if (added) live = { path: sessionPath, read: raw.subarray(0, end), turns: [...live.turns, added], at };
    else {
      const fresh = start(stem);
      const turns = [convertBytes(raw.subarray(0, end), fresh)];
      live = { path: sessionPath, read: raw.subarray(0, end), turns, at: fresh };
    }
  }
  // A last line without its newline may still be being written: converted for this file, not kept.
  let turns = live.turns;
  if (end < raw.length) {
    const tail = convertBytes(raw.subarray(end), { ...live.at });
    turns = tail ? [...turns, tail] : [convertBytes(raw, start(stem))];
  }
  return writeTurns(outFor(outArg, stem), buffer.Buffer.concat(turns), stat);
}

// The turns file at `out`, written atomically and stamped with the session's own time.
function writeTurns(out, turns, stat) {
  // The temporary name is not a `.jsonl` one, so a concurrent `funes index` over the spool never
  // lists it.
  const tmp = `${out}.tmp${process.pid}`;
  const fd = openCreating(tmp);
  try {
    writeFileSync(fd, turns);
    // Stamped with the session's own time, so funes drains the spool newest session first rather
    // than in the order the seed happened to convert them.
    futimesSync(fd, stat.atime, stat.mtime);
  } finally {
    closeSync(fd);
  }
  renameSync(tmp, out);
  return out;
}

// A file opened for writing, its directory made only when it is missing: a spool is there for every
// session but the first, and asking for it each time is two more calls per session.
function openCreating(path) {
  try {
    return openSync(path, "w");
  } catch (e) {
    if (e?.code !== "ENOENT") throw e;
    mkdirSync(dirname(path), { recursive: true });
    return openSync(path, "w");
  }
}

/** Every session under a `~/.pi/agent/sessions` tree into the spool — with `since` (epoch ms), only
 * those written after it, and never `except`. */
export function convertTree(root, spool, since = 0, except = "") {
  return convertEach(sessionsUnder(root, since, except), spool);
}

function sessionsUnder(root, since, except, found = []) {
  let entries;
  try {
    entries = readdirSync(root, { withFileTypes: true });
  } catch {
    return found; // a directory that cannot be listed holds no session of pi's
  }
  for (const entry of entries) {
    const p = join(root, entry.name);
    if (entry.isDirectory()) sessionsUnder(p, since, except, found);
    else if (entry.name.endsWith(".jsonl") && p !== except) {
      try {
        if (!since || statSync(p).mtimeMs > since) found.push(p);
      } catch {}
    }
  }
  return found;
}

// One session that cannot be read costs its own capture, not everyone else's: the next sweep meets
// it again if it changes.
function convertEach(paths, spool) {
  const written = [];
  for (const p of paths) {
    try {
      written.push(convert(p, spool));
    } catch {}
  }
  return written;
}

// A worker thread costs about what converting a few megabytes does: one is started for each this
// many bytes of the store past the first.
const THREAD_BYTES = 4 << 20;

/** `convertTree` over every core, for the bulk conversion of a whole store: parsing and serializing
 * are the cost, and both are per session. The sessions form one queue, largest first, that this
 * thread and its workers claim from through a shared counter, so a thread on a slow core takes
 * fewer sessions rather than holding back the run. Sessions that share a turns file are one entry,
 * converted in tree order as `convertTree` would, the last one's file kept.
 *
 * A worker starts as the sizing reaches its share of the store, so it boots while the rest is
 * sized, and a store too small for one starts none. Each entry records, in a shared slot, how many
 * of its sessions were written; an entry a worker claimed and never finished — it could not start,
 * or it died — is converted here once the workers are gone, so a runtime without worker threads
 * loses only the speed. Resolves to the number written and how many workers wrote any of it. */
export function convertTreeParallel(root, spool) {
  const paths = sessionsUnder(root, 0, "");
  const cores = (typeof os.availableParallelism === "function" ? os.availableParallelism() : os.cpus().length) || 1;
  const byOut = new Map();
  const workers = [];
  let bytes = 0;
  for (const p of paths) {
    const out = outFor(spool, stemOf(p));
    if (!byOut.has(out)) byOut.set(out, { paths: [], size: 0 });
    const entry = byOut.get(out);
    entry.paths.push(p);
    try {
      const size = statSync(p).size;
      entry.size += size;
      bytes += size;
    } catch {}
    if (workers.length < Math.min(cores, paths.length) - 1 && bytes > (workers.length + 1) * THREAD_BYTES) {
      try {
        workers.push(new Worker(new URL(import.meta.url), { workerData: { piConvert: true } }));
      } catch {}
    }
  }
  const queue = [...byOut.values()].sort((a, b) => b.size - a.size).map((e) => e.paths);

  // `next` is the queue's head; `written[i]` is 1 + how many of entry i's sessions were written, 0
  // until it is converted, and `by[i]` the thread that converted it.
  const work = {
    queue,
    spool,
    next: new Int32Array(new SharedArrayBuffer(4)),
    written: new Int32Array(new SharedArrayBuffer(4 * queue.length)),
    by: new Int32Array(new SharedArrayBuffer(4 * queue.length)),
  };
  const gone = workers.map(
    (worker) =>
      new Promise((resolve) => {
        worker.once("error", () => {});
        worker.once("exit", resolve);
        worker.postMessage(work);
      }),
  );
  drain(work);
  return Promise.all(gone).then(() => {
    let written = 0;
    const writers = new Set();
    for (let i = 0; i < queue.length; i++) {
      if (Atomics.load(work.written, i) === 0) convertEntry(work, i);
      written += Atomics.load(work.written, i) - 1;
      if (work.by[i] !== threadId) writers.add(work.by[i]);
    }
    return { written, workers: writers.size };
  });
}

// Convert entries off the shared queue until it is empty.
function drain(work) {
  for (let i = Atomics.add(work.next, 0, 1); i < work.queue.length; i = Atomics.add(work.next, 0, 1)) {
    convertEntry(work, i);
  }
}

function convertEntry(work, i) {
  const written = convertEach(work.queue[i], work.spool).length;
  Atomics.store(work.by, i, threadId);
  Atomics.store(work.written, i, written + 1);
}

if (!isMainThread && workerData?.piConvert) parentPort.once("message", drain);

// `import.meta.url` is the resolved path; argv[1] is not, so a run through a symlinked directory
// (macOS's /tmp) would otherwise miss.
if (isMainThread && process.argv[1] && import.meta.url === pathToFileURL(realpathSync(process.argv[1])).href) {
  const [src, spool] = process.argv.slice(2);
  if (!src || !spool) {
    console.error("usage: convert.mjs <session.jsonl | sessions-root> <spool-dir>");
    process.exit(2);
  }
  if (statSync(src).isDirectory()) convertTreeParallel(src, spool).then(({ written }) => console.log(written));
  else console.log([convert(src, spool)].length);
}
