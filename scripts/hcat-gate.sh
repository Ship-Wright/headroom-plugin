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
# HOME can be unset in hook environments (set -u would kill every Read);
# degrade to a temp-dir state location rather than dying.
STATE_DIR="${HEADROOM_STATE_DIR:-${HOME:-${TMPDIR:-/tmp}}/.claude/headroom-indicator}"

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
# Plugin layout ships it in bin/ (on Bash PATH while the plugin is enabled);
# a legacy ~/.claude install keeps it as a sibling of this script.
here="$(cd "$(dirname "$0")" && pwd)"
HCAT="$here/../bin/hcat"
legacy=0
if [ ! -x "$HCAT" ]; then
  HCAT="$here/hcat"
  legacy=1
fi
[ -x "$HCAT" ] || exit 0
py=""
if [ -n "${HCAT_PYTHON:-}" ]; then
  py="$HCAT_PYTHON"
elif [ -x "${HOME:-}/.headroom-venv/bin/python" ]; then
  py="$HOME/.headroom-venv/bin/python"
fi
if [ -n "$py" ]; then
  [ -x "$py" ] || exit 0
  # A half-created venv passes -x yet cannot `import headroom` (hcat exits 4)
  # — verify the import and fail OPEN (allow the Read) on a broken engine.
  # Only runs on the rare deny path, so the interpreter spawn is fine.
  "$py" -c 'import headroom' >/dev/null 2>&1 || exit 0
else
  command -v headroom >/dev/null 2>&1 || exit 0
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
# Install-aware pointer: the plugin layout has hcat on Bash PATH; a legacy
# sibling install does not, so cite the absolute path we actually resolved.
if [ "$legacy" -eq 1 ]; then
  hcat_cmd="$HCAT"
  path_note=""
else
  hcat_cmd="hcat"
  path_note=" (hcat is on PATH while this plugin is enabled)"
fi
jq -cn --arg fp "$fp" --arg kb "$kb" --arg hcat "$hcat_cmd" --arg note "$path_note" \
  '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",
    permissionDecisionReason:("🤖 hcat-gate: \($fp) is a \($kb) KB structured file. Run `\($hcat) \"\($fp)\"` in Bash instead\($note) — it prints a compressed rendering (raw bytes never enter context; Read the path with offset/limit later for exact details). To read it raw anyway, just Read it again — this gate only fires once per file.")}}' 2>/dev/null
exit 0
