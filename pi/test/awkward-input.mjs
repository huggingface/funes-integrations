// Sessions built to take every way the converter reads one — as bytes; as text, for a `\u` escape
// past ASCII, for a line whose end only text can trim, or for neither, with lone surrogates and bytes
// that are not UTF-8; and under a stem past ASCII — each beside the turns file the converter wrote
// for it before it read any session as bytes. Reading a session as bytes is a speed, so every one of
// them must still come out byte for byte.
//
// Usage: awkward-input.mjs <work-dir>; exits 1 on a file that differs. `stem` in a name stands for a stem
// past ASCII, which the session is converted under.
import { copyFileSync, mkdirSync, readFileSync, readdirSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { convert } from "../convert.mjs";

const [work] = process.argv.slice(2);
const here = join(dirname(fileURLToPath(import.meta.url)), "awkward-input");
mkdirSync(work, { recursive: true });

let failed = 0;
for (const name of readdirSync(here).filter((n) => n.endsWith(".jsonl") && !n.endsWith(".funes.jsonl"))) {
  const stem = name.replace(/\.jsonl$/, "").replace("stem", "café-✓");
  const session = join(work, `${stem}.jsonl`);
  copyFileSync(join(here, name), session);
  const got = readFileSync(convert(session, join(work, "out")));
  if (!got.equals(readFileSync(join(here, name.replace(/\.jsonl$/, ".funes.jsonl"))))) {
    console.error(`awkward-input/${name}: the turns file changed`);
    failed++;
  }
}
process.exit(failed ? 1 : 0);
