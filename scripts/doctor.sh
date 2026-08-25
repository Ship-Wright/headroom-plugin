#!/usr/bin/env bash
# doctor.sh — setup health checks (and --fix repairs) for the
# headroom-usage-indicator plugin.
#
# Read-only by default: prints aligned ok/FAIL/fixable/skip lines and exits 0
# iff nothing FAILed. `--fix` applies the repairs reported as fixable:
#   * engine bootstrap — python3 -m venv ~/.headroom-venv + pip install "headroom-ai[all]"
#   * legacy hooks     — remove pre-plugin dangi/gate hook entries from
#                        settings.json (timestamped .bak written first)
#   * statusLine       — copy scripts/statusline.sh to ~/.claude/headroom-statusline.sh
#                        and wire settings.json statusLine at it (.bak first);
#                        merge-aware: an existing non-headroom command is kept
#                        under _headroomStatusLineBackup and chained before the
#                        badge (same semantics as the SKILL.md installer)
#   * wired-missing copy — re-copy statusline.sh (+ lib deps, price table) to
#                        ~/.claude when settings already point at the canonical
#                        path but the script is absent; if the wiring named it
#                        by a respelling bash can never expand (a quoted ~),
#                        also rewrites statusLine.command to the absolute path
#                        (.bak first)
#   * quoted mcp cmd   — strip literal quotes from the .mcp.json command
#                        (.bak first); MCP commands are spawned without a
#                        shell, so quotes break the launcher path
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

# Ambient-health state (see statusline.sh): checked before the run because the
# hcat smoke test itself clears engine errors on a working compression. Source
# the shared STATE_DIR definition; fall back to the inline default if the lib
# is absent (legacy flat install).
# shellcheck disable=SC1090,SC1091
for _sl in "$SELF_DIR/lib/headroom-state.sh" "$SELF_DIR/headroom-state.sh"; do
  [ -f "$_sl" ] && { . "$_sl"; break; }
done
HEALTH_STATE_DIR="${STATE_DIR:-${HEADROOM_STATE_DIR:-${HOME:-${TMPDIR:-/tmp}}/.claude/headroom-indicator}}"
HEALTH_HAD_ERROR=0
HEALTH_ERR_SNAP=""
if [ -f "$HEALTH_STATE_DIR/last-error" ]; then
  HEALTH_HAD_ERROR=1
  # Snapshot the CONTENT, not just existence: a --fix run can take a while,
  # and the final all-clear must not wipe a fresh error some other session
  # recorded mid-run.
  HEALTH_ERR_SNAP=$(cat "$HEALTH_STATE_DIR/last-error" 2>/dev/null) || HEALTH_ERR_SNAP=""
fi

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
  if [ -x "$HCAT_PYTHON" ] && "$HCAT_PYTHON" -c 'import headroom.compress' >/dev/null 2>&1; then
    PY=$HCAT_PYTHON
  else
    HCAT_PY_BROKEN=1
  fi
else
  HR_CLI=$(command -v headroom 2>/dev/null || true)
  for cand in "${HR_CLI:+$(dirname "$HR_CLI")/python}" \
              "$([ -n "$HR_CLI" ] && shebang_interp "$HR_CLI")" \
              "$VENV_DIR/bin/python"; do
    if [ -n "$cand" ] && [ -x "$cand" ] && "$cand" -c 'import headroom.compress' >/dev/null 2>&1; then
      PY=$cand; break
    fi
  done
fi
if [ -n "$PY" ]; then
  say ok "engine python: $PY (import headroom.compress works)"
elif [ "$HCAT_PY_BROKEN" -eq 1 ] && [ "$FIX" -eq 1 ]; then
  # the override is authoritative, so a bootstrapped venv would never be used:
  # bootstrapping here burns time every run and the check still never turns ok
  say FAIL "HCAT_PYTHON is set but broken ($HCAT_PYTHON) — unset it or point it at a working python (refusing to bootstrap while it is set)"
elif [ "$FIX" -eq 1 ]; then
  venv_preexisted=0; [ -e "$VENV_DIR" ] && venv_preexisted=1
  if python3 -m venv "$VENV_DIR" >/dev/null 2>&1 \
     && [ -x "$VENV_DIR/bin/pip" ] \
     && "$VENV_DIR/bin/pip" install "headroom-ai[all]" >/dev/null 2>&1 \
     && [ -x "$VENV_DIR/bin/python" ] \
     && "$VENV_DIR/bin/python" -c 'import headroom.compress' >/dev/null 2>&1; then
    say fixed "engine bootstrapped: python3 -m venv $VENV_DIR + pip install \"headroom-ai[all]\""
  else
    # never leave a half-created venv behind: its bin/python would pass -x
    # checks elsewhere while pip and the headroom package are missing
    [ "$venv_preexisted" -eq 0 ] && rm -rf "$VENV_DIR"
    hint=""
    command -v apt-get >/dev/null 2>&1 \
      && hint=" (on Debian/Ubuntu, python3 -m venv needs the python3-venv package: sudo apt install python3-venv)"
    say FAIL "engine bootstrap failed — try by hand: python3 -m venv $VENV_DIR && $VENV_DIR/bin/pip install \"headroom-ai[all]\"$hint"
  fi
elif [ "$HCAT_PY_BROKEN" -eq 1 ]; then
  say fixable "engine python not found — HCAT_PYTHON is set but broken ($HCAT_PYTHON); unset it or point it at a working python (--fix refuses to bootstrap while it is set)"
else
  say fixable "engine python not found — --fix creates $VENV_DIR and pip-installs headroom-ai"
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
  # Claude Code expands ${CLAUDE_PLUGIN_ROOT} and spawns the result directly
  # (posix_spawn, no shell) — judge the string exactly as spawned; quotes are
  # never unwrapped, they become part of the filename.
  mcp_path=${mcp_cmd//'${CLAUDE_PLUGIN_ROOT}'/$PLUGIN_ROOT}
  if [ -x "$mcp_path" ]; then
    say ok ".mcp.json registers the headroom MCP (launcher: $mcp_path)"
  elif [ -x "${mcp_path//\"/}" ]; then
    # the launcher exists but the command wraps it in literal quotes (shipped
    # v2.5→v2.7.2): ENOENT at spawn → the /plugin ✗, server never connects
    if [ "$FIX" -eq 1 ]; then
      # the backup must actually land before we overwrite the only copy on
      # disk — a swallowed backup failure followed by a rewrite would claim
      # "(backup: ...)" while leaving no recovery copy at all
      if ! cp "$MCP_DEF" "$MCP_DEF.bak.$(date +%Y%m%d%H%M%S)" 2>/dev/null; then
        say FAIL "could not back up $MCP_DEF before rewriting it — refusing to overwrite without one"
      elif jq --arg c "${mcp_cmd//\"/}" '.mcpServers.headroom.command = $c' \
          "$MCP_DEF" > "$TMPD/mcp.new" && cat "$TMPD/mcp.new" > "$MCP_DEF"; then
        say fixed "unquoted the .mcp.json command — MCP commands are spawned without a shell (backup: .mcp.json.bak.*)"
      else
        say FAIL "could not rewrite $MCP_DEF to drop the literal quotes"
      fi
    else
      say fixable ".mcp.json command carries literal quotes — spawned without a shell they break the launcher path, so the bundled MCP never connects (--fix unquotes it)"
    fi
  else
    say FAIL ".mcp.json launcher missing or not executable ($mcp_path)"
  fi
fi

# --- 4c. bundled model price table — the badge reads it so adding a model is a
# data edit, not a code change; --fix copies it beside the statusline copy
PRICES_DEF="$PLUGIN_ROOT/data/model-prices.json"
if [ "$HAVE_JQ" -eq 0 ]; then
  say skip "model-prices.json (needs jq)"
elif jq -e '(.prices | type) == "array" and (.prices | length) > 0' "$PRICES_DEF" >/dev/null 2>&1; then
  say ok "model-prices.json parses ($(jq -r '.prices | length' "$PRICES_DEF") model prices)"
else
  say FAIL "model-prices.json missing or invalid ($PRICES_DEF)"
fi

# --- 5–8. settings.json + ~/.claude legacy state (need jq)
LEGACY_JQ='[.hooks // {} | to_entries[] | .value[]?.hooks[]?
      | select((.command // "") | test("dangi-hook\\.sh|hcat-gate\\.sh"))
      | select((.command // "") | contains("CLAUDE_PLUGIN_ROOT") | not)] | length'
# the one strip program every legacy-hook fix uses (settings.json,
# settings.local.json, project-level settings) — one definition, no drift
LEGACY_STRIP_JQ='.hooks |= (with_entries(.value |= (map(.hooks |= map(select(
        (((.command // "") | test("dangi-hook\\.sh|hcat-gate\\.sh"))
         and ((.command // "") | contains("CLAUDE_PLUGIN_ROOT") | not)) | not)))
      | map(select((.hooks | length) > 0))))
      | with_entries(select((.value | length) > 0)))
      | if .hooks == {} then del(.hooks) else . end'
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
      if jq "$LEGACY_STRIP_JQ" \
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
    if [ "$legacy_local" -gt 0 ] && [ "$FIX" -eq 1 ]; then
      cp "$LOCAL_SETTINGS" "$LOCAL_SETTINGS.bak.$(date +%Y%m%d%H%M%S)" 2>/dev/null || true
      if jq "$LEGACY_STRIP_JQ" "$LOCAL_SETTINGS" > "$TMPD/settings.local.new" \
         && cat "$TMPD/settings.local.new" > "$LOCAL_SETTINGS"; then
        say fixed "removed $legacy_local legacy hook entries from settings.local.json (backup: settings.local.json.bak.*)"
        legacy_local=0
      else
        say FAIL "could not rewrite settings.local.json to drop the legacy hook entries"
      fi
    elif [ "$legacy_local" -gt 0 ]; then
      say fixable "legacy hooks in settings.local.json ($legacy_local entries double-firing with the plugin-native hooks)"
    elif [ "$legacy_local" -lt 0 ]; then
      say FAIL "settings.local.json did not parse ($LOCAL_SETTINGS) — legacy-hook scan inconclusive"
    fi
  fi

  # 6b. project-level settings in the CURRENT directory: the same legacy-hook
  # scan + fix, for the project the doctor is being run from. Other projects'
  # .claude dirs are out of reach — the stale-copy note below says so.
  PROJ_DIR=${DOCTOR_PROJECT_DIR:-$PWD}
  proj_legacy=0
  for pj in "$PROJ_DIR/.claude/settings.json" "$PROJ_DIR/.claude/settings.local.json"; do
    [ -f "$pj" ] || continue
    [ "$pj" -ef "$SETTINGS" ] && continue          # already scanned above
    [ "$pj" -ef "$LOCAL_SETTINGS" ] && continue
    pl=$(jq "$LEGACY_JQ" "$pj" 2>/dev/null) || pl=""
    case $pl in
      ''|*[!0-9]*)
        proj_legacy=1
        say FAIL "project settings did not parse ($pj) — legacy-hook scan inconclusive"
        continue ;;
    esac
    if [ "$pl" -eq 0 ]; then
      say ok "no legacy hook registrations in $pj"
    elif [ "$FIX" -eq 1 ]; then
      cp "$pj" "$pj.bak.$(date +%Y%m%d%H%M%S)" 2>/dev/null || true
      if jq "$LEGACY_STRIP_JQ" "$pj" > "$TMPD/proj.new" && cat "$TMPD/proj.new" > "$pj"; then
        say fixed "removed $pl legacy hook entries from $pj (backup: $pj.bak.*)"
      else
        proj_legacy=1
        say FAIL "could not rewrite $pj to drop the legacy hook entries"
      fi
    else
      proj_legacy=1
      say fixable "legacy hooks in project settings ($pj: $pl entries double-firing with the plugin-native hooks)"
    fi
  done

  # 7. statusLine wiring — merge-aware, mirroring the SKILL installer: an
  # existing non-headroom command is preserved under _headroomStatusLineBackup
  # and chained ahead of the badge
  sl=""
  [ "$SETTINGS_OK" -eq 1 ] && [ -f "$SETTINGS" ] && sl=$(jq -r '.statusLine.command // empty' "$SETTINGS" 2>/dev/null)
  if [ "$SETTINGS_OK" -eq 0 ]; then
    say skip "statusLine (settings.json unparseable — repair it first)"
  elif printf '%s' "$sl" | grep -q "headroom-statusline"; then
    # A bare string match is not proof the script is on disk. Extract every path
    # token that names the statusline script — absolute, quoted-tilde, or a
    # foreign home synced from dotfiles — expand a leading ~, and require at
    # least one to exist; otherwise the badge renders nothing while 7b/7c only
    # `skip` (guarded on the same absent file) and block 9 clears any recorded
    # failure — a silent pass for every respelling of the canonical path. Only
    # the canonical $CLAUDE_DIR copy is ours to re-copy under --fix; a script
    # missing at a hand-edited custom path is a FAIL, not a fixable — the
    # doctor won't guess where to place a copy (no-orphan policy), and a
    # fixable that --fix cannot repair would break the fixable contract. A
    # command with no extractable path token is trusted as wired.
    # Candidate tokens are whole quote/space-delimited words, not a substring
    # regex match: a substring match has no token boundary, so it silently
    # truncates a suffixed filename (headroom-statusline.sh.bak -> verifies
    # the wrong, unsuffixed file) and can start mid-token on a false match
    # (matching the '/' inside "$HOME/..." instead of the token's real start).
    # Each token is then structurally validated (starts with ~/ or /, ends
    # exactly at "headroom-statusline.sh") before being trusted as a real
    # candidate; anything else falls through to the no-extractable-token
    # trust rule below, same as before.
    sl_present=0; sl_seen=0; sl_canonical_missing=0; sl_canonical_raw=""
    sl_custom_missing=""; sl_wired_path=""
    while IFS= read -r sl_tok; do
      [ -n "$sl_tok" ] || continue
      # shellcheck disable=SC2088 # matching a LITERAL ~ the shell never expanded — this just structurally validates the token shape
      case $sl_tok in
        "~/"*headroom-statusline.sh | /*headroom-statusline.sh) ;;
        *) continue ;;
      esac
      sl_cand=$sl_tok
      sl_seen=1
      sl_raw=$sl_cand
      # shellcheck disable=SC2088 # matching a LITERAL ~ the shell never expanded — we expand it here
      case $sl_cand in "~/"*) sl_cand="$HOME/${sl_cand#"~/"}" ;; esac
      if [ -f "$sl_cand" ]; then sl_present=1; sl_wired_path=$sl_cand
      elif [ "$sl_cand" = "$CLAUDE_DIR/headroom-statusline.sh" ]; then
        sl_canonical_missing=1; sl_canonical_raw=$sl_raw
      else sl_custom_missing=$sl_cand
      fi
    done < <(printf '%s\n' "$sl" | grep -oE "[^\"' ]+")
    if [ "$sl_present" -eq 1 ] || [ "$sl_seen" -eq 0 ]; then
      say ok "statusLine wired ($sl)"
    elif [ "$sl_canonical_missing" -eq 1 ]; then
      if [ "$FIX" -eq 1 ]; then
        mkdir -p "$CLAUDE_DIR/lib"
        # model-prices.json degrades gracefully when absent (statusline.sh
        # falls back to a built-in table), so it stays best-effort; the two
        # deps below are load-bearing for a working badge and must gate the
        # "fixed" claim, same as the sibling fix in 7c just below
        [ -f "$PLUGIN_ROOT/data/model-prices.json" ] \
          && cp "$PLUGIN_ROOT/data/model-prices.json" "$CLAUDE_DIR/headroom-model-prices.json" 2>/dev/null || true
        if cp "$PLUGIN_ROOT/scripts/lib/attribution.jq"    "$CLAUDE_DIR/lib/" \
           && cp "$PLUGIN_ROOT/scripts/lib/headroom-state.sh" "$CLAUDE_DIR/lib/" \
           && cp "$PLUGIN_ROOT/scripts/statusline.sh" "$CLAUDE_DIR/headroom-statusline.sh" \
           && chmod +x "$CLAUDE_DIR/headroom-statusline.sh"; then
          if [ "$sl_canonical_raw" != "$CLAUDE_DIR/headroom-statusline.sh" ]; then
            # matched via a respelling (a quoted ~) that bash never expands at
            # spawn time — no shell unwraps a tilde inside double quotes, so
            # the file now exists but the wired command would still fail to
            # find it. Rewrite the command to the literal resolved path.
            backup_settings
            sl_new_cmd=${sl//$sl_canonical_raw/$CLAUDE_DIR/headroom-statusline.sh}
            if jq --arg c "$sl_new_cmd" '.statusLine.command = $c' \
                "$SETTINGS" > "$TMPD/settings.sl2" && cat "$TMPD/settings.sl2" > "$SETTINGS"; then
              say fixed "re-copied the missing statusline script to $CLAUDE_DIR/headroom-statusline.sh and rewrote the unexpandable '$sl_canonical_raw' wiring to an absolute path (settings.json backup: .bak.*)"
            else
              say FAIL "re-copied statusline.sh but could not rewrite the '$sl_canonical_raw' wiring in settings.json"
            fi
          else
            say fixed "re-copied the missing statusline script to $CLAUDE_DIR/headroom-statusline.sh (settings already pointed at it)"
          fi
        else
          say FAIL "could not re-copy statusline.sh and its lib deps to $CLAUDE_DIR"
        fi
      else
        say fixable "statusLine points at $CLAUDE_DIR/headroom-statusline.sh but the script is missing — --fix re-copies it"
      fi
    else
      say FAIL "statusLine points at $sl_custom_missing but no such file exists — restore it or re-wire settings.json (--fix will not guess a custom location)"
    fi
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
    [ -f "$PLUGIN_ROOT/data/model-prices.json" ] \
      && cp "$PLUGIN_ROOT/data/model-prices.json" "$CLAUDE_DIR/headroom-model-prices.json" 2>/dev/null || true
    # statusline.sh resolves attribution.jq + headroom-state.sh from a lib/ dir
    # next to itself; without them compute() degrades to a permanent idle badge
    # showing zero savings (issue #2). Provision them alongside the copy.
    mkdir -p "$CLAUDE_DIR/lib"
    cp "$PLUGIN_ROOT/scripts/lib/attribution.jq"    "$CLAUDE_DIR/lib/" 2>/dev/null || true
    cp "$PLUGIN_ROOT/scripts/lib/headroom-state.sh" "$CLAUDE_DIR/lib/" 2>/dev/null || true
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

  # 7b. the wired copy must match the plugin's statusline.sh (upgrade path).
  # sl_copy follows whatever check 7 actually validated as wired — including
  # a doctor-blessed custom path — instead of always assuming the canonical
  # location. Previously 7b/7c only ever looked at $CLAUDE_DIR, so a custom
  # install's stale/missing script or deps went undetected forever (`skip`,
  # not FAILED/FIXABLE) and block 9's all-clear cleared any recorded failure
  # regardless — issue #2's original symptom, for the custom-path population.
  sl_copy=${sl_wired_path:-"$CLAUDE_DIR/headroom-statusline.sh"}
  sl_custom_copy=0
  [ "$sl_copy" != "$CLAUDE_DIR/headroom-statusline.sh" ] && sl_custom_copy=1
  if [ ! -f "$sl_copy" ]; then
    say skip "statusline copy refresh (no $sl_copy yet)"
  elif cmp -s "$PLUGIN_ROOT/scripts/statusline.sh" "$sl_copy"; then
    say ok "statusline copy is current ($sl_copy)"
  elif [ "$sl_custom_copy" -eq 1 ]; then
    # no-orphan policy (matches check 7): a custom path is the user's own to
    # own, so doctor detects but never overwrites it
    say FAIL "statusline copy at $sl_copy is stale — a custom-path install is yours to update (doctor will not overwrite it)"
  elif [ "$FIX" -eq 1 ]; then
    [ -f "$PLUGIN_ROOT/data/model-prices.json" ] \
      && cp "$PLUGIN_ROOT/data/model-prices.json" "$CLAUDE_DIR/headroom-model-prices.json" 2>/dev/null || true
    mkdir -p "$CLAUDE_DIR/lib"
    cp "$PLUGIN_ROOT/scripts/lib/attribution.jq"    "$CLAUDE_DIR/lib/" 2>/dev/null || true
    cp "$PLUGIN_ROOT/scripts/lib/headroom-state.sh" "$CLAUDE_DIR/lib/" 2>/dev/null || true
    if cp "$PLUGIN_ROOT/scripts/statusline.sh" "$sl_copy" && chmod +x "$sl_copy"; then
      say fixed "statusline copy refreshed from the plugin ($sl_copy)"
    else
      say FAIL "could not refresh $sl_copy from the plugin"
    fi
  else
    say fixable "statusline copy differs from the plugin's scripts/statusline.sh — --fix refreshes it"
  fi

  # 7c. statusline.sh's runtime deps (attribution.jq + headroom-state.sh) must sit
  # next to the installed copy, or compute() silently degrades to a permanent idle
  # badge showing zero savings (issue #2). The plain cmp in 7b only covers the
  # script itself — these are separate files and were never provisioned.
  # statusline.sh resolves each dep from EITHER a lib/ subdir OR a flat sibling
  # (the legacy full-manual install layout), preferring lib/. Mirror that here so
  # a healthy flat install is not falsely flagged (which would also block block 9's
  # ambient-health all-clear via a spurious FIXABLE).
  if [ ! -f "$sl_copy" ]; then
    say skip "statusline lib deps (no $sl_copy yet)"
  else
    sl_dep_dir=$(dirname "$sl_copy")
    lib_stale=""
    for f in attribution.jq headroom-state.sh; do
      # Resolve each dep exactly as statusline.sh does — by EXISTENCE, lib/ first,
      # else the flat sibling next to the copy actually wired (canonical or
      # custom-path), then currency-check only the file it would load.
      # A plain "lib matches OR flat matches" would green a stale lib/ copy that
      # shadows a current flat sibling: statusline.sh sources the stale lib/ one
      # (it takes lib/ the moment the file exists, content-blind) and never falls
      # through, so the badge would silently run on the stale dep.
      if   [ -f "$sl_dep_dir/lib/$f" ]; then dep="$sl_dep_dir/lib/$f"
      elif [ -f "$sl_dep_dir/$f" ];     then dep="$sl_dep_dir/$f"
      else dep=""; fi
      if [ -n "$dep" ] && cmp -s "$PLUGIN_ROOT/scripts/lib/$f" "$dep"; then
        :   # the exact file statusline.sh loads is present and current
      else
        lib_stale="$lib_stale $f"
      fi
    done
    if [ -z "$lib_stale" ]; then
      say ok "statusline lib deps current (attribution.jq, headroom-state.sh)"
    elif [ "$sl_custom_copy" -eq 1 ]; then
      say FAIL "statusline lib deps at $sl_dep_dir missing/stale —$lib_stale (custom-path install is yours to update; doctor will not write there)"
    elif [ "$FIX" -eq 1 ]; then
      mkdir -p "$CLAUDE_DIR/lib"
      if cp "$PLUGIN_ROOT/scripts/lib/attribution.jq"    "$CLAUDE_DIR/lib/" \
         && cp "$PLUGIN_ROOT/scripts/lib/headroom-state.sh" "$CLAUDE_DIR/lib/"; then
        say fixed "installed statusline lib deps to $CLAUDE_DIR/lib —$lib_stale"
      else
        say FAIL "could not copy statusline lib deps to $CLAUDE_DIR/lib"
      fi
    else
      say fixable "statusline lib deps missing/stale —$lib_stale (badge shows zero savings without them; --fix installs attribution.jq + headroom-state.sh)"
    fi
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
    if [ "$PLUGNAT" -eq 1 ] && [ "$legacy" -eq 0 ] && [ "$legacy_local" -eq 0 ] && [ "$proj_legacy" -eq 0 ]; then
      for f in $stale; do rm -f "$CLAUDE_DIR/$f"; done
      say fixed "removed stale copies from $CLAUDE_DIR:$stale"
      printf '%-7s - %s\n' note "project-level .claude settings in OTHER directories are not scanned (this one was) — if another project still registers the deleted paths, remove those entries by hand"
    else
      say skip "stale copies kept:$stale (plugin-native hooks unconfirmed, or legacy hooks still registered in settings.json / settings.local.json / project settings)"
    fi
  else
    say fixable "stale copies in $CLAUDE_DIR:$stale"
  fi
fi

# --- 9. ambient-health state: hooks/hcat record failures in a last-error file
# that flips the badge to "broken". A fully-clean doctor run (nothing failed,
# nothing fixable) is the all-clear that restores the badge; the hcat smoke
# test may already have cleared an engine error mid-run — report that too.
if [ "$HEALTH_HAD_ERROR" -eq 1 ]; then
  if [ ! -f "$HEALTH_STATE_DIR/last-error" ]; then
    say ok "cleared recorded failure state — badge restored"
  elif [ "$FAILED" -eq 0 ] && [ "$FIXABLE" -eq 0 ]; then
    if [ "$(cat "$HEALTH_STATE_DIR/last-error" 2>/dev/null)" = "$HEALTH_ERR_SNAP" ]; then
      rm -f "$HEALTH_STATE_DIR/last-error" 2>/dev/null || true
      say ok "cleared recorded failure state — badge restored"
    else
      say skip "a NEW failure was recorded while this run was in progress — badge kept broken; run /doctor again"
    fi
  else
    say skip "recorded failure state kept (badge shows broken until a clean doctor run)"
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
