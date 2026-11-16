#!/bin/sh
# Claude Code's end-of-turn question: a turn that ends on a message long enough to be a plan, a
# proposal or a verdict, with funes not consulted since the prompt, is sent back once with one
# line asking whether it rings a bell. Whether to look is left to the model. Fired by Stop, whose
# payload arrives on stdin.
#
# The question goes back as additional context: Claude Code hands it to the model as a system
# reminder and records it as an attachment, which makes no turn in the memory.
#
# A payload or a transcript this script cannot read ends the turn as it was: nothing is printed.
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

# Whether funes was called since the prompt `$2` in the transcript `$1`: an assistant line naming
# one of its tools. The tool listings Claude Code logs name them too, hence the line's type.
consulted() {
    [ -n "$1" ] && [ -r "$1" ] && [ -n "$2" ] || return 1
    from=$(grep -n -m 1 -F "\"promptId\":\"$2\"" "$1" | cut -d: -f1)
    [ -n "$from" ] || return 1
    tail -n "+$from" "$1" | grep -F '"name":"mcp__funes__' |
        "$jq" -e -n 'any(inputs; .type == "assistant")' >/dev/null 2>&1
}

jq=$(find_bin jq || true)
[ -n "$jq" ] && [ -x "$jq" ] || exit 0

# One field a line: whether a Stop hook already continued this turn, the length of its last
# message, the transcript and the prompt.
fields=$("$jq" -r '(.stop_hook_active == true), ((.last_assistant_message // "") | length),
    (.transcript_path // ""), (.prompt_id // "")' 2>/dev/null) || exit 0
{
    read -r active
    read -r chars
    read -r transcript
    read -r prompt
} <<EOF
$fields
EOF

[ "$active" = false ] || exit 0
[ "${chars:-0}" -ge "$MIN_CHARS" ] 2>/dev/null || exit 0
! consulted "$transcript" "$prompt" || exit 0

"$jq" -n -c --arg question "$QUESTION" \
    '{hookSpecificOutput: {hookEventName: "Stop", additionalContext: $question}}'
