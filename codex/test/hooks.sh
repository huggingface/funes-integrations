#!/bin/sh
# The per-turn hook converts the rollout its payload names, then every rollout changed since the
# hook last ran — the sessions whose own hook never fired — and a boundary converts before it
# publishes. Drives the worker half of funes-index.sh against a fake Codex home, with a `funes`
# that only records what it is asked, so the conversion alone is under test.
set -eu

HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
BUNDLE=$(CDPATH= cd -- "$HERE/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT INT TERM
fail() {
    echo "codex hooks: $*" >&2
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
# The PATH a hook gets on Windows, where Codex starts Git's shell from a native program: in
# Windows' own order, System32, whose `find` is a text search, ahead of Git's tools. Elsewhere the
# PATH as it is.
native=$PATH
[ ! -x /usr/bin/cygpath ] || native="$(cygpath -u -S):$PATH"
export FUNES_TEST_CLI_LOG="$tmp/cli.log"
# The origin comes from the scripts, not from whoever ran the test.
unset HF_HUB_USER_AGENT_ORIGIN
unset CODEX_HOME
# Codex names its hooks the directory it keeps for the plugin's data, outside the plugin whose
# contents it pins when they are trusted: what a run writes goes there.
export PLUGIN_DATA="$tmp/plugin-data"
data=$PLUGIN_DATA

# Installed with a memory bound: the `spool` record and the memory `setup add` writes beside the
# scripts.
cp -R "$BUNDLE" "$HOME/.funes/agents/codex"
scripts="$HOME/.funes/agents/codex/codex-plugin/plugins/funes/scripts"
spool="$tmp/spool"
mkdir -p "$spool"
printf '%s\n' "$spool" >"$scripts/spool"
printf 'acme/kb\n' >"$scripts/memory"
tree="$HOME/.codex/sessions/2026/09/24"
mkdir -p "$tree"
fixture="$BUNDLE/codex-plugin/plugins/funes/test/session.jsonl"

# The converter, wrapped so a test can act on one rollout as the hook converts it:
# - `$ctl/<stem>.fail` fails its conversion;
# - `$ctl/<stem>.hold` holds its conversion until the file is removed, and `<stem>.held` says it
#   started;
# - the lines of `$ctl/<stem>.late` are appended to the rollout once its conversion is done, as a
#   session writes on while the hook reads.
ctl="$tmp/ctl"
mkdir -p "$ctl"
plugin="$HOME/.funes/agents/codex/codex-plugin/plugins/funes"
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

# A rollout written now: `cp` would keep the fixture's stamp, and the sweep goes by stamps.
rollout() { cat "$fixture" >"$tree/$1"; }
# The worker half, as the foreground half runs it: the payload's file, then `--publish` at a
# boundary. The payload names `rollout-a.jsonl` unless told another. The worker takes the file with
# it.
fire() {
    printf '{"transcript_path":"%s","session_id":"s"}' "$tree/${2:-rollout-a.jsonl}" >"$tmp/payload"
    PATH=$native sh "$scripts/funes-index.sh" --worker "$tmp/payload" "${1:-}"
    [ ! -e "$tmp/payload" ] || fail "the worker left the payload's file"
}
# Filesystems stamp to the second at worst, and `find -newer` compares stamps.
tick() { sleep 2; }
# A worker in the background, its payload naming the rollout `$1`.
fire_in_background() {
    printf '{"transcript_path":"%s","session_id":"s"}' "$tree/$1" >"$tmp/payload-$1"
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

# The plugin as installed: every run below must leave it as it is.
: >"$tmp/installed"

# Two sessions written after the install: the hook fires for one of them only.
tick
rollout rollout-a.jsonl
rollout rollout-b.jsonl
fire
[ -f "$spool/rollout-a.funes.jsonl" ] || fail "the rollout the payload named was not converted"
[ -f "$spool/rollout-b.funes.jsonl" ] || fail "the rollout whose hook never fired was not converted"
[ -f "$data/converted" ] || fail "the sweep left no mark"

# A third, written after that run; the second, drained by funes meanwhile, is not re-emitted.
tick
rollout rollout-c.jsonl
rm "$spool/rollout-b.funes.jsonl"
fire
[ -f "$spool/rollout-c.funes.jsonl" ] || fail "a rollout written since the last sweep was not converted"
[ ! -e "$spool/rollout-b.funes.jsonl" ] || fail "a rollout unchanged since the last sweep was converted again"

# A boundary: what was written since is converted first, then the index and the push to the
# memory recorded beside the scripts. Of the turns before it, the first had no push behind it and
# pushed after its index, and the second indexed alone.
tick
rollout rollout-d.jsonl
fire --publish
[ -f "$spool/rollout-d.funes.jsonl" ] || fail "the boundary did not convert before publishing"
expected="funes; agent/codex; agent_version/0.141.0: index --harness codex
funes; agent/codex; agent_version/0.141.0: push acme/kb
funes; agent/codex; agent_version/0.141.0: index --harness codex
funes; agent/codex; agent_version/0.141.0: index --harness codex
funes; agent/codex; agent_version/0.141.0: push acme/kb"
[ "$(cat "$FUNES_TEST_CLI_LOG")" = "$expected" ] || fail "funes was asked:
$(cat "$FUNES_TEST_CLI_LOG")"

# A session can stop without its end firing, so a turn pushes too, once the last push is an hour
# old: not right after the boundary's push, then at the turn after that push has aged, which leaves
# the next turn to index alone.
: >"$FUNES_TEST_CLI_LOG"
fire
touch -t 202001010000 "$data/pushed"
fire
fire
expected="funes; agent/codex; agent_version/0.141.0: index --harness codex
funes; agent/codex; agent_version/0.141.0: index --harness codex
funes; agent/codex; agent_version/0.141.0: push acme/kb
funes; agent/codex; agent_version/0.141.0: index --harness codex"
[ "$(cat "$FUNES_TEST_CLI_LOG")" = "$expected" ] || fail "funes was asked, turn after turn:
$(cat "$FUNES_TEST_CLI_LOG")"

# A turn whose index fails does not push, even when a push is due: it would miss that turn. The
# stamp stays as it was, so the next turn that indexes pushes.
i="funes; agent/codex; agent_version/0.141.0: index --harness codex"
p="funes; agent/codex; agent_version/0.141.0: push acme/kb"
: >"$FUNES_TEST_CLI_LOG"
touch -t 202001010000 "$data/pushed"
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
touch -t 202001010000 "$data/pushed"
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

# What a session writes while the hook converts the rollout it named is converted by the next sweep.
tick
rollout rollout-f.jsonl
printf '%s\n' '{"timestamp": "2026-06-23T06:00:00.000Z", "type": "response_item", "payload": {"type": "message", "role": "user", "content": [{"type": "input_text", "text": "late"}]}}' >"$ctl/rollout-f.late"
fire "" rollout-f.jsonl
tick
fire
jq -r '.blocks[].text' "$spool/rollout-f.funes.jsonl" | grep -qx late ||
    fail "a turn written while the hook converted its rollout was never converted"

# Two runs side by side: the first holds its sweep, a session is written, and the second stamps its
# mark before the first publishes. The session is newer than the first run's mark, so the second
# run's sweep converts it.
tick
rollout rollout-p.jsonl
: >"$ctl/rollout-p.hold"
fire_in_background rollout-a.jsonl
first=$!
await "$ctl/rollout-p.held" "the first run never reached its sweep"
tick
rollout rollout-q.jsonl
rollout rollout-r.jsonl
: >"$ctl/rollout-r.hold"
tick
fire_in_background rollout-r.jsonl
second=$!
await "$ctl/rollout-r.held" "the second run never converted the rollout it named"
rm "$ctl/rollout-p.hold"
wait "$first"
rm "$ctl/rollout-r.hold"
wait "$second"
[ -f "$spool/rollout-q.funes.jsonl" ] ||
    fail "a session written while two runs swept side by side was never converted"

# A conversion that fails leaves the mark where it was, so the next sweep tries the session again,
# and the run leaves no stamp behind.
tick
rollout rollout-x.jsonl
: >"$ctl/rollout-x.fail"
fire
[ -z "$(find "$data" -name 'converted.*')" ] || fail "a run left its stamp behind"
rm "$ctl/rollout-x.fail"
tick
fire
[ -f "$spool/rollout-x.funes.jsonl" ] ||
    fail "a rollout whose conversion failed was never converted again"

# Codex on Windows names the rollout and the plugin's data as Windows does, `C:\Users\…`, or led by
# `\\` when they live on a share, `\\server\share\…`, or are spelled verbatim, `\\?\C:\Users\…`, as
# Rust's canonical paths are: the rollout is converted under its own stem, once, though the sweep
# lists it as the shell spells it, and the run moves the mark. A name the hook could not split would
# fail its conversion and hold the mark back, so every turn after swept everything since. Only
# Windows has the spellings to test; the verbatim one stands for a share, which a runner may not
# serve.
if command -v cygpath >/dev/null 2>&1; then
    for lead in '' '\\?\'; do
        tick
        rollout rollout-w.jsonl
        rm -f "$spool/rollout-w.funes.jsonl"
        : >"$data/funes-sync.log"
        touch -t 202001010000 "$data/converted"
        printf '{"transcript_path":"%s","session_id":"w"}' "$(printf '%s%s' "$lead" "$(cygpath -w "$tree/rollout-w.jsonl")" | sed 's/\\/\\\\/g')" >"$tmp/payload"
        PLUGIN_DATA="$lead$(cygpath -w "$data")" sh "$scripts/funes-index.sh" --worker "$tmp/payload"
        log=$(cat "$data/funes-sync.log")
        [ -f "$spool/rollout-w.funes.jsonl" ] || fail "a rollout Windows named ${lead}C:\\… was not converted: $log"
        if grep -q 'convert: FAILED' "$data/funes-sync.log"; then fail "a conversion failed: $log"; fi
        [ "$(grep -c 'convert: rollout-w$' "$data/funes-sync.log")" = 1 ] || fail "a rollout Windows named ${lead}C:\\… was converted more than once: $log"
        [ "$data/converted" -nt "$tree/rollout-w.jsonl" ] || fail "a run on a rollout Windows named ${lead}C:\\… left the mark where it was"
    done
fi

# A run Codex hands no directory keeps its state where Codex has the plugin's data, which is where
# the walk `setup add` makes leaves the mark the sweeps share.
tick
rollout rollout-g.jsonl
(unset PLUGIN_DATA; fire "" rollout-g.jsonl) || fail "the run Codex named no directory to failed"
[ -f "$HOME/.codex/plugins/data/funes-huggingface/converted" ] ||
    fail "a run Codex named no directory to left its mark elsewhere"

# The foreground half, as the hook runs it: the payload on stdin — carrying an assistant message
# larger than any argument could — handed to a detached worker, and the hook returns at once.
tick
rollout rollout-e.jsonl
{
    printf '{"transcript_path":"%s","session_id":"e","last_assistant_message":"' "$tree/rollout-e.jsonl"
    head -c 1100000 /dev/zero | tr '\0' x
    printf '"}'
} | sh "$scripts/funes-index.sh"
for _ in $(seq 1 100); do
    [ -f "$spool/rollout-e.funes.jsonl" ] && break
    sleep 0.1
done
[ -f "$spool/rollout-e.funes.jsonl" ] || fail "the detached worker never converted the rollout the hook named"
# Trusting the hooks pins a hash of the plugin's contents: no run wrote into it.
[ -z "$(find "$plugin" -newer "$tmp/installed")" ] || fail "a run wrote into the plugin: $(find "$plugin" -newer "$tmp/installed")"
echo "codex hooks: ok"
