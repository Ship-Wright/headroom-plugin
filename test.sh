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

# image tool_responses are base64 blobs — not text-compressible
out=$(jq -n '{hook_event_name:"PostToolUse", tool_name:"Read", session_id:"dangi-s8",
  tool_response:{type:"image", source:{data:("A"*9000)}}}' | bash "$DANGI")
check_absent "dangi: image response excluded" "additionalContext" "$out"
out=$(hook_input WebFetch 9000 dangi-s9 | bash "$DANGI")
check_absent "dangi: WebFetch excluded" "additionalContext" "$out"

# hcat receipts ARE compressions — their outputs are never nudge targets
out=$(jq -n '{hook_event_name:"PostToolUse", tool_name:"Bash", session_id:"dangi-s13",
  tool_response:("── hcat: /tmp/x.json · 10 lines · 5.0 KB · ~9000 tok → ~3000 tok (66.7% saved)\n" + ("y"*9000))}' | bash "$DANGI")
check_absent "dangi: hcat receipt excluded" "additionalContext" "$out"
# ...even buried mid-text after a persisted-output preview banner
out=$(jq -n '{hook_event_name:"PostToolUse", tool_name:"Bash", session_id:"dangi-s14",
  tool_response:("Output too large. Preview:\n── hcat: /tmp/x.json · ~9000 tok → ~3000 tok (66.7% saved)\n" + ("y"*9000))}' | bash "$DANGI")
check_absent "dangi: buried hcat receipt excluded" "additionalContext" "$out"
# ...and in object-form tool_responses, where tostring JSON-escapes the newlines
out=$(jq -n '{hook_event_name:"PostToolUse", tool_name:"Bash", session_id:"dangi-s15",
  tool_response:{stdout:("── hcat: /tmp/x.json · ~9000 tok → ~3000 tok (66.7% saved)\n" + ("y"*9000)), stderr:""}}' | bash "$DANGI")
check_absent "dangi: object-form receipt excluded" "additionalContext" "$out"
# a big blob that merely mentions hcat mid-line is still a missed opportunity
out=$(jq -n '{hook_event_name:"PostToolUse", tool_name:"Bash", session_id:"dangi-s16",
  tool_response:("run hcat <path> next time maybe " + ("y"*9000))}' | bash "$DANGI")
check "dangi: mid-line hcat mention still nudges" "additionalContext" "$out"

# size must be bytes, not codepoints: 3000 two-byte chars = 6000 bytes ≥ 4096
out=$(jq -n --arg sid dangi-s10 '{hook_event_name:"PostToolUse", tool_name:"Bash",
  session_id:$sid, tool_response:("é"*3000)}' | bash "$DANGI")
check "dangi: multibyte content counted in bytes" "additionalContext" "$out"

# notification branch: a fake osascript on PATH must get invoked
FAKEBIN="$TMP/fakebin"; mkdir -p "$FAKEBIN"
printf '#!/bin/sh\necho "$@" >> "%s/osascript.calls"\n' "$TMP" > "$FAKEBIN/osascript"
chmod +x "$FAKEBIN/osascript"
out=$(jq -n '{hook_event_name:"PostToolUse", tool_name:"Bash", session_id:"dangi-s11",
  tool_response:("x"*9000)}' | env -u DANGI_NO_NOTIFY PATH="$FAKEBIN:$PATH" bash "$DANGI")
for _ in 1 2 3 4 5 6 7 8 9 10; do   # osascript fires in the background — poll up to 2s
  [ -s "$TMP/osascript.calls" ] && break
  sleep 0.2
done
check "dangi: notification invoked" "display notification" "$(cat "$TMP/osascript.calls" 2>/dev/null)"
check "dangi: notification names the tool" "Bash" "$(cat "$TMP/osascript.calls" 2>/dev/null)"

# a stale lock must never wedge the hook
mkdir -p "$HEADROOM_STATE_DIR/.lock-dangi-s12" 2>/dev/null
out=$(jq -n '{hook_event_name:"PostToolUse", tool_name:"Bash", session_id:"dangi-s12",
  tool_response:("x"*9000)}' | bash "$DANGI"); rc=$?
check "dangi: stale lock tolerated (exit 0)" "0" "$rc"
check "dangi: stale lock still nudges" "additionalContext" "$out"
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
HCAT="$ROOT/bin/hcat"
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

  # --- 29. gate covers Bash raw dumps (tell, not nudge)
  bash_gate_input() {  # bash_gate_input <command> <session-id>
    jq -n --arg cmd "$1" --arg sid "$2" \
      '{hook_event_name:"PreToolUse", tool_name:"Bash", session_id:$sid, tool_input:{command:$cmd}}'
  }
  out=$(bash_gate_input "cat $TMP/hc_big.json" gate-b1 | bash "$GATE")
  check "gate/bash: bare cat of big json denied" '"permissionDecision":"deny"' "$out"
  check "gate/bash: reason names hcat" "hcat" "$out"
  out=$(bash_gate_input "cat $TMP/hc_big.json" gate-b1 | bash "$GATE")
  check_absent "gate/bash: retry same file allowed" "deny" "$out"
  out=$(bash_gate_input "cat $TMP/hc_big.json | jq '.[0]'" gate-b2 | bash "$GATE")
  check_absent "gate/bash: piped cat allowed (real processing)" "deny" "$out"
  out=$(bash_gate_input "head -c 200 $TMP/hc_big.json" gate-b2 | bash "$GATE")
  check_absent "gate/bash: bounded head allowed" "deny" "$out"
  out=$(bash_gate_input "cat $TMP/hc_small.json" gate-b2 | bash "$GATE")
  check_absent "gate/bash: small file allowed" "deny" "$out"
  out=$(bash_gate_input "cat $TMP/hc_big.dart" gate-b2 | bash "$GATE")
  check_absent "gate/bash: non-structured ext allowed" "deny" "$out"
  out=$(bash_gate_input "cat \"$TMP/hc_big.json\"" gate-b3 | bash "$GATE")
  check "gate/bash: quoted path still denied" '"permissionDecision":"deny"' "$out"
else
  echo "skip - gate deny tests (headroom venv not found)"
fi

# --- 30. badge counts hcat receipts from the transcript
export HEADROOM_STATE_DIR="$TMP/state-hcat-badge"

hcat_event() {  # hcat_event <tool-use-id> <before-tok> <after-tok> [pad-bytes]
  local pad=""
  [ -n "${4:-}" ] && pad=$(head -c "$4" /dev/zero | tr '\0' 'y')
  printf '%s\n%s\n' \
    "{\"timestamp\":\"$NOW\",\"message\":{\"content\":[{\"type\":\"tool_use\",\"id\":\"$1\",\"name\":\"Bash\"}]}}" \
    "{\"message\":{\"content\":[{\"type\":\"tool_result\",\"tool_use_id\":\"$1\",\"content\":[{\"type\":\"text\",\"text\":\"── hcat: /tmp/x.json · 10 lines · 5.0 KB · ~$2 tok → ~$3 tok (60.0% saved) · original on disk\\n$pad\"}]}]}}"
}

# hcat alone: green badge, savings counted, 1×
hcat_event h1 1000 400 > "$TMP/t_hcat.jsonl"
out=$(badge "$TMP/t_hcat.jsonl" claude-opus-4-8 sess-h1)
check "hcat badge: green dot"        "●"        "$out"
check "hcat badge: tokens counted"   "600"      "$out"
check "hcat badge: count"            "1×"       "$out"

# a big hcat receipt is NOT a missed opportunity (it IS compressed)
hcat_event h2 9000 3000 6000 > "$TMP/t_hcat_big.jsonl"
out=$(badge "$TMP/t_hcat_big.jsonl" claude-opus-4-8 sess-h2)
check_absent "hcat badge: receipt not counted as missed" "missed" "$out"
check "hcat badge: mascot asleep" "😴 dangi" "$out"

# mixed: MCP compress (500) + hcat (600) = 1.1k, 2×
{ compress_event m1 500; hcat_event h3 1000 400; } > "$TMP/t_mixed.jsonl"
out=$(badge "$TMP/t_mixed.jsonl" claude-opus-4-8 sess-hm)
check "hcat badge: mixed total" "1.1k" "$out"
check "hcat badge: mixed count" "2×"   "$out"

# a persisted big output buries the receipt mid-text after a preview banner
printf '%s\n%s\n' \
  "{\"timestamp\":\"$NOW\",\"message\":{\"content\":[{\"type\":\"tool_use\",\"id\":\"h5\",\"name\":\"Bash\"}]}}" \
  '{"message":{"content":[{"type":"tool_result","tool_use_id":"h5","content":[{"type":"text","text":"Output too large (32.1KB). Full output saved.\nPreview (first 2KB):\n── hcat: /tmp/z.json · 9 lines · 8.0 KB · ~2000 tok → ~800 tok (60.0% saved) · original on disk\n..."}]}]}}' \
  > "$TMP/t_persist.jsonl"
out=$(badge "$TMP/t_persist.jsonl" claude-opus-4-8 sess-hpers)
check "hcat badge: persisted preview receipt counted" "1.2k" "$out"

# passthrough receipts (no "→") are not compressions
printf '%s\n%s\n' \
  "{\"timestamp\":\"$NOW\",\"message\":{\"content\":[{\"type\":\"tool_use\",\"id\":\"h4\",\"name\":\"Bash\"}]}}" \
  '{"message":{"content":[{"type":"tool_result","tool_use_id":"h4","content":[{"type":"text","text":"── hcat: /tmp/y.txt · 3 lines · 0.1 KB · passthrough (compression would save 0.0%)\nshort prose line"}]}]}}' \
  > "$TMP/t_pass.jsonl"
out=$(badge "$TMP/t_pass.jsonl" claude-opus-4-8 sess-hp)
check "hcat badge: passthrough not counted" "not compressing yet" "$out"

# --- 31. plugin-native hooks (hooks/hooks.json + bin/hcat)
HOOKS_JSON="$ROOT/hooks/hooks.json"
export HEADROOM_STATE_DIR="$TMP/state-plugnat"

if jq -e . "$HOOKS_JSON" >/dev/null 2>&1; then
  echo "ok - hooks.json: parses"; PASS=$((PASS+1))
else
  echo "FAIL - hooks.json: parses"; FAIL=$((FAIL+1))
fi
check "hooks.json: exactly the two event arrays" "PostToolUse,PreToolUse" \
  "$(jq -r '.hooks | keys | sort | join(",")' "$HOOKS_JSON" 2>/dev/null)"
check "hooks.json: single PreToolUse entry"  "1" "$(jq -r '.hooks.PreToolUse  | length' "$HOOKS_JSON" 2>/dev/null)"
check "hooks.json: single PostToolUse entry" "1" "$(jq -r '.hooks.PostToolUse | length' "$HOOKS_JSON" 2>/dev/null)"
check "hooks.json: PreToolUse matcher"  "Read|Bash" "$(jq -r '.hooks.PreToolUse[0].matcher'  "$HOOKS_JSON" 2>/dev/null)"
check "hooks.json: PostToolUse matcher" "*"         "$(jq -r '.hooks.PostToolUse[0].matcher' "$HOOKS_JSON" 2>/dev/null)"

gate_cmd=$(jq -r '.hooks.PreToolUse[0].hooks[0].command'  "$HOOKS_JSON" 2>/dev/null)
dangi_cmd=$(jq -r '.hooks.PostToolUse[0].hooks[0].command' "$HOOKS_JSON" 2>/dev/null)
check "hooks.json: gate command uses CLAUDE_PLUGIN_ROOT"  '${CLAUDE_PLUGIN_ROOT}' "$gate_cmd"
check "hooks.json: gate command targets hcat-gate.sh"     "hcat-gate.sh"          "$gate_cmd"
check "hooks.json: dangi command uses CLAUDE_PLUGIN_ROOT" '${CLAUDE_PLUGIN_ROOT}' "$dangi_cmd"
check "hooks.json: dangi command targets dangi-hook.sh"   "dangi-hook.sh"         "$dangi_cmd"

# hcat ships in bin/ (auto-added to Bash PATH while the plugin is enabled)
if [ -x "$ROOT/bin/hcat" ]; then
  echo "ok - bin/hcat: exists and is executable"; PASS=$((PASS+1))
else
  echo "FAIL - bin/hcat: exists and is executable"; FAIL=$((FAIL+1))
fi

# end-to-end through the EXACT command strings from hooks.json (not hardcoded
# paths): substitute CLAUDE_PLUGIN_ROOT=$ROOT and run via sh -c.
out=$(hook_input Bash 9000 plugnat-d1 | CLAUDE_PLUGIN_ROOT="$ROOT" sh -c "$dangi_cmd"); rc=$?
check "plugin-native dangi: nudges via hooks.json command" "additionalContext" "$out"
check "plugin-native dangi: exit 0" "0" "$rc"
check "dangi nudge: plain hcat form (on PATH)" 'hcat \"<path>\"' "$out"
check "dangi nudge: says it is on PATH" "on PATH" "$out"
check_absent "dangi nudge: no ~/.claude" "~/.claude" "$out"
check_absent "dangi nudge: no .claude/hcat" ".claude/hcat" "$out"

if [ -n "$HEADROOM_PY" ]; then
  out=$(gate_input "$TMP/hc_big.json" plugnat-g1 | CLAUDE_PLUGIN_ROOT="$ROOT" sh -c "$gate_cmd"); rc=$?
  check "plugin-native gate: denies big json via hooks.json command" '"permissionDecision":"deny"' "$out"
  check "plugin-native gate: exit 0" "0" "$rc"
  check "gate deny: plain hcat form" 'Run `hcat \"' "$out"
  check_absent "gate deny: no scripts/hcat path" "scripts/hcat" "$out"
  check_absent "gate deny: no bin/hcat path" "bin/hcat" "$out"
  check_absent "gate deny: no .claude/hcat" ".claude/hcat" "$out"
  check_absent "gate deny: no ~/.claude" "~/.claude" "$out"
else
  echo "skip - plugin-native gate deny tests (headroom venv not found)"
fi

# --- 32. portability (v2.5 WS3): linux notify-send fallback, hcat SIGPIPE, GNU-stat env
export HEADROOM_STATE_DIR="$TMP/state-port"

# A minimal "Linux" PATH: coreutils + jq symlinked in, a GNU-style stat shim
# (accepts -c, rejects -f like GNU stat does), a fake notify-send that logs its
# args, and NO osascript anywhere on it.
LINBIN="$TMP/linbin"; mkdir -p "$LINBIN"
for t in jq tr wc date mkdir rmdir cat; do
  ln -s "$(command -v "$t")" "$LINBIN/$t"
done
cat > "$LINBIN/stat" <<'EOF'
#!/bin/sh
case "$1" in
  -c) shift; exec /usr/bin/stat -f %m "$2" ;;
  # Faithful to real GNU `stat -f %m FILE`: -f means --file-system there, so it
  # errors on the '%m' operand (stderr) but STILL prints an fs-info block for
  # FILE on stdout, and exits 1 — stdout garbage that poisons $(( now - ... ))
  # if a caller tries BSD-style -f first.
  -f) echo "stat: cannot read file system information for '%m': No such file or directory" >&2
      printf '  File: "%s"\n    ID: 100000ff Namelen: 255     Type: ext2/ext3\n' "${3:-}"
      exit 1 ;;
  *) echo "stat: invalid option" >&2; exit 1 ;;
esac
EOF
printf '#!/bin/sh\necho "$@" >> "%s/notifysend.calls"\n' "$TMP" > "$LINBIN/notify-send"
chmod +x "$LINBIN/stat" "$LINBIN/notify-send"

ns_count() { wc -l < "$TMP/notifysend.calls" 2>/dev/null | tr -d ' '; }

# no osascript on PATH → notify-send fallback fires; nudge and exit 0 intact
out=$(jq -n '{hook_event_name:"PostToolUse", tool_name:"Bash", session_id:"port-s1",
  tool_response:("x"*9000)}' | env -u DANGI_NO_NOTIFY PATH="$LINBIN" /bin/bash "$DANGI"); rc=$?
check "portability: linux env still nudges" "additionalContext" "$out"
check "portability: linux env exit 0" "0" "$rc"
for _ in 1 2 3 4 5 6 7 8 9 10; do   # notify-send fires in the background — poll up to 2s
  [ -s "$TMP/notifysend.calls" ] && break
  sleep 0.2
done
check "portability: notify-send invoked without osascript" "Dangi" "$(cat "$TMP/notifysend.calls" 2>/dev/null)"
check "portability: notify-send carries the message" "KB Bash output" "$(cat "$TMP/notifysend.calls" 2>/dev/null)"

# NOTIFY_COOLDOWN applies to notify-send too — same session again stays quiet
jq -n '{hook_event_name:"PostToolUse", tool_name:"Bash", session_id:"port-s1",
  tool_response:("x"*9000)}' | env -u DANGI_NO_NOTIFY PATH="$LINBIN" /bin/bash "$DANGI" > /dev/null
sleep 0.5
check "portability: notify-send cooldown per session" "1" "$(ns_count)"

# DANGI_NO_NOTIFY kill switch silences notify-send as well
jq -n '{hook_event_name:"PostToolUse", tool_name:"Bash", session_id:"port-s2",
  tool_response:("x"*9000)}' | env DANGI_NO_NOTIFY=1 PATH="$LINBIN" /bin/bash "$DANGI" > /dev/null
sleep 0.5
check "portability: DANGI_NO_NOTIFY silences notify-send" "1" "$(ns_count)"

# when both notifiers are present, osascript is preferred (macOS look stays native)
osa_pre=$(wc -l < "$TMP/osascript.calls" | tr -d ' ')
jq -n '{hook_event_name:"PostToolUse", tool_name:"Bash", session_id:"port-s3",
  tool_response:("x"*9000)}' | env -u DANGI_NO_NOTIFY PATH="$FAKEBIN:$LINBIN:$PATH" bash "$DANGI" > /dev/null
for _ in 1 2 3 4 5 6 7 8 9 10; do
  [ "$(wc -l < "$TMP/osascript.calls" | tr -d ' ')" -gt "$osa_pre" ] && break
  sleep 0.2
done
check "portability: osascript preferred when both exist" "$((osa_pre + 1))" "$(wc -l < "$TMP/osascript.calls" | tr -d ' ')"
check "portability: notify-send not doubled" "1" "$(ns_count)"

# stale-lock steal must work where only GNU stat exists (stat -c, no -f)
mkdir -p "$HEADROOM_STATE_DIR/.lock-port-s4"
touch -t 202001010000 "$HEADROOM_STATE_DIR/.lock-port-s4"
out=$(jq -n '{hook_event_name:"PostToolUse", tool_name:"Bash", session_id:"port-s4",
  tool_response:("x"*9000)}' | env DANGI_NO_NOTIFY=1 PATH="$LINBIN" /bin/bash "$DANGI"); rc=$?
check "portability: stale lock stolen with GNU-only stat" "additionalContext" "$out"
check "portability: GNU-only stat exit 0" "0" "$rc"

# hcat piped into head must not spew BrokenPipeError from python stdout teardown
if [ -n "$HEADROOM_PY" ]; then
  "$HEADROOM_PY" - "$TMP/hc_pipe.json" <<'PYEOF'
import json, sys
rows = [{"id": i, "user": f"user_{i%50}", "event": "click", "ts": 1700000000+i, "ok": True} for i in range(5000)]
open(sys.argv[1], "w").write(json.dumps(rows, indent=2))
PYEOF
  err=$( { HEADROOM_WORKSPACE_DIR="$TMP/hc_ws" bash "$HCAT" "$TMP/hc_pipe.json" | head -1 > "$TMP/hc_pipe.out"; } 2>&1 )
  check_absent "portability: no BrokenPipeError when piped to head" "BrokenPipeError" "$err"
  check_absent "portability: no traceback when piped to head" "Traceback" "$err"
  check "portability: receipt header survives the pipe" "── hcat:" "$(cat "$TMP/hc_pipe.out")"
else
  echo "skip - hcat SIGPIPE test (headroom venv not found)"
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
