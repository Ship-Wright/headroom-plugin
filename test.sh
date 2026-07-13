#!/usr/bin/env bash
# Test suite for scripts/statusline.sh — synthetic transcripts, no live session needed.
set -u

ROOT=$(cd "$(dirname "$0")" && pwd)
SCRIPT="$ROOT/scripts/statusline.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export HEADROOM_STATE_DIR="$TMP/state"

PASS=0; FAIL=0

check() {  # check <name> <expected-substring> <actual>
  if printf '%s' "$3" | grep -qF -- "$2"; then
    echo "ok - $1"; PASS=$((PASS+1))
  else
    echo "FAIL - $1"
    echo "    expected substring: $2"
    echo "    got: $3"
    FAIL=$((FAIL+1))
  fi
}

check_absent() {  # check_absent <name> <forbidden-substring> <actual>
  if printf '%s' "$3" | grep -qF -- "$2"; then
    echo "FAIL - $1"
    echo "    forbidden substring present: $2"
    echo "    got: $3"
    FAIL=$((FAIL+1))
  else
    echo "ok - $1"; PASS=$((PASS+1))
  fi
}

badge() {  # badge <transcript> <model-id> <session-id> — run the script as Claude Code would
  printf '{"transcript_path":"%s","model":{"id":"%s"},"session_id":"%s"}' "$1" "$2" "$3" \
    | bash "$SCRIPT"
}

NOW=$(date -u +%Y-%m-%dT%H:%M:%S.000Z)

compress_event() {  # compress_event <tool-use-id> <tokens-saved> — one compress + linked result
  printf '%s\n%s\n' \
    "{\"timestamp\":\"$NOW\",\"message\":{\"content\":[{\"type\":\"tool_use\",\"id\":\"$1\",\"name\":\"mcp__headroom__headroom_compress\"}]}}" \
    "{\"message\":{\"content\":[{\"type\":\"tool_result\",\"tool_use_id\":\"$1\",\"content\":[{\"type\":\"text\",\"text\":\"{\\\"tokens_saved\\\": $2}\"}]}]}}"
}

# --- 1. compress + linked result → green active badge with tokens and count
compress_event t1 500 > "$TMP/t_active.jsonl"
out=$(badge "$TMP/t_active.jsonl" claude-opus-4-8 sess-active)
check "active: green dot"  "●"        "$out"
check "active: tokens"     "~500 tok" "$out"
check "active: count"      "1×"       "$out"

# --- 2. stats-only transcript → red idle (no false positive)
printf '%s\n' '{"message":{"content":[{"type":"tool_use","id":"s1","name":"mcp__headroom__headroom_stats"}]}}' > "$TMP/t_stats.jsonl"
out=$(badge "$TMP/t_stats.jsonl" claude-opus-4-8 sess-stats)
check "stats-only: idle"   "not compressing yet" "$out"

# --- 3. money: 500 tok on opus-4-8 = $0.0025 → shown as cents
out=$(badge "$TMP/t_active.jsonl" claude-opus-4-8 sess-money)
check "money: cents"        "0.25¢"      "$out"

# 10,000 tok on fable-5 = $0.10 → dollars + k-abbreviated tokens
compress_event big 10000 > "$TMP/t_big.jsonl"
out=$(badge "$TMP/t_big.jsonl" claude-fable-5 sess-big)
check "money: dollars"      "\$0.10"     "$out"
check "tokens: k-abbrev"    "~10.0k tok" "$out"

# --- 4. unknown model → tokens-only, never a wrong dollar figure
# Fresh state dir: once lifetime totals exist (Task 4), earlier sessions' "$X all-time"
# segment would otherwise leak into this badge and false-fail the absence checks.
export HEADROOM_STATE_DIR="$TMP/state-2"
out=$(badge "$TMP/t_active.jsonl" some-future-model sess-unknown)
check "unknown model: tokens"      "~500 tok" "$out"
check_absent "unknown model: no ¢" "¢"        "$out"
check_absent "unknown model: no \$" "\$"      "$out"

# --- 5. cache: same-size transcript rewrite is served from cache (proves no re-parse)
compress_event c1 500 > "$TMP/t_cache.jsonl"
out=$(badge "$TMP/t_cache.jsonl" claude-opus-4-8 sess-cache)
check "cache: first render"  "~500 tok" "$out"
# mangle the tool name in place, keeping byte length identical — a re-parse would find 0 events
sed 's/headroom_compress/headroom_compresX/' "$TMP/t_cache.jsonl" > "$TMP/t_cache.mangled" \
  && mv "$TMP/t_cache.mangled" "$TMP/t_cache.jsonl"
out=$(badge "$TMP/t_cache.jsonl" claude-opus-4-8 sess-cache)
check "cache: same-size rewrite still served from cache" "~500 tok" "$out"

# --- 6. cache invalidation: transcript growth triggers re-parse
compress_event g1 500 > "$TMP/t_grow.jsonl"
out=$(badge "$TMP/t_grow.jsonl" claude-opus-4-8 sess-grow)
check "growth: first render" "1×" "$out"
compress_event g2 250 >> "$TMP/t_grow.jsonl"
out=$(badge "$TMP/t_grow.jsonl" claude-opus-4-8 sess-grow)
check "growth: recount"      "2×"       "$out"
check "growth: retotal"      "~750 tok" "$out"

# --- 7. lifetime totals across sessions
rm -rf "$HEADROOM_STATE_DIR"   # reset state accumulated by earlier tests
compress_event a1 500 > "$TMP/t_life_a.jsonl"
compress_event b1 500 > "$TMP/t_life_b.jsonl"
out=$(badge "$TMP/t_life_a.jsonl" claude-opus-4-8 sess-life-a)
check_absent "lifetime: hidden on first-ever session" "all-time" "$out"
out=$(badge "$TMP/t_life_b.jsonl" claude-opus-4-8 sess-life-b)
check "lifetime: shown from 2nd session" "all-time"       "$out"
check "lifetime: summed usd"             "0.50¢ all-time" "$out"

# --- 8. decay badge: a compress event with an old timestamp renders dim idle, never green/red
rm -rf "$HEADROOM_STATE_DIR"
printf '%s\n%s\n' \
  '{"timestamp":"2020-01-01T00:00:00.000Z","message":{"content":[{"type":"tool_use","id":"d1","name":"mcp__headroom__headroom_compress"}]}}' \
  '{"message":{"content":[{"type":"tool_result","tool_use_id":"d1","content":[{"type":"text","text":"{\"tokens_saved\": 500}"}]}]}}' \
  > "$TMP/t_decay.jsonl"
out=$(badge "$TMP/t_decay.jsonl" claude-opus-4-8 sess-decay)
check "decay: dim idle badge"  "○ headroom idle · ~500 tok"  "$out"
check_absent "decay: not active" "●"                          "$out"

# --- 9. fix 1: sessions that saved nothing must not get a totals file
rm -rf "$HEADROOM_STATE_DIR"
printf '%s\n' '{"message":{"content":[{"type":"tool_use","id":"s1","name":"mcp__headroom__headroom_stats"}]}}' > "$TMP/t_zero.jsonl"
badge "$TMP/t_zero.jsonl" claude-opus-4-8 sess-zero > /dev/null
if [ -e "$HEADROOM_STATE_DIR/session-sess-zero.totals" ]; then
  echo "FAIL - fix1: no totals file for zero-saved session"
  echo "    found: $HEADROOM_STATE_DIR/session-sess-zero.totals"
  FAIL=$((FAIL+1))
else
  echo "ok - fix1: no totals file for zero-saved session"; PASS=$((PASS+1))
fi

# --- 10. fix 2: a model switch mid-session must never shrink the session's recorded usd
rm -rf "$HEADROOM_STATE_DIR"
compress_event sw1 500 > "$TMP/t_switch.jsonl"
badge "$TMP/t_switch.jsonl" claude-opus-4-8 sess-switch > /dev/null
check "fix2: initial totals usd" "0.002500" "$(cat "$HEADROOM_STATE_DIR/session-sess-switch.totals")"
compress_event sw2 100 >> "$TMP/t_switch.jsonl"
badge "$TMP/t_switch.jsonl" claude-haiku-4-5 sess-switch > /dev/null
check "fix2: totals usd never shrinks on model switch" "0.002500" "$(cat "$HEADROOM_STATE_DIR/session-sess-switch.totals")"

# --- 11-15. missed-opportunity nudge
export HEADROOM_STATE_DIR="$TMP/state-nudge"
OLD_TS="2020-01-01T00:00:00.000Z"

old_compress_event() {  # old_compress_event <id> <tokens> — compress stamped in the past (grey badge)
  printf '%s\n%s\n' \
    "{\"timestamp\":\"$OLD_TS\",\"message\":{\"content\":[{\"type\":\"tool_use\",\"id\":\"$1\",\"name\":\"mcp__headroom__headroom_compress\"}]}}" \
    "{\"message\":{\"content\":[{\"type\":\"tool_result\",\"tool_use_id\":\"$1\",\"content\":[{\"type\":\"text\",\"text\":\"{\\\"tokens_saved\\\": $2}\"}]}]}}"
}

big_result_event() {  # big_result_event <tool-use-id> <tool-name> <byte-count> — a large non-compress tool result
  pad=$(printf 'x%.0s' $(seq 1 "$3"))
  printf '%s\n%s\n' \
    "{\"message\":{\"content\":[{\"type\":\"tool_use\",\"id\":\"$1\",\"name\":\"$2\"}]}}" \
    "{\"message\":{\"content\":[{\"type\":\"tool_result\",\"tool_use_id\":\"$1\",\"content\":[{\"type\":\"text\",\"text\":\"$pad\"}]}]}}"
}

# 11. big blobs with no compress → red nudge, singular/plural
big_result_event b1 Bash 4096 > "$TMP/t_nudge1.jsonl"
out=$(badge "$TMP/t_nudge1.jsonl" claude-opus-4-8 sess-n1)
check "nudge: singular" "1 big blob uncompressed" "$out"
{ big_result_event b1 Bash 4096; big_result_event b2 Read 4096; } > "$TMP/t_nudge2.jsonl"
out=$(badge "$TMP/t_nudge2.jsonl" claude-opus-4-8 sess-n2)
check "nudge: plural" "2 big blobs uncompressed" "$out"

# 12. just under the threshold → no nudge
big_result_event u1 Bash 4095 > "$TMP/t_under.jsonl"
out=$(badge "$TMP/t_under.jsonl" claude-opus-4-8 sess-n3)
check "nudge: under threshold" "not compressing yet" "$out"

# 13. headroom's own oversized results are excluded
big_result_event r1 mcp__headroom__headroom_retrieve 5000 > "$TMP/t_retr.jsonl"
out=$(badge "$TMP/t_retr.jsonl" claude-opus-4-8 sess-n4)
check "nudge: headroom results excluded" "not compressing yet" "$out"

# 14. forgiveness: each compression forgives one big blob
{ old_compress_event c1 500; big_result_event b1 Bash 4096; big_result_event b2 Bash 4096; } > "$TMP/t_forgive.jsonl"
out=$(badge "$TMP/t_forgive.jsonl" claude-opus-4-8 sess-n5)
check "forgive: grey shows missed"      "· 1 missed"                "$out"
check "forgive: grey idle with totals"  "○ headroom idle · ~500 tok" "$out"
{ old_compress_event c1 500; big_result_event b1 Bash 4096; } > "$TMP/t_even.jsonl"
out=$(badge "$TMP/t_even.jsonl" claude-opus-4-8 sess-n6)
check_absent "forgive: even count hides missed" " missed" "$out"

# 15. v2.0 4-field cache line forces recompute and upgrades to 5 fields
big_result_event b1 Bash 4096 > "$TMP/t_upg.jsonl"
sz=$(stat -c%s "$TMP/t_upg.jsonl" 2>/dev/null || stat -f%z "$TMP/t_upg.jsonl")
mkdir -p "$HEADROOM_STATE_DIR"
printf '%s|9|9999|2020-01-01T00:00:00.000Z\n' "$sz" > "$HEADROOM_STATE_DIR/session-sess-n7.cache"
out=$(badge "$TMP/t_upg.jsonl" claude-opus-4-8 sess-n7)
check "cache upgrade: stale 4-field line recomputed" "1 big blob uncompressed" "$out"
fields=$(awk -F'|' '{print NF; exit}' "$HEADROOM_STATE_DIR/session-sess-n7.cache")
check "cache upgrade: rewritten with 5 fields" "5" "$fields"

# --- shellcheck (when available)
if command -v shellcheck >/dev/null 2>&1; then
  if shellcheck "$SCRIPT"; then
    echo "ok - shellcheck"; PASS=$((PASS+1))
  else
    echo "FAIL - shellcheck"; FAIL=$((FAIL+1))
  fi
else
  echo "skip - shellcheck not installed"
fi

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
