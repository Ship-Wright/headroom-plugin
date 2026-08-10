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
HUGE_BYTES=${DANGI_HUGE_BYTES:-131072}  # at/above this TRUE size, advise delegation over compression
NUDGE_COOLDOWN=60      # seconds between context nudges per session
NOTIFY_COOLDOWN=300    # seconds between macOS notifications per session
HPREFIX="mcp__headroom__"
# Shared state helpers (STATE_DIR, structured-file checks, canon_path). The
# plugin layout ships lib/ next to this script; a legacy flat install keeps a
# sibling copy. A partial copy must not kill the hook — offender learning
# simply switches off when the helpers are absent.
_here="$(cd "$(dirname "$0")" 2>/dev/null && pwd || echo .)"
# shellcheck disable=SC1090,SC1091
for _sl in "$_here/lib/headroom-state.sh" "$_here/headroom-state.sh"; do
  [ -f "$_sl" ] && { . "$_sl"; break; }
done
type canon_path >/dev/null 2>&1 || canon_path() { printf '%s' "$1"; }
# HOME can be unset in hook environments (set -u would kill every tool call);
# degrade to a temp-dir state location rather than dying.
[ -n "${STATE_DIR:-}" ] || STATE_DIR="${HEADROOM_STATE_DIR:-${HOME:-${TMPDIR:-/tmp}}/.claude/headroom-indicator}"

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

# True-size resolution: the hook payload is truncated (~10K chars) before we
# see it, so for file-backed reads the on-disk size — not the payload size —
# decides what advice to give and what size to report. The TRIGGER stays on
# payload size (a written-but-never-read file must not nudge); the file size
# only escalates the tier and the reported KB.
fp=""
case "$tool" in
  Read)
    fp=$(printf '%s' "$in" | jq -r '.tool_input.file_path // empty' 2>/dev/null) || fp=""
    ;;
  Bash)
    fp=$(printf '%s' "${cmd:-}" \
        | grep -oE "[^[:space:]\"'\\\\]+\\.(json|jsonl|ndjson|csv|tsv|log)" | tail -1)
    ;;
esac
fsize=0
if [ -n "$fp" ] && [ -f "$fp" ]; then
  fp=$(canon_path "$fp")
  fsize=$(wc -c < "$fp" 2>/dev/null | tr -d ' ') || fsize=0
  case "$fsize" in (*[!0-9]*|"") fsize=0 ;; esac
fi
# Escalate to the on-disk size ONLY for whole-file ingests: a bare cat/hcat
# of exactly that file, or a Read with no offset/limit. A file merely NAMED
# in a filter (`grep ERROR big.log`, `jq .x big.json`) or read bounded did
# not put its full size into context — reporting the file size there would
# misstate the output and mis-route the advice to delegation.
ingest=0
if [ "$fsize" -gt 0 ] 2>/dev/null; then
  case "$tool" in
    Read)
      printf '%s' "$in" | jq -e '.tool_input | has("offset") or has("limit")' >/dev/null 2>&1 || ingest=1
      ;;
    Bash)
      bare=$(printf '%s' "${cmd:-}" | sed -nE 's/^[[:space:]]*([^[:space:]]*\/)?(cat|hcat)[[:space:]]+("([^"]+)"|'\''([^'\'']+)'\''|([^[:space:]]+))[[:space:]]*$/\4\5\6/p')
      if [ -n "$bare" ] && [ "$(canon_path "$bare")" = "$fp" ]; then ingest=1; fi
      ;;
  esac
fi
eff=$size
[ "$ingest" -eq 1 ] && [ "$fsize" -gt "$eff" ] 2>/dev/null && eff=$fsize
kb=$(( eff / 1024 ))

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
  # File-aware: when the source is a real file on disk whose path is JSON-safe
  # (no whitespace/quotes/backslashes — it is printf'd into a JSON literal),
  # point advice at it by name. Extension no longer matters: the huge tier
  # fires precisely on extensionless/mislabeled dumps, and handing the model a
  # literal "<path>" placeholder there sends a subagent to a nonexistent file.
  target="<path>"
  if [ -n "$fp" ] \
     && printf '%s' "$fp" | LC_ALL=C grep -qE "^[^[:space:]\"'\\\\]+$"; then
    target="$fp"
  fi
  # Offender memory: a file-backed blob that burned context once is recorded so
  # hcat-gate gates its next access regardless of extension — but only when the
  # file actually LOOKS structured (innate extension or 512-byte sniff): a big
  # source file read once must not get itself compression-gated for 14 days.
  # Canonical exact-path lines ("<epoch> <path>"), deduped, TTL-pruned on every
  # write. Best effort; off when the shared lib is absent.
  if [ -n "$fp" ] && [ -f "$fp" ] && [ "$fsize" -ge "$NUDGE_BYTES" ] 2>/dev/null \
     && type structured_ext >/dev/null 2>&1 \
     && { structured_ext "$fp" || sniff_structured "$fp"; }; then
    off="$STATE_DIR/offenders"
    ttl=${HEADROOM_OFFENDER_TTL:-1209600}
    keep=$(LC_ALL=C awk -v now="$now" -v ttl="$ttl" -v p="$fp" '
      {path=substr($0, index($0, " ") + 1)}
      path != p && ($1+0) >= now - ttl {print}' "$off" 2>/dev/null)
    { { [ -n "$keep" ] && printf '%s\n' "$keep"; printf '%s %s\n' "$now" "$fp"; } > "$off"; } \
      2>/dev/null || true
  fi

  batch_note=""
  [ "$batched" -gt 0 ] 2>/dev/null \
    && batch_note=" (+$batched more large outputs slipped by while I was quiet)"
  # Size-tiered router: medium blobs → compress in place (hcat / MCP compress);
  # past HUGE_BYTES at the source, compression in place would still flood the
  # window — delegation to a disposable subagent is the right strategy.
  # The huge tier sends a SUBAGENT at the named path, so it must be a real,
  # stat-able file; the medium tier's hcat advice may name an unverified token
  # (it is advice for Claude, who knows the file it just read).
  if [ "$eff" -ge "$HUGE_BYTES" ] 2>/dev/null && [ "$target" != "<path>" ] && [ -f "$fp" ]; then
    printf '{"hookSpecificOutput":{"hookEventName":"PostToolUse","additionalContext":"🤖 Dangi: that %s output is ~%s KB at the source — too large to compress in place.%s Do not re-read it raw: spawn a disposable subagent (Agent tool) to read/analyze \\"%s\\" and return only conclusions or an hcat-compressed digest — the raw bytes then never enter this context. (headroom_compress on a blob this size would still flood the window.)"}}' "$tool" "$kb" "$batch_note" "$target"
  elif [ "$eff" -ge "$HUGE_BYTES" ] 2>/dev/null; then
    printf '{"hookSpecificOutput":{"hookEventName":"PostToolUse","additionalContext":"🤖 Dangi: that %s output is ~%s KB — too large to compress in place, and it is not traceable to a file on disk.%s Re-derive it inside a disposable subagent (Agent tool) that fetches/produces and analyzes it, returning only conclusions or an hcat-compressed digest — the raw bytes then never enter this context."}}' "$tool" "$kb" "$batch_note"
  else
    printf '{"hookSpecificOutput":{"hookEventName":"PostToolUse","additionalContext":"🤖 Dangi: that %s output was ~%s KB and was not compressed.%s If it came from a file on disk, run hcat \\"%s\\" via Bash next time (plugin installs have it on PATH; legacy installs use ~/.claude/hcat) — raw bytes never enter context. If it is not file-backed but structured/repetitive, use mcp__headroom__headroom_compress, or read+compress it inside a disposable subagent that returns only the compressed text."}}' "$tool" "$kb" "$batch_note" "$target"
  fi
fi
exit 0
