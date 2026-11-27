// The automation worker, run as the extension runs it, on every platform: a turn indexes and,
// handed a memory, pushes once the last push is an hour old, and a boundary indexes then pushes.
// Against a `funes` that only records what it is asked.
//
//   node pi/test/index.mjs    (run.sh and run.ps1 run it)
import { spawnSync } from "node:child_process";
import { cpSync, existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, utimesSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { delimiter, dirname, join, sep } from "node:path";
import { fileURLToPath } from "node:url";
import { fakeFunes, runtimeArgs } from "./fake.mjs";

const HERE = dirname(fileURLToPath(import.meta.url));
const root = mkdtempSync(join(tmpdir(), "funes-pi-index-"));
process.on("exit", () => rmSync(root, { recursive: true, force: true }));

function fail(message) {
  console.error(`pi index: ${message}`);
  process.exit(1);
}

const bin = join(root, "bin");
const scripts = join(root, "scripts");
const home = join(root, "home");
for (const dir of [bin, scripts, home]) mkdirSync(dir, { recursive: true });
const worker = join(scripts, "funes-index.mjs");
cpSync(join(HERE, "..", "scripts", "funes-index.mjs"), worker);
const cli = join(root, "cli.log");
const sync = join(scripts, "funes-sync.log");
const pushed = join(scripts, "pushed");

// Records what it is asked, says something of its own for the log, and finds the memory busy, as
// funes reports it, while the test says so.
const RECORDER = `
import { appendFileSync, existsSync } from "node:fs";
const log = process.env.FUNES_TEST_CLI_LOG;
const args = process.argv.slice(2);
appendFileSync(log, (process.env.FUNES_TEST_NAME ?? "") + args.join(" ") + "\\n");
process.stdout.write("said by funes\\n");
if (args[0] === "index" && existsSync(log + ".busy")) process.exit(75);
`;
fakeFunes(bin, RECORDER);

// The worker, as the extension starts it: on this runtime, in its own directory.
function run(args, env = {}) {
  const base = { ...process.env, PATH: bin, HOME: home, USERPROFILE: home, FUNES_TEST_CLI_LOG: cli };
  delete base.FUNES_BIN;
  const result = spawnSync(process.execPath, [...runtimeArgs(worker), ...args], { cwd: scripts, env: { ...base, ...env }, encoding: "utf8" });
  if (result.status !== 0) fail(`the worker exited ${result.status}: ${result.stderr}`);
}

// What funes was asked since the last check, which must be `want`.
function asked(want, when) {
  const got = existsSync(cli) ? readFileSync(cli, "utf8") : "";
  if (got !== want.map((line) => `${line}\n`).join("")) fail(`${when}, funes was asked:\n${got}`);
  rmSync(cli, { force: true });
}

const aged = () => utimesSync(pushed, new Date("2020-01-01T00:00:00Z"), new Date("2020-01-01T00:00:00Z"));
const index = "index --harness pi";
const push = "push acme/kb";

// With no memory, a turn indexes alone.
run([]);
asked([index], "at a turn with no memory");
// What funes says goes to the log, beside the worker's own lines.
const said = readFileSync(sync, "utf8");
if (!said.includes("said by funes") || !said.includes("index[pi]: ok")) fail(`the log holds:\n${said}`);

// Handed a memory, the first turn, with no push behind it, pushes after its index. The next, right
// after that push, indexes alone, and one after that push has aged pushes again.
run(["acme/kb"]);
asked([index, push], "at the first turn");
run(["acme/kb"]);
asked([index], "at a turn right after a push");
aged();
run(["acme/kb"]);
asked([index, push], "at a turn after the last push aged");

// A boundary pushes however recent the last push is.
run(["--publish", "acme/kb"]);
asked([index, push], "at a boundary");

// A turn whose index fails does not push, even when a push is due: it would miss that turn. The
// stamp stays as it was, so the next turn that indexes pushes.
aged();
writeFileSync(`${cli}.busy`, "");
run(["acme/kb"]);
asked([index], "at a turn whose index failed");
rmSync(`${cli}.busy`);
run(["acme/kb"]);
asked([index, push], "at the turn after a failed index");

// A boundary whose index never goes through still pushes what the memory holds, and leaves the
// stamp as it was, so the next turn that indexes pushes what that push missed.
aged();
writeFileSync(`${cli}.busy`, "");
run(["--publish", "acme/kb"]);
asked([index, index, index, index, index, push], "at a boundary whose index failed");
rmSync(`${cli}.busy`);
run(["acme/kb"]);
asked([index, push], "at the turn after that boundary");

// FUNES_BIN names the funes to run, wherever it is.
const pinned = join(root, "pinned");
mkdirSync(pinned);
run([], { FUNES_BIN: fakeFunes(pinned, `process.env.FUNES_TEST_NAME = "pinned: ";\n${RECORDER}`) });
asked([`pinned: ${index}`], "with FUNES_BIN set");

// A PATH entry that is not absolute names a directory of the project pi runs in: none is searched.
const project = join(root, "project");
mkdirSync(join(project, "bin"), { recursive: true });
fakeFunes(join(project, "bin"), RECORDER);
rmSync(sync, { force: true });
const relative = spawnSync(process.execPath, [...runtimeArgs(worker)], {
  cwd: project,
  env: { ...process.env, PATH: `bin${delimiter}.${sep}bin`, HOME: home, USERPROFILE: home, FUNES_TEST_CLI_LOG: cli, FUNES_BIN: "" },
  encoding: "utf8",
});
if (relative.status !== 0) fail(`the worker exited ${relative.status}: ${relative.stderr}`);
asked([], "with only a relative PATH entry holding funes");
if (!readFileSync(sync, "utf8").includes("index ABORT: funes not found")) fail("a worker that found no funes did not say so");

// With no funes on PATH, the directory funes's installer puts it in.
fakeFunes(join(home, ".local", "bin"), `process.env.FUNES_TEST_NAME = "installed: ";\n${RECORDER}`);
run([], { PATH: join(root, "empty") });
asked([`installed: ${index}`], "with funes only where its installer puts it");
console.log("pi index: ok");
