// pi's automation: advance funes's index over this agent's spool and, at a session boundary,
// publish it. The extension converts each turn itself, then starts this worker detached on the JS
// runtime pi runs on, so the work needs no shell, on any platform, and nothing here waits on a hook.
//
//   funes-index.mjs [MEMORY]            per turn: index and, if that went through, push to MEMORY
//                                       once the last push is `PUSH_EVERY_MS` old
//   funes-index.mjs --publish [MEMORY]  at a boundary: index, waiting out a per-turn run that still
//                                       holds the memory lock, then push to MEMORY
//
// No locking: `funes` serializes local-memory writes itself. A per-turn run that loses the lock
// exits non-zero and is logged, and the next turn re-sweeps the same content (indexing is
// idempotent).
import { spawn } from "node:child_process";
import { accessSync, appendFileSync, constants, statSync, utimesSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { delimiter, dirname, isAbsolute, join } from "node:path";
import { fileURLToPath } from "node:url";

const HERE = dirname(fileURLToPath(import.meta.url));
const LOG = join(HERE, "funes-sync.log");
// When the last push after a successful index started.
const PUSHED = join(HERE, "pushed");
const HARNESS = "pi";
// How old the last push gets before a turn pushes too. A push compacts the remote once enough rows
// sit unindexed there, so many small pushes compact it more often than a few large ones.
const PUSH_EVERY_MS = 60 * 60 * 1000;

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

// The local time and its UTC offset, as every bundle's log stamps its lines.
function now() {
  const date = new Date();
  const pad = (n) => String(n).padStart(2, "0");
  const offset = -date.getTimezoneOffset();
  const zone = `${offset < 0 ? "-" : "+"}${pad(Math.floor(Math.abs(offset) / 60))}${pad(Math.abs(offset) % 60)}`;
  return `${date.getFullYear()}-${pad(date.getMonth() + 1)}-${pad(date.getDate())}T${pad(date.getHours())}:${pad(date.getMinutes())}:${pad(date.getSeconds())}${zone}`;
}

function log(message) {
  try {
    appendFileSync(LOG, `${now()} ${message}\n`);
  } catch {}
}

function executable(path) {
  try {
    accessSync(path, constants.X_OK);
    return statSync(path).isFile();
  } catch {
    return false;
  }
}

// FUNES_BIN, else the first funes on PATH, else one in a common install directory (an agent can run
// with a minimal PATH, e.g. launched from an IDE). A PATH entry that is not absolute names a
// directory of the project pi runs in, so it is skipped.
function findFunes() {
  if (process.env.FUNES_BIN) return process.env.FUNES_BIN;
  const windows = process.platform === "win32";
  const home = homedir();
  const dirs = (process.env.PATH ?? "").split(delimiter).filter((dir) => isAbsolute(dir));
  dirs.push(join(home, ".local", "bin"));
  if (!windows) dirs.push("/opt/homebrew/bin", "/usr/local/bin", join(home, "go", "bin"), "/usr/bin", "/bin");
  return dirs.map((dir) => join(dir, windows ? "funes.exe" : "funes")).find(executable);
}

const FUNES = findFunes();

// Run funes, its output appended to the log. Settles on its exit code, or on why it did not start.
function funes(...args) {
  return new Promise((resolve) => {
    try {
      const child = spawn(FUNES, args, { stdio: ["ignore", "pipe", "pipe"], windowsHide: true });
      const keep = (chunk) => {
        try {
          appendFileSync(LOG, chunk);
        } catch {}
      };
      child.stdout?.on("data", keep);
      child.stderr?.on("data", keep);
      child.on("error", (error) => resolve(error.code ?? error.message));
      child.on("close", (code, signal) => resolve(code ?? signal));
    } catch (error) {
      resolve(error.code ?? error.message);
    }
  });
}

async function index() {
  log(`index[${HARNESS}]: start`);
  const code = await funes("index", "--harness", HARNESS);
  log(code === 0 ? `index[${HARNESS}]: ok` : `index[${HARNESS}]: FAILED (exit ${code})`);
  return code === 0;
}

// Push what the local memory holds to `memory`. A first push to a memory this index shares no
// chunks with is refused off a terminal. funes does it once, interactively, when it binds the
// memory.
async function push(memory) {
  log(`push: start (${memory})`);
  const code = await funes("push", memory);
  if (code === 0) log("push: ok");
  else if (code === 2) log("push: WARN — secrets held back; run `funes scrub`, then it publishes next run");
  else log(`push: FAILED (exit ${code})`);
}

// Mark a push as started now.
function stamp() {
  const time = new Date();
  writeFileSync(PUSHED, "");
  utimesSync(PUSHED, time, time);
}

function pushedRecently() {
  try {
    return Date.now() - statSync(PUSHED).mtimeMs < PUSH_EVERY_MS;
  } catch {
    return false;
  }
}

// A push after an index that never went through misses the last turns, so it leaves the `pushed`
// stamp as it was, and the next turn that indexes pushes them.
async function publish(memory) {
  let indexed = false;
  for (let attempt = 1; attempt <= 5; attempt++) {
    if ((await funes("index", "--harness", HARNESS)) === 0) {
      log(`index[${HARNESS}]: ok (before push)`);
      indexed = true;
      break;
    }
    log(`index[${HARNESS}]: busy or failed, retry ${attempt}`);
    await sleep(2000);
  }
  if (!memory) {
    log("push: skipped (no memory bound)");
    return;
  }
  if (indexed) stamp();
  await push(memory);
}

// A session can stop without its end firing (a process killed, a host disconnected), so a turn
// publishes too, once the last push is `PUSH_EVERY_MS` old. Not after a failed index: that push
// would miss the turn, and its stamp would hold the turn back `PUSH_EVERY_MS` more. The stamp says
// when the last push after a successful index started, whatever the push's outcome, so a failed
// push waits `PUSH_EVERY_MS` rather than retrying at every turn. Runs side by side may both push:
// funes lets one through and the other steps aside.
async function turn(memory) {
  if (!(await index()) || !memory || pushedRecently()) return;
  stamp();
  await push(memory);
}

if (!FUNES) log("index ABORT: funes not found; skipping.");
else if (process.argv[2] === "--publish") await publish(process.argv[3]);
else await turn(process.argv[2]);
