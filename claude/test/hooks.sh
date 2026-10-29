#!/bin/sh
# The per-turn hook converts the transcript its payload names, then every transcript changed since
# the hook last ran — the sessions whose own hook never fired — and a boundary converts before it
# publishes. Drives the worker half of funes-index.sh against a fake Claude home, with a `funes`
# that only records what it is asked, so the conversion alone is under test.
set -eu

HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
BUNDLE=$(CDPATH= cd -- "$HERE/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT INT TERM
fail() {
    echo "claude hooks: $*" >&2
    exit 1
}

export HOME="$tmp/home"
mkdir -p "$HOME/.funes/agents" "$tmp/bin"
cat >"$tmp/bin/funes" <<'FAKE'
#!/bin/sh
printf '%s: %s\n' "${HF_HUB_USER_AGENT_ORIGIN:-}" "$*" >>"$FUNES_TEST_CLI_LOG"
FAKE
chmod +x "$tmp/bin/funes"
export PATH="$tmp/bin:/usr/bin:/bin"
export FUNES_TEST_CLI_LOG="$tmp/cli.log"
# funes and the agent are named after an origin the user set.
export HF_HUB_USER_AGENT_ORIGIN=mine
# Claude Code's transcripts live under its config directory, wherever the user put it.
export CLAUDE_CONFIG_DIR="$tmp/claude-config"

# Installed, with the `spool` record `setup add` writes beside the scripts.
cp -R "$BUNDLE" "$HOME/.funes/agents/claude"
scripts="$HOME/.funes/agents/claude/claude-plugin/funes/scripts"
spool="$tmp/spool"
mkdir -p "$spool"
printf '%s\n' "$spool" >"$scripts/spool"
tree="$CLAUDE_CONFIG_DIR/projects/-Users-me-repo"
mkdir -p "$tree"
fixture="$BUNDLE/claude-plugin/funes/test/session.jsonl"

# The converter, wrapped so a test can act on one transcript as the hook converts it:
# - `$ctl/<stem>.fail` fails its conversion;
# - `$ctl/<stem>.hold` holds its conversion until the file is removed, and `<stem>.held` says it
#   started;
# - the lines of `$ctl/<stem>.late` are appended to the transcript once its conversion is done, as
#   Claude Code writes a sub-agent's last turns after its SubagentStop fired.
ctl="$tmp/ctl"
mkdir -p "$ctl"
plugin="$HOME/.funes/agents/claude/claude-plugin/funes"
mv "$plugin/convert" "$plugin/convert.real"
cat >"$plugin/convert" <<WRAP
#!/bin/sh
out=
for arg; do src=\$out; out=\$arg; done
stem=\${out##*/}
stem=\${stem%.funes.jsonl}
[ ! -e "$ctl/\$stem.fail" ] || exit 1
if [ -e "$ctl/\$stem.hold" ]; then
    : >"$ctl/\$stem.held"
    while [ -e "$ctl/\$stem.hold" ]; do sleep 0.1; done
fi
sh "$plugin/convert.real" "\$@" || exit
if [ -e "$ctl/\$stem.late" ]; then
    sleep 2
    cat "$ctl/\$stem.late" >>"\$src"
    rm "$ctl/\$stem.late"
fi
WRAP
chmod +x "$plugin/convert"

# A transcript written now: `cp` would keep the fixture's stamp, and the sweep goes by stamps.
transcript() { cat "$fixture" >"$tree/$1"; }
# The worker half, as the foreground half runs it: the payload's file, then `--publish` at a
# boundary. The payload names `a.jsonl` unless told another. The worker takes the file with it.
fire() {
    printf '{"transcript_path":"%s"}' "$tree/${2:-a.jsonl}" >"$tmp/payload"
    sh "$scripts/funes-index.sh" --worker "$tmp/payload" "${1:-}"
    [ ! -e "$tmp/payload" ] || fail "the worker left the payload's file"
}
# Filesystems stamp to the second at worst, and `find -newer` compares stamps.
tick() { sleep 2; }
# A worker in the background, its payload naming the transcript `$1`.
fire_in_background() {
    printf '{"transcript_path":"%s"}' "$tree/$1" >"$tmp/payload-$1"
    sh "$scripts/funes-index.sh" --worker "$tmp/payload-$1" &
}
# Wait for a file a background worker creates, as long as a conversion could take.
await() {
    for _ in $(seq 1 100); do
        [ -e "$1" ] && return 0
        sleep 0.1
    done
    fail "$2"
}

# Two sessions written after the install: the hook fires for one of them only.
tick
transcript a.jsonl
transcript b.jsonl
fire
[ -f "$spool/a.funes.jsonl" ] || fail "the session the payload named was not converted"
[ -f "$spool/b.funes.jsonl" ] || fail "the session whose hook never fired was not converted"
[ -f "$scripts/swept" ] || fail "the sweep left no mark"

# A third, written after that run; the second, drained by funes meanwhile, is not re-emitted.
tick
transcript c.jsonl
rm "$spool/b.funes.jsonl"
fire
[ -f "$spool/c.funes.jsonl" ] || fail "a session written since the last sweep was not converted"
[ ! -e "$spool/b.funes.jsonl" ] || fail "a session unchanged since the last sweep was converted again"

# A boundary: what was written since is converted first, then the index and the push to the
# memory recorded beside the scripts.
tick
transcript d.jsonl
printf 'acme/kb\n' >"$scripts/memory"
fire --publish
[ -f "$spool/d.funes.jsonl" ] || fail "the boundary did not convert before publishing"
expected="mine; funes; agent/claude; agent_version/2.1.175: index --harness claude
mine; funes; agent/claude; agent_version/2.1.175: index --harness claude
mine; funes; agent/claude; agent_version/2.1.175: index --harness claude
mine; funes; agent/claude; agent_version/2.1.175: push acme/kb"
[ "$(cat "$FUNES_TEST_CLI_LOG")" = "$expected" ] || fail "funes was asked:
$(cat "$FUNES_TEST_CLI_LOG")"

# A session the memory holds without its queued messages keeps that numbering: the rows `setup add`
# keeps beside the scripts reach the converter.
tick
cat "$BUNDLE/claude-plugin/funes/test/queued.jsonl" >"$tree/queued.jsonl"
printf 'queued 2026-10-01T10:01:00.000Z 5\n' >"$scripts/indexed"
fire
[ "$(jq -r .turn_uuid "$spool/queued.funes.jsonl" | paste -s -d ' ' -)" = "u1 a1 a2 a3 u2 a4" ] ||
    fail "a session held without its queued messages took them"

# What Claude Code writes while the hook converts the transcript it named, as a sub-agent's last
# turns after its SubagentStop fired, is converted by the next sweep.
tick
transcript f.jsonl
printf '%s\n' '{"type":"user","uuid":"late","timestamp":"2026-06-12T22:00:00.000Z","message":{"role":"user","content":"late"}}' >"$ctl/f.late"
fire "" f.jsonl
tick
fire
jq -r '.blocks[].text' "$spool/f.funes.jsonl" | grep -qx late ||
    fail "a turn written while the hook converted its transcript was never converted"

# Two runs side by side: the first holds its sweep, a session is written, and the second stamps its
# mark before the first publishes. The session is newer than the first run's mark, so the second
# run's sweep converts it.
tick
transcript p.jsonl
: >"$ctl/p.hold"
fire_in_background a.jsonl
first=$!
await "$ctl/p.held" "the first run never reached its sweep"
tick
transcript q.jsonl
transcript r.jsonl
: >"$ctl/r.hold"
tick
fire_in_background r.jsonl
second=$!
await "$ctl/r.held" "the second run never converted the transcript it named"
rm "$ctl/p.hold"
wait "$first"
rm "$ctl/r.hold"
wait "$second"
[ -f "$spool/q.funes.jsonl" ] ||
    fail "a session written while two runs swept side by side was never converted"

# A conversion that fails leaves the mark where it was, so the next sweep tries the session again,
# and the run leaves no stamp behind.
tick
transcript x.jsonl
: >"$ctl/x.fail"
fire
[ -z "$(find "$scripts" -name 'swept.*')" ] || fail "a run left its stamp behind"
rm "$ctl/x.fail"
tick
fire
[ -f "$spool/x.funes.jsonl" ] || fail "a session whose conversion failed was never converted again"

# The foreground half, as the hook runs it: the payload on stdin — carrying an assistant message
# larger than any argument could — handed to a detached worker, and the hook returns at once.
tick
transcript e.jsonl
{
    printf '{"transcript_path":"%s","last_assistant_message":"' "$tree/e.jsonl"
    head -c 1100000 /dev/zero | tr '\0' x
    printf '"}'
} | sh "$scripts/funes-index.sh"
for _ in $(seq 1 100); do
    [ -f "$spool/e.funes.jsonl" ] && break
    sleep 0.1
done
[ -f "$spool/e.funes.jsonl" ] || fail "the detached worker never converted the session the hook named"
echo "claude hooks: ok"
