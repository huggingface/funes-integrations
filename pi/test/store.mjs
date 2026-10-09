// A sessions store big enough that the converter spreads it over worker threads, and each of its
// sessions converted on its own: what a bulk conversion of the store must come out as.
//
// Usage: store.mjs <store-dir> <spool-dir>. The store is three projects of sixteen sessions, each the
// test session with a long tool result added, about 12 MB in all.
import { readFileSync, writeFileSync, mkdirSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { convert } from "../convert.mjs";

const [store, spool] = process.argv.slice(2);
const here = dirname(fileURLToPath(import.meta.url));
const session = readFileSync(join(here, "session.jsonl"), "utf8");

for (let p = 0; p < 3; p++) {
  const project = join(store, `--project-${p}--`);
  mkdirSync(project, { recursive: true });
  for (let s = 0; s < 16; s++) {
    // Escapes, non-ASCII and a line's worth of output per row, so no two sessions are the same size.
    const output = `row ${p}.${s}\t"quoted" \\ back — ünïcode ✓ ${"x".repeat(40 + s)}\n`.repeat(3000 + 100 * s);
    const result = {
      type: "message",
      id: `r${p}${s}`,
      parentId: "16c31112",
      timestamp: "2026-04-13T09:30:00.000Z",
      message: { role: "toolResult", toolCallId: `call_${p}${s}`, toolName: "bash", content: [{ type: "text", text: output }] },
    };
    const path = join(project, `2026-04-13T09-28-54-581Z_${p}-${s}.jsonl`);
    writeFileSync(path, session + JSON.stringify(result) + "\n");
    convert(path, spool);
  }
}
