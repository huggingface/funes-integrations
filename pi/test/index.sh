#!/bin/sh
# The automation script, run as the extension runs it: a turn indexes and, handed a memory, pushes
# once the last push is an hour old, and a boundary indexes then pushes. Against a `funes` that
# only records what it is asked.
set -eu

HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT INT TERM
fail() {
    echo "pi index: $*" >&2
    exit 1
}

mkdir -p "$tmp/bin" "$tmp/scripts"
cat >"$tmp/bin/funes" <<'FAKE'
#!/bin/sh
printf '%s\n' "$*" >>"$FUNES_TEST_CLI_LOG"
# An index finds the memory busy, as funes reports it, while the test says so.
[ "$1" != index ] || [ ! -e "$FUNES_TEST_CLI_LOG.busy" ] || exit 75
FAKE
chmod +x "$tmp/bin/funes"
export PATH="$tmp/bin:/usr/bin:/bin"
export FUNES_TEST_CLI_LOG="$tmp/cli.log"
cp "$HERE/../scripts/funes-index.sh" "$tmp/scripts/"
script="$tmp/scripts/funes-index.sh"

# What funes was asked since the last check, which must be `$1`.
asked() {
    got=$(cat "$FUNES_TEST_CLI_LOG" 2>/dev/null || true)
    [ "$got" = "$1" ] || fail "$2, funes was asked:
$got"
    rm -f "$FUNES_TEST_CLI_LOG"
}

# With no memory, a turn indexes alone, and so does a boundary: the script pushes to the memory it
# is handed, never to one it finds on disk.
printf 'acme/kb\n' >"$tmp/scripts/memory"
sh "$script"
sh "$script" --publish
asked "index --harness pi
index --harness pi" "handed no memory"

# Handed a memory, the first turn, with no push behind it, pushes after its index. The next, right
# after that push, indexes alone, and one after that push has aged pushes again.
sh "$script" acme/kb
asked "index --harness pi
push acme/kb" "at the first turn"
sh "$script" acme/kb
asked "index --harness pi" "at a turn right after a push"
touch -t 202001010000 "$tmp/scripts/pushed"
sh "$script" acme/kb
asked "index --harness pi
push acme/kb" "at a turn after the last push aged"

# A boundary pushes however recent the last push is.
sh "$script" --publish acme/kb
asked "index --harness pi
push acme/kb" "at a boundary"

# A turn whose index fails does not push, even when a push is due: it would miss that turn. The
# stamp stays as it was, so the next turn that indexes pushes.
touch -t 202001010000 "$tmp/scripts/pushed"
: >"$FUNES_TEST_CLI_LOG.busy"
sh "$script" acme/kb
asked "index --harness pi" "at a turn whose index failed"
rm "$FUNES_TEST_CLI_LOG.busy"
sh "$script" acme/kb
asked "index --harness pi
push acme/kb" "at the turn after a failed index"

# A boundary whose index never goes through still pushes what the memory holds, and leaves the
# stamp as it was, so the next turn that indexes pushes what that push missed.
touch -t 202001010000 "$tmp/scripts/pushed"
: >"$FUNES_TEST_CLI_LOG.busy"
sh "$script" --publish acme/kb
asked "index --harness pi
index --harness pi
index --harness pi
index --harness pi
index --harness pi
push acme/kb" "at a boundary whose index failed"
rm "$FUNES_TEST_CLI_LOG.busy"
sh "$script" acme/kb
asked "index --harness pi
push acme/kb" "at the turn after that boundary"
echo "pi index: ok"
