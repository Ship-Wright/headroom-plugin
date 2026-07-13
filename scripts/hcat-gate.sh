#!/usr/bin/env bash
# hcat-gate — PreToolUse gate for the headroom-usage-indicator plugin.
# Registered on the Read tool. When Claude is about to Read a large structured
# file (json/jsonl/ndjson/csv/tsv/log), deny ONCE per file per session with a
# pointer to `hcat`, which compresses at the source so the raw bytes never
# enter context. A retry of the same Read passes — the gate is a redirect with
# an escape hatch, never a wall. If hcat can't run (headroom missing), the
# gate allows everything.
# MUST always exit 0 and print nothing except the single JSON decision.

set -u

GATE_BYTES=${HCAT_GATE_BYTES:-16384}   # gate files at least this large
STATE_DIR="${HEADROOM_STATE_DIR:-$HOME/.claude/headroom-indicator}"

[ -n "${HCAT_GATE_OFF:-}" ] && exit 0

in=$(cat)

tool=$(printf '%s' "$in" | jq -r '.tool_name // empty' 2>/dev/null) || exit 0
case "$tool" in
  Read)
    fp=$(printf '%s' "$in" | jq -r '.tool_input.file_path // empty' 2>/dev/null) || exit 0
    ;;
  Bash)
    # Only a bare, single-file `cat <path>` — a raw whole-file dump. Pipes,
    # redirects, flags, and bounded peeks (head/tail) are real processing.
    cmd=$(printf '%s' "$in" | jq -r '.tool_input.command // empty' 2>/dev/null) || exit 0
    case "$cmd" in *'|'*|*'>'*|*'<'*|*';'*|*'&'*|*'$('*|*'`'*) exit 0 ;; esac
    fp=$(printf '%s' "$cmd" | sed -nE 's/^[[:space:]]*cat[[:space:]]+("([^"]+)"|'\''([^'\'']+)'\''|([^[:space:]]+))[[:space:]]*$/\2\3\4/p')
    ;;
  *) exit 0 ;;
esac
[ -n "$fp" ] && [ -f "$fp" ] || exit 0

case "$fp" in
  *.json|*.jsonl|*.ndjson|*.csv|*.tsv|*.log) : ;;
  *) exit 0 ;;
esac

size=$(wc -c < "$fp" 2>/dev/null | tr -d ' ') || exit 0
case "$size" in (*[!0-9]*|"") exit 0 ;; esac
[ "$size" -ge "$GATE_BYTES" ] || exit 0

# hcat must actually be runnable, or we'd deny Reads and point at a dead end.
HCAT="$(cd "$(dirname "$0")" && pwd)/hcat"
[ -x "$HCAT" ] || exit 0
if [ -n "${HCAT_PYTHON:-}" ]; then
  [ -x "$HCAT_PYTHON" ] || exit 0
elif [ ! -x "$HOME/.headroom-venv/bin/python" ] && ! command -v headroom >/dev/null 2>&1; then
  exit 0
fi

sid=$(printf '%s' "$in" | jq -r '.session_id // "unknown"' 2>/dev/null) || sid="unknown"
[ -n "$sid" ] || sid="unknown"

# Escape hatch: deny each file only once per session; a retry passes.
state="$STATE_DIR/session-$sid.gate"
if [ -f "$state" ] && grep -qFx -- "$fp" "$state" 2>/dev/null; then
  exit 0
fi
if mkdir -p "$STATE_DIR" 2>/dev/null; then
  { printf '%s\n' "$fp" >> "$state"; } 2>/dev/null || true
fi

kb=$(( size / 1024 ))
jq -cn --arg fp "$fp" --arg hcat "$HCAT" --arg kb "$kb" \
  '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",
    permissionDecisionReason:("🤖 hcat-gate: \($fp) is a \($kb) KB structured file. Run `\($hcat) \"\($fp)\"` in Bash instead — it prints a compressed rendering (raw bytes never enter context; Read the path with offset/limit later for exact details). To read it raw anyway, just Read it again — this gate only fires once per file.")}}' 2>/dev/null
exit 0
