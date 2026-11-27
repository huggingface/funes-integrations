// The extension loads in a compiled host, registers its tools, and lets an idle pi exit.
// Startup converts pending history before indexing or publishing. A failed MCP server disables
// recall without stopping indexing. Per turn, the extension converts the current session and
// sweeps the sessions root. The fake worker records its arguments, the spool it found and the
// directory it ran in.
//
//   node integrations/pi/test/startup.mjs    (run.sh and run.ps1 run it)
import assert from "node:assert/strict";
import { chmodSync, cpSync, existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { basename, delimiter, dirname, join } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { fakeFunes } from "./fake.mjs";

const HERE = dirname(fileURLToPath(import.meta.url));
const WINDOWS = process.platform === "win32";
delete process.env.FUNES_MEMORY;
delete process.env.HF_HUB_USER_AGENT_ORIGIN;

setTimeout(() => {
  console.error("pi startup: the idle extension keeps the event loop alive");
  process.exit(1);
}, 15_000).unref();

const roots = [];
function scratch(prefix) {
  const root = mkdtempSync(join(tmpdir(), prefix));
  roots.push(root);
  return root;
}
// A stand-in still running on Windows holds its files; what it leaves, the temporary directory
// keeps.
process.on("exit", () => {
  for (const root of roots) {
    try {
      rmSync(root, { recursive: true, force: true });
    } catch (error) {
      if (!WINDOWS) throw error;
    }
  }
});

// The worker runs on the runtime pi runs on, through no shell: an `sh` and a `bash` that fail prove
// nothing is spawned through either. Windows runs neither by its first line.
const shims = scratch("funes-pi-shims-");
if (!WINDOWS) {
  for (const shell of ["sh", "bash"]) {
    writeFileSync(join(shims, shell), "#!/bin/sh\nexit 127\n");
    chmodSync(join(shims, shell), 0o755);
  }
  process.env.PATH = `${shims}${delimiter}${process.env.PATH}`;
}

// An import can ignore a virtual argv[1], while other filesystem failures must be reported. Windows
// makes a symbolic link only for an administrator or in developer mode.
const loop = join(shims, "loop");
let looped = true;
try {
  symlinkSync("loop", loop);
} catch (error) {
  if (!WINDOWS || error.code !== "EPERM") throw error;
  looped = false;
}
if (looped) {
  process.argv[1] = loop;
  await assert.rejects(import(pathToFileURL(join(HERE, "..", "convert.mjs")).href), { code: "ELOOP" });
}
process.argv[1] = "/$bunfs/root/pi";

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

// A session written now, under `dir`: a copy would keep the fixture's stamp, and the sweep goes by
// stamps.
function session(dir, name) {
  mkdirSync(dir, { recursive: true });
  const file = join(dir, name);
  writeFileSync(file, readFileSync(join(HERE, "session.jsonl")));
  return file;
}

// The extension as installed under `root`: its files, the records `setup` writes beside them, and
// a worker that records what it was launched for, what the spool held when it started and where it
// ran.
function install(root, { memory = "", pending = false } = {}) {
  const ext = join(root, "ext");
  mkdirSync(join(ext, "scripts"), { recursive: true });
  for (const name of ["index.ts", "convert.mjs"]) cpSync(join(HERE, "..", name), join(ext, name));
  // This import wrapper works under Node, Bun and Deno. Bun's stdin has no unref.
  const index = join(ext, "index.ts");
  const source = readFileSync(index, "utf8");
  const wrapped = source.replace('from "node:child_process"', 'from "./child-process.mjs"');
  assert.notEqual(wrapped, source, "the extension's spawn import was not wrapped");
  writeFileSync(index, wrapped);
  writeFileSync(join(ext, "child-process.mjs"), `
import { spawn as realSpawn } from "node:child_process";
import { EventEmitter } from "node:events";
export function spawn(command, ...args) {
  if (/[\\\\/]no-pipes$/.test(command)) {
    const child = new EventEmitter();
    queueMicrotask(() => child.emit("error", new Error("spawn EMFILE")));
    return child;
  }
  const child = realSpawn(command, ...args);
  if (child.stdin) Object.defineProperty(child.stdin, "unref", { value: undefined });
  return child;
}
`);
  const sessions = join(root, "sessions");
  mkdirSync(sessions, { recursive: true });
  const spool = join(root, "spool");
  mkdirSync(spool);
  writeFileSync(join(ext, "spool"), `${spool}\n`);
  // On Windows the root is recorded in upper case, as a path the extension sees in lower case still
  // falls under it.
  writeFileSync(join(ext, "sessions"), `${WINDOWS ? sessions.toUpperCase() : sessions}\n`);
  if (pending) writeFileSync(join(ext, "seed-pending"), `${sessions}\n`);
  if (memory) writeFileSync(join(ext, "memory"), `${memory}\n`);
  // The package pi lends its extensions, for the version funes names.
  const pkg = join(root, "node_modules", "@mariozechner", "pi-coding-agent");
  mkdirSync(pkg, { recursive: true });
  writeFileSync(join(pkg, "package.json"), '{"name":"@mariozechner/pi-coding-agent","type":"module","main":"index.js"}');
  writeFileSync(join(pkg, "index.js"), 'export const VERSION = "9.9.9";\n');
  const log = join(root, "worker.log");
  writeFileSync(join(ext, "scripts", "funes-index.mjs"), `
import { readdirSync, renameSync, writeFileSync } from "node:fs";
const log = ${JSON.stringify(log)};
writeFileSync(log + ".agent", process.env.HF_HUB_USER_AGENT_ORIGIN ?? "");
writeFileSync(log + ".cwd", process.cwd());
const args = process.argv.slice(2);
const lines = ["funes-index.mjs" + (args.length ? " " + args.join(" ") : ""), ...readdirSync(${JSON.stringify(spool)}).sort()];
writeFileSync(log + ".tmp", lines.join("\\n") + "\\n");
renameSync(log + ".tmp", log);
`);
  return { ext, sessions, spool, log };
}

// Load the installed extension with a fake pi, returning its handlers by event.
async function activate(ext) {
  const handlers = {};
  const tools = [];
  const pi = { registerTool(tool) { tools.push(tool); }, on(name, fn) { handlers[name] = fn; } };
  const { default: activate } = await import(pathToFileURL(join(ext, "index.ts")).href);
  await activate(pi);
  return { ...handlers, tools };
}

async function workerLog(log, what) {
  const deadline = Date.now() + 10_000;
  while (!existsSync(log)) {
    if (Date.now() > deadline) throw new Error(`no worker ran for ${what}`);
    await sleep(50);
  }
  return readFileSync(log, "utf8");
}

// One tool, with a reply to a call; with `agent`, the origin it was started with goes into the file
// `agent` beside it. A different body can fail during the handshake.
function mcpServer({ agent = false } = {}) {
  return `
import { writeFileSync } from "node:fs";
import { createInterface } from "node:readline";
import { fileURLToPath } from "node:url";
${agent ? 'writeFileSync(fileURLToPath(new URL("agent", import.meta.url)), process.env.HF_HUB_USER_AGENT_ORIGIN ?? "");' : ""}
for await (const line of createInterface({ input: process.stdin })) {
  let message;
  try { message = JSON.parse(line); } catch { continue; }
  if (typeof message.id !== "number") continue;
  const result = message.method === "tools/list" ? { tools: [{ name: "recall", inputSchema: { type: "object" } }] }
    : message.method === "tools/call" ? { content: [{ type: "text", text: "past answer" }] } : {};
  process.stdout.write(JSON.stringify({ jsonrpc: "2.0", id: message.id, result }) + "\\n");
}
`;
}
// Echoes the handshake back and exits: the next request meets a closed pipe.
const DYING = `
import { createInterface } from "node:readline";
for await (const line of createInterface({ input: process.stdin })) { process.stdout.write(line + "\\n"); break; }
process.exit(0);
`;

async function startup(memory, { body = mcpServer(), missing = "" } = {}) {
  const root = scratch("funes-pi-startup-");
  process.env.FUNES_BIN = missing ? join(root, missing) : fakeFunes(root, body);
  const { ext, sessions, log } = install(root, { memory, pending: true });
  // pi's layout: one directory per project under the sessions root.
  session(join(sessions, "--Users-me-repo--"), "session.jsonl");

  const handlers = await activate(ext);
  const notices = [];
  await handlers.session_start({ reason: "startup" }, { ui: { notify: (text) => notices.push(text) } });

  if (existsSync(join(ext, "seed-pending"))) throw new Error("the pending history was not converted");
  return { root, ext, log: await workerLog(log, memory || "the local memory"), notices, tools: handlers.tools };
}

// A turn of the session at `file`, with `stale` written since the last sweep and `foreign` a
// `.jsonl` no sweep may touch: what the spool holds afterwards, and what the worker was handed.
async function turn(root, file, stale, foreign, memory = "") {
  const { ext, spool, log } = install(root, { memory });
  process.env.FUNES_BIN = fakeFunes(root, mcpServer());
  const handlers = await activate(ext);
  // The records are older than the sessions, so the sweep sees the sessions as new.
  await sleep(20);
  const named = session(dirname(file), basename(file));
  const others = [session(dirname(stale), basename(stale)), session(dirname(foreign), basename(foreign))];
  // pi names the session file in its own spelling, which on Windows is not the one `setup`
  // recorded the root in.
  const reported = WINDOWS ? named.toLowerCase() : named;
  await handlers.turn_end({}, { sessionManager: { getSessionFile: () => reported } });
  const worker = (await workerLog(log, "the turn")).split("\n")[0];
  const converted = (p) => existsSync(join(spool, `${basename(p).replace(/\.jsonl$/i, "")}.funes.jsonl`));
  return { named: converted(named), stale: converted(others[0]), foreign: converted(others[1]), swept: existsSync(join(ext, "swept")), worker };
}

// The `funes mcp` it spawns, and the worker, name funes, pi and its version in their Hub requests.
const local = await startup("", { body: mcpServer({ agent: true }) });
if (local.tools.map((tool) => tool.name).join() !== "recall") {
  throw new Error(`expected recall registered, got: ${local.tools.map((tool) => tool.name)}`);
}
const reply = await local.tools[0].execute("test", {});
if (reply.content[0].text !== "past answer") throw new Error(`unexpected tool reply: ${JSON.stringify(reply)}`);
for (const [who, file] of [["funes mcp", join(local.root, "agent")], ["the worker", join(local.root, "worker.log.agent")]]) {
  const agent = readFileSync(file, "utf8");
  const want = "funes; agent/pi; agent_version/9.9.9";
  if (agent !== want) throw new Error(`${who}: expected ${want}, got ${JSON.stringify(agent)}`);
}
if (local.log !== "funes-index.mjs\nsession.funes.jsonl\n") {
  throw new Error(`local memory: expected the index worker to find the seeded session, got:\n${local.log}`);
}
// The worker runs in its own directory, so its runtime reads no configuration of the project's.
const cwd = readFileSync(join(local.root, "worker.log.cwd"), "utf8");
if (cwd.toLowerCase() !== join(local.ext, "scripts").toLowerCase()) throw new Error(`the worker ran in ${cwd}`);
if (local.notices.length) throw new Error(`local memory: unexpected notices: ${local.notices}`);
const bound = await startup("acme/kb");
if (bound.log !== "funes-index.mjs --publish acme/kb\nsession.funes.jsonl\n") {
  throw new Error(`memory bound: expected the publish worker to find the seeded session, got:\n${bound.log}`);
}
// A funes that answers the handshake and exits: the next request meets a closed pipe. The
// extension still loads, indexes what it can, and says recall is unavailable.
const dying = await startup("", { body: DYING });
if (dying.log !== "funes-index.mjs\nsession.funes.jsonl\n") {
  throw new Error(`dying funes: expected the index worker all the same, got:\n${dying.log}`);
}
if (!dying.notices.some((text) => text.startsWith("funes recall is unavailable"))) {
  throw new Error(`dying funes: expected the start to say recall is unavailable, got: ${dying.notices}`);
}
for (const [missing, error] of [["missing-funes", "ENOENT"], ["no-pipes", "EMFILE"]]) {
  const failed = await startup("", { missing });
  if (failed.tools.length || !failed.notices.some((text) => text.includes(error))) {
    throw new Error(`${missing}: expected recall unavailable with ${error}, got: ${JSON.stringify(failed)}`);
  }
  if (failed.log !== "funes-index.mjs\nsession.funes.jsonl\n") {
    throw new Error(`${missing}: the pending history was not indexed: ${failed.log}`);
  }
}

// Per turn, under pi's own root: the session that spoke and the one another project wrote since
// the last sweep, and never a file beside the root.
{
  const root = scratch("funes-pi-turn-");
  const sessions = join(root, "sessions");
  const got = await turn(root, join(sessions, "--Users-me-repo--", "a.jsonl"), join(sessions, "--Users-me-other--", "b.jsonl"), join(root, "beside", "x.jsonl"));
  if (!got.named || !got.stale) throw new Error(`under the root: expected both sessions converted, got ${JSON.stringify(got)}`);
  if (got.foreign) throw new Error("under the root: a file beside the root was converted");
  if (!got.swept) throw new Error("under the root: the sweep left no mark");
  if (got.worker !== "funes-index.mjs") throw new Error(`under the root: expected the index worker, got ${got.worker}`);
}
// With a memory bound, the turn's worker is handed it, to push once the last push is old enough.
{
  const root = scratch("funes-pi-turn-");
  const sessions = join(root, "sessions");
  const got = await turn(root, join(sessions, "--Users-me-repo--", "a.jsonl"), join(sessions, "--Users-me-other--", "b.jsonl"), join(root, "beside", "x.jsonl"), "acme/kb");
  if (got.worker !== "funes-index.mjs acme/kb") throw new Error(`memory bound: expected the turn's worker handed the memory, got ${got.worker}`);
}
// A session pi was pointed elsewhere (`--session-dir`) sits in that directory with no directory
// per project: its own directory is swept, and nothing above it.
{
  const root = scratch("funes-pi-turn-");
  const custom = join(root, "custom");
  const got = await turn(root, join(custom, "a.jsonl"), join(custom, "b.jsonl"), join(root, "other", "x.jsonl"));
  if (!got.named || !got.stale) throw new Error(`elsewhere: expected both sessions converted, got ${JSON.stringify(got)}`);
  if (got.foreign) throw new Error("elsewhere: a file above the session's directory was converted");
}
