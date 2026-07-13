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

# 16. string-form tool_result content is measured too (the dominant shape in real transcripts)
strpad=$(printf 'x%.0s' $(seq 1 4096))
printf '%s\n%s\n' \
  '{"message":{"content":[{"type":"tool_use","id":"s1","name":"Bash"}]}}' \
  "{\"message\":{\"content\":[{\"type\":\"tool_result\",\"tool_use_id\":\"s1\",\"content\":\"$strpad\"}]}}" > "$TMP/t_str.jsonl"
out=$(badge "$TMP/t_str.jsonl" claude-opus-4-8 sess-n8)
check "nudge: string-form content" "1 big blob uncompressed" "$out"

# --- 17-19. dangi hook (real-time detector)
DANGI="$ROOT/scripts/dangi-hook.sh"
export HEADROOM_STATE_DIR="$TMP/state-dangi"
export DANGI_NO_NOTIFY=1

hook_input() {  # hook_input <tool-name> <char-count> <session-id> — synthetic PostToolUse stdin
  jq -n --arg tool "$1" --arg sid "$3" --argjson n "$2" \
    '{hook_event_name:"PostToolUse", tool_name:$tool, session_id:$sid, tool_response:("x"*$n)}'
}

# 17. big output → one-line additionalContext JSON, exit 0
out=$(hook_input Bash 4096 dangi-s1 | bash "$DANGI"); rc=$?
check "dangi: nudges on big output"   "additionalContext" "$out"
check "dangi: message names itself"   "Dangi"             "$out"
check "dangi: exit code"              "0"                  "$rc"
printf '%s' "$out" | jq -e '.hookSpecificOutput.hookEventName == "PostToolUse"' >/dev/null \
  && check "dangi: valid hook JSON" "ok" "ok" \
  || check "dangi: valid hook JSON" "ok" "INVALID"

# 18. rate limiting — same session silent, other session nudges
out=$(hook_input Bash 8192 dangi-s1 | bash "$DANGI")
check_absent "dangi: cooldown silences same session" "additionalContext" "$out"
out=$(hook_input Bash 8192 dangi-s2 | bash "$DANGI")
check "dangi: cooldown is per-session" "additionalContext" "$out"

# 19. non-events stay silent (and exit 0)
out=$(hook_input Bash 4095 dangi-s3 | bash "$DANGI")
check_absent "dangi: under threshold" "additionalContext" "$out"
out=$(hook_input Edit 9000 dangi-s6 | bash "$DANGI")
check_absent "dangi: Edit excluded (echoes code being edited)" "additionalContext" "$out"
out=$(hook_input Write 9000 dangi-s6 | bash "$DANGI")
check_absent "dangi: Write excluded" "additionalContext" "$out"
out=$(hook_input Bash 9000 dangi-s7 | bash "$DANGI")
check "dangi: nudge points to hcat" "hcat" "$out"
check "dangi: nudge offers subagent fallback" "subagent" "$out"
out=$(hook_input mcp__headroom__headroom_compress 9000 dangi-s4 | bash "$DANGI")
check_absent "dangi: headroom tools excluded" "additionalContext" "$out"
out=$(printf 'not json at all' | bash "$DANGI"); rc=$?
check_absent "dangi: garbage stdin silent" "additionalContext" "$out"
check "dangi: garbage stdin exit 0" "0" "$rc"

# 20. stderr purity: an unreadable state file must not leak bash diagnostics
hook_input Bash 5000 dangi-s5 | bash "$DANGI" >/dev/null 2>/dev/null   # first call creates the state file
chmod 000 "$HEADROOM_STATE_DIR/session-dangi-s5.dangi"
err=$(hook_input Bash 5000 dangi-s5 | bash "$DANGI" 2>&1 >/dev/null)
chmod 644 "$HEADROOM_STATE_DIR/session-dangi-s5.dangi"
if [ -z "$err" ]; then
  echo "ok - dangi: stderr silent on unreadable state"; PASS=$((PASS+1))
else
  echo "FAIL - dangi: stderr silent on unreadable state"
  echo "    got stderr: $err"
  FAIL=$((FAIL+1))
fi

# --- 21. status-line mascot
export HEADROOM_STATE_DIR="$TMP/state-mascot"
big_result_event m1 Bash 4096 > "$TMP/t_mascot.jsonl"
out=$(badge "$TMP/t_mascot.jsonl" claude-opus-4-8 sess-m1)
check "mascot: awake with count" "🤖 dangi: 1!" "$out"
compress_event m2 500 > "$TMP/t_asleep.jsonl"
out=$(badge "$TMP/t_asleep.jsonl" claude-opus-4-8 sess-m2)
check "mascot: asleep when clear" "😴 dangi" "$out"

# --- 22-25. hcat (compress-at-the-source shim)
HCAT="$ROOT/scripts/hcat"
HEADROOM_PY=""
for cand in "${HCAT_PYTHON:-}" "$(command -v headroom 2>/dev/null | xargs -I{} dirname {} 2>/dev/null)/python" "$HOME/.headroom-venv/bin/python"; do
  [ -n "$cand" ] && [ -x "$cand" ] && HEADROOM_PY="$cand" && break
done

# 22. arg validation runs before python resolution — testable everywhere
out=$(bash "$HCAT" 2>&1); rc=$?
check "hcat: no args → usage" "usage" "$out"
check "hcat: no args → exit 2" "2" "$rc"
out=$(bash "$HCAT" "$TMP/does-not-exist.json" 2>&1); rc=$?
check "hcat: missing file → exit 2" "2" "$rc"

# 23. unusable python → distinct exit 3, nothing on stdout
printf '{"k":1}' > "$TMP/hc_small.json"
out=$(HCAT_PYTHON=/nonexistent/python bash "$HCAT" "$TMP/hc_small.json" 2>/dev/null); rc=$?
check "hcat: no headroom → exit 3" "3" "$rc"
check_absent "hcat: no headroom → stdout empty" "{" "$out"

if [ -n "$HEADROOM_PY" ]; then
  # 24. real compression: big structured JSON shrinks, header cites source path
  "$HEADROOM_PY" - "$TMP/hc_big.json" <<'PYEOF'
import json, sys
rows = [{"id": i, "user": f"user_{i%50}", "event": "click", "ts": 1700000000+i, "ok": True} for i in range(500)]
open(sys.argv[1], "w").write(json.dumps(rows, indent=2))
PYEOF
  out=$(HEADROOM_WORKSPACE_DIR="$TMP/hc_ws" bash "$HCAT" "$TMP/hc_big.json"); rc=$?
  check "hcat: exit 0 on success" "0" "$rc"
  check "hcat: header cites source path" "$TMP/hc_big.json" "$out"
  check "hcat: header shows savings" "% saved" "$out"
  raw_bytes=$(wc -c < "$TMP/hc_big.json")
  out_bytes=$(printf '%s' "$out" | wc -c)
  if [ "$out_bytes" -lt $(( raw_bytes / 2 )) ]; then
    echo "ok - hcat: output < half of raw"; PASS=$((PASS+1))
  else
    echo "FAIL - hcat: output < half of raw (raw=$raw_bytes out=$out_bytes)"; FAIL=$((FAIL+1))
  fi
  check "hcat: stats event written" '"strategy":"hcat"' "$(cat "$TMP"/hc_ws/*.jsonl 2>/dev/null)"

  # 25. incompressible content → raw passthrough, no schema noise
  printf 'short prose line\n' > "$TMP/hc_prose.txt"
  out=$(HEADROOM_WORKSPACE_DIR="$TMP/hc_ws" bash "$HCAT" "$TMP/hc_prose.txt")
  check "hcat: passthrough keeps raw" "short prose line" "$out"
else
  echo "skip - hcat compression tests (headroom venv not found)"
fi

# --- 26-28. hcat-gate (PreToolUse Read gate)
GATE="$ROOT/scripts/hcat-gate.sh"
export HEADROOM_STATE_DIR="$TMP/state-gate"

gate_input() {  # gate_input <file-path> <session-id> — synthetic PreToolUse stdin
  jq -n --arg fp "$1" --arg sid "$2" \
    '{hook_event_name:"PreToolUse", tool_name:"Read", session_id:$sid, tool_input:{file_path:$fp}}'
}

# 26. small / non-structured / garbage → silent allow, exit 0
out=$(gate_input "$TMP/hc_small.json" gate-s1 | bash "$GATE"); rc=$?
check_absent "gate: small file allowed" "deny" "$out"
check "gate: small file exit 0" "0" "$rc"
head -c 20000 /dev/zero | tr '\0' 'x' > "$TMP/hc_big.dart"
out=$(gate_input "$TMP/hc_big.dart" gate-s1 | bash "$GATE")
check_absent "gate: non-structured ext allowed" "deny" "$out"
out=$(printf 'not json' | bash "$GATE"); rc=$?
check_absent "gate: garbage stdin silent" "deny" "$out"
check "gate: garbage stdin exit 0" "0" "$rc"

if [ -n "$HEADROOM_PY" ]; then
  # 27. big structured file → deny once with hcat guidance...
  out=$(gate_input "$TMP/hc_big.json" gate-s2 | bash "$GATE")
  check "gate: big json denied" '"permissionDecision":"deny"' "$out"
  check "gate: reason names hcat" "hcat" "$out"
  # 28. ...second attempt on the same file passes (escape hatch)
  out=$(gate_input "$TMP/hc_big.json" gate-s2 | bash "$GATE")
  check_absent "gate: retry same file allowed" "deny" "$out"
  # other sessions unaffected
  out=$(gate_input "$TMP/hc_big.json" gate-s3 | bash "$GATE")
  check "gate: deny is per-session" '"permissionDecision":"deny"' "$out"
  # kill switch
  out=$(gate_input "$TMP/hc_big.json" gate-s4 | HCAT_GATE_OFF=1 bash "$GATE")
  check_absent "gate: HCAT_GATE_OFF disables" "deny" "$out"
else
  echo "skip - gate deny tests (headroom venv not found)"
fi

# --- shellcheck (when available)
if command -v shellcheck >/dev/null 2>&1; then
  if shellcheck "$SCRIPT" "$DANGI" "$ROOT/scripts/hcat-gate.sh"; then
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
