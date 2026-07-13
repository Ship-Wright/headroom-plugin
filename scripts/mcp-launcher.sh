#!/usr/bin/env bash
# mcp-launcher.sh — plugin-bundled entry point for the headroom MCP server.
#
# Referenced by the plugin's .mcp.json so enabling the plugin auto-registers
# the headroom MCP: no manual `claude mcp add` step. Resolves the headroom
# engine (same order as bin/hcat: $HCAT_PYTHON authoritative → sibling of
# `headroom` on PATH → ~/.headroom-venv) and execs the exact invocation a
# manual registration would use: `headroom mcp serve`, offline.
#
# Engine missing → one helpful stderr line naming the doctor, nonzero exit.
set -u

VENV_DIR=${DOCTOR_VENV_DIR:-$HOME/.headroom-venv}

PY=""
if [ -n "${HCAT_PYTHON:-}" ]; then
  [ -x "$HCAT_PYTHON" ] && PY=$HCAT_PYTHON   # explicit override: no fallback
else
  for cand in "$(dirname "$(command -v headroom 2>/dev/null || echo /nonexistent)")/python" "$VENV_DIR/bin/python"; do
    if [ -x "$cand" ]; then PY=$cand; break; fi
  done
fi

BIN=""
if [ -n "$PY" ] && [ -x "$(dirname "$PY")/headroom" ]; then
  BIN="$(dirname "$PY")/headroom"
fi
if [ -z "$BIN" ]; then
  echo "headroom engine not found — run the plugin doctor with --fix (/headroom-usage-indicator:doctor), or: python3 -m venv ~/.headroom-venv && ~/.headroom-venv/bin/pip install headroom" >&2
  exit 1
fi

HEADROOM_UPDATE_CHECK=off HF_HUB_OFFLINE=1 exec "$BIN" mcp serve
