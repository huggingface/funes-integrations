#!/bin/sh
# Every test of the pi bundle: the converter, the extension's startup, and `setup`.
#
# The converter's acceptance test: a real pi session, trimmed and secret-scanned, and the turns file
# it must produce. `expected.funes.jsonl` is what funes's own pi parser emitted while it had one, so
# a change here that moves a chunk id re-keys sessions users already hold.
#
#   sh integrations/pi/test/run.sh [node|bun|deno]
set -eu

HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
JS=${1:-node}
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT INT TERM

"$JS" "$HERE/../convert.mjs" "$HERE/session.jsonl" "$out"
if ! diff -u "$HERE/expected.funes.jsonl" "$out/session.funes.jsonl"; then
    echo "pi converter: output changed — see the diff above" >&2
    exit 1
fi
# To the second: the runtime stamps to the millisecond, and ordering the spool needs no more.
if ! "$JS" "$HERE/same-second.mjs" "$out/session.funes.jsonl" "$HERE/session.jsonl"; then
    echo "pi converter: the turns file does not carry the session's own time" >&2
    exit 1
fi
echo "pi converter: ok"

# A whole store, converted over worker threads, comes out as each of its sessions converted alone.
"$JS" "$HERE/store.mjs" "$out/store" "$out/alone"
if [ "$("$JS" "$HERE/../convert.mjs" "$out/store" "$out/bulk")" != 48 ] || ! diff -r "$out/alone" "$out/bulk" >/dev/null; then
    echo "pi converter: a store converted in bulk is not its sessions converted one by one" >&2
    exit 1
fi
echo "pi converter, a whole store: ok"

# Sessions that take every way a session is read, against what the converter wrote for them before
# it read one as bytes.
"$JS" "$HERE/awkward.mjs" "$out/awkward"
echo "pi converter, awkward sessions: ok"

# The session pi is writing, converted as it grows: what a whole conversion writes, at every step.
"$JS" "$HERE/live.mjs" "$out/live"
echo "pi converter, live: ok"

# The extension's startup, run as pi runs it: node strips the types itself from 22.18 on; bun and
# deno always did.
case "$JS" in
node) TS=--experimental-strip-types ;;
*) TS= ;;
esac
if ! "$JS" $TS "$HERE/startup.mjs"; then
    echo "pi startup: a history setup left pending is not indexed at the next start — see above" >&2
    exit 1
fi
echo "pi startup: ok"

sh "$HERE/setup.sh"
