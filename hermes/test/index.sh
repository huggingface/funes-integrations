#!/bin/sh
# The index script, run as the plugin runs it: a turn indexes and, with the memory `setup add`
# recorded beside it, pushes once the last push is an hour old, and a boundary indexes then
# pushes. Against a `funes` that only records what it is asked.
set -eu

HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT INT TERM
fail() {
    echo "hermes index: $*" >&2
    exit 1
}

mkdir -p "$tmp/bin" "$tmp/plugin"
cat >"$tmp/bin/funes" <<'FAKE'
#!/bin/sh
printf '%s\n' "$*" >>"$FUNES_TEST_CLI_LOG"
# An index finds the memory busy, as funes reports it, while the test says so.
[ "$1" != index ] || [ ! -e "$FUNES_TEST_CLI_LOG.busy" ] || exit 75
FAKE
chmod +x "$tmp/bin/funes"
export PATH="$tmp/bin:/usr/bin:/bin"
export FUNES_TEST_CLI_LOG="$tmp/cli.log"
cp "$HERE/../plugin/funes-index.sh" "$tmp/plugin/"
script="$tmp/plugin/funes-index.sh"
# The home funes installed it for, and the `spool` record `setup add` writes beside the script.
export FUNES_HOME="$tmp/home"
printf '%s\n' "$FUNES_HOME/spool/hermes" >"$tmp/plugin/spool"

# What funes was asked since the last check, which must be `$1`.
asked() {
    got=$(cat "$FUNES_TEST_CLI_LOG" 2>/dev/null || true)
    [ "$got" = "$1" ] || fail "$2, funes was asked:
$got"
    rm -f "$FUNES_TEST_CLI_LOG"
}

# With no memory, a turn indexes alone.
sh "$script"
asked "index --harness hermes" "at a turn with no memory"

# With a memory, the first turn, with no push behind it, pushes after its index. The next, right
# after that push, indexes alone, and one after that push has aged pushes again.
printf 'acme/kb\n' >"$tmp/plugin/memory"
sh "$script"
asked "index --harness hermes
push acme/kb" "at the first turn"
sh "$script"
asked "index --harness hermes" "at a turn right after a push"
touch -t 202001010000 "$tmp/plugin/pushed"
sh "$script"
asked "index --harness hermes
push acme/kb" "at a turn after the last push aged"

# A boundary pushes however recent the last push is.
sh "$script" --publish
asked "index --harness hermes
push acme/kb" "at a boundary"

# A turn whose index fails does not push, even when a push is due: it would miss that turn. The
# stamp stays as it was, so the next turn that indexes pushes.
touch -t 202001010000 "$tmp/plugin/pushed"
: >"$FUNES_TEST_CLI_LOG.busy"
sh "$script"
asked "index --harness hermes" "at a turn whose index failed"
rm "$FUNES_TEST_CLI_LOG.busy"
sh "$script"
asked "index --harness hermes
push acme/kb" "at the turn after a failed index"

# A boundary whose index never goes through still pushes what the memory holds, and leaves the
# stamp as it was, so the next turn that indexes pushes what that push missed.
touch -t 202001010000 "$tmp/plugin/pushed"
: >"$FUNES_TEST_CLI_LOG.busy"
sh "$script" --publish
asked "index --harness hermes
index --harness hermes
index --harness hermes
index --harness hermes
index --harness hermes
push acme/kb" "at a boundary whose index failed"
rm "$FUNES_TEST_CLI_LOG.busy"
sh "$script"
asked "index --harness hermes
push acme/kb" "at the turn after that boundary"

# A `$HOME` spelled with a trailing slash is the home funes recorded without one.
touch -t 202001010000 "$tmp/plugin/pushed"
printf '%s\n' "$tmp/user/.funes/spool/hermes" >"$tmp/plugin/spool"
(unset FUNES_HOME && HOME="$tmp/user/" sh "$script")
asked "index --harness hermes
push acme/kb" "under a home spelled with a trailing slash"
printf '%s\n' "$FUNES_HOME/spool/hermes" >"$tmp/plugin/spool"

# Under another funes home the memory recorded for the installed one is not its binding: a turn
# with a push due and a boundary both index that home's spool, which they make, and push nothing.
touch -t 202001010000 "$tmp/plugin/pushed"
FUNES_HOME="$tmp/other" sh "$script"
FUNES_HOME="$tmp/other" sh "$script" --publish
asked "index --harness hermes
index --harness hermes" "under another home"
[ -d "$tmp/other/spool/hermes" ] || fail "the other home's spool was not made"
echo "hermes index: ok"
