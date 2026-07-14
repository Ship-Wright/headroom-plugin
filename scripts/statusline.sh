#!/usr/bin/env bash
# headroom-usage-indicator — status-line segment for Claude Code.
# Reads the status-line stdin JSON once; prints the headroom badge (ANSI, no newline).
# State: ${HEADROOM_STATE_DIR:-~/.claude/headroom-indicator}

set -u

TOOL="mcp__headroom__headroom_compress"
# HOME can be unset in hook/statusline environments (set -u would kill us);
# degrade to a temp-dir state location rather than dying on every render.
STATE_DIR="${HEADROOM_STATE_DIR:-${HOME:-${TMPDIR:-/tmp}}/.claude/headroom-indicator}"
SELF_DIR=$(cd "$(dirname "$0")" 2>/dev/null && pwd || echo .)
NUDGE_BYTES=4096            # tool results at least this large count as compression candidates
HPREFIX="mcp__headroom__"   # results of headroom's own tools are never "missed"

in=$(cat)

tp=$(printf '%s' "$in" | jq -r '.transcript_path // empty' 2>/dev/null) || tp=""
model=$(printf '%s' "$in" | jq -r '.model.id // empty' 2>/dev/null) || model=""
sid=$(printf '%s' "$in" | jq -r '.session_id // empty' 2>/dev/null) || sid=""

# All awk math runs under LC_ALL=C: BSD awk honors LC_NUMERIC, and a
# comma-decimal locale (de_DE, …) would corrupt printed money and the
# session-*.totals files (later summed as 0).
fmt_tok() {  # 2400 -> "2.4k", 500 -> "500"
  if [ "$1" -ge 1000 ] 2>/dev/null; then
    LC_ALL=C awk -v t="$1" 'BEGIN{printf "%.1fk", t/1000}'
  else
    printf '%s' "$1"
  fi
}

# Data-driven price table: adding a model is a data edit in data/model-prices.json,
# not a code change. Resolve it next to the running script (a copied install gets
# headroom-model-prices.json beside the copy) or in the plugin's data/ dir. When
# it's present and parses, it is authoritative (first substring match wins; no
# match = unknown). When it's absent or invalid, the built-in table below keeps
# the badge working with zero regression (and offline — the file is never fetched).
PRICES_FILE=""
for _pf in "${HEADROOM_PRICES_FILE:-}" \
           "$SELF_DIR/headroom-model-prices.json" \
           "$SELF_DIR/../data/model-prices.json"; do
  if [ -n "$_pf" ] && [ -f "$_pf" ]; then PRICES_FILE="$_pf"; break; fi
done
if [ -n "$PRICES_FILE" ] && ! jq -e . "$PRICES_FILE" >/dev/null 2>&1; then
  PRICES_FILE=""   # invalid JSON → fall back to the built-in table
fi

price_per_mtok() {  # input $/MTok by model-id substring; empty = unknown
  if [ -n "$PRICES_FILE" ]; then
    jq -r --arg m "$1" \
      'first((.prices // [])[]
             | (.match // "") as $x
             | select(($x | length) > 0 and ($m | contains($x)))
             | .usd_per_mtok) // ""' "$PRICES_FILE" 2>/dev/null
    return
  fi
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
  LC_ALL=C awk -v t="$1" -v p="$2" 'BEGIN{printf "%.6f", t*p/1000000}'
}

fmt_usd() {  # dollars -> "$0.03" (>= 1 cent) or "0.42¢"
  LC_ALL=C awk -v u="$1" 'BEGIN{ if (u>=0.01) printf "$%.2f", u; else printf "%.2f¢", u*100 }'
}

n=0; saved=0; last_ts=""; missed=0

# One slurped jq pass fills n / saved / last_ts / missed. Compressions are
# MCP compress calls PLUS hcat receipts — tool_results whose text carries the
# "── hcat: … ~B tok → ~A tok" header (matched at any line start: persisted
# big outputs prepend a preview banner). Receipts are attributed
# STRUCTURALLY: a receipt counts only when its tool_result links
# (tool_use_id) to a Bash tool_use whose .input.command actually invokes
# hcat — outputs that merely QUOTE a receipt line (grep/cat over docs or
# tests) count as nothing (and, if big, as missed). Passthrough receipts
# have no arrow and count as nothing. Genuine receipts are excluded from
# "big" (they ARE the compression, not a missed opportunity).
compute() {
  local out big hn hsaved
  out=$(jq -rs --arg tool "$TOOL" --arg pfx "$HPREFIX" --argjson min "$NUDGE_BYTES" '
    def txt: (.content | if type=="string" then .
                         elif type=="array" then ([.[]? | .text? // ""] | join(""))
                         else "" end);
    def is_receipt: test("(^|\\n)── hcat: ");
    def is_hcat_cmd: test("(^|\\n|[|;&]\\s*|[$][(]\\s*|/)hcat(\\s|$)");
    ([.[]|.message.content[]? | select(.type=="tool_use" and .name==$tool) | .id]) as $mids
    | ([.[]|.message.content[]? | select(.type=="tool_use" and ((.name // "")|startswith($pfx))) | .id]) as $hpids
    | ([.[]|.message.content[]? | select(.type=="tool_use" and (.name // "")=="Bash"
        and ((.input.command? // "") | is_hcat_cmd)) | .id]) as $hcids
    | ([.[]|.message.content[]? | select(.type=="tool_result")
        | {id: (.tool_use_id // ""), t: txt}]) as $res
    | def is_genuine: (.t | is_receipt) and ((.id as $t | $hcids | index($t)) != null);
      ($res | map(select(is_genuine)
        | (try (.t | capture("~(?<b>[0-9]+) tok → ~(?<a>[0-9]+) tok")) catch null) as $c
        | select($c != null)
        | {id: .id, s: (($c.b|tonumber) - ($c.a|tonumber))})) as $rcpt
    | ($res | map(select(.id as $t | $mids | index($t))
        | (try (.t | fromjson.tokens_saved) catch 0) // 0) | add // 0) as $saved
    | ($res | map(select(((.id as $t | $hpids | index($t)) == null)
        and (is_genuine | not)
        and ((.t | length) >= $min))) | length) as $big
    | ($rcpt | map(.id)) as $rids
    | ([.[] | select(.timestamp)
        | select(any(.message.content[]?; .type=="tool_use"
            and (((.name // "") == $tool) or ((.id // "") as $i | ($rids | index($i)) != null))))
        | .timestamp] | max // "") as $last
    | "\($mids|length)|\($saved)|\($big)|\($rcpt|length)|\($rcpt | map(.s) | add // 0)|\($last)"
  ' "$tp" 2>/dev/null)
  IFS='|' read -r n saved big hn hsaved last_ts <<< "${out:-}"
  n=${n:-0}; saved=${saved:-0}; big=${big:-0}; hn=${hn:-0}; hsaved=${hsaved:-0}
  if [ "$big" -gt "$n" ] 2>/dev/null; then missed=$((big - n)); else missed=0; fi
  n=$((n + hn)); saved=$((saved + hsaved))
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
          t_usd=$(LC_ALL=C awk -v a="$t_usd" -v b="${old_usd:-0}" 'BEGIN{printf "%.6f", (a>b)?a:b}')
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
  lt_usd=$(cat "$STATE_DIR"/session-*.totals 2>/dev/null | LC_ALL=C awk '{u+=$2} END{printf "%.6f", u+0}')
  if LC_ALL=C awk -v u="$lt_usd" 'BEGIN{exit !(u>0)}'; then
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
