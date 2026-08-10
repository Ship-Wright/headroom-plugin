#!/usr/bin/env bash
# ledger-hook — Stop/SessionEnd hook for the headroom-usage-indicator plugin.
# Walks the session transcript (the untruncated ground truth) and appends one
# cumulative snapshot per session to an append-only JSONL ledger: verified
# saves (MCP compress + structurally-attributed hcat receipts), and the big
# blobs that went UNCOMPRESSED — counted, sized, and priced, with the biggest
# offenders' file paths. Consumers (session-probe's invoice line, digests,
# audits) read the ledger instead of re-parsing transcripts.
# Cost discipline: Stop fires on EVERY assistant turn, and the slurped parse
# is the expensive part on a multi-MB transcript — so a size marker skips the
# parse entirely when the transcript has not grown (statusline.sh's trick),
# and every id lookup inside the jq pass is an O(1) INDEX/set probe, never an
# `index()` rescan (quadratic over long sessions).
# Dedup: a per-session content marker additionally skips the append when the
# snapshot is unchanged (last line per session is authoritative-cumulative).
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

# Shared attribution defs (plugin lib/, or a flat sibling in legacy copies);
# without them there is nothing trustworthy to record — fail open.
JQ_LIB=""
for _jl in "$SELF_DIR/lib" "$SELF_DIR"; do
  if [ -f "$_jl/attribution.jq" ]; then JQ_LIB="$_jl"; break; fi
done
[ -n "$JQ_LIB" ] || exit 0

# Unchanged transcript → skip the whole parse, not just the append.
tsize=$(wc -c < "$tp" 2>/dev/null | tr -d ' ') || tsize=""
case "$tsize" in (*[!0-9]*) tsize="" ;; esac
szmark="$STATE_DIR/session-$sid.ledgersize"
if [ -n "$tsize" ] && [ -f "$szmark" ] && [ "$(cat "$szmark" 2>/dev/null)" = "$tsize" ]; then
  exit 0
fi

# One slurped pass sharing statusline.sh's structural attribution (lib):
# receipts count only when linked (tool_use_id) to a Bash tool_use that really
# invoked hcat; big results that are neither compressions nor receipts — and
# not an exempt output class (edits, web prose, subagent digests) — are misses.
snap=$(jq -crs -L "$JQ_LIB" --arg tool "$TOOL" --arg pfx "$HPREFIX" --argjson min "$NUDGE_BYTES" '
  include "attribution";
  (mcp_ids($tool)) as $mids
  | idset($mids) as $mset
  | idset(headroom_ids($pfx)) as $hpset
  | idset(hcat_bash_ids) as $hcset
  | ([tool_uses[] | {id: (.id // ""), name: (.name // ""),
                     src: ((.input.file_path? // .input.command?) // "")}]) as $uses
  | (INDEX($uses[]; .id)) as $uidx
  | tool_results as $res
  | def is_genuine: (.t | is_receipt) and ($hcset[.id] // false);
    ($res | map(select(is_genuine)
      | (try (.t | capture("~(?<b>[0-9]+) tok → ~(?<a>[0-9]+) tok")) catch null) as $c
      | select($c != null) | (($c.b|tonumber) - ($c.a|tonumber)))) as $rsav
  | ($res | map(select($mset[.id] // false)
      | (try (.t | fromjson.tokens_saved) catch 0) // 0)) as $msav
  | ($res | map(select((($hpset[.id] // false) | not)
      and (is_genuine | not)
      and (((($uidx[.id] // {}).name // "") as $n | (exempt_tools | index($n)) == null))
      and ((.t | length) >= $min))
      | {id: .id, bytes: (.t | length)})) as $missed
  | ($missed | map(. as $m
      | {bytes: $m.bytes,
         path: ((($uidx[$m.id] // {}).src // "")
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

# Remember the size we just parsed so quiet Stop firings skip the parse.
if [ -n "$tsize" ] && mkdir -p "$STATE_DIR" 2>/dev/null; then
  { printf '%s' "$tsize" > "$szmark"; } 2>/dev/null || true
fi

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
