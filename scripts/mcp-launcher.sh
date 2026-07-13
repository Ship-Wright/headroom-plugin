#!/usr/bin/env bash
# mcp-launcher.sh — plugin-bundled entry point for the headroom MCP server.
#
# Referenced by the plugin's .mcp.json so enabling the plugin auto-registers
# the headroom MCP: no manual `claude mcp add` step. Unlike bin/hcat, this
# only needs the `headroom` CLI — no importable python — so pip --user and
# pipx layouts (console script with no sibling python) work. Resolution:
# $HCAT_PYTHON's directory's `headroom` (the override is authoritative when
# set — same contract as bin/hcat, no fallback) → `headroom` on PATH (used
# directly) → ~/.headroom-venv/bin/headroom. Execs the exact invocation a
# manual registration would use: `headroom mcp serve`, offline.
#
# Engine missing → one helpful stderr line naming the doctor, nonzero exit.
set -u

VENV_DIR=${DOCTOR_VENV_DIR:-$HOME/.headroom-venv}

BIN=""
if [ -n "${HCAT_PYTHON:-}" ]; then
  # explicit override: authoritative, no fallback
  cand="$(dirname "$HCAT_PYTHON")/headroom"
  [ -x "$cand" ] && BIN=$cand
else
  BIN=$(command -v headroom 2>/dev/null || true)
  if [ -z "$BIN" ] && [ -x "$VENV_DIR/bin/headroom" ]; then
    BIN="$VENV_DIR/bin/headroom"
  fi
fi
if [ -z "$BIN" ]; then
  echo "headroom engine not found — run the plugin doctor with --fix (/headroom-usage-indicator:doctor), or: python3 -m venv ~/.headroom-venv && ~/.headroom-venv/bin/pip install headroom" >&2
  exit 1
fi

HEADROOM_UPDATE_CHECK=off HF_HUB_OFFLINE=1 exec "$BIN" mcp serve
