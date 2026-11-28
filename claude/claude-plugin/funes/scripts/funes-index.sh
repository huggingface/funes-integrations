#!/bin/sh
# Claude Code's per-turn capture: convert the transcript that just changed into funes's spool, then
# any other changed since the last run, then advance the index over it. Fired by Stop and by
# SubagentStop, whose payloads arrive on stdin — and, as `funes-index.sh --publish`, by the session
# boundaries, where the same conversion runs first and the publish follows it, so the last turn is
# in the spool before it is indexed and pushed. With a memory bound, a turn pushes as well, once the
# last push is `PUSH_EVERY` minutes old.
#
# The foreground half reads that payload and returns, so a turn never waits on the conversion or on
# the embedder; the worker it leaves behind does both. Detaching uses nohup alone, which is portable
# to macOS and Linux.
#
# No locking: `funes` serializes local-memory writes itself. A run that loses the lock exits
# non-zero, is logged, and the next turn re-sweeps the same content — indexing is idempotent.
set -u

# Git for Windows' shell, started from a native program, keeps Windows' PATH order, which puts
# System32, whose `find` is a text search, ahead of Git's own tools: those go first. Only such a
# shell has /usr/bin/cygpath.
[ ! -x /usr/bin/cygpath ] || PATH="/usr/bin:$PATH"

HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
LOG="$HERE/funes-sync.log"
# Written by `setup add`: the directory funes drains for this agent.
SPOOL=$(cat "$HERE/spool" 2>/dev/null || true)
HARNESS=claude
# How old the last push gets, in minutes, before a turn pushes too. A push compacts the remote once
# enough rows sit unindexed there, so many small pushes compact it more often than a few large ones.
PUSH_EVERY=60

log() { printf '%s %s\n' "$(date +%Y-%m-%dT%H:%M:%S%z)" "$*" >>"$LOG"; }

# Resolve a binary by name, falling back to common install dirs — a hook can run with a minimal
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

# A path as this shell spells it. Claude Code on Windows names a transcript as Windows does,
# `C:\Users\…`, or `\\server\share\…` on a share, which a `/` cannot split and which is not what
# `find` lists; Git's `cygpath` gives the spelling `find` uses.
posix_path() {
    case $1 in
    [A-Za-z]:[\\/]* | *\\*) cygpath -u -- "$1" 2>/dev/null && return 0 ;;
    esac
    printf '%s\n' "$1"
}

# One transcript into the spool, named after the session it belongs to, which is its own file stem,
# and numbered as the memory holds it, from the rows `setup add` keeps beside this script. Fails
# when the converter does.
convert_one() {
    jq=$1
    src=$2
    [ -n "$src" ] && [ -r "$src" ] || return 0
    stem=${src##*/}
    stem=${stem%.jsonl}
    if PATH="$(dirname "$jq"):$PATH" FUNES_JQ_FLAGS=$JQ_FLAGS "$HERE/../convert" --indexed "$HERE/indexed" "$src" "$SPOOL/$stem.funes.jsonl" 2>>"$LOG"; then
        log "convert: $stem"
    else
        log "convert: FAILED for $src"
        return 1
    fi
}

# Name funes, this agent and its version (when known) in funes's Hub requests: hf-hub appends
# HF_HUB_USER_AGENT_ORIGIN to its User-Agent. An origin already set is kept in front.
tag_hub_requests() {
    origin="funes; agent/$HARNESS${1:+; agent_version/$1}"
    export HF_HUB_USER_AGENT_ORIGIN="${HF_HUB_USER_AGENT_ORIGIN:+$HF_HUB_USER_AGENT_ORIGIN; }$origin"
}

# The Claude Code version that wrote a transcript: every record carries it, so its last lines
# settle it.
agent_version() {
    [ -n "$2" ] && [ -r "$2" ] || return 0
    tail -n 20 "$2" | "$1" $JQ_FLAGS -rR 'fromjson? | .version // empty | strings' 2>/dev/null | tail -n 1
}

# The transcripts changed since the last sweep: sessions whose own hook never fired — untrusted,
# timed out, a host that died mid-turn — and the sub-agents a workflow nests under a session, whose
# SubagentStop funes may not see. What the spool holds cannot say which those are (funes drains it),
# so the sweep goes by a mark it shares with the walk `setup add` makes over the history: the stamp
# of the last of them, or, before there is one, the `spool` record `setup add` wrote just before
# that walk. The transcript the payload named was converted already and is skipped. The next mark is
# the stamp `$3` the worker took before it converted anything, unless a conversion failed and
# dropped it. The journal a workflow keeps beside its sub-agents holds no turn and is left out.
convert_stale() {
    jq=$1
    named=$2
    stamp=$3
    projects="$(posix_path "${CLAUDE_CONFIG_DIR:-$HOME/.claude}")/projects"
    [ -d "$projects" ] || return 0
    mark="$HERE/converted"
    since=$mark
    [ -e "$since" ] || since="$HERE/spool"
    find "$projects" -type f -name '*.jsonl' ! -name journal.jsonl -newer "$since" 2>/dev/null | while IFS= read -r src; do
        [ "$src" = "$named" ] || convert_one "$jq" "$src" || rm -f "$stamp"
    done
    [ ! -e "$stamp" ] || mv -f "$stamp" "$mark"
}

# The memory `setup add` recorded beside this script, empty when it was handed none.
bound_memory() { head -n 1 "$HERE/memory" 2>/dev/null | tr -d '[:space:]'; }

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

# The boundary's second half: land the turns in the memory, waiting out a per-turn worker that may
# still hold its lock, then push them to the memory `setup add` recorded beside this script. A push
# after an index that never went through misses the last turns, so it leaves the `pushed` stamp as
# it was, and the next turn that indexes pushes them.
publish() {
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
    memory=$(bound_memory)
    if [ -z "$memory" ]; then
        log "push: skipped (no memory bound)"
        return
    fi
    [ -z "$indexed" ] || : >"$HERE/pushed"
    push "$memory"
}

worker() {
    payload=$1
    mode=${2:-}
    # The sweep's next mark, as this run stamps it: named after the process, so runs side by side
    # never publish each other's, and dropped on exit unless the sweep published it.
    stamp="$HERE/converted.$$"
    trap 'rm -f "$payload" "$stamp"' EXIT
    funes=$(find_bin funes || true)
    if [ -z "$funes" ] || [ ! -x "$funes" ]; then
        log "index ABORT: funes not found; skipping."
        return
    fi
    jq=$(find_bin jq || true)
    if [ -z "$jq" ] || [ ! -x "$jq" ]; then
        log "convert ABORT: jq not found; the session was not captured."
        return
    fi
    if [ -z "$SPOOL" ]; then
        log "convert ABORT: no spool recorded; re-run \`funes add claude\`."
        return
    fi
    # A native Windows jq ends every line it writes with CRLF unless told `--binary`. No other jq
    # writes one, and a jq before 1.7 may not take the flag, so only a jq seen writing CRLF is told.
    JQ_FLAGS=
    case $("$jq" -n 1 2>/dev/null | od -An -c) in *'\r'*) JQ_FLAGS=--binary ;; esac

    # SubagentStop carries the sub-agent's own transcript in its own field; the session's is still
    # `transcript_path`. A reported bug fires the event for internal calls whose file never exists,
    # which `convert_one` skips.
    agent_src=$("$jq" $JQ_FLAGS -r '.agent_transcript_path // empty' "$payload" 2>/dev/null || true)
    src=$("$jq" $JQ_FLAGS -r '.transcript_path // empty' "$payload" 2>/dev/null || true)
    named=$(posix_path "${agent_src:-$src}")
    tag_hub_requests "$(agent_version "$jq" "$named")"
    # Stamped before anything is converted, the named transcript included: what is written while
    # this run reads, such as a sub-agent's last turns after its SubagentStop fired, is newer than
    # the mark it leaves and is swept next turn. A failed conversion drops the stamp: the mark stays
    # where it was, and the next sweep tries again.
    : >"$stamp"
    convert_one "$jq" "$named" || rm -f "$stamp"
    convert_stale "$jq" "$named" "$stamp"

    if [ "$mode" = --publish ]; then
        publish
        return
    fi

    log "index[$HARNESS]: start"
    if "$funes" index --harness "$HARNESS" >>"$LOG" 2>&1; then
        log "index[$HARNESS]: ok"
    else
        log "index[$HARNESS]: FAILED (exit $?)"
        # A push now would miss this turn, and its stamp would hold the turn back `PUSH_EVERY`
        # minutes more. The next turn that indexes pushes it.
        return
    fi

    # A session can stop without its end firing (a conversation switched away, a window closed, a
    # host disconnected), so a turn publishes too, once the last push is `PUSH_EVERY` minutes old.
    # The `pushed` stamp says when the last push after a successful index started, whatever the
    # push's outcome, so a failed push waits `PUSH_EVERY` minutes rather than retrying at every
    # turn. Runs side by side may both push: funes lets one through and the other steps aside.
    memory=$(bound_memory)
    if [ -n "$memory" ] && [ -z "$(find "$HERE/pushed" -mmin -"$PUSH_EVERY" 2>/dev/null)" ]; then
        : >"$HERE/pushed"
        push "$memory"
    fi
}

# Worker mode (re-exec): the payload's file and the mode are the arguments, and the turn is already
# over.
if [ "${1:-}" = "--worker" ]; then
    worker "${2:-}" "${3:-}"
    exit 0
fi

# The payload carries the last assistant message, which can outgrow what a kernel lets an argument
# hold, so it goes through a file the worker takes with it.
mode=${1:-}
payload=$(mktemp "${TMPDIR:-/tmp}/funes-payload.XXXXXX") || {
    log "index ABORT: no temporary file for the payload"
    exit 0
}
cat >"$payload"
nohup sh "$0" --worker "$payload" "$mode" >/dev/null 2>&1 </dev/null &
exit 0
