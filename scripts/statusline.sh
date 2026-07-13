#!/usr/bin/env bash
# headroom-usage-indicator — status-line segment for Claude Code.
# Reads the status-line stdin JSON once; prints the headroom badge (ANSI, no newline).
# State: ${HEADROOM_STATE_DIR:-~/.claude/headroom-indicator}

set -u

TOOL="mcp__headroom__headroom_compress"

in=$(cat)

tp=$(printf '%s' "$in" | jq -r '.transcript_path // empty' 2>/dev/null) || tp=""
model=$(printf '%s' "$in" | jq -r '.model.id // empty' 2>/dev/null) || model=""

fmt_tok() {  # 2400 -> "2.4k", 500 -> "500"
  if [ "$1" -ge 1000 ] 2>/dev/null; then
    awk -v t="$1" 'BEGIN{printf "%.1fk", t/1000}'
  else
    printf '%s' "$1"
  fi
}

price_per_mtok() {  # input $/MTok by model-id substring; empty = unknown
  case "$1" in
    *fable-5*|*mythos*)                           echo 10 ;;
    *opus-4-8*|*opus-4-7*|*opus-4-6*|*opus-4-5*)  echo 5 ;;
    *opus-4-1*|*opus-4-0*|*opus-4-2025*|*3-opus*) echo 15 ;;
    *haiku-4-5*)                                  echo 1 ;;
    *3-5-haiku*)                                  echo 0.80 ;;
    *3-haiku*)                                    echo 0.25 ;;
    *sonnet*)                                     echo 3 ;;
    *)                                            echo "" ;;
  esac
}

usd_of() {  # usd_of <tokens> <price-per-mtok> -> dollars (6 dp)
  awk -v t="$1" -v p="$2" 'BEGIN{printf "%.6f", t*p/1000000}'
}

fmt_usd() {  # dollars -> "$0.03" (>= 1 cent) or "0.42¢"
  awk -v u="$1" 'BEGIN{ if (u>=0.01) printf "$%.2f", u; else printf "%.2f¢", u*100 }'
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

money=""
price=$(price_per_mtok "$model")
if [ -n "$price" ] && [ "$saved" -gt 0 ] 2>/dev/null; then
  money=" · $(fmt_usd "$(usd_of "$saved" "$price")")"
fi

if [ "$n" -gt 0 ] 2>/dev/null; then
  tok=$(fmt_tok "$saved")
  if [ "$age" -le 60 ] 2>/dev/null; then
    printf '\033[32m● headroom · ~%s tok%s · %s×\033[0m' "$tok" "$money" "$n"
  else
    printf '\033[90m○ headroom idle · ~%s tok%s · %s×\033[0m' "$tok" "$money" "$n"
  fi
else
  printf '\033[31m○ headroom idle (not compressing yet)\033[0m'
fi
