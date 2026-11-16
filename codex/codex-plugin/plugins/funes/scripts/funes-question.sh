#!/bin/sh
# Codex's end-of-turn question: a turn that ends on a message long enough to be a plan, a proposal
# or a verdict, with funes not consulted since it started, is sent back once with one line asking
# whether it rings a bell. Whether to look is left to the model. Fired by Stop, whose payload
# arrives on stdin.
#
# The question goes back as the reason of a block decision: Codex hands it to the model as a new
# prompt and records it as a `hook_prompt` message, which the converter gives the role `system`.
#
# A payload or a rollout this script cannot read ends the turn as it was: nothing is printed. It
# writes no file, so the plugin Codex pins stays as trusted.
set -u

QUESTION='Does this ring a bell? Past sessions are in funes.'
# A last message shorter than this, in characters, is taken for an acknowledgement.
MIN_CHARS=600

# Resolve a binary by name, falling back to common install dirs: a hook can run with a minimal
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

# Whether funes was called in the turn `$2` of the rollout `$1`: a tool call naming one of its
# tools, or, in code mode, a script that calls one.
consulted() {
    [ -n "$1" ] && [ -r "$1" ] && [ -n "$2" ] || return 1
    from=$(grep -n -m 1 -F "\"turn_id\":\"$2\"" "$1" | cut -d: -f1)
    [ -n "$from" ] || return 1
    tail -n "+$from" "$1" | grep -F 'mcp__funes__' |
        "$jq" -e -n 'any(inputs; .type == "response_item"
            and (.payload.type == "function_call" or .payload.type == "custom_tool_call"))' >/dev/null 2>&1
}

jq=$(find_bin jq || true)
[ -n "$jq" ] && [ -x "$jq" ] || exit 0

# One field a line: whether a Stop hook already continued this turn, the length of its last
# message, the rollout and the turn.
fields=$("$jq" -r '(.stop_hook_active == true), ((.last_assistant_message // "") | length),
    (.transcript_path // ""), (.turn_id // "")' 2>/dev/null) || exit 0
{
    read -r active
    read -r chars
    read -r rollout
    read -r turn
} <<EOF
$fields
EOF

[ "$active" = false ] || exit 0
[ "${chars:-0}" -ge "$MIN_CHARS" ] 2>/dev/null || exit 0
! consulted "$rollout" "$turn" || exit 0

"$jq" -n -c --arg question "$QUESTION" '{decision: "block", reason: $question}'
