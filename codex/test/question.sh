#!/bin/sh
# The end-of-turn question: funes-question.sh sends a turn back once, when it ended on a message
# long enough to be a plan, a proposal or a verdict and funes was not consulted since it started.
# Drives the script with the payload Codex's Stop event hands it, against a rollout written here.
set -eu

HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
BUNDLE=$(CDPATH= cd -- "$HERE/.." && pwd)
script="$BUNDLE/codex-plugin/plugins/funes/scripts/funes-question.sh"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT INT TERM
fail() {
    echo "codex question: $*" >&2
    exit 1
}

rollout="$tmp/rollout-a.jsonl"
# What the hook prints for the turn `t2`: its last message is `$1` characters long, `$2` says
# whether a Stop hook already continued it, and `$3` is its rollout, as JSON.
hook() {
    {
        printf '{"hook_event_name":"Stop","turn_id":"t2","stop_hook_active":%s,"transcript_path":%s,"last_assistant_message":"' \
            "${2:-false}" "${3:-\"$rollout\"}"
        head -c "$1" /dev/zero | tr '\0' x
        printf '"}'
    } | sh "$script"
}
# Whether the hook sent the turn back, with the question as the reason.
asked() {
    printf '%s' "$1" | jq -e '.decision == "block" and (.reason | length) > 0' >/dev/null 2>&1
}

# funes was consulted in the turn before, and Codex logged its tool listing in this one.
turn() {
    cat <<'EOF'
{"type":"event_msg","payload":{"type":"task_started","turn_id":"t1"}}
{"type":"response_item","payload":{"type":"function_call","name":"mcp__funes__recall","arguments":"{\"query\":\"get drill-down\"}","call_id":"call_1"}}
{"type":"event_msg","payload":{"type":"task_started","turn_id":"t2"}}
{"type":"turn_context","payload":{"turn_id":"t2","cwd":"/workspace"}}
{"type":"response_item","payload":{"type":"additional_tools","tools":[{"name":"mcp__funes__recall"}]}}
{"type":"response_item","payload":{"type":"function_call","name":"shell","arguments":"{\"command\":[\"ls\"]}","call_id":"call_2"}}
EOF
}
turn >"$rollout"

asked "$(hook 600)" || fail "a turn that ended on a long message, funes not consulted, was not sent back"
[ -z "$(hook 600 true)" ] || fail "a turn a Stop hook already continued was sent back again"
[ -z "$(hook 599)" ] || fail "a turn that ended on an acknowledgement was sent back"
# An ephemeral run writes no rollout, and its payload names none.
asked "$(hook 600 false null)" || fail "a turn with no rollout was not sent back"
# A rollout that does not hold the turn says nothing of it.
head -n 2 "$rollout" >"$tmp/rollout-before.jsonl"
asked "$(hook 600 false "\"$tmp/rollout-before.jsonl\"")" || fail "a turn its rollout does not hold was not sent back"
[ -z "$(printf 'not json' | sh "$script")" ] || fail "a payload that is not JSON was answered"

# funes consulted since the turn started, as a tool call or from a script in code mode: the model
# has looked already.
printf '%s\n' '{"type":"response_item","payload":{"type":"function_call","name":"mcp__funes__get","arguments":"{}","call_id":"call_3"}}' >>"$rollout"
[ -z "$(hook 600)" ] || fail "a turn that called funes was sent back"
turn >"$rollout"
printf '%s\n' '{"type":"response_item","payload":{"type":"custom_tool_call","name":"exec","input":"const r = await tools.mcp__funes__recall({query:\"get\"}); text(r);","call_id":"call_4"}}' >>"$rollout"
[ -z "$(hook 600)" ] || fail "a turn that called funes from a script was sent back"
echo "codex question: ok"
