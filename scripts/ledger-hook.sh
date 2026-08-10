#!/usr/bin/env bash
# ledger-hook — Stop/SessionEnd hook for the headroom-usage-indicator plugin.
# Walks the session transcript (the untruncated ground truth) and appends one
# cumulative snapshot per session to an append-only JSONL ledger: verified
# saves (MCP compress + structurally-attributed hcat receipts), and the big
# blobs that went UNCOMPRESSED — counted, sized, and priced, with the biggest
# offenders' file paths. Consumers (session-probe's invoice line, digests,
# audits) read the ledger instead of re-parsing transcripts.
# Dedup: a per-session marker skips the append when nothing changed, so the
# many Stop firings of a busy session don't spam the ledger (last line per
# session is the authoritative cumulative snapshot).
# MUST always exit 0 and print nothing — a Stop hook that speaks can block
# the session from stopping.

set -u

TOOL="mcp__headroom__headroom_compress"
HPREFIX="mcp__headroom__"
NUDGE_BYTES=4096
STATE_DIR="${HEADROOM_STATE_DIR:-${HOME:-${TMPDIR:-/tmp}}/.claude/headroom-indicator}"
SELF_DIR=$(cd "$(dirname "$0")" 2>/dev/null && pwd || echo .)

in=$(cat)

command -v jq >/dev/null 2>&1 || exit 0
tp=$(printf '%s' "$in" | jq -r '.transcript_path // empty' 2>/dev/null) || exit 0
sid=$(printf '%s' "$in" | jq -r '.session_id // "unknown"' 2>/dev/null) || sid="unknown"
[ -n "$sid" ] || sid="unknown"
[ -n "$tp" ] && [ -f "$tp" ] || exit 0

# One slurped pass, mirroring statusline.sh's structural attribution: receipts
# count only when linked (tool_use_id) to a Bash tool_use that really invoked
# hcat; big results that are neither compressions nor receipts are misses.
snap=$(jq -crs --arg tool "$TOOL" --arg pfx "$HPREFIX" --argjson min "$NUDGE_BYTES" '
  def txt: (.content | if type=="string" then .
                       elif type=="array" then ([.[]? | .text? // ""] | join(""))
                       else "" end);
  def is_receipt: test("(^|\\n)── hcat: ");
  def is_hcat_cmd: test("(^|\\n|[|;&]\\s*|[$][(]\\s*|/)hcat(\\s|$)");
  ([.[]|.message.content[]? | select(.type=="tool_use" and .name==$tool) | .id]) as $mids
  | ([.[]|.message.content[]? | select(.type=="tool_use" and ((.name // "")|startswith($pfx))) | .id]) as $hpids
  | ([.[]|.message.content[]? | select(.type=="tool_use" and (.name // "")=="Bash"
      and ((.input.command? // "") | is_hcat_cmd)) | .id]) as $hcids
  | ([.[]|.message.content[]? | select(.type=="tool_use")
      | {id: (.id // ""), src: ((.input.file_path? // .input.command?) // "")}]) as $uses
  | ([.[]|.message.content[]? | select(.type=="tool_result")
      | {id: (.tool_use_id // ""), t: txt}]) as $res
  | def is_genuine: (.t | is_receipt) and ((.id as $t | $hcids | index($t)) != null);
    ($res | map(select(is_genuine)
      | (try (.t | capture("~(?<b>[0-9]+) tok → ~(?<a>[0-9]+) tok")) catch null) as $c
      | select($c != null) | (($c.b|tonumber) - ($c.a|tonumber)))) as $rsav
  | ($res | map(select(.id as $t | $mids | index($t))
      | (try (.t | fromjson.tokens_saved) catch 0) // 0)) as $msav
  | ($res | map(select(((.id as $t | $hpids | index($t)) == null)
      and (is_genuine | not)
      and ((.t | length) >= $min))
      | {id: .id, bytes: (.t | length)})) as $missed
  | ($missed | map(. as $m
      | {bytes: $m.bytes,
         path: ((([$uses[] | select(.id == $m.id) | .src] | first) // "")
                | (try ([scan("[^\\s\"'"'"'\\\\]+\\.(?:json|jsonl|ndjson|csv|tsv|log)")] | last)
                   catch null))})) as $mp
  | ([.[] | .message.model? // empty] | last // "") as $model
  | {model: $model,
     save_count: (($mids|length) + ($rsav|length)),
     save_tokens: (($msav | add // 0) + ($rsav | add // 0)),
     miss_count: ($missed | length),
     miss_chars: ($missed | map(.bytes) | add // 0),
     top_misses: ($mp | sort_by(-.bytes) | .[0:3])}
' "$tp" 2>/dev/null) || exit 0
[ -n "$snap" ] || exit 0

# Nothing to record → no ledger noise for empty sessions.
sc=$(printf '%s' "$snap" | jq -r '.save_count + .miss_count' 2>/dev/null) || exit 0
case "$sc" in (*[!0-9]*|""|0) exit 0 ;; esac

mkdir -p "$STATE_DIR" 2>/dev/null || exit 0

# Skip when this session's snapshot is unchanged since the last append.
marker="$STATE_DIR/session-$sid.ledgermark"
sum=$(printf '%s' "$snap" | cksum 2>/dev/null | awk '{print $1}') || sum=""
if [ -n "$sum" ] && [ -f "$marker" ] && [ "$(cat "$marker" 2>/dev/null)" = "$sum" ]; then
  exit 0
fi

# Price with the same data table the badge uses (first substring match wins).
# No match / no table → usd fields stay null; quantities are still recorded.
PRICES_FILE=""
for _pf in "${HEADROOM_PRICES_FILE:-}" \
           "$SELF_DIR/headroom-model-prices.json" \
           "$SELF_DIR/../data/model-prices.json"; do
  if [ -n "$_pf" ] && [ -f "$_pf" ]; then PRICES_FILE="$_pf"; break; fi
done
model=$(printf '%s' "$snap" | jq -r '.model // ""' 2>/dev/null) || model=""
price=""
if [ -n "$PRICES_FILE" ] && [ -n "$model" ]; then
  price=$(jq -r --arg m "$model" \
    'first((.prices // [])[]
           | (.match // "") as $x
           | select(($x | length) > 0 and ($m | contains($x)))
           | .usd_per_mtok) // ""' "$PRICES_FILE" 2>/dev/null) || price=""
fi
save_tok=$(printf '%s' "$snap" | jq -r '.save_tokens' 2>/dev/null) || save_tok=0
miss_chars=$(printf '%s' "$snap" | jq -r '.miss_chars' 2>/dev/null) || miss_chars=0
miss_tok=$(( miss_chars / 4 ))   # ~4 chars/token estimate for unpriced raw text
save_usd=""; miss_usd=""
if [ -n "$price" ]; then
  save_usd=$(LC_ALL=C awk -v t="$save_tok" -v p="$price" 'BEGIN{printf "%.6f", t*p/1000000}')
  miss_usd=$(LC_ALL=C awk -v t="$miss_tok" -v p="$price" 'BEGIN{printf "%.6f", t*p/1000000}')
fi

event=$(printf '%s' "$snap" | jq -c \
  --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg sid "$sid" \
  --argjson mt "$miss_tok" --arg su "$save_usd" --arg mu "$miss_usd" \
  '{ts: $ts, session_id: $sid} + .
   + {miss_est_tokens: $mt,
      save_usd: (if $su == "" then null else $su end),
      miss_usd: (if $mu == "" then null else $mu end)}' 2>/dev/null) || exit 0
[ -n "$event" ] || exit 0

{ printf '%s\n' "$event" >> "$STATE_DIR/ledger.jsonl"; } 2>/dev/null || exit 0
[ -n "$sum" ] && { printf '%s' "$sum" > "$marker"; } 2>/dev/null
exit 0
