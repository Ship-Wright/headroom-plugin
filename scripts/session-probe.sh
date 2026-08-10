#!/usr/bin/env bash
# session-probe — SessionStart micro-doctor for the headroom-usage-indicator
# plugin. A fast subset of doctor.sh that runs once per session: silent when
# healthy, one additionalContext line when the install is broken — so an outage
# is announced at session start instead of silently mimicking the idle badge.
# Checks stay cheap (existence/parse checks only, no `import headroom`): the
# gate and hcat verify the import at use time and record failures themselves.
# MUST always exit 0 and print nothing except the single JSON context line.

set -u

STATE_DIR="${HEADROOM_STATE_DIR:-${HOME:-${TMPDIR:-/tmp}}/.claude/headroom-indicator}"

problems=""
add_problem() { problems="${problems:+$problems; }$1"; }

note_error() {  # note_error <component> <message> — flips the badge to broken
  { mkdir -p "$STATE_DIR" \
    && printf '%s %s %s\n' "$(date +%s)" "$1" "$2" > "$STATE_DIR/last-error"; } 2>/dev/null || true
}

# --- 1. jq — every hook and the badge lean on it
if ! command -v jq >/dev/null 2>&1; then
  # Inconsistent install (the plugin is running but its toolchain is gone):
  # record it so the badge shows broken, not just idle.
  note_error jq "jq not found — hooks and badge are disabled"
  add_problem "jq not found (brew install jq / apt install jq)"
fi

# --- 2. hcat present + executable (plugin layout, legacy sibling fallback)
here="$(cd "$(dirname "$0")" && pwd)"
HCAT="$here/../bin/hcat"
[ -x "$HCAT" ] || HCAT="$here/hcat"
if [ ! -x "$HCAT" ]; then
  note_error install "hcat missing or not executable"
  add_problem "hcat is missing or not executable — reinstall the plugin or run /doctor"
fi

# --- 3. engine python resolvable (existence only — import is checked at use time)
if [ -n "${HCAT_PYTHON:-}" ]; then
  # An explicit override pointing nowhere is a breakage, not an absence.
  if [ ! -x "$HCAT_PYTHON" ]; then
    note_error engine "HCAT_PYTHON is set but not executable ($HCAT_PYTHON)"
    add_problem "HCAT_PYTHON points at a non-executable python ($HCAT_PYTHON) — unset or fix it"
  fi
else
  py=""
  HR_CLI=$(command -v headroom 2>/dev/null || true)
  [ -n "$HR_CLI" ] && [ -x "$(dirname "$HR_CLI")/python" ] && py="$(dirname "$HR_CLI")/python"
  [ -z "$py" ] && [ -n "$HR_CLI" ] && py="$HR_CLI"
  [ -z "$py" ] && [ -x "${HOME:-}/.headroom-venv/bin/python" ] && py="$HOME/.headroom-venv/bin/python"
  if [ -z "$py" ]; then
    # Never-installed engine is the ordinary red-idle state, not a breakage:
    # say it once at session start, but do not flip the badge to broken.
    add_problem "headroom engine not installed — run /doctor --fix to bootstrap it"
  fi
fi

# --- 4. bundled price table parses (when jq is available to check)
PRICES="$here/../data/model-prices.json"
[ -f "$PRICES" ] || PRICES="$here/headroom-model-prices.json"
if [ -f "$PRICES" ] && command -v jq >/dev/null 2>&1 \
   && ! jq -e '(.prices | type) == "array"' "$PRICES" >/dev/null 2>&1; then
  note_error prices "model price table invalid ($PRICES)"
  add_problem "model price table is invalid ($PRICES) — badge money figures disabled"
fi

# --- 5. surface a fresh recorded error even when today's checks pass
if [ -z "$problems" ] && [ -f "$STATE_DIR/last-error" ]; then
  { read -r le_ts _le_comp le_msg < "$STATE_DIR/last-error"; } 2>/dev/null || true
  case "${le_ts:-}" in (*[!0-9]*|"") le_ts=0 ;; esac
  le_age=$(( $(date +%s) - le_ts ))
  if [ "$le_age" -ge 0 ] 2>/dev/null && [ "$le_age" -le 86400 ] 2>/dev/null; then
    add_problem "a recent failure was recorded: ${le_msg:-see last-error} — run /doctor (doctor clears this once healthy)"
  fi
fi

# --- 6. healthy and quiet? surface the previous session's invoice, once.
# The ledger hook (Stop/SessionEnd) records what each session saved and what
# it burned; the next session start is the natural moment to show the bill.
LEDGER="$STATE_DIR/ledger.jsonl"
invoice=""
if [ -z "$problems" ] && [ -f "$LEDGER" ] && command -v jq >/dev/null 2>&1; then
  last=$(tail -1 "$LEDGER" 2>/dev/null) || last=""
  key=$(printf '%s' "$last" | jq -r '"\(.session_id)|\(.ts)"' 2>/dev/null) || key=""
  mark=$(cat "$STATE_DIR/last-invoice-mark" 2>/dev/null) || mark=""
  if [ -n "$key" ] && [ "$key" != "null|null" ] && [ "$key" != "$mark" ]; then
    invoice=$(printf '%s' "$last" | jq -r '
      def k: if . >= 1000 then (((. / 100 | floor) / 10 | tostring) + "k") else tostring end;
      "last session: saved ~" + (.save_tokens | k) + " tok"
      + (if .save_usd then " (~$" + .save_usd + ")" else "" end)
      + (if .miss_count > 0 then
           " · " + (.miss_count | tostring) + " big output(s) went uncompressed (~"
           + (.miss_est_tokens | k) + " tok"
           + (if .miss_usd then " ≈ $" + .miss_usd + " left on the table" else "" end)
           + (if (.top_misses[0].path // null) then " — biggest: " + .top_misses[0].path else "" end)
           + ")"
         else "" end)' 2>/dev/null) || invoice=""
    [ -n "$invoice" ] && { printf '%s' "$key" > "$STATE_DIR/last-invoice-mark"; } 2>/dev/null
  fi
fi

if [ -n "$problems" ] && command -v jq >/dev/null 2>&1; then
  jq -cn --arg p "$problems" \
    '{hookSpecificOutput:{hookEventName:"SessionStart",
      additionalContext:("🤖 headroom probe: " + $p)}}' 2>/dev/null
elif [ -n "$invoice" ]; then
  jq -cn --arg p "$invoice" \
    '{hookSpecificOutput:{hookEventName:"SessionStart",
      additionalContext:("🤖 headroom invoice: " + $p)}}' 2>/dev/null
elif [ -n "$problems" ]; then
  # No jq: emit the JSON by hand from a fixed-format string (problems built
  # above contain no quotes/backslashes in the no-jq path).
  printf '{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"🤖 headroom probe: %s"}}' \
    "$(printf '%s' "$problems" | tr -d '"\\')"
fi
exit 0
