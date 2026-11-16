#!/bin/sh
# The end-of-turn question: funes-question.sh sends a turn back once, when it ended on a message
# long enough to be a plan, a proposal or a verdict and funes was not consulted since the prompt.
# Drives the script with the payload Claude Code's Stop event hands it, against a transcript written
# here.
set -eu

HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
BUNDLE=$(CDPATH= cd -- "$HERE/.." && pwd)
script="$BUNDLE/claude-plugin/funes/scripts/funes-question.sh"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT INT TERM
fail() {
    echo "claude question: $*" >&2
    exit 1
}

transcript="$tmp/transcript.jsonl"
# What the hook prints for the turn the prompt `p2` started: its last message is `$1` characters
# long, `$2` says whether a Stop hook already continued it, and `$3` names its transcript.
hook() {
    {
        printf '{"hook_event_name":"Stop","prompt_id":"p2","stop_hook_active":%s,"transcript_path":"%s","last_assistant_message":"' \
            "${2:-false}" "${3:-$transcript}"
        head -c "$1" /dev/zero | tr '\0' x
        printf '"}'
    } | sh "$script"
}
# Whether the hook sent the turn back, with the question as additional context.
asked() {
    printf '%s' "$1" | jq -e '.hookSpecificOutput | .hookEventName == "Stop" and (.additionalContext | length) > 0' >/dev/null 2>&1
}

# funes was consulted in the turn before, and Claude Code logged its tool listing in this one.
cat >"$transcript" <<'EOF'
{"type":"user","promptId":"p1","message":{"role":"user","content":"Is get in scope?"}}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"toolu_1","name":"mcp__funes__recall","input":{"query":"get drill-down"}}]}}
{"type":"user","promptId":"p1","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_1","content":"no hit"}]}}
{"type":"user","promptId":"p2","message":{"role":"user","content":"Plan the port."}}
{"type":"attachment","attachment":{"type":"deferred_tools_record","tools":[{"name":"mcp__funes__recall"}]}}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"toolu_2","name":"Bash","input":{"command":"ls"}}]}}
EOF

asked "$(hook 600)" || fail "a turn that ended on a long message, funes not consulted, was not sent back"
[ -z "$(hook 600 true)" ] || fail "a turn a Stop hook already continued was sent back again"
[ -z "$(hook 599)" ] || fail "a turn that ended on an acknowledgement was sent back"
asked "$(hook 600 false "$tmp/gone.jsonl")" || fail "a turn whose transcript cannot be read was not sent back"
# A transcript that does not hold the prompt says nothing of this turn.
head -n 3 "$transcript" >"$tmp/before.jsonl"
asked "$(hook 600 false "$tmp/before.jsonl")" || fail "a turn its transcript does not hold was not sent back"
[ -z "$(printf 'not json' | sh "$script")" ] || fail "a payload that is not JSON was answered"

# funes consulted since the prompt: the model has looked already.
printf '%s\n' '{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"toolu_3","name":"mcp__funes__get","input":{"session_id":"s"}}]}}' >>"$transcript"
[ -z "$(hook 600)" ] || fail "a turn that consulted funes was sent back"
echo "claude question: ok"
