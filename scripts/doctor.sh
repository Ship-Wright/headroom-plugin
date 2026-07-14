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
#                        and wire settings.json statusLine at it (.bak first);
#                        merge-aware: an existing non-headroom command is kept
#                        under _headroomStatusLineBackup and chained before the
#                        badge (same semantics as the SKILL.md installer)
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
# sibling "python" of `headroom` on PATH → the `headroom` console script's
# shebang interpreter (pip --user / pipx layouts ship no sibling python) →
# $VENV_DIR/bin/python.
shebang_interp() {  # shebang_interp <script> — interpreter path from its #! line
  local line rest
  IFS= read -r line < "$1" 2>/dev/null || return 1
  case $line in '#!'*) ;; *) return 1 ;; esac
  rest=${line#'#!'}
  # shellcheck disable=SC2086
  set -- $rest
  [ $# -ge 1 ] || return 1
  case $1 in
    */env|env) [ $# -ge 2 ] || return 1; command -v "$2" 2>/dev/null ;;
    *) printf '%s\n' "$1" ;;
  esac
}

PY=""
HCAT_PY_BROKEN=0
if [ -n "${HCAT_PYTHON:-}" ]; then
  if [ -x "$HCAT_PYTHON" ] && "$HCAT_PYTHON" -c 'import headroom' >/dev/null 2>&1; then
    PY=$HCAT_PYTHON
  else
    HCAT_PY_BROKEN=1
  fi
else
  HR_CLI=$(command -v headroom 2>/dev/null || true)
  for cand in "${HR_CLI:+$(dirname "$HR_CLI")/python}" \
              "$([ -n "$HR_CLI" ] && shebang_interp "$HR_CLI")" \
              "$VENV_DIR/bin/python"; do
    if [ -n "$cand" ] && [ -x "$cand" ] && "$cand" -c 'import headroom' >/dev/null 2>&1; then
      PY=$cand; break
    fi
  done
fi
if [ -n "$PY" ]; then
  say ok "engine python: $PY (import headroom works)"
elif [ "$HCAT_PY_BROKEN" -eq 1 ] && [ "$FIX" -eq 1 ]; then
  # the override is authoritative, so a bootstrapped venv would never be used:
  # bootstrapping here burns time every run and the check still never turns ok
  say FAIL "HCAT_PYTHON is set but broken ($HCAT_PYTHON) — unset it or point it at a working python (refusing to bootstrap while it is set)"
elif [ "$FIX" -eq 1 ]; then
  venv_preexisted=0; [ -e "$VENV_DIR" ] && venv_preexisted=1
  if python3 -m venv "$VENV_DIR" >/dev/null 2>&1 \
     && [ -x "$VENV_DIR/bin/pip" ] \
     && "$VENV_DIR/bin/pip" install headroom >/dev/null 2>&1 \
     && [ -x "$VENV_DIR/bin/python" ] \
     && "$VENV_DIR/bin/python" -c 'import headroom' >/dev/null 2>&1; then
    say fixed "engine bootstrapped: python3 -m venv $VENV_DIR + pip install headroom"
  else
    # never leave a half-created venv behind: its bin/python would pass -x
    # checks elsewhere while pip and the headroom package are missing
    [ "$venv_preexisted" -eq 0 ] && rm -rf "$VENV_DIR"
    hint=""
    command -v apt-get >/dev/null 2>&1 \
      && hint=" (on Debian/Ubuntu, python3 -m venv needs the python3-venv package: sudo apt install python3-venv)"
    say FAIL "engine bootstrap failed — try by hand: python3 -m venv $VENV_DIR && $VENV_DIR/bin/pip install headroom$hint"
  fi
elif [ "$HCAT_PY_BROKEN" -eq 1 ]; then
  say fixable "engine python not found — HCAT_PYTHON is set but broken ($HCAT_PYTHON); unset it or point it at a working python (--fix refuses to bootstrap while it is set)"
else
  say fixable "engine python not found — --fix creates $VENV_DIR and pip-installs headroom"
fi

# --- 3. bin/hcat + a real smoke compression of a generated ~26 KB JSON
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

# --- 4b. bundled .mcp.json — parses, names the headroom server, launcher runs
MCP_DEF="$PLUGIN_ROOT/.mcp.json"
if [ "$HAVE_JQ" -eq 0 ]; then
  say skip ".mcp.json (needs jq)"
elif ! jq -e '.mcpServers.headroom.command' "$MCP_DEF" >/dev/null 2>&1; then
  say FAIL ".mcp.json missing/invalid or lacks the headroom server ($MCP_DEF)"
else
  mcp_cmd=$(jq -r '.mcpServers.headroom.command' "$MCP_DEF")
  mcp_path=${mcp_cmd//'${CLAUDE_PLUGIN_ROOT}'/$PLUGIN_ROOT}
  mcp_path=${mcp_path//\"/}
  if [ -x "$mcp_path" ]; then
    say ok ".mcp.json registers the headroom MCP (launcher: $mcp_path)"
  else
    say FAIL ".mcp.json launcher missing or not executable ($mcp_path)"
  fi
fi

# --- 5–8. settings.json + ~/.claude legacy state (need jq)
LEGACY_JQ='[.hooks // {} | to_entries[] | .value[]?.hooks[]?
      | select((.command // "") | test("dangi-hook\\.sh|hcat-gate\\.sh"))
      | select((.command // "") | contains("CLAUDE_PLUGIN_ROOT") | not)] | length'
if [ "$HAVE_JQ" -eq 0 ]; then
  say skip "legacy hooks / statusLine / stale copies (need jq)"
else
  # 5. settings.json must be a single valid JSON document before anything may
  # read or edit it — jq errors otherwise collapse into false "ok" results,
  # and a rewrite of a multi-document file stays unparseable
  SETTINGS_OK=1
  if [ -f "$SETTINGS" ]; then
    ndocs=$(jq -n '[inputs] | length' "$SETTINGS" 2>/dev/null) || ndocs=bad
    if [ "$ndocs" = "1" ]; then
      say ok "settings.json parses as a single JSON document"
    else
      SETTINGS_OK=0
      say FAIL "settings.json is not a single valid JSON document ($SETTINGS) — repair it by hand; all settings-editing fixes are disabled"
    fi
  fi

  # 6. legacy dual-registration: pre-plugin hook entries in settings.json that
  # now double-fire alongside the plugin-native hooks. settings.local.json in
  # the same directory is scanned too — its hooks fire just the same.
  legacy=0
  if [ "$SETTINGS_OK" -eq 0 ]; then
    legacy=1   # unparseable: scan inconclusive, keep the stale-copy gate shut
    say skip "legacy hooks (settings.json unparseable — repair it first)"
  else
    if [ -f "$SETTINGS" ]; then
      legacy=$(jq "$LEGACY_JQ" "$SETTINGS" 2>/dev/null || echo 0)
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
          "$SETTINGS" > "$TMPD/settings.new" && cat "$TMPD/settings.new" > "$SETTINGS"; then
        say fixed "removed $legacy legacy hook entries from settings.json (backup: settings.json.bak.*)"
        legacy=0
      else
        say FAIL "could not rewrite settings.json to drop the legacy hook entries"
      fi
    else
      say fixable "legacy hooks in settings.json ($legacy entries double-firing with the plugin-native hooks)"
    fi
  fi
  LOCAL_SETTINGS=$(dirname "$SETTINGS")/settings.local.json
  legacy_local=0
  if [ -f "$LOCAL_SETTINGS" ]; then
    legacy_local=$(jq "$LEGACY_JQ" "$LOCAL_SETTINGS" 2>/dev/null) || legacy_local=""
    case $legacy_local in
      ''|*[!0-9]*) legacy_local=-1 ;;   # unparseable → scan inconclusive
    esac
    if [ "$legacy_local" -gt 0 ]; then
      say FAIL "legacy hooks in settings.local.json ($legacy_local entries) — the doctor only edits settings.json; remove them from $LOCAL_SETTINGS by hand"
    elif [ "$legacy_local" -lt 0 ]; then
      say FAIL "settings.local.json did not parse ($LOCAL_SETTINGS) — legacy-hook scan inconclusive"
    fi
  fi

  # 7. statusLine wiring — merge-aware, mirroring the SKILL installer: an
  # existing non-headroom command is preserved under _headroomStatusLineBackup
  # and chained ahead of the badge
  sl=""
  [ "$SETTINGS_OK" -eq 1 ] && [ -f "$SETTINGS" ] && sl=$(jq -r '.statusLine.command // empty' "$SETTINGS" 2>/dev/null)
  if [ "$SETTINGS_OK" -eq 0 ]; then
    say skip "statusLine (settings.json unparseable — repair it first)"
  elif printf '%s' "$sl" | grep -q "headroom-statusline"; then
    say ok "statusLine wired ($sl)"
  elif [ "$FIX" -eq 1 ]; then
    mkdir -p "$CLAUDE_DIR"
    [ -f "$SETTINGS" ] || printf '{}\n' > "$SETTINGS"
    backup_settings
    sl_path="$CLAUDE_DIR/headroom-statusline.sh"
    case $sl_path in
      "$HOME"/*) sl_disp="~${sl_path#"$HOME"}" ;;
      *)         sl_disp=$sl_path ;;
    esac
    # same decision + command template as the SKILL.md installer python
    sl_merge_jq=$(cat <<'JQEOF'
(._headroomStatusLineBackup // null) as $bak
| (.statusLine // null) as $ex
| (if ($bak | type) == "object" and $bak.type == "command" and (($bak.command // "") != "") then $bak
   elif ($ex | type) == "object" and $ex.type == "command" and (($ex.command // "") != "")
        and (($ex.command | contains("headroom-statusline.sh")) | not)
        and (($ex.command | contains("mcp__headroom__headroom_compress")) | not)
   then $ex else null end) as $base
| if $base != null then
    ._headroomStatusLineBackup = $base
    | .statusLine = {type: "command",
        command: ("in=$(cat); left=$(printf '%s' \"$in\" | { " + $base.command
                  + "; }); hr=$(printf '%s' \"$in\" | " + $hr
                  + "); printf '%s  %s' \"$left\" \"$hr\""),
        refreshInterval: 1}
  else
    .statusLine = {type: "command", command: $hr, refreshInterval: 1}
  end
JQEOF
)
    if cp "$PLUGIN_ROOT/scripts/statusline.sh" "$sl_path" && chmod +x "$sl_path" \
       && jq --arg hr "bash \"$sl_path\"" "$sl_merge_jq" \
          "$SETTINGS" > "$TMPD/settings.sl" && cat "$TMPD/settings.sl" > "$SETTINGS"; then
      if [ -n "$sl" ] && ! printf '%s' "$sl" | grep -q "mcp__headroom__headroom_compress"; then
        say fixed "statusLine merged — your command kept and backed up under _headroomStatusLineBackup, badge appended ($sl_disp)"
      else
        say fixed "statusLine wired to $sl_disp (script copied, backup: settings.json.bak.*)"
      fi
    else
      say FAIL "could not copy statusline.sh to $sl_path and wire settings.json"
    fi
  elif [ -n "$sl" ]; then
    say fixable "statusLine present without the headroom badge — --fix appends it, preserving your command under _headroomStatusLineBackup"
  else
    say fixable "statusLine not wired — --fix copies the script to $CLAUDE_DIR and points settings.json at it"
  fi

  # 7b. the wired copy must match the plugin's statusline.sh (upgrade path)
  sl_copy="$CLAUDE_DIR/headroom-statusline.sh"
  if [ ! -f "$sl_copy" ]; then
    say skip "statusline copy refresh (no $sl_copy yet)"
  elif cmp -s "$PLUGIN_ROOT/scripts/statusline.sh" "$sl_copy"; then
    say ok "statusline copy is current ($sl_copy)"
  elif [ "$FIX" -eq 1 ]; then
    if cp "$PLUGIN_ROOT/scripts/statusline.sh" "$sl_copy" && chmod +x "$sl_copy"; then
      say fixed "statusline copy refreshed from the plugin ($sl_copy)"
    else
      say FAIL "could not refresh $sl_copy from the plugin"
    fi
  else
    say fixable "statusline copy differs from the plugin's scripts/statusline.sh — --fix refreshes it"
  fi

  # 8. stale pre-plugin copies in ~/.claude (headroom-statusline.sh stays: the
  # statusLine points at it by design)
  stale=""
  for f in dangi-hook.sh hcat-gate.sh hcat; do
    [ -e "$CLAUDE_DIR/$f" ] && stale="$stale $f"
  done
  if [ -z "$stale" ]; then
    say ok "no stale pre-plugin copies in $CLAUDE_DIR"
  elif [ "$FIX" -eq 1 ]; then
    if [ "$PLUGNAT" -eq 1 ] && [ "$legacy" -eq 0 ] && [ "$legacy_local" -eq 0 ]; then
      for f in $stale; do rm -f "$CLAUDE_DIR/$f"; done
      say fixed "removed stale copies from $CLAUDE_DIR:$stale"
      printf '%-7s - %s\n' note "project-level .claude/settings.json files are not scanned — if a project still registers the deleted paths, remove those entries by hand"
    else
      say skip "stale copies kept:$stale (plugin-native hooks unconfirmed, or legacy hooks still registered in settings.json / settings.local.json)"
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
