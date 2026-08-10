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

note_error() {  # note_error <message> — record a broken engine for the badge, best effort
  { mkdir -p "$STATE_DIR" \
    && printf '%s engine %s\n' "$(date +%s)" "$1" > "$STATE_DIR/last-error"; } 2>/dev/null || true
}

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

size=$(wc -c < "$fp" 2>/dev/null | tr -d ' ') || exit 0
case "$size" in (*[!0-9]*|"") exit 0 ;; esac
[ "$size" -ge "$GATE_BYTES" ] || exit 0

# Eligibility: structured extension (innate list), OR a learned offender (this
# exact path burned context before — recorded by dangi-hook, TTL-decayed), OR
# a 512-byte structural sniff for big files whose extension lies (extensionless
# API dumps, .txt JSON). The learned/sniff tiers close the narrow-gate misses
# without widening the fragile static pattern list.
eligible=0
case "$fp" in
  *.json|*.jsonl|*.ndjson|*.csv|*.tsv|*.log) eligible=1 ;;
esac
if [ "$eligible" -eq 0 ] && [ -f "$STATE_DIR/offenders" ]; then
  now_g=$(date +%s)
  ttl=${HEADROOM_OFFENDER_TTL:-1209600}   # learned entries decay after 14 days
  if LC_ALL=C awk -v now="$now_g" -v ttl="$ttl" -v p="$fp" '
       {path=substr($0, index($0, " ") + 1)}
       path == p && ($1+0) >= now - ttl {found=1; exit}
       END{exit !found}' "$STATE_DIR/offenders" 2>/dev/null; then
    eligible=1
  fi
fi
if [ "$eligible" -eq 0 ] && [ -z "${HCAT_GATE_NO_SNIFF:-}" ]; then
  h=$(head -c 512 "$fp" 2>/dev/null | tr -d '\0')
  fc=$(printf '%s' "$h" | LC_ALL=C awk '{gsub(/^[ \t\r]+/,""); if (length($0)) {print substr($0,1,1); exit}}')
  case "$fc" in '{'|'[') eligible=1 ;; esac
  if [ "$eligible" -eq 0 ]; then
    # delimiter vitals: two rows with the same 3+ comma/tab count reads as CSV/TSV
    c1=$(printf '%s' "$h" | sed -n 1p | tr -cd ',\t' | wc -c | tr -d ' ')
    c2=$(printf '%s' "$h" | sed -n 2p | tr -cd ',\t' | wc -c | tr -d ' ')
    [ "$c1" -ge 3 ] 2>/dev/null && [ "$c1" -eq "$c2" ] 2>/dev/null && eligible=1
  fi
fi
[ "$eligible" -eq 1 ] || exit 0

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
  # A resolved-but-broken engine is a real outage the fail-open would otherwise
  # hide — record it so the badge can show "broken" instead of mimicking idle.
  # (An engine that was never installed is NOT recorded: that is the ordinary
  # red-idle state, not a breakage.)
  if [ ! -x "$py" ]; then
    note_error "engine python not executable ($py) — gate failing open; run /doctor"
    exit 0
  fi
  # A half-created venv passes -x yet cannot `import headroom` (hcat exits 4)
  # — verify the import and fail OPEN (allow the Read) on a broken engine.
  # Only runs on the rare deny path, so the interpreter spawn is fine.
  if ! "$py" -c 'import headroom' >/dev/null 2>&1; then
    note_error "engine import failed ($py) — gate failing open; run /doctor"
    exit 0
  fi
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

# Bash `cat` gets REWRITTEN, not denied: the gate already computed the exact
# replacement command, and updatedInput delivers it in one shot — no deny→
# re-plan→retry round trip, no compliance bet. The hcat receipt line makes the
# substitution visible in the output. The once-per-file state still applies:
# if the rewrite already happened once this session (e.g. hcat failed and
# Claude re-ran cat), the raw command passes — a rewrite loop must not wedge.
# Paths/commands with shell-metacharacters fall through to the deny path
# rather than risk building an injectable command line.
if [ "$tool" = "Bash" ] && [ -z "${HCAT_GATE_NO_REWRITE:-}" ]; then
  safe=1
  case "$fp$hcat_cmd" in *'"'*|*'\'*|*'$'*|*'`'*) safe=0 ;; esac
  if [ "$safe" -eq 1 ]; then
    printf '%s' "$in" | jq -c --arg cmd "\"$hcat_cmd\" \"$fp\"" --arg fp "$fp" --arg kb "$kb" \
      '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"allow",
        permissionDecisionReason:("🤖 hcat-gate: rewrote the raw `cat` to `" + $cmd + "` — \($fp) is \($kb) KB of structured data; hcat prints a compressed rendering with a receipt (raw bytes never enter context; Read the path with offset/limit for exact details)."),
        updatedInput: ((.tool_input // {}) | .command = $cmd)}}' 2>/dev/null
    exit 0
  fi
fi

jq -cn --arg fp "$fp" --arg kb "$kb" --arg hcat "$hcat_cmd" --arg note "$path_note" \
  '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",
    permissionDecisionReason:("🤖 hcat-gate: \($fp) is a \($kb) KB structured file. Run `\($hcat) \"\($fp)\"` in Bash instead\($note) — it prints a compressed rendering (raw bytes never enter context; Read the path with offset/limit later for exact details). To read it raw anyway, just Read it again — this gate only fires once per file.")}}' 2>/dev/null
exit 0
