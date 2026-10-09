// A sessions store big enough that the converter spreads it over worker threads, converted over
// them and, for what that must come out as, one session after another by `convertTree`.
//
// Usage: store.mjs <store-dir> <spool-dir>; exits 1 when the two differ, or when a machine with
// more than one core converted none of it on a worker. The store is three projects of sixteen sessions,
// each the test session with a long tool result added, about 12 MB in all; two projects also hold a
// session under the same name, whose turns files are one file, the one tree order converts last.
// That one is the largest session and the other the smallest, so converting largest first without
// regard to tree order would keep the wrong one.
// The sequential conversion is left in <spool-dir>, for the CLI's to be checked against.
import { readFileSync, readdirSync, writeFileSync, mkdirSync } from "node:fs";
import { availableParallelism, cpus } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { convertTree, convertTreeParallel } from "../convert.mjs";

const [store, spool] = process.argv.slice(2);
const here = dirname(fileURLToPath(import.meta.url));
const session = readFileSync(join(here, "session.jsonl"), "utf8");

const withResult = (id, text) => {
  const result = {
    type: "message",
    id,
    parentId: "16c31112",
    timestamp: "2026-04-13T09:30:00.000Z",
    message: { role: "toolResult", toolCallId: `call_${id}`, toolName: "bash", content: [{ type: "text", text }] },
  };
  return session + JSON.stringify(result) + "\n";
};

for (let p = 0; p < 3; p++) {
  const project = join(store, `--project-${p}--`);
  mkdirSync(project, { recursive: true });
  for (let s = 0; s < 16; s++) {
    // Escapes, non-ASCII and a line's worth of output per row, so no two sessions are the same size.
    const output = `row ${p}.${s}\t"quoted" \\ back — ünïcode ✓ ${"x".repeat(40 + s)}\n`.repeat(3000 + 100 * s);
    writeFileSync(join(project, `2026-04-13T09-28-54-581Z_${p}-${s}.jsonl`), withResult(`r${p}${s}`, output));
  }
}
// Tree order is the listing's, which only some filesystems sort.
const [first, last] = readdirSync(store).filter((d) => d !== "--project-0--");
writeFileSync(join(store, first, "shared.jsonl"), withResult("shared-first", "converted first\n"));
writeFileSync(join(store, last, "shared.jsonl"), withResult("shared-last", "converted last, kept\n".repeat(100000)));

const fail = (why) => {
  console.error(`pi converter, a whole store: ${why}`);
  process.exit(1);
};
const sequential = convertTree(store, spool).length;
const { written, workers } = await convertTreeParallel(store, `${spool}-parallel`);
if (written !== sequential) fail(`${written} sessions written over workers, ${sequential} one by one`);
const names = readdirSync(spool).sort();
if (names.join() !== readdirSync(`${spool}-parallel`).sort().join()) fail("the turns files written differ");
for (const name of names) {
  if (!readFileSync(join(spool, name)).equals(readFileSync(join(`${spool}-parallel`, name)))) fail(`${name} differs`);
}
const cores = typeof availableParallelism === "function" ? availableParallelism() : cpus().length;
if (cores > 1 && workers === 0) fail("no worker converted any of it");
