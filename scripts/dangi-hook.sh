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
# HOME can be unset in hook environments (set -u would kill every tool call);
# degrade to a temp-dir state location rather than dying.
STATE_DIR="${HEADROOM_STATE_DIR:-${HOME:-${TMPDIR:-/tmp}}/.claude/headroom-indicator}"

in=$(cat)

tool=$(printf '%s' "$in" | jq -r '.tool_name // empty' 2>/dev/null) || exit 0
tool=$(printf '%s' "$tool" | tr -cd 'A-Za-z0-9_.-')   # defensive: tool name feeds JSON + AppleScript
[ -n "$tool" ] || exit 0
case "$tool" in "$HPREFIX"*) exit 0 ;; esac
# Edits/writes echo the code being changed; web results are prose — never
# compression targets. Neither are image responses (base64, not text).
case "$tool" in Edit|Write|MultiEdit|NotebookEdit|WebFetch|WebSearch) exit 0 ;; esac
if printf '%s' "$in" | jq -e '.tool_response | tostring | contains("\"type\":\"image\"")' >/dev/null 2>&1; then
  exit 0
fi

# hcat invocations ARE compressions — never nudge on their output. The check
# is STRUCTURAL: only a Bash call whose .tool_input.command actually invokes
# hcat is exempt; outputs that merely QUOTE a receipt line (grep/cat over
# docs or tests) are still missed opportunities.
if [ "$tool" = "Bash" ]; then
  cmd=$(printf '%s' "$in" | jq -r '.tool_input.command // empty' 2>/dev/null) || cmd=""
  if printf '%s' "$cmd" | LC_ALL=C grep -Eq '(^|[|;&][[:space:]]*|\$\([[:space:]]*|/)hcat([[:space:]]|$)'; then
    exit 0
  fi
fi

txt=$(printf '%s' "$in" | jq -j '.tool_response // "" | tostring' 2>/dev/null) || exit 0
# Size in BYTES (jq length counts codepoints and undercounts non-ASCII).
size=$(printf '%s' "$txt" | wc -c | tr -d ' ') || exit 0
case "$size" in (*[!0-9]*|"") exit 0 ;; esac
[ "$size" -ge "$NUDGE_BYTES" ] || exit 0

sid=$(printf '%s' "$in" | jq -r '.session_id // "unknown"' 2>/dev/null) || sid="unknown"
[ -n "$sid" ] || sid="unknown"
now=${DANGI_NOW:-$(date +%s)}   # DANGI_NOW is a test seam for the cooldown clock
case "$now" in (*[!0-9]*|"") now=$(date +%s) ;; esac
kb=$(( size / 1024 ))

# Best-effort lock so parallel tool batches don't double-nudge (macOS has no
# flock(1); mkdir is atomic). Steal a stale lock (>5s); if we still can't get
# it, proceed unlocked — a hook must never block.
lock="$STATE_DIR/.lock-$sid"
locked=0
if mkdir -p "$STATE_DIR" 2>/dev/null; then
  if mkdir "$lock" 2>/dev/null; then
    locked=1
  else
    lock_age=$(( now - $(stat -c %Y "$lock" 2>/dev/null || stat -f %m "$lock" 2>/dev/null || echo "$now") ))
    if [ "$lock_age" -gt 5 ]; then
      rmdir "$lock" 2>/dev/null || true
      mkdir "$lock" 2>/dev/null && locked=1
    fi
  fi
fi

state="$STATE_DIR/session-$sid.dangi"
last_nudge=0; last_notify=0; pending=0
if [ -f "$state" ]; then
  # 3rd field (pending) may be absent in state files written by older versions.
  { read -r last_nudge last_notify pending < "$state"; } 2>/dev/null || true
fi
case "$last_nudge" in (*[!0-9]*|"") last_nudge=0 ;; esac
case "$last_notify" in (*[!0-9]*|"") last_notify=0 ;; esac
case "$pending" in (*[!0-9]*|"") pending=0 ;; esac

# Fire-and-forget desktop notification: osascript on macOS, notify-send on
# Linux. Backgrounded — a hook must never wait on a notification daemon.
if [ -z "${DANGI_NO_NOTIFY:-}" ] && [ $(( now - last_notify )) -ge "$NOTIFY_COOLDOWN" ]; then
  notify_msg="A ${kb} KB ${tool} output just landed uncompressed — headroom could shrink it."
  if command -v osascript >/dev/null 2>&1; then
    osascript -e "display notification \"$notify_msg\" with title \"🤖 Dangi\"" >/dev/null 2>&1 &
    last_notify=$now
  elif command -v notify-send >/dev/null 2>&1; then
    notify-send "🤖 Dangi" "$notify_msg" >/dev/null 2>&1 &
    last_notify=$now
  fi
fi

# Rate-limit the context nudge, but count the big blobs that slipped by while
# quiet so the next nudge can say how many were missed (batched, not one-per).
nudge=0; batched=0
if [ $(( now - last_nudge )) -ge "$NUDGE_COOLDOWN" ]; then
  nudge=1
  last_nudge=$now
  batched=$pending      # surface how many were suppressed since the last nudge
  pending=0
else
  pending=$(( pending + 1 ))
fi

if mkdir -p "$STATE_DIR" 2>/dev/null; then
  { printf '%s %s %s\n' "$last_nudge" "$last_notify" "$pending" > "$state"; } 2>/dev/null || true
fi
[ "$locked" -eq 1 ] && rmdir "$lock" 2>/dev/null

if [ "$nudge" -eq 1 ]; then
  # File-aware: when the Bash command names a structured file, point hcat at it
  # by name instead of a generic <path>. High precision — only a bare token
  # ending in a structured extension (never quotes/spaces/backslashes, so it is
  # always JSON-safe here). Otherwise the generic placeholder is kept.
  target="<path>"
  if [ "$tool" = "Bash" ]; then
    f=$(printf '%s' "${cmd:-}" \
        | grep -oE "[^[:space:]\"'\\\\]+\\.(json|jsonl|ndjson|csv|tsv|log)" | tail -1)
    [ -n "$f" ] && target="$f"
  fi
  batch_note=""
  [ "$batched" -gt 0 ] 2>/dev/null \
    && batch_note=" (+$batched more large outputs slipped by while I was quiet)"
  printf '{"hookSpecificOutput":{"hookEventName":"PostToolUse","additionalContext":"🤖 Dangi: that %s output was ~%s KB and was not compressed.%s If it came from a file on disk, run hcat \\"%s\\" via Bash next time (plugin installs have it on PATH; legacy installs use ~/.claude/hcat) — raw bytes never enter context. If it is not file-backed but structured/repetitive, use mcp__headroom__headroom_compress, or read+compress it inside a disposable subagent that returns only the compressed text."}}' "$tool" "$kb" "$batch_note" "$target"
fi
exit 0
