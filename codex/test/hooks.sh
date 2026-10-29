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
FAKE
chmod +x "$tmp/bin/funes"
export PATH="$tmp/bin:/usr/bin:/bin"
export FUNES_TEST_CLI_LOG="$tmp/cli.log"
# The origin comes from the scripts, not from whoever ran the test.
unset HF_HUB_USER_AGENT_ORIGIN
unset CODEX_HOME

# Installed, with the `spool` record `setup add` writes beside the scripts.
cp -R "$BUNDLE" "$HOME/.funes/agents/codex"
scripts="$HOME/.funes/agents/codex/codex-plugin/plugins/funes/scripts"
spool="$tmp/spool"
mkdir -p "$spool"
printf '%s\n' "$spool" >"$scripts/spool"
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
    sh "$scripts/funes-index.sh" --worker "$tmp/payload" "${1:-}"
    [ ! -e "$tmp/payload" ] || fail "the worker left the payload's file"
}
# Filesystems stamp to the second at worst, and `find -newer` compares stamps.
tick() { sleep 2; }
# A worker in the background, its payload naming the rollout `$1`.
fire_in_background() {
    printf '{"transcript_path":"%s","session_id":"s"}' "$tree/$1" >"$tmp/payload-$1"
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
rollout rollout-a.jsonl
rollout rollout-b.jsonl
fire
[ -f "$spool/rollout-a.funes.jsonl" ] || fail "the rollout the payload named was not converted"
[ -f "$spool/rollout-b.funes.jsonl" ] || fail "the rollout whose hook never fired was not converted"
[ -f "$scripts/swept" ] || fail "the sweep left no mark"

# A third, written after that run; the second, drained by funes meanwhile, is not re-emitted.
tick
rollout rollout-c.jsonl
rm "$spool/rollout-b.funes.jsonl"
fire
[ -f "$spool/rollout-c.funes.jsonl" ] || fail "a rollout written since the last sweep was not converted"
[ ! -e "$spool/rollout-b.funes.jsonl" ] || fail "a rollout unchanged since the last sweep was converted again"

# A boundary: what was written since is converted first, then the index and the push to the
# memory recorded beside the scripts.
tick
rollout rollout-d.jsonl
printf 'acme/kb\n' >"$scripts/memory"
fire --publish
[ -f "$spool/rollout-d.funes.jsonl" ] || fail "the boundary did not convert before publishing"
expected="funes; agent/codex; agent_version/0.141.0: index --harness codex
funes; agent/codex; agent_version/0.141.0: index --harness codex
funes; agent/codex; agent_version/0.141.0: index --harness codex
funes; agent/codex; agent_version/0.141.0: push acme/kb"
[ "$(cat "$FUNES_TEST_CLI_LOG")" = "$expected" ] || fail "funes was asked:
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
[ -z "$(find "$scripts" -name 'swept.*')" ] || fail "a run left its stamp behind"
rm "$ctl/rollout-x.fail"
tick
fire
[ -f "$spool/rollout-x.funes.jsonl" ] ||
    fail "a rollout whose conversion failed was never converted again"

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
echo "codex hooks: ok"
