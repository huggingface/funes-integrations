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
# An index finds the memory busy, as funes reports it, while the test says so.
[ "$1" != index ] || [ ! -e "$FUNES_TEST_CLI_LOG.busy" ] || exit 75
FAKE
chmod +x "$tmp/bin/funes"
# The jq of the caller's PATH stays on this one, wherever the box keeps it: Windows does not keep it
# in /usr/bin. A native Windows jq is read as the bundle reads it, told `--binary`.
jq=$(command -v jq) || fail "jq is not on PATH"
export PATH="$tmp/bin:/usr/bin:/bin:${jq%/*}"
case $(jq -n 1 2>/dev/null | od -An -c) in *'\r'*) jq() { command jq --binary "$@"; } ;; esac
# The PATH a hook gets on Windows when its shell is started from a native program: in Windows' own
# order, System32, whose `find` is a text search, ahead of Git's tools. Elsewhere the PATH as it is.
native=$PATH
[ ! -x /usr/bin/cygpath ] || native="$(cygpath -u -S):$PATH"
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
    PATH=$native sh "$scripts/funes-index.sh" --worker "$tmp/payload" "${1:-}"
    [ ! -e "$tmp/payload" ] || fail "the worker left the payload's file"
}
# Filesystems stamp to the second at worst, and `find -newer` compares stamps.
tick() { sleep 2; }
# A worker in the background, its payload naming the transcript `$1`.
fire_in_background() {
    printf '{"transcript_path":"%s"}' "$tree/$1" >"$tmp/payload-$1"
    PATH=$native sh "$scripts/funes-index.sh" --worker "$tmp/payload-$1" &
}
# Wait for a file a background worker creates, as long as a conversion could take.
await() {
    for _ in $(seq 1 100); do
        [ -e "$1" ] && return 0
        sleep 0.1
    done
    fail "$2"
}

# Two sessions written after the install, and the journal a workflow keeps beside its sub-agents:
# the hook fires for one of the sessions only.
tick
transcript a.jsonl
transcript b.jsonl
journal="$tree/a/subagents/workflows/wf_1/journal.jsonl"
mkdir -p "${journal%/*}"
printf '%s\n' '{"type":"started","agentId":"agent-1","key":"review"}' >"$journal"
fire
[ -f "$spool/a.funes.jsonl" ] || fail "the session the payload named was not converted"
[ -f "$spool/b.funes.jsonl" ] || fail "the session whose hook never fired was not converted"
[ ! -e "$spool/journal.funes.jsonl" ] || fail "a workflow's journal was converted"
[ -f "$scripts/converted" ] || fail "the sweep left no mark"

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

# A session can stop without its end firing, so with a memory bound a turn pushes too, once the
# last push is an hour old: not right after the boundary's push, then at the turn after that
# push has aged, which leaves the next turn to index alone.
: >"$FUNES_TEST_CLI_LOG"
fire
touch -t 202001010000 "$scripts/pushed"
fire
fire
expected="mine; funes; agent/claude; agent_version/2.1.175: index --harness claude
mine; funes; agent/claude; agent_version/2.1.175: index --harness claude
mine; funes; agent/claude; agent_version/2.1.175: push acme/kb
mine; funes; agent/claude; agent_version/2.1.175: index --harness claude"
[ "$(cat "$FUNES_TEST_CLI_LOG")" = "$expected" ] || fail "funes was asked, turn after turn:
$(cat "$FUNES_TEST_CLI_LOG")"

# A turn whose index fails does not push, even when a push is due: it would miss that turn. The
# stamp stays as it was, so the next turn that indexes pushes.
i="mine; funes; agent/claude; agent_version/2.1.175: index --harness claude"
p="mine; funes; agent/claude; agent_version/2.1.175: push acme/kb"
: >"$FUNES_TEST_CLI_LOG"
touch -t 202001010000 "$scripts/pushed"
: >"$FUNES_TEST_CLI_LOG.busy"
fire
rm "$FUNES_TEST_CLI_LOG.busy"
fire
[ "$(cat "$FUNES_TEST_CLI_LOG")" = "$i
$i
$p" ] || fail "funes was asked, around a failed index:
$(cat "$FUNES_TEST_CLI_LOG")"

# A boundary whose index never goes through still pushes what the memory holds, and leaves the
# stamp as it was, so the next turn that indexes pushes what that push missed.
: >"$FUNES_TEST_CLI_LOG"
touch -t 202001010000 "$scripts/pushed"
: >"$FUNES_TEST_CLI_LOG.busy"
fire --publish
rm "$FUNES_TEST_CLI_LOG.busy"
fire
[ "$(cat "$FUNES_TEST_CLI_LOG")" = "$i
$i
$i
$i
$i
$p
$i
$p" ] || fail "funes was asked, around a boundary's failed index:
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
[ -z "$(find "$scripts" -name 'converted.*')" ] || fail "a run left its stamp behind"
rm "$ctl/x.fail"
tick
fire
[ -f "$spool/x.funes.jsonl" ] || fail "a session whose conversion failed was never converted again"

# Claude Code on Windows names the transcript as Windows does, `C:\Users\…`, or led by `\\` when it
# lives on a share, `\\server\share\…`, or is spelled verbatim, `\\?\C:\Users\…`: it is converted
# under its own stem, once, though the sweep lists it as the shell spells it, and the run moves the
# mark. A name the hook could not split would fail its conversion and hold the mark back, so every
# turn after swept everything since. Only Windows has the spellings to test; the verbatim one stands
# for a share, which a runner may not serve.
if command -v cygpath >/dev/null 2>&1; then
    for lead in '' '\\?\'; do
        tick
        transcript w.jsonl
        rm -f "$spool/w.funes.jsonl"
        : >"$scripts/funes-sync.log"
        touch -t 202001010000 "$scripts/converted"
        printf '{"transcript_path":"%s"}' "$(printf '%s%s' "$lead" "$(cygpath -w "$tree/w.jsonl")" | sed 's/\\/\\\\/g')" >"$tmp/payload"
        sh "$scripts/funes-index.sh" --worker "$tmp/payload"
        log=$(cat "$scripts/funes-sync.log")
        [ -f "$spool/w.funes.jsonl" ] || fail "a transcript Windows named ${lead}C:\\… was not converted: $log"
        if grep -q 'convert: FAILED' "$scripts/funes-sync.log"; then fail "a conversion failed: $log"; fi
        [ "$(grep -c 'convert: w$' "$scripts/funes-sync.log")" = 1 ] || fail "a transcript Windows named ${lead}C:\\… was converted more than once: $log"
        [ "$scripts/converted" -nt "$tree/w.jsonl" ] || fail "a run on a transcript Windows named ${lead}C:\\… left the mark where it was"
    done
fi

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
