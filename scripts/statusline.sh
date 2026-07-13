#!/usr/bin/env bash
# headroom-usage-indicator — status-line segment for Claude Code.
# Reads the status-line stdin JSON once; prints the headroom badge (ANSI, no newline).
# State: ${HEADROOM_STATE_DIR:-~/.claude/headroom-indicator}

set -u

TOOL="mcp__headroom__headroom_compress"

in=$(cat)

tp=$(printf '%s' "$in" | jq -r '.transcript_path // empty' 2>/dev/null) || tp=""

fmt_tok() {  # 2400 -> "2.4k", 500 -> "500"
  if [ "$1" -ge 1000 ] 2>/dev/null; then
    awk -v t="$1" 'BEGIN{printf "%.1fk", t/1000}'
  else
    printf '%s' "$1"
  fi
}

n=0; saved=0; last_ts=""

compute() {  # fills n / saved / last_ts from the transcript at $tp
  n=$(jq -s --arg tool "$TOOL" \
    '[.[]|.message.content[]?|select(.type=="tool_use" and .name==$tool)]|length' \
    "$tp" 2>/dev/null)
  saved=$(jq -s --arg tool "$TOOL" \
    '([.[]|.message.content[]?|select(.type=="tool_use" and .name==$tool)|.id]) as $ids
     | [.[]|.message.content[]?
        | select(.type=="tool_result" and ((.tool_use_id) as $t|($ids|index($t))!=null))
        | .content[]? | .text? // empty | (try (fromjson.tokens_saved) catch 0)]
     | add // 0' \
    "$tp" 2>/dev/null)
  last_ts=$(jq -r --arg tool "$TOOL" \
    'select(.message.content)|select(any(.message.content[]?;.type=="tool_use" and .name==$tool))|.timestamp' \
    "$tp" 2>/dev/null | tail -1)
  n=${n:-0}; saved=${saved:-0}
}

if [ -n "$tp" ] && [ -f "$tp" ]; then
  compute
fi

age=999999
if [ -n "$last_ts" ]; then
  le=$(date -d "$last_ts" +%s 2>/dev/null \
    || date -j -u -f "%Y-%m-%dT%H:%M:%S" "${last_ts%%.*}" +%s 2>/dev/null \
    || echo "")
  [ -n "$le" ] && age=$(( $(date -u +%s) - le ))
fi

if [ "$n" -gt 0 ] 2>/dev/null; then
  tok=$(fmt_tok "$saved")
  if [ "$age" -le 60 ] 2>/dev/null; then
    printf '\033[32m● headroom · ~%s tok · %s×\033[0m' "$tok" "$n"
  else
    printf '\033[90m○ headroom idle · ~%s tok · %s×\033[0m' "$tok" "$n"
  fi
else
  printf '\033[31m○ headroom idle (not compressing yet)\033[0m'
fi
