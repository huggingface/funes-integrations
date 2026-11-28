#!/bin/sh
# The converter's acceptance test: a real Codex rollout, trimmed and secret-scanned, and the turns
# file it must produce. `expected.funes.jsonl` is what funes's own Codex parser emitted while it had
# one, so a change here that moves a chunk id re-keys sessions users already hold.
#
#   sh <plugin>/test/run.sh
set -eu

HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT INT TERM

# Read with the jq the converter runs, told `--binary` when it is a native Windows jq, as the
# converter tells it.
JQ_FLAGS=
case $(jq -n 1 2>/dev/null | od -An -c) in *'\r'*) JQ_FLAGS=--binary ;; esac

"$HERE/../convert" "$HERE/session.jsonl" "$out/got.funes.jsonl"
if ! diff -u "$HERE/expected.funes.jsonl" "$out/got.funes.jsonl"; then
    echo "codex converter: output changed — see the diff above" >&2
    exit 1
fi
if [ "$out/got.funes.jsonl" -nt "$HERE/session.jsonl" ] || [ "$out/got.funes.jsonl" -ot "$HERE/session.jsonl" ]; then
    echo "codex converter: the turns file does not carry the rollout's own time" >&2
    exit 1
fi

# A caller that asked the jq on PATH already hands its answer down in FUNES_JQ_FLAGS, and the
# converter does not ask again: a seed asks once, not once per rollout.
mkdir "$out/bin"
cat >"$out/bin/jq" <<EOF
#!/bin/sh
[ "\$*" != "-n 1" ] || : >"$out/asked"
exec "$(command -v jq)" "\$@"
EOF
chmod +x "$out/bin/jq"
PATH="$out/bin:$PATH" FUNES_JQ_FLAGS=$JQ_FLAGS "$HERE/../convert" "$HERE/session.jsonl" "$out/handed.funes.jsonl"
if [ -e "$out/asked" ] || ! cmp -s "$HERE/expected.funes.jsonl" "$out/handed.funes.jsonl"; then
    echo "codex converter: handed jq's flags, it asked jq again or converted otherwise" >&2
    exit 1
fi

# The first four turns were captured with Codex 0.169.0, a Stop hook and a local mock model server.
# Paths and session metadata are normalized. Later turns cover multiple hooks and user messages
# that quote or mix hook text.
cat >"$out/want" <<'EOF'
0 user
1 assistant
2 system
3 assistant
4 system
5 user
6 user
EOF
"$HERE/../convert" "$HERE/attribution.jsonl" | jq $JQ_FLAGS -r '"\(.seq) \(.role)"' >"$out/got"
if ! diff -u "$out/want" "$out/got"; then
    echo "codex converter: a turn has the wrong role, see the diff above" >&2
    exit 1
fi
echo "codex converter: ok"
