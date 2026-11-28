// The extension loads in a compiled host, registers its tools, and lets an idle pi exit.
// Startup converts pending history before indexing or publishing. A failed MCP server disables
// recall without stopping indexing. Per turn, the extension converts the current session and
// sweeps the sessions root. The fake worker records its arguments and the spool it found.
//
//   node integrations/pi/test/startup.mjs    (run.sh runs it)
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { chmodSync, cpSync, existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { basename, delimiter, dirname, isAbsolute, join } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const HERE = dirname(fileURLToPath(import.meta.url));
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
// The `funes mcp` servers the extension started live until this process ends, and Windows will not
// delete a program that runs, so there what they hold is left to the temporary directory's owner.
process.on("exit", () => {
  for (const root of roots) {
    try {
      rmSync(root, { recursive: true, force: true });
    } catch (e) {
      if (process.platform !== "win32") throw e;
    }
  }
});

// Only `sh` is promised on a box running pi: a `bash` that fails proves nothing is spawned
// through it.
const shims = scratch("funes-pi-shims-");
writeFileSync(join(shims, "bash"), "#!/bin/sh\nexit 127\n");
chmodSync(join(shims, "bash"), 0o755);
process.env.PATH = `${shims}${delimiter}${process.env.PATH}`;

// An import can ignore a virtual argv[1], while other filesystem failures must be reported. The
// failure is a link to itself, which Windows lets only an administrator, or Developer Mode, make.
const loop = join(shims, "loop");
let linked = true;
try {
  symlinkSync("loop", loop);
} catch (e) {
  if (e.code !== "EPERM") throw e;
  linked = false;
  console.error("pi startup: no symlink to fail an import with on this box; skipping that check");
}
if (linked) {
  process.argv[1] = loop;
  await assert.rejects(import(pathToFileURL(join(HERE, "..", "convert.mjs")).href), { code: "ELOOP" });
}
process.argv[1] = "/$bunfs/root/pi";

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

// A session written now, under `dir`: `cp` would keep the fixture's stamp, and the sweep goes by
// stamps.
function session(dir, name) {
  mkdirSync(dir, { recursive: true });
  const file = join(dir, name);
  writeFileSync(file, readFileSync(join(HERE, "session.jsonl")));
  return file;
}

// The extension as installed under `root`: its files, the records `setup` writes beside them, and
// a worker script that records what it was launched for and what the spool held when it started.
// The sessions root is recorded as `recorded` spells it, when given.
function install(root, { memory = "", pending = false, recorded = "" } = {}) {
  const ext = join(root, "ext");
  mkdirSync(join(ext, "scripts"), { recursive: true });
  for (const name of ["index.ts", "convert.mjs"]) cpSync(join(HERE, "..", name), join(ext, name));
  // This import wrapper works under Node, Bun and Deno. Bun's stdin has no unref.
  const index = join(ext, "index.ts");
  const source = readFileSync(index, "utf8");
  const wrapped = source.replace('from "node:child_process"', 'from "./child-process.mjs"');
  assert.notEqual(wrapped, source, "the extension's spawn import was not wrapped");
  writeFileSync(index, wrapped);
  // It records each command it is handed, when the test names a file to record them in.
  writeFileSync(join(ext, "child-process.mjs"), `
import { spawn as realSpawn } from "node:child_process";
import { EventEmitter } from "node:events";
import { appendFileSync } from "node:fs";
export function spawn(command, ...args) {
  if (process.env.FUNES_TEST_SPAWNED) appendFileSync(process.env.FUNES_TEST_SPAWNED, command + "\\n");
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
  writeFileSync(join(ext, "sessions"), `${recorded || sessions}\n`);
  if (pending) writeFileSync(join(ext, "seed-pending"), `${sessions}\n`);
  if (memory) writeFileSync(join(ext, "memory"), `${memory}\n`);
  // The package pi lends its extensions, for the version funes names.
  const pkg = join(root, "node_modules", "@mariozechner", "pi-coding-agent");
  mkdirSync(pkg, { recursive: true });
  writeFileSync(join(pkg, "package.json"), '{"name":"@mariozechner/pi-coding-agent","type":"module","main":"index.js"}');
  writeFileSync(join(pkg, "index.js"), 'export const VERSION = "9.9.9";\n');
  const log = join(root, "worker.log");
  const script = join(ext, "scripts", "funes-index.sh");
  writeFileSync(script, `#!/bin/sh\nprintf '%s' "$HF_HUB_USER_AGENT_ORIGIN" >"${log}.agent"\n{ printf 'funes-index.sh%s\\n' "${"${*:+ $*}"}"; ls "${spool}"; } >"${log}.tmp" && mv "${log}.tmp" "${log}"\n`);
  chmodSync(script, 0o755);
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

// One tool, with a reply to a call. A different body can fail during the handshake.
const MCP_SERVER = `
while IFS= read -r line; do
  id=$(printf '%s' "$line" | sed -n 's/.*"id":\\([0-9][0-9]*\\).*/\\1/p')
  [ -n "$id" ] || continue
  case $line in
  *'"tools/list"'*) result='{"tools":[{"name":"recall","inputSchema":{"type":"object"}}]}' ;;
  *'"tools/call"'*) result='{"content":[{"type":"text","text":"past answer"}]}' ;;
  *) result='{}' ;;
  esac
  printf '{"jsonrpc":"2.0","id":%s,"result":%s}\\n' "$id" "$result"
done`;

// Windows runs no script by its first line, so a fake `funes` there is a launcher beside the script:
// one program, built once with the C# compiler every Windows ships, that runs the script named as
// itself less `.exe` through `sh`, on the launcher's own standard streams.
const LAUNCHER = `
using System.Diagnostics;
public static class Launcher {
    public static int Main(string[] args) {
        string self = Process.GetCurrentProcess().MainModule.FileName;
        string line = "\\"" + self.Substring(0, self.Length - 4).Replace('\\\\', '/') + "\\"";
        foreach (string arg in args) line += " \\"" + arg.Replace("\\"", "\\\\\\"") + "\\"";
        ProcessStartInfo info = new ProcessStartInfo("sh", line);
        info.UseShellExecute = false;
        Process child = Process.Start(info);
        child.WaitForExit();
        return child.ExitCode;
    }
}`;
let launcher;
function windowsLauncher() {
  if (launcher) return launcher;
  launcher = join(scratch("funes-pi-launcher-"), "launcher.exe");
  execFileSync(
    "powershell.exe",
    ["-NoProfile", "-NonInteractive", "-Command", "Add-Type -OutputAssembly $env:FUNES_TEST_LAUNCHER -OutputType ConsoleApplication -TypeDefinition $env:FUNES_TEST_LAUNCHER_SOURCE"],
    { env: { ...process.env, FUNES_TEST_LAUNCHER: launcher, FUNES_TEST_LAUNCHER_SOURCE: LAUNCHER }, stdio: "inherit" },
  );
  return launcher;
}

function fakeFunes(root, body = MCP_SERVER) {
  const path = join(root, "funes");
  writeFileSync(path, `#!/bin/sh\n${body}\n`);
  chmodSync(path, 0o755);
  if (process.platform !== "win32") return path;
  cpSync(windowsLauncher(), `${path}.exe`);
  return `${path}.exe`;
}

async function startup(memory, { body = MCP_SERVER, missing = "" } = {}) {
  const root = scratch("funes-pi-startup-");
  process.env.FUNES_BIN = missing ? join(root, missing) : fakeFunes(root, body);
  const { ext, sessions, log } = install(root, { memory, pending: true });
  // pi's layout: one directory per project under the sessions root.
  session(join(sessions, "--Users-me-repo--"), "session.jsonl");

  const handlers = await activate(ext);
  const notices = [];
  await handlers.session_start({ reason: "startup" }, { ui: { notify: (text) => notices.push(text) } });

  if (existsSync(join(ext, "seed-pending"))) throw new Error("the pending history was not converted");
  return { root, log: await workerLog(log, memory || "the local memory"), notices, tools: handlers.tools };
}

// A turn of the session at `file`, with `stale` written since the last sweep and `foreign` a
// `.jsonl` no sweep may touch: what the spool holds afterwards, and what the worker was handed.
async function turn(root, file, stale, foreign, { memory = "", recorded = "" } = {}) {
  const { ext, spool, log } = install(root, { memory, recorded });
  process.env.FUNES_BIN = fakeFunes(root);
  const handlers = await activate(ext);
  // The records are older than the sessions, so the sweep sees the sessions as new.
  await sleep(20);
  const named = session(dirname(file), basename(file));
  const others = [session(dirname(stale), basename(stale)), session(dirname(foreign), basename(foreign))];
  await handlers.turn_end({}, { sessionManager: { getSessionFile: () => named } });
  const worker = (await workerLog(log, "the turn")).split("\n")[0];
  const converted = (p) => existsSync(join(spool, `${basename(p).replace(/\.jsonl$/, "")}.funes.jsonl`));
  return { named: converted(named), stale: converted(others[0]), foreign: converted(others[1]), swept: existsSync(join(ext, "swept")), worker };
}

// The `funes mcp` it spawns, and the worker, name funes, pi and its version in their Hub requests.
const local = await startup("", { body: `printf '%s' "$HF_HUB_USER_AGENT_ORIGIN" >"$(dirname "$0")/agent"; ${MCP_SERVER}` });
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
if (local.log !== "funes-index.sh\nsession.funes.jsonl\n") {
  throw new Error(`local memory: expected the index worker to find the seeded session, got:\n${local.log}`);
}
if (local.notices.length) throw new Error(`local memory: unexpected notices: ${local.notices}`);
const bound = await startup("acme/kb");
if (bound.log !== "funes-index.sh --publish acme/kb\nsession.funes.jsonl\n") {
  throw new Error(`memory bound: expected the publish worker to find the seeded session, got:\n${bound.log}`);
}
// A funes that answers the handshake and exits: the next request meets a closed pipe. The
// extension still loads, indexes what it can, and says recall is unavailable.
const dying = await startup("", { body: "exec head -n 1" });
if (dying.log !== "funes-index.sh\nsession.funes.jsonl\n") {
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
  if (failed.log !== "funes-index.sh\nsession.funes.jsonl\n") {
    throw new Error(`${missing}: the pending history was not indexed: ${failed.log}`);
  }
}

// Per turn, under pi's own root: the session that spoke and the one another project wrote since
// the last sweep, and never a file beside the root.
{
  const root = scratch("funes-pi-turn-");
  const sessions = join(root, "sessions");
  const got = await turn(root, join(sessions, "--Users-me-repo--/a.jsonl"), join(sessions, "--Users-me-other--/b.jsonl"), join(root, "beside/x.jsonl"));
  if (!got.named || !got.stale) throw new Error(`under the root: expected both sessions converted, got ${JSON.stringify(got)}`);
  if (got.foreign) throw new Error("under the root: a file beside the root was converted");
  if (!got.swept) throw new Error("under the root: the sweep left no mark");
  if (got.worker !== "funes-index.sh") throw new Error(`under the root: expected the index worker, got ${got.worker}`);
}
// With a memory bound, the turn's worker is handed it, to push once the last push is old enough.
{
  const root = scratch("funes-pi-turn-");
  const sessions = join(root, "sessions");
  const got = await turn(root, join(sessions, "--Users-me-repo--/a.jsonl"), join(sessions, "--Users-me-other--/b.jsonl"), join(root, "beside/x.jsonl"), { memory: "acme/kb" });
  if (got.worker !== "funes-index.sh acme/kb") throw new Error(`memory bound: expected the turn's worker handed the memory, got ${got.worker}`);
}
// A session pi was pointed elsewhere (`--session-dir`) sits in that directory with no directory
// per project: its own directory is swept, and nothing above it.
{
  const root = scratch("funes-pi-turn-");
  const custom = join(root, "custom");
  const got = await turn(root, join(custom, "a.jsonl"), join(custom, "b.jsonl"), join(root, "other/x.jsonl"));
  if (!got.named || !got.stale) throw new Error(`elsewhere: expected both sessions converted, got ${JSON.stringify(got)}`);
  if (got.foreign) throw new Error("elsewhere: a file above the session's directory was converted");
}
// On Windows, where a path's case is not its own, the root `setup` recorded in another case than pi
// names the session in is the same root: the sweep still walks all of it, and nothing beside it.
if (process.platform === "win32") {
  const root = scratch("funes-pi-turn-");
  const sessions = join(root, "sessions");
  const got = await turn(root, join(sessions, "--Users-me-repo--/a.jsonl"), join(sessions, "--Users-me-other--/b.jsonl"), join(root, "beside/x.jsonl"), { recorded: sessions.toUpperCase() });
  if (!got.named || !got.stale) throw new Error(`root in another case: expected both sessions converted, got ${JSON.stringify(got)}`);
  if (got.foreign) throw new Error("root in another case: a file beside the root was converted");
}
// On Windows the worker's shell comes from a directory PATH names in full, or from Git's install,
// never from the project pi runs in, which Windows searches first: not one in a directory PATH
// names relative to it. With no shell anywhere, no worker is started.
if (process.platform === "win32") {
  const project = join(scratch("funes-pi-project-"), "project");
  mkdirSync(join(project, "bin"), { recursive: true });
  writeFileSync(join(project, "bin", "sh.exe"), "");
  // A turn in the project, under `environment`, returning the commands the extension spawned and
  // its worker's log. The extension is loaded, and its fake funes started, before: the fake's
  // launcher looks `sh` up as Windows does, and would run into the planted one.
  async function turnInProject(environment) {
    const root = scratch("funes-pi-turn-");
    const { ext, log } = install(root);
    process.env.FUNES_BIN = fakeFunes(root);
    const handlers = await activate(ext);
    const named = session(join(root, "sessions", "--Users-me-repo--"), "a.jsonl");
    const spawned = join(root, "spawned");
    writeFileSync(spawned, "");
    const saved = { ...process.env };
    const cwd = process.cwd();
    process.env.FUNES_TEST_SPAWNED = spawned;
    // As Windows has it by default: a lookup by bare name searches the current directory first.
    delete process.env.NoDefaultCurrentDirectoryInExePath;
    Object.assign(process.env, environment);
    process.chdir(project);
    try {
      await handlers.turn_end({}, { sessionManager: { getSessionFile: () => named } });
    } finally {
      process.chdir(cwd);
      for (const name of Object.keys(process.env)) delete process.env[name];
      Object.assign(process.env, saved);
    }
    return { shells: readFileSync(spawned, "utf8").split("\n").filter(Boolean), log };
  }

  const planted = await turnInProject({ PATH: `bin${delimiter}${process.env.PATH}` });
  const taken = planted.shells.filter((shell) => !isAbsolute(shell) || shell.toLowerCase().startsWith(project.toLowerCase()));
  if (taken.length) throw new Error(`the worker's shell was taken from the project: ${taken}`);
  await workerLog(planted.log, "the turn in the project");

  const empty = scratch("funes-pi-empty-");
  const none = await turnInProject({ PATH: empty, ProgramFiles: empty, ProgramW6432: empty, LOCALAPPDATA: empty });
  if (none.shells.length) throw new Error(`with no shell anywhere, spawned ${none.shells}`);
}
