#!/usr/bin/env bash
# headroom-usage-indicator — status-line segment for Claude Code.
# Reads the status-line stdin JSON once; prints the headroom badge (ANSI, no newline).
# State: ${HEADROOM_STATE_DIR:-~/.claude/headroom-indicator}

set -u

TOOL="mcp__headroom__headroom_compress"
STATE_DIR="${HEADROOM_STATE_DIR:-$HOME/.claude/headroom-indicator}"
NUDGE_BYTES=4096            # tool results at least this large count as compression candidates
HPREFIX="mcp__headroom__"   # results of headroom's own tools are never "missed"

in=$(cat)

tp=$(printf '%s' "$in" | jq -r '.transcript_path // empty' 2>/dev/null) || tp=""
model=$(printf '%s' "$in" | jq -r '.model.id // empty' 2>/dev/null) || model=""
sid=$(printf '%s' "$in" | jq -r '.session_id // empty' 2>/dev/null) || sid=""

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

n=0; saved=0; last_ts=""; missed=0

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
  big=$(jq -s --arg pfx "$HPREFIX" --argjson min "$NUDGE_BYTES" \
    '([.[]|.message.content[]?|select(.type=="tool_use" and ((.name // "")|startswith($pfx)))|.id]) as $hids
     | [.[]|.message.content[]?
        | select(.type=="tool_result" and ((.tool_use_id) as $t|($hids|index($t))==null))
        | (.content
           | if type=="string" then length
             elif type=="array" then ([.[]? | .text? // ""] | join("") | length)
             else 0 end)
        | select(. >= $min)]
     | length' \
    "$tp" 2>/dev/null)
  big=${big:-0}
  n=${n:-0}; saved=${saved:-0}
  if [ "$big" -gt "$n" ] 2>/dev/null; then missed=$((big - n)); else missed=0; fi
}

if [ -n "$tp" ] && [ -f "$tp" ]; then
  size=$(stat -c%s "$tp" 2>/dev/null || stat -f%z "$tp" 2>/dev/null || echo "")
  cache=""
  [ -n "$sid" ] && cache="$STATE_DIR/session-$sid.cache"
  hit=0
  if [ -n "$cache" ] && [ -n "$size" ] && [ -f "$cache" ]; then
    IFS='|' read -r csize cn csaved clast cmissed < "$cache" || true
    if [ "${csize:-}" = "$size" ] && [ -n "${cmissed:-}" ]; then
      n=${cn:-0}; saved=${csaved:-0}; last_ts=${clast:-}; missed=${cmissed:-0}
      hit=1
    fi
  fi
  if [ "$hit" -ne 1 ]; then
    compute
    if [ -n "$cache" ] && mkdir -p "$STATE_DIR" 2>/dev/null; then
      printf '%s|%s|%s|%s|%s\n' "${size:-0}" "$n" "$saved" "$last_ts" "$missed" > "$cache" 2>/dev/null || true
      if [ "$saved" -gt 0 ] 2>/dev/null; then
        t_price=$(price_per_mtok "$model")
        t_usd=0
        [ -n "$t_price" ] && t_usd=$(usd_of "$saved" "$t_price")
        tf="$STATE_DIR/session-$sid.totals"
        if [ -f "$tf" ]; then
          read -r _ old_usd < "$tf" || old_usd=0
          t_usd=$(awk -v a="$t_usd" -v b="${old_usd:-0}" 'BEGIN{printf "%.6f", (a>b)?a:b}')
        fi
        printf '%s %s\n' "$saved" "$t_usd" > "$tf" 2>/dev/null || true
      fi
    fi
  fi
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

lifetime=""
totals_count=$(find "$STATE_DIR" -name 'session-*.totals' 2>/dev/null | wc -l | tr -d ' ')
if [ "${totals_count:-0}" -gt 1 ] 2>/dev/null; then
  lt_usd=$(cat "$STATE_DIR"/session-*.totals 2>/dev/null | awk '{u+=$2} END{printf "%.6f", u+0}')
  if awk -v u="$lt_usd" 'BEGIN{exit !(u>0)}'; then
    lifetime=" | $(fmt_usd "$lt_usd") all-time"
  fi
fi

nudge=""
if [ "$missed" -gt 0 ] 2>/dev/null; then
  nudge=" · ${missed} missed"
fi

if [ "$n" -gt 0 ] 2>/dev/null; then
  tok=$(fmt_tok "$saved")
  if [ "$age" -le 60 ] 2>/dev/null; then
    printf '\033[32m● headroom · ~%s tok%s · %s×%s\033[0m' "$tok" "$money" "$n" "$lifetime"
  else
    printf '\033[90m○ headroom idle · ~%s tok%s · %s×%s%s\033[0m' "$tok" "$money" "$n" "$nudge" "$lifetime"
  fi
else
  if [ "$missed" -gt 0 ] 2>/dev/null; then
    blobs="big blobs"
    [ "$missed" -eq 1 ] 2>/dev/null && blobs="big blob"
    printf '\033[31m○ headroom idle · %s %s uncompressed\033[0m' "$missed" "$blobs"
  else
    printf '\033[31m○ headroom idle (not compressing yet)\033[0m'
  fi
fi

if [ "$missed" -gt 0 ] 2>/dev/null; then
  printf '  \033[33m🤖 dangi: %s!\033[0m' "$missed"
else
  printf '  \033[2m😴 dangi\033[0m'
fi
