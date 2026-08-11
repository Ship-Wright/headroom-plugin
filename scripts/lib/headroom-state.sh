#!/usr/bin/env bash
# headroom-state.sh — shared state helpers for the plugin's shell entry points
# (hcat-gate.sh, dangi-hook.sh, session-probe.sh, bin/hcat). Sourced, never
# executed; must not print or exit. One definition of the state dir, the
# last-error writer, and the "does this file look structured?" checks, so the
# cross-script file formats stay a single contract instead of hand-synced
# copies. The Python heredoc in bin/hcat mirrors the last-error format
# ("<epoch> <component> <message>", one line, overwritten) — keep in sync.

# HOME can be unset in hook environments (set -u would kill the caller);
# degrade to a temp-dir state location rather than dying.
STATE_DIR="${HEADROOM_STATE_DIR:-${HOME:-${TMPDIR:-/tmp}}/.claude/headroom-indicator}"

note_error() {  # note_error <component> <message> — flips the badge to broken; best effort
  { mkdir -p "$STATE_DIR" \
    && printf '%s %s %s\n' "$(date +%s)" "$1" "$2" > "$STATE_DIR/last-error"; } 2>/dev/null || true
}

structured_ext() {  # structured_ext <path> — extension is on the innate structured list
  case "$1" in *.json|*.jsonl|*.ndjson|*.csv|*.tsv|*.log) return 0 ;; esac
  return 1
}

sniff_structured() {  # sniff_structured <path> — first 512 bytes look JSON- or CSV-shaped
  local h fc c1 c2
  h=$(head -c 512 "$1" 2>/dev/null | tr -d '\0')
  fc=$(printf '%s' "$h" | LC_ALL=C awk '{gsub(/^[ \t\r]+/,""); if (length($0)) {print substr($0,1,1); exit}}')
  case "$fc" in '{'|'[') return 0 ;; esac
  # delimiter vitals: two rows with the same 3+ comma/tab count reads as CSV/TSV
  c1=$(printf '%s' "$h" | sed -n 1p | tr -cd ',\t' | wc -c | tr -d ' ')
  c2=$(printf '%s' "$h" | sed -n 2p | tr -cd ',\t' | wc -c | tr -d ' ')
  [ "$c1" -ge 3 ] 2>/dev/null && [ "$c1" -eq "$c2" ] 2>/dev/null && return 0
  return 1
}

canon_path() {  # canon_path <path> — absolute form (dir resolved), or the input unchanged
  local dir d
  dir=$(dirname "$1")
  case "$dir" in -*) dir="./$dir" ;; esac   # a leading '-' must not read as a cd flag
  # Unset CDPATH so a user CDPATH can't cd elsewhere and print that dir instead.
  d=$(unset CDPATH; cd "$dir" 2>/dev/null && pwd) || d=""
  if [ -n "$d" ]; then printf '%s/%s' "$d" "$(basename "$1")"; else printf '%s' "$1"; fi
}
