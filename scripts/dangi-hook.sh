#!/usr/bin/env bash
# dangi — real-time compression detector for the headroom-usage-indicator plugin.
# Registered as a Claude Code PostToolUse hook (matcher "*"). Reads the hook
# input JSON on stdin; when a tool result >= NUDGE_BYTES lands and wasn't
# produced by headroom, nudges Claude via additionalContext (rate-limited)
# and pings the user with a macOS notification (rate-limited harder).
# MUST always exit 0 and print nothing except the single JSON nudge —
# anything else disturbs every tool call of every session.

set -u

NUDGE_BYTES=4096       # tool outputs at least this large are compression candidates
NUDGE_COOLDOWN=60      # seconds between context nudges per session
NOTIFY_COOLDOWN=300    # seconds between macOS notifications per session
HPREFIX="mcp__headroom__"
STATE_DIR="${HEADROOM_STATE_DIR:-$HOME/.claude/headroom-indicator}"

in=$(cat)

tool=$(printf '%s' "$in" | jq -r '.tool_name // empty' 2>/dev/null) || exit 0
tool=$(printf '%s' "$tool" | tr -cd 'A-Za-z0-9_.-')   # defensive: tool name feeds JSON + AppleScript
[ -n "$tool" ] || exit 0
case "$tool" in "$HPREFIX"*) exit 0 ;; esac
# Edits/writes echo the code being changed — never compression targets.
case "$tool" in Edit|Write|MultiEdit|NotebookEdit) exit 0 ;; esac

size=$(printf '%s' "$in" | jq -r '.tool_response // "" | tostring | length' 2>/dev/null) || exit 0
case "$size" in (*[!0-9]*|"") exit 0 ;; esac
[ "$size" -ge "$NUDGE_BYTES" ] || exit 0

sid=$(printf '%s' "$in" | jq -r '.session_id // "unknown"' 2>/dev/null) || sid="unknown"
[ -n "$sid" ] || sid="unknown"
now=$(date +%s)
kb=$(( size / 1024 ))

state="$STATE_DIR/session-$sid.dangi"
last_nudge=0; last_notify=0
if [ -f "$state" ]; then
  { read -r last_nudge last_notify < "$state"; } 2>/dev/null || true
fi
case "$last_nudge" in (*[!0-9]*|"") last_nudge=0 ;; esac
case "$last_notify" in (*[!0-9]*|"") last_notify=0 ;; esac

if [ -z "${DANGI_NO_NOTIFY:-}" ] && command -v osascript >/dev/null 2>&1 \
   && [ $(( now - last_notify )) -ge "$NOTIFY_COOLDOWN" ]; then
  osascript -e "display notification \"A ${kb} KB ${tool} output just landed uncompressed — headroom could shrink it.\" with title \"🤖 Dangi\"" >/dev/null 2>&1 &
  last_notify=$now
fi

nudge=0
if [ $(( now - last_nudge )) -ge "$NUDGE_COOLDOWN" ]; then
  nudge=1
  last_nudge=$now
fi

if mkdir -p "$STATE_DIR" 2>/dev/null; then
  { printf '%s %s\n' "$last_nudge" "$last_notify" > "$state"; } 2>/dev/null || true
fi

if [ "$nudge" -eq 1 ]; then
  printf '{"hookSpecificOutput":{"hookEventName":"PostToolUse","additionalContext":"🤖 Dangi: that %s output was ~%s KB and was not compressed. If it came from a file on disk, run hcat <path> (in ~/.claude) via Bash next time — raw bytes never enter context. If it is not file-backed but structured/repetitive, use mcp__headroom__headroom_compress, or read+compress it inside a disposable subagent that returns only the compressed text."}}' "$tool" "$kb"
fi
exit 0
