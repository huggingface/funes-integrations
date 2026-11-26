#!/bin/sh
# hermes's automation: advance funes's index over this agent's spool and, at a session boundary,
# publish it. The plugin converts each turn itself and spawns this script detached, so the work is
# done in place — nothing here waits on a hook.
#
#   funes-index.sh [MEMORY]            per turn: index and, if that went through, push to MEMORY
#                                      (or to the memory `setup add` recorded beside this script)
#                                      once the last push is `PUSH_EVERY` minutes old
#   funes-index.sh --publish [MEMORY]  at a boundary: index, waiting out a per-turn run that still
#                                      holds the memory lock, then push to MEMORY — or to the memory
#                                      `setup add` recorded beside this script
#
# No locking: `funes` serializes local-memory writes itself. A per-turn run that loses the lock
# exits non-zero, is logged, and the next turn re-sweeps the same content — indexing is idempotent.
set -u

HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
LOG="$HERE/funes-sync.log"
HARNESS=hermes
# The spool `funes` drains below: in the home hermes was started under, as funes resolves it, a
# trailing slash on `$HOME` dropped as funes drops it.
SPOOL=${FUNES_HOME:-${HOME%/}/.funes}/spool/$HARNESS
# How old the last push gets, in minutes, before a turn pushes too. A push compacts the remote once
# enough rows sit unindexed there, so many small pushes compact it more often than a few large ones.
PUSH_EVERY=60

log() { printf '%s %s\n' "$(date +%Y-%m-%dT%H:%M:%S%z)" "$*" >>"$LOG"; }

# Resolve a binary by name, falling back to common install dirs — an agent can run with a minimal
# PATH, e.g. launched from an IDE.
find_bin() {
    command -v "$1" 2>/dev/null && return 0
    for d in "$HOME/.local/bin" /opt/homebrew/bin /usr/local/bin "$HOME/go/bin" /usr/bin /bin; do
        [ -x "$d/$1" ] && {
            printf '%s\n' "$d/$1"
            return 0
        }
    done
    return 1
}

index() {
    log "index[$HARNESS]: start"
    if "$funes" index --harness "$HARNESS" >>"$LOG" 2>&1; then
        log "index[$HARNESS]: ok"
    else
        log "index[$HARNESS]: FAILED (exit $?)"
        return 1
    fi
}

# The memory `$1`, else the one `setup add` recorded beside this script, else nothing. That one is
# the binding of the home `setup add` ran under, whose spool it recorded too: a run under another
# home has none, and pushes nothing.
bound_memory() {
    if [ -n "$1" ]; then
        printf '%s\n' "$1"
    elif [ "$SPOOL" = "$(cat "$HERE/spool" 2>/dev/null)" ]; then
        head -n 1 "$HERE/memory" 2>/dev/null | tr -d '[:space:]'
    fi
}

# Push what the local memory holds to the memory `$1`. A first push to a memory this index shares
# no chunks with is refused off a terminal. funes does it once, interactively, when it binds the
# memory.
push() {
    log "push: start ($1)"
    "$funes" push "$1" >>"$LOG" 2>&1
    rc=$?
    case "$rc" in
    0) log "push: ok" ;;
    2) log "push: WARN — secrets held back; run \`funes scrub\`, then it publishes next run" ;;
    *) log "push: FAILED (exit $rc)" ;;
    esac
}

# A push after an index that never went through misses the last turns, so it leaves the `pushed`
# stamp as it was, and the next turn that indexes pushes them.
publish() {
    memory=$(bound_memory "$1")
    indexed=
    for attempt in 1 2 3 4 5; do
        if "$funes" index --harness "$HARNESS" >>"$LOG" 2>&1; then
            log "index[$HARNESS]: ok (before push)"
            indexed=1
            break
        fi
        log "index[$HARNESS]: busy or failed, retry $attempt"
        sleep 2
    done
    if [ -z "$memory" ]; then
        log "push: skipped (no memory bound)"
        return
    fi
    [ -z "$indexed" ] || : >"$HERE/pushed"
    push "$memory"
}

# A session can stop without its end firing (a process killed, a host disconnected), so a turn
# publishes too, once the last push is `PUSH_EVERY` minutes old. Not after a failed index: that
# push would miss the turn, and its stamp would hold the turn back `PUSH_EVERY` minutes more. The
# `pushed` stamp says when the last push after a successful index started, whatever the push's
# outcome, so a failed push waits `PUSH_EVERY` minutes rather than retrying at every turn. Runs
# side by side may both push: funes lets one through and the other steps aside.
turn() {
    index || return 0
    memory=$(bound_memory "$1")
    if [ -n "$memory" ] && [ -z "$(find "$HERE/pushed" -mmin -"$PUSH_EVERY" 2>/dev/null)" ]; then
        : >"$HERE/pushed"
        push "$memory"
    fi
}

funes=$(find_bin funes || true)
if [ -z "$funes" ] || [ ! -x "$funes" ]; then
    log "index ABORT: funes not found; skipping."
    exit 0
fi
# `setup add` made the spool of its own home; funes drains only one that exists.
[ ! -s "$HERE/spool" ] || mkdir -p "$SPOOL"
case "${1:-}" in
--publish) publish "${2:-}" ;;
*) turn "${1:-}" ;;
esac
