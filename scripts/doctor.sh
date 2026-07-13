#!/usr/bin/env bash
# doctor.sh — setup health checks (and --fix repairs) for the
# headroom-usage-indicator plugin.
#
# Read-only by default: prints aligned ok/FAIL/fixable/skip lines and exits 0
# iff nothing FAILed. `--fix` applies the repairs reported as fixable:
#   * engine bootstrap — python3 -m venv ~/.headroom-venv + pip install headroom
#   * legacy hooks     — remove pre-plugin dangi/gate hook entries from
#                        settings.json (timestamped .bak written first)
#   * statusLine       — copy scripts/statusline.sh to ~/.claude/headroom-statusline.sh
#                        and wire settings.json statusLine at it (.bak first)
#   * stale copies     — delete pre-plugin script copies in ~/.claude, but only
#                        once plugin-native hooks are confirmed and no legacy
#                        hook entries remain
# All fixes are idempotent: a second --fix run changes nothing.
#
# Env overrides (used by the hermetic test suite):
#   DOCTOR_SETTINGS    settings.json path   (default ~/.claude/settings.json)
#   DOCTOR_CLAUDE_DIR  legacy-copy dir      (default ~/.claude)
#   DOCTOR_VENV_DIR    engine venv dir      (default ~/.headroom-venv)
#   HCAT_PYTHON        engine python override (authoritative, no fallback —
#                      same contract as bin/hcat)
#
# Exit codes: 0 no FAILs · 1 at least one FAIL · 2 usage
set -u

SELF_DIR=$(cd "$(dirname "$0")" && pwd)
PLUGIN_ROOT=$(cd "$SELF_DIR/.." && pwd)
SETTINGS=${DOCTOR_SETTINGS:-$HOME/.claude/settings.json}
CLAUDE_DIR=${DOCTOR_CLAUDE_DIR:-$HOME/.claude}
VENV_DIR=${DOCTOR_VENV_DIR:-$HOME/.headroom-venv}

FIX=0
for arg in "$@"; do
  case $arg in
    --fix) FIX=1 ;;
    *) echo "doctor: unknown argument: $arg (usage: doctor.sh [--fix])" >&2; exit 2 ;;
  esac
done

OK=0; FIXABLE=0; FAILED=0; SKIPPED=0
say() {  # say <ok|fixed|FAIL|fixable|skip> <message> — aligned status lines
  printf '%-7s - %s\n' "$1" "$2"
  case $1 in
    ok|fixed) OK=$((OK+1)) ;;
    fixable)  FIXABLE=$((FIXABLE+1)) ;;
    FAIL)     FAILED=$((FAILED+1)) ;;
    skip)     SKIPPED=$((SKIPPED+1)) ;;
  esac
}

TMPD=$(mktemp -d) || exit 1
trap 'rm -rf "$TMPD"' EXIT

# one timestamped settings.json backup per doctor run, before the first edit
BAK_DONE=0
backup_settings() {
  [ "$BAK_DONE" -eq 1 ] && return 0
  BAK_DONE=1
  [ -f "$SETTINGS" ] && cp "$SETTINGS" "$SETTINGS.bak.$(date +%Y%m%d%H%M%S)"
  return 0
}

# --- 1. jq — everything else that reads JSON leans on it
HAVE_JQ=0
if command -v jq >/dev/null 2>&1; then
  HAVE_JQ=1
  say ok "jq found ($(command -v jq))"
else
  say FAIL "jq not found — install it (brew install jq / apt install jq)"
fi

# --- 2. headroom engine python
# Resolution (first hit wins, mirrors bin/hcat): $HCAT_PYTHON (authoritative) →
# sibling "python" of `headroom` on PATH → $VENV_DIR/bin/python.
PY=""
if [ -n "${HCAT_PYTHON:-}" ]; then
  [ -x "$HCAT_PYTHON" ] && PY=$HCAT_PYTHON
else
  for cand in "$(dirname "$(command -v headroom 2>/dev/null || echo /nonexistent)")/python" "$VENV_DIR/bin/python"; do
    if [ -x "$cand" ]; then PY=$cand; break; fi
  done
fi
if [ -n "$PY" ] && "$PY" -c 'import headroom' >/dev/null 2>&1; then
  say ok "engine python: $PY (import headroom works)"
else
  PY=""
  if [ "$FIX" -eq 1 ]; then
    if python3 -m venv "$VENV_DIR" >/dev/null 2>&1 \
       && [ -x "$VENV_DIR/bin/pip" ] \
       && "$VENV_DIR/bin/pip" install headroom >/dev/null 2>&1 \
       && [ -x "$VENV_DIR/bin/python" ] \
       && "$VENV_DIR/bin/python" -c 'import headroom' >/dev/null 2>&1; then
      say fixed "engine bootstrapped: python3 -m venv $VENV_DIR + pip install headroom"
    else
      say FAIL "engine bootstrap failed — try by hand: python3 -m venv $VENV_DIR && $VENV_DIR/bin/pip install headroom"
    fi
  else
    say fixable "engine python not found — --fix creates $VENV_DIR and pip-installs headroom"
  fi
fi

# --- 3. bin/hcat + a real smoke compression of a generated ~20 KB JSON
HCAT="$PLUGIN_ROOT/bin/hcat"
if [ ! -x "$HCAT" ]; then
  say FAIL "bin/hcat missing or not executable ($HCAT)"
elif [ -z "$PY" ]; then
  # engine absent at detection time — even if --fix just bootstrapped it, a
  # stubbed/new venv is smoke-tested on the next doctor run, not this one
  say skip "hcat smoke (engine missing — fix the engine, then re-run the doctor)"
else
  say ok "bin/hcat is executable"
  "$PY" -c '
import json, sys
rows = [{"id": i, "user": "user_%d" % (i % 50), "event": "click",
         "ts": 1700000000 + i, "ok": True} for i in range(250)]
open(sys.argv[1], "w").write(json.dumps(rows, indent=2))' "$TMPD/big.json" >/dev/null 2>&1
  if [ ! -s "$TMPD/big.json" ]; then
    say FAIL "hcat smoke: could not generate fixture JSON with $PY"
  else
    out=$(HCAT_PYTHON="$PY" HEADROOM_WORKSPACE_DIR="$TMPD/ws" bash "$HCAT" "$TMPD/big.json" 2>"$TMPD/hcat.err"); rc=$?
    raw=$(($(wc -c < "$TMPD/big.json")))
    got=$(printf '%s' "$out" | wc -c); got=$((got))
    if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q "── hcat:" && [ "$got" -lt "$raw" ]; then
      say ok "hcat smoke: compressed a ${raw}-byte JSON to ${got} bytes"
    else
      say FAIL "hcat smoke: hcat exit $rc ($(head -1 "$TMPD/hcat.err" 2>/dev/null))"
    fi
  fi
fi

# --- 4. plugin-native hooks definition
HOOKS_JSON="$PLUGIN_ROOT/hooks/hooks.json"
PLUGNAT=0
if [ "$HAVE_JQ" -eq 0 ]; then
  say skip "hooks.json (needs jq)"
elif jq -e '.hooks.PreToolUse and .hooks.PostToolUse' "$HOOKS_JSON" >/dev/null 2>&1; then
  PLUGNAT=1
  say ok "hooks.json parses with PreToolUse + PostToolUse (plugin-native hooks)"
else
  say FAIL "hooks.json missing/invalid or lacks PreToolUse+PostToolUse ($HOOKS_JSON)"
fi

# --- 5–7. settings.json + ~/.claude legacy state (need jq)
if [ "$HAVE_JQ" -eq 0 ]; then
  say skip "legacy hooks / statusLine / stale copies (need jq)"
else
  # 5. legacy dual-registration: pre-plugin hook entries in settings.json that
  # now double-fire alongside the plugin-native hooks
  legacy=0
  if [ -f "$SETTINGS" ]; then
    legacy=$(jq '[.hooks // {} | to_entries[] | .value[]?.hooks[]?
      | select((.command // "") | test("dangi-hook\\.sh|hcat-gate\\.sh"))
      | select((.command // "") | contains("CLAUDE_PLUGIN_ROOT") | not)] | length' \
      "$SETTINGS" 2>/dev/null || echo 0)
  fi
  if [ "$legacy" -eq 0 ]; then
    say ok "no legacy hook registrations in settings.json"
  elif [ "$FIX" -eq 1 ]; then
    backup_settings
    if jq '.hooks |= (with_entries(.value |= (map(.hooks |= map(select(
            (((.command // "") | test("dangi-hook\\.sh|hcat-gate\\.sh"))
             and ((.command // "") | contains("CLAUDE_PLUGIN_ROOT") | not)) | not)))
          | map(select((.hooks | length) > 0))))
        | with_entries(select((.value | length) > 0)))
        | if .hooks == {} then del(.hooks) else . end' \
        "$SETTINGS" > "$TMPD/settings.new" && mv "$TMPD/settings.new" "$SETTINGS"; then
      say fixed "removed $legacy legacy hook entries from settings.json (backup: settings.json.bak.*)"
      legacy=0
    else
      say FAIL "could not rewrite settings.json to drop the legacy hook entries"
    fi
  else
    say fixable "legacy hooks in settings.json ($legacy entries double-firing with the plugin-native hooks)"
  fi

  # 6. statusLine wiring
  sl=""
  [ -f "$SETTINGS" ] && sl=$(jq -r '.statusLine.command // empty' "$SETTINGS" 2>/dev/null)
  if printf '%s' "$sl" | grep -q "headroom-statusline"; then
    say ok "statusLine wired ($sl)"
  elif [ -n "$sl" ]; then
    say skip "statusLine is a non-headroom command — leaving it alone ($sl)"
  elif [ "$FIX" -eq 1 ]; then
    mkdir -p "$CLAUDE_DIR"
    [ -f "$SETTINGS" ] || printf '{}\n' > "$SETTINGS"
    backup_settings
    sl_path="$CLAUDE_DIR/headroom-statusline.sh"
    case $sl_path in
      "$HOME"/*) sl_disp="~${sl_path#"$HOME"}" ;;
      *)         sl_disp=$sl_path ;;
    esac
    if cp "$PLUGIN_ROOT/scripts/statusline.sh" "$sl_path" && chmod +x "$sl_path" \
       && jq --arg cmd "$sl_disp" '.statusLine = {type: "command", command: $cmd}' \
          "$SETTINGS" > "$TMPD/settings.sl" && mv "$TMPD/settings.sl" "$SETTINGS"; then
      say fixed "statusLine wired to $sl_disp (script copied, backup: settings.json.bak.*)"
    else
      say FAIL "could not copy statusline.sh to $sl_path and wire settings.json"
    fi
  else
    say fixable "statusLine not wired — --fix copies the script to $CLAUDE_DIR and points settings.json at it"
  fi

  # 7. stale pre-plugin copies in ~/.claude (headroom-statusline.sh stays: the
  # statusLine points at it by design)
  stale=""
  for f in dangi-hook.sh hcat-gate.sh hcat; do
    [ -e "$CLAUDE_DIR/$f" ] && stale="$stale $f"
  done
  if [ -z "$stale" ]; then
    say ok "no stale pre-plugin copies in $CLAUDE_DIR"
  elif [ "$FIX" -eq 1 ]; then
    if [ "$PLUGNAT" -eq 1 ] && [ "$legacy" -eq 0 ]; then
      for f in $stale; do rm -f "$CLAUDE_DIR/$f"; done
      say fixed "removed stale copies from $CLAUDE_DIR:$stale"
    else
      say skip "stale copies kept:$stale (plugin-native hooks unconfirmed or legacy hooks still registered)"
    fi
  else
    say fixable "stale copies in $CLAUDE_DIR:$stale"
  fi
fi

# --- summary
echo
summary="$OK ok"
[ "$FIXABLE" -gt 0 ] && summary="$summary · $FIXABLE fixable"
[ "$FAILED"  -gt 0 ] && summary="$summary · $FAILED failed"
[ "$SKIPPED" -gt 0 ] && summary="$summary · $SKIPPED skipped"
echo "$summary"
if [ "$FIXABLE" -gt 0 ] && [ "$FIX" -eq 0 ]; then
  echo "→ re-run with --fix to repair."
fi
[ "$FAILED" -eq 0 ]
