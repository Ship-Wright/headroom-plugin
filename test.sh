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

check_eq() {  # check_eq <name> <expected> <actual> — exact match (exit codes, counts)
  if [ "$2" = "$3" ]; then
    echo "ok - $1"; PASS=$((PASS+1))
  else
    echo "FAIL - $1"
    echo "    expected exactly: $2"
    echo "    got: $3"
    FAIL=$((FAIL+1))
  fi
}

badge() {  # badge <transcript> <model-id> <session-id> — run the script as Claude Code would
  printf '{"transcript_path":"%s","model":{"id":"%s"},"session_id":"%s"}' "$1" "$2" "$3" \
    | bash "$SCRIPT"
}

mkuniform() {  # mkuniform <path> [rows] — a uniform JSON array (gate-eligible by size)
  jq -n --argjson n "${2:-900}" '[range(0; $n) | {id:., v:"xxxxxxxxxxxxxxxx"}]' > "$1"
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
check_eq "cache upgrade: rewritten with 5 fields" "5" "$fields"

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
check_eq "dangi: exit code"              "0"                  "$rc"
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

# hcat invocations ARE compressions — their outputs are never nudge targets.
# (Real PostToolUse input carries the command in .tool_input.command; the hook
# attributes receipts structurally, so the fixtures carry it too.)
out=$(jq -n '{hook_event_name:"PostToolUse", tool_name:"Bash", session_id:"dangi-s13",
  tool_input:{command:"hcat \"/tmp/x.json\""},
  tool_response:("── hcat: /tmp/x.json · 10 lines · 5.0 KB · ~9000 tok → ~3000 tok (66.7% saved)\n" + ("y"*9000))}' | bash "$DANGI")
check_absent "dangi: hcat receipt excluded" "additionalContext" "$out"
# ...even buried mid-text after a persisted-output preview banner (legacy-path form)
out=$(jq -n '{hook_event_name:"PostToolUse", tool_name:"Bash", session_id:"dangi-s14",
  tool_input:{command:"/Users/abhi/.claude/hcat \"/tmp/x.json\""},
  tool_response:("Output too large. Preview:\n── hcat: /tmp/x.json · ~9000 tok → ~3000 tok (66.7% saved)\n" + ("y"*9000))}' | bash "$DANGI")
check_absent "dangi: buried hcat receipt excluded" "additionalContext" "$out"
# ...and in object-form tool_responses, where tostring JSON-escapes the newlines (chained form)
out=$(jq -n '{hook_event_name:"PostToolUse", tool_name:"Bash", session_id:"dangi-s15",
  tool_input:{command:"cd /tmp && hcat x.json"},
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
check_eq "dangi: stale lock tolerated (exit 0)" "0" "$rc"
check "dangi: stale lock still nudges" "additionalContext" "$out"
out=$(hook_input mcp__headroom__headroom_compress 9000 dangi-s4 | bash "$DANGI")
check_absent "dangi: headroom tools excluded" "additionalContext" "$out"
out=$(printf 'not json at all' | bash "$DANGI"); rc=$?
check_absent "dangi: garbage stdin silent" "additionalContext" "$out"
check_eq "dangi: garbage stdin exit 0" "0" "$rc"

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
check_eq "hcat: no args → exit 2" "2" "$rc"
out=$(bash "$HCAT" "$TMP/does-not-exist.json" 2>&1); rc=$?
check_eq "hcat: missing file → exit 2" "2" "$rc"

# 23. unusable python → distinct exit 3, nothing on stdout
printf '{"k":1}' > "$TMP/hc_small.json"
out=$(HCAT_PYTHON=/nonexistent/python bash "$HCAT" "$TMP/hc_small.json" 2>/dev/null); rc=$?
check_eq "hcat: no headroom → exit 3" "3" "$rc"
check_absent "hcat: no headroom → stdout empty" "{" "$out"

if [ -n "$HEADROOM_PY" ]; then
  # 24. real compression: big structured JSON shrinks, header cites source path
  "$HEADROOM_PY" - "$TMP/hc_big.json" <<'PYEOF'
import json, sys
rows = [{"id": i, "user": f"user_{i%50}", "event": "click", "ts": 1700000000+i, "ok": True} for i in range(500)]
open(sys.argv[1], "w").write(json.dumps(rows, indent=2))
PYEOF
  out=$(HEADROOM_WORKSPACE_DIR="$TMP/hc_ws" bash "$HCAT" "$TMP/hc_big.json"); rc=$?
  check_eq "hcat: exit 0 on success" "0" "$rc"
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
check_eq "gate: small file exit 0" "0" "$rc"
head -c 20000 /dev/zero | tr '\0' 'x' > "$TMP/hc_big.dart"
out=$(gate_input "$TMP/hc_big.dart" gate-s1 | bash "$GATE")
check_absent "gate: non-structured ext allowed" "deny" "$out"
out=$(printf 'not json' | bash "$GATE"); rc=$?
check_absent "gate: garbage stdin silent" "deny" "$out"
check_eq "gate: garbage stdin exit 0" "0" "$rc"

bash_gate_input() {  # bash_gate_input <command> <session-id>
  jq -n --arg cmd "$1" --arg sid "$2" \
    '{hook_event_name:"PreToolUse", tool_name:"Bash", session_id:$sid, tool_input:{command:$cmd}}'
}

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
  out=$(bash_gate_input "cat $TMP/hc_big.json" gate-b1 | bash "$GATE")
  check "gate/bash: bare cat rewritten, not denied" '"permissionDecision":"allow"' "$out"
  check "gate/bash: updatedInput carries the hcat command" '"updatedInput"' "$out"
  check "gate/bash: rewritten command targets the file" "hc_big.json" "$out"
  check_absent "gate/bash: rewrite is not a deny" '"permissionDecision":"deny"' "$out"
  out=$(bash_gate_input "cat $TMP/hc_big.json" gate-b1 | bash "$GATE")
  check_absent "gate/bash: retry same file passes raw (no rewrite loop)" "updatedInput" "$out"
  out=$(bash_gate_input "cat $TMP/hc_big.json | jq '.[0]'" gate-b2 | bash "$GATE")
  check_absent "gate/bash: piped cat allowed (real processing)" "deny" "$out"
  out=$(bash_gate_input "head -c 200 $TMP/hc_big.json" gate-b2 | bash "$GATE")
  check_absent "gate/bash: bounded head allowed" "deny" "$out"
  out=$(bash_gate_input "cat $TMP/hc_small.json" gate-b2 | bash "$GATE")
  check_absent "gate/bash: small file allowed" "deny" "$out"
  out=$(bash_gate_input "cat $TMP/hc_big.dart" gate-b2 | bash "$GATE")
  check_absent "gate/bash: non-structured ext allowed" "deny" "$out"
  out=$(bash_gate_input "cat \"$TMP/hc_big.json\"" gate-b3 | bash "$GATE")
  check "gate/bash: quoted path still rewritten" '"updatedInput"' "$out"
else
  echo "skip - gate deny tests (headroom venv not found)"
fi

# --- 30. badge counts hcat receipts from the transcript
export HEADROOM_STATE_DIR="$TMP/state-hcat-badge"

hcat_event() {  # hcat_event <tool-use-id> <before-tok> <after-tok> [pad-bytes]
  # Real transcripts carry the Bash command in tool_use .input.command — the
  # badge attributes receipts structurally, so the fixture must carry it too.
  local pad=""
  [ -n "${4:-}" ] && pad=$(head -c "$4" /dev/zero | tr '\0' 'y')
  printf '%s\n%s\n' \
    "{\"timestamp\":\"$NOW\",\"message\":{\"content\":[{\"type\":\"tool_use\",\"id\":\"$1\",\"name\":\"Bash\",\"input\":{\"command\":\"hcat \\\"/tmp/x.json\\\"\"}}]}}" \
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
  "{\"timestamp\":\"$NOW\",\"message\":{\"content\":[{\"type\":\"tool_use\",\"id\":\"h5\",\"name\":\"Bash\",\"input\":{\"command\":\"hcat \\\"/tmp/z.json\\\"\"}}]}}" \
  '{"message":{"content":[{"type":"tool_result","tool_use_id":"h5","content":[{"type":"text","text":"Output too large (32.1KB). Full output saved.\nPreview (first 2KB):\n── hcat: /tmp/z.json · 9 lines · 8.0 KB · ~2000 tok → ~800 tok (60.0% saved) · original on disk\n..."}]}]}}' \
  > "$TMP/t_persist.jsonl"
out=$(badge "$TMP/t_persist.jsonl" claude-opus-4-8 sess-hpers)
check "hcat badge: persisted preview receipt counted" "1.2k" "$out"

# passthrough receipts (no "→") are not compressions
printf '%s\n%s\n' \
  "{\"timestamp\":\"$NOW\",\"message\":{\"content\":[{\"type\":\"tool_use\",\"id\":\"h4\",\"name\":\"Bash\",\"input\":{\"command\":\"hcat \\\"/tmp/y.txt\\\"\"}}]}}" \
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
check_eq "hooks.json: exactly the five event arrays" "PostToolUse,PreToolUse,SessionEnd,SessionStart,Stop" \
  "$(jq -r '.hooks | keys | sort | join(",")' "$HOOKS_JSON" 2>/dev/null)"
check_eq "hooks.json: single PreToolUse entry"  "1" "$(jq -r '.hooks.PreToolUse  | length' "$HOOKS_JSON" 2>/dev/null)"
check_eq "hooks.json: single PostToolUse entry" "1" "$(jq -r '.hooks.PostToolUse | length' "$HOOKS_JSON" 2>/dev/null)"
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
check_eq "plugin-native dangi: exit 0" "0" "$rc"
check "dangi nudge: plain hcat form (on PATH)" 'hcat \"<path>\"' "$out"
check "dangi nudge: says plugin installs have it on PATH" "plugin installs have it on PATH" "$out"
check "dangi nudge: names legacy fallback" "~/.claude/hcat" "$out"
check_absent "dangi nudge: no plugin-internal path" "bin/hcat" "$out"

if [ -n "$HEADROOM_PY" ]; then
  out=$(gate_input "$TMP/hc_big.json" plugnat-g1 | CLAUDE_PLUGIN_ROOT="$ROOT" sh -c "$gate_cmd"); rc=$?
  check "plugin-native gate: denies big json via hooks.json command" '"permissionDecision":"deny"' "$out"
  check_eq "plugin-native gate: exit 0" "0" "$rc"
  check "gate deny: plain single-quoted hcat form" "Run \`hcat '" "$out"
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
check_eq "portability: linux env exit 0" "0" "$rc"
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
check_eq "portability: notify-send cooldown per session" "1" "$(ns_count)"

# DANGI_NO_NOTIFY kill switch silences notify-send as well
jq -n '{hook_event_name:"PostToolUse", tool_name:"Bash", session_id:"port-s2",
  tool_response:("x"*9000)}' | env DANGI_NO_NOTIFY=1 PATH="$LINBIN" /bin/bash "$DANGI" > /dev/null
sleep 0.5
check_eq "portability: DANGI_NO_NOTIFY silences notify-send" "1" "$(ns_count)"

# when both notifiers are present, osascript is preferred (macOS look stays native)
osa_pre=$(wc -l < "$TMP/osascript.calls" | tr -d ' ')
jq -n '{hook_event_name:"PostToolUse", tool_name:"Bash", session_id:"port-s3",
  tool_response:("x"*9000)}' | env -u DANGI_NO_NOTIFY PATH="$FAKEBIN:$LINBIN:$PATH" bash "$DANGI" > /dev/null
for _ in 1 2 3 4 5 6 7 8 9 10; do
  [ "$(wc -l < "$TMP/osascript.calls" | tr -d ' ')" -gt "$osa_pre" ] && break
  sleep 0.2
done
check_eq "portability: osascript preferred when both exist" "$((osa_pre + 1))" "$(wc -l < "$TMP/osascript.calls" | tr -d ' ')"
check_eq "portability: notify-send not doubled" "1" "$(ns_count)"

# stale-lock steal must work where only GNU stat exists (stat -c, no -f)
mkdir -p "$HEADROOM_STATE_DIR/.lock-port-s4"
touch -t 202001010000 "$HEADROOM_STATE_DIR/.lock-port-s4"
out=$(jq -n '{hook_event_name:"PostToolUse", tool_name:"Bash", session_id:"port-s4",
  tool_response:("x"*9000)}' | env DANGI_NO_NOTIFY=1 PATH="$LINBIN" /bin/bash "$DANGI"); rc=$?
check "portability: stale lock stolen with GNU-only stat" "additionalContext" "$out"
check_eq "portability: GNU-only stat exit 0" "0" "$rc"

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

# --- 33. doctor + engine bootstrap + bundled MCP definition (v2.5 WS2)
DOCTOR="$ROOT/scripts/doctor.sh"
# hermetic: the doctor scans $PWD/.claude by default (v2.7) — point it at an
# empty dir so the developer's real project settings never leak into the suite
export DOCTOR_PROJECT_DIR="$TMP/no-proj"
LAUNCHER="$ROOT/scripts/mcp-launcher.sh"
MCP_JSON="$ROOT/.mcp.json"
DOCD="$TMP/doc"; mkdir -p "$DOCD"

doc_settings_wired() {  # doc_settings_wired <claude-dir> — statusLine wired, no legacy hooks
  jq -n --arg cd "$1" '{statusLine:{type:"command",command:("bash \"" + $cd + "/headroom-statusline.sh\"")}}'
}
doc_settings_legacy() {  # doc_settings_legacy <claude-dir> — the real pre-plugin layout
  jq -n --arg cd "$1" '{hooks:{
    PostToolUse:[
      {matcher:"*",hooks:[{type:"command",command:("bash \"" + $cd + "/dangi-hook.sh\""),timeout:10}]},
      {matcher:"*",hooks:[{type:"command",command:"echo unrelated-hook"}]}],
    PreToolUse:[
      {matcher:"Read",hooks:[{type:"command",command:("bash \"" + $cd + "/hcat-gate.sh\""),timeout:10}]}]}}'
}

# stub toolchain for --fix tests: fake python3 whose `-m venv` materializes a fake
# venv (fake pip records its args; NEVER runs real pip), plus the real jq on PATH.
STUB="$DOCD/stub"; mkdir -p "$STUB"
ln -sf "$(command -v jq)" "$STUB/jq"
cat > "$STUB/python3" <<'STUBEOF'
#!/bin/sh
d=$(dirname "$0")
echo "$@" >> "$d/python3.calls"
if [ "$1" = "-m" ] && [ "$2" = "venv" ]; then
  mkdir -p "$3/bin"
  cat > "$3/bin/pip" <<'PIPEOF'
#!/bin/sh
echo "$@" >> "$(dirname "$0")/../pip.calls"
PIPEOF
  cat > "$3/bin/python" <<'PYEOF2'
#!/bin/sh
exit 0
PYEOF2
  chmod +x "$3/bin/pip" "$3/bin/python"
fi
exit 0
STUBEOF
chmod +x "$STUB/python3"

# fake engine dir: python that always succeeds + headroom that reports its invocation
FENG="$DOCD/feng"; mkdir -p "$FENG"
printf '#!/bin/sh\nexit 0\n' > "$FENG/python"
cat > "$FENG/headroom" <<'FENGEOF'
#!/bin/sh
echo "launched: $* update=$HEADROOM_UPDATE_CHECK offline=$HF_HUB_OFFLINE"
FENGEOF
chmod +x "$FENG/python" "$FENG/headroom"

# 32a. healthy read-only run against the real engine
if [ -n "$HEADROOM_PY" ]; then
  CD1="$DOCD/cd1"; mkdir -p "$CD1"
  S1="$DOCD/s1.json"; doc_settings_wired "$CD1" > "$S1"
  out=$(HCAT_PYTHON="$HEADROOM_PY" DOCTOR_SETTINGS="$S1" DOCTOR_CLAUDE_DIR="$CD1" \
        DOCTOR_VENV_DIR="$DOCD/none" bash "$DOCTOR" 2>&1); rc=$?
  check "doctor: healthy engine"          "engine python"   "$out"
  check "doctor: healthy hcat smoke"      "hcat smoke"      "$out"
  check "doctor: healthy hooks.json"      "hooks.json"      "$out"
  check "doctor: healthy statusLine"      "statusLine"      "$out"
  check_absent "doctor: healthy has no FAIL"    "FAIL"    "$out"
  check_absent "doctor: healthy has no fixable" "fixable" "$out"
  check_eq "doctor: healthy exit 0" "0" "$rc"
else
  echo "skip - doctor healthy-run tests (headroom venv not found)"
fi

# 32b. engine missing → fixable (not FAIL), smoke skipped, exit stays 0
CD2="$DOCD/cd2"; mkdir -p "$CD2"
S2="$DOCD/s2.json"; doc_settings_wired "$CD2" > "$S2"
out=$(HCAT_PYTHON=/nonexistent/python DOCTOR_SETTINGS="$S2" DOCTOR_CLAUDE_DIR="$CD2" \
      DOCTOR_VENV_DIR="$DOCD/none" bash "$DOCTOR" 2>&1); rc=$?
check "doctor: missing engine is fixable"    "fixable - engine"          "$out"
check "doctor: smoke skipped without engine" "hcat smoke (engine missing" "$out"
check_eq "doctor: fixable-only still exit 0"    "0"                          "$rc"

# 32c. broken engine (import ok, real runs fail) → FAIL + nonzero exit
BADPY="$DOCD/badpy"; mkdir -p "$BADPY"
printf '#!/bin/sh\ncase "$*" in *-c*) exit 0;; esac\nexit 1\n' > "$BADPY/python"
chmod +x "$BADPY/python"
out=$(HCAT_PYTHON="$BADPY/python" DOCTOR_SETTINGS="$S2" DOCTOR_CLAUDE_DIR="$CD2" \
      DOCTOR_VENV_DIR="$DOCD/none" bash "$DOCTOR" 2>&1); rc=$?
check "doctor: broken engine FAILs smoke" "FAIL" "$out"
if [ "$rc" -ne 0 ]; then
  echo "ok - doctor: FAIL exits nonzero"; PASS=$((PASS+1))
else
  echo "FAIL - doctor: FAIL exits nonzero (got rc=0)"; FAIL=$((FAIL+1))
fi

# 32d. resolution order branch 2: sibling python of `headroom` found on PATH
out=$(env -u HCAT_PYTHON PATH="$FENG:$STUB:/usr/bin:/bin" DOCTOR_SETTINGS="$S2" \
      DOCTOR_CLAUDE_DIR="$CD2" DOCTOR_VENV_DIR="$DOCD/none" bash "$DOCTOR" 2>&1)
check "doctor: engine via headroom on PATH" "engine python: $FENG/python" "$out"

# 32e. detectors: legacy hooks, unwired statusLine, stale copies, foreign statusLine
CD3="$DOCD/cd3"; mkdir -p "$CD3"
touch "$CD3/dangi-hook.sh" "$CD3/hcat-gate.sh" "$CD3/hcat"
S3="$DOCD/s3.json"; doc_settings_legacy "$CD3" > "$S3"
out=$(HCAT_PYTHON=/nonexistent/python DOCTOR_SETTINGS="$S3" DOCTOR_CLAUDE_DIR="$CD3" \
      DOCTOR_VENV_DIR="$DOCD/none" bash "$DOCTOR" 2>&1)
check "doctor: detects legacy hooks"        "fixable - legacy hooks" "$out"
check "doctor: detects unwired statusLine"  "fixable - statusLine"   "$out"
check "doctor: detects stale copies"        "fixable - stale"        "$out"
S3b="$DOCD/s3b.json"
jq -n '{statusLine:{type:"command",command:"bash ~/my-custom-line.sh"}}' > "$S3b"
out=$(HCAT_PYTHON=/nonexistent/python DOCTOR_SETTINGS="$S3b" DOCTOR_CLAUDE_DIR="$CD2" \
      DOCTOR_VENV_DIR="$DOCD/none" bash "$DOCTOR" --fix 2>&1)
check "doctor: foreign statusLine merged, not clobbered" "merged" "$out"
check "doctor: foreign statusLine preserved by --fix" "my-custom-line.sh" \
      "$(jq -r '.statusLine.command' "$S3b")"

# 32f. --fix end-to-end: venv bootstrap (stubbed), legacy removal, statusLine, stale cleanup
CD4="$DOCD/cd4"; mkdir -p "$CD4"
touch "$CD4/dangi-hook.sh" "$CD4/hcat-gate.sh" "$CD4/hcat"
S4="$DOCD/s4.json"; doc_settings_legacy "$CD4" > "$S4"
out=$(env -u HCAT_PYTHON PATH="$STUB:/usr/bin:/bin" DOCTOR_SETTINGS="$S4" \
      DOCTOR_CLAUDE_DIR="$CD4" DOCTOR_VENV_DIR="$DOCD/venv-boot" bash "$DOCTOR" --fix 2>&1); rc=$?
check "fix: reports fixed"        "fixed"   "$out"
check_eq "fix: exit 0"               "0"       "$rc"
check "fix: venv created via python3 -m venv" "-m venv $DOCD/venv-boot" "$(cat "$STUB/python3.calls" 2>/dev/null)"
check "fix: pip install headroom (stubbed)"   "install headroom" "$(cat "$DOCD/venv-boot/pip.calls" 2>/dev/null)"
check_eq "fix: legacy hooks removed" "0" \
  "$(jq '[.hooks // {} | to_entries[] | .value[]?.hooks[]? | select((.command // "") | test("dangi-hook|hcat-gate"))] | length' "$S4")"
check "fix: unrelated hook preserved" "unrelated-hook" "$(cat "$S4")"
check "fix: statusLine written" "headroom-statusline.sh" "$(jq -r '.statusLine.command // empty' "$S4")"
if cmp -s "$ROOT/scripts/statusline.sh" "$CD4/headroom-statusline.sh"; then
  echo "ok - fix: statusline script copied"; PASS=$((PASS+1))
else
  echo "FAIL - fix: statusline script copied"; FAIL=$((FAIL+1))
fi
if [ -e "$CD4/dangi-hook.sh" ] || [ -e "$CD4/hcat-gate.sh" ] || [ -e "$CD4/hcat" ]; then
  echo "FAIL - fix: stale copies removed"; FAIL=$((FAIL+1))
else
  echo "ok - fix: stale copies removed"; PASS=$((PASS+1))
fi
check_eq "fix: one timestamped backup" "1" "$(ls "$S4".bak.* 2>/dev/null | wc -l | tr -d ' ')"
# idempotency: a second --fix run must change nothing and re-bootstrap nothing
cp "$S4" "$DOCD/s4.after1"
out2=$(env -u HCAT_PYTHON PATH="$STUB:/usr/bin:/bin" DOCTOR_SETTINGS="$S4" \
       DOCTOR_CLAUDE_DIR="$CD4" DOCTOR_VENV_DIR="$DOCD/venv-boot" bash "$DOCTOR" --fix 2>&1)
if cmp -s "$S4" "$DOCD/s4.after1"; then
  echo "ok - fix: second run leaves settings unchanged"; PASS=$((PASS+1))
else
  echo "FAIL - fix: second run leaves settings unchanged"; FAIL=$((FAIL+1))
fi
check_eq "fix: second run adds no backup" "1" "$(ls "$S4".bak.* 2>/dev/null | wc -l | tr -d ' ')"
check_eq "fix: bootstrap not repeated"    "1" "$(wc -l < "$STUB/python3.calls" | tr -d ' ')"
check_absent "fix: nothing left fixable after fix" "fixable" "$out2"

# 32g. doctor CLI hygiene
out=$(bash "$DOCTOR" --bogus 2>&1); rc=$?
check "doctor: unknown flag errors" "unknown" "$out"
check_eq "doctor: unknown flag exit 2" "2"       "$rc"

# 32h. mcp-launcher.sh — resolves the engine and execs `headroom mcp serve`
if [ -x "$LAUNCHER" ]; then
  echo "ok - launcher: executable"; PASS=$((PASS+1))
else
  echo "FAIL - launcher: executable"; FAIL=$((FAIL+1))
fi
out=$(HCAT_PYTHON="$FENG/python" bash "$LAUNCHER" 2>&1); rc=$?
check "launcher: execs headroom mcp serve" "launched: mcp serve" "$out"
check "launcher: update check off"         "update=off"          "$out"
check "launcher: hf offline"               "offline=1"           "$out"
check_eq "launcher: exit 0"                   "0"                   "$rc"
err=$(HCAT_PYTHON=/nonexistent/python bash "$LAUNCHER" 2>&1 >/dev/null); rc=$?
check "launcher: missing engine names doctor" "doctor" "$err"
if [ "$rc" -ne 0 ]; then
  echo "ok - launcher: missing engine exits nonzero"; PASS=$((PASS+1))
else
  echo "FAIL - launcher: missing engine exits nonzero (got rc=0)"; FAIL=$((FAIL+1))
fi
if [ "$(printf '%s\n' "$err" | wc -l | tr -d ' ')" = "1" ]; then
  echo "ok - launcher: single stderr line"; PASS=$((PASS+1))
else
  echo "FAIL - launcher: single stderr line (got: $err)"; FAIL=$((FAIL+1))
fi
NOHR="$DOCD/nohr"; mkdir -p "$NOHR"
printf '#!/bin/sh\nexit 0\n' > "$NOHR/python"; chmod +x "$NOHR/python"
err=$(HCAT_PYTHON="$NOHR/python" bash "$LAUNCHER" 2>&1 >/dev/null); rc=$?
check "launcher: python without headroom binary names doctor" "doctor" "$err"
if [ "$rc" -ne 0 ]; then
  echo "ok - launcher: headroom-binary-missing exits nonzero"; PASS=$((PASS+1))
else
  echo "FAIL - launcher: headroom-binary-missing exits nonzero"; FAIL=$((FAIL+1))
fi

# 32i. bundled .mcp.json — erases the manual "register headroom MCP" step
if jq -e . "$MCP_JSON" >/dev/null 2>&1; then
  echo "ok - mcp.json: parses"; PASS=$((PASS+1))
else
  echo "FAIL - mcp.json: parses"; FAIL=$((FAIL+1))
fi
check "mcp.json: stdio server" "stdio" "$(jq -r '.mcpServers.headroom.type // empty' "$MCP_JSON" 2>/dev/null)"
mcp_cmd=$(jq -r '.mcpServers.headroom.command // empty' "$MCP_JSON" 2>/dev/null)
check "mcp.json: command uses CLAUDE_PLUGIN_ROOT" '${CLAUDE_PLUGIN_ROOT}' "$mcp_cmd"
check "mcp.json: command targets mcp-launcher.sh" "mcp-launcher.sh"       "$mcp_cmd"
check "mcp.json: env update off" "off" "$(jq -r '.mcpServers.headroom.env.HEADROOM_UPDATE_CHECK // empty' "$MCP_JSON" 2>/dev/null)"
check_eq "mcp.json: env hf offline" "1"   "$(jq -r '.mcpServers.headroom.env.HF_HUB_OFFLINE // empty' "$MCP_JSON" 2>/dev/null)"
# the command string is shell-interpreted (quoted like hooks.json), so run it
# the same way the hooks.json commands are exercised: via sh -c
mcp_resolved=${mcp_cmd/'${CLAUDE_PLUGIN_ROOT}'/"$ROOT"}
out=$(HCAT_PYTHON="$FENG/python" sh -c "$mcp_resolved" 2>&1)
check "mcp.json: end-to-end launch through the bundled command" "launched: mcp serve" "$out"

# 32j. /doctor skill
DSKILL="$ROOT/skills/doctor/SKILL.md"
if [ -f "$DSKILL" ]; then
  echo "ok - doctor skill: exists"; PASS=$((PASS+1))
else
  echo "FAIL - doctor skill: exists"; FAIL=$((FAIL+1))
fi
check "doctor skill: frontmatter name"     "name: doctor" "$(head -5 "$DSKILL" 2>/dev/null)"
check "doctor skill: triggers on breakage" "not working"  "$(cat "$DSKILL" 2>/dev/null)"
check "doctor skill: runs doctor.sh"       "doctor.sh"    "$(cat "$DSKILL" 2>/dev/null)"
check "doctor skill: consent before --fix" "consent"      "$(cat "$DSKILL" 2>/dev/null)"

# --- 34. review fixes: badge + hooks
export HEADROOM_STATE_DIR="$TMP/state-review"

# 34a. receipt attribution is structural: a tool result that merely QUOTES a
# receipt line (grep/cat over docs or this very test file) must not count.
quote_event() {  # quote_event <id> <bash-command> [pad-bytes] — result quotes a receipt lookalike
  local pad=""
  [ -n "${3:-}" ] && pad=$(head -c "$3" /dev/zero | tr '\0' 'y')
  printf '%s\n%s\n' \
    "{\"timestamp\":\"$NOW\",\"message\":{\"content\":[{\"type\":\"tool_use\",\"id\":\"$1\",\"name\":\"Bash\",\"input\":{\"command\":\"$2\"}}]}}" \
    "{\"message\":{\"content\":[{\"type\":\"tool_result\",\"tool_use_id\":\"$1\",\"content\":[{\"type\":\"text\",\"text\":\"── hcat: /x.json · ~9999999 tok → ~1 tok (100.0% saved)\\n$pad\"}]}]}}"
}
quote_event q1 "grep -rn hcat-header notes" > "$TMP/t_rquote.jsonl"
out=$(badge "$TMP/t_rquote.jsonl" claude-opus-4-8 sess-rq1)
check "review: quoted receipt renders idle"      "not compressing yet" "$out"
check_absent "review: quoted receipt never green" "●"                  "$out"
if [ -e "$HEADROOM_STATE_DIR/session-sess-rq1.totals" ]; then
  echo "FAIL - review: quoted receipt writes no totals"
  echo "    found: $(cat "$HEADROOM_STATE_DIR/session-sess-rq1.totals")"
  FAIL=$((FAIL+1))
else
  echo "ok - review: quoted receipt writes no totals"; PASS=$((PASS+1))
fi

# a BIG quoted receipt is uncompressed raw text — a missed opportunity, not a save
quote_event q2 "cat README.md" 6000 > "$TMP/t_rquote_big.jsonl"
out=$(badge "$TMP/t_rquote_big.jsonl" claude-opus-4-8 sess-rq2)
check "review: big quoted receipt counts as missed" "1 big blob uncompressed" "$out"

# non-Bash receipts never count (Read of a file that starts with a receipt line)
printf '%s\n%s\n' \
  "{\"timestamp\":\"$NOW\",\"message\":{\"content\":[{\"type\":\"tool_use\",\"id\":\"q3\",\"name\":\"Read\",\"input\":{\"file_path\":\"/tmp/notes.txt\"}}]}}" \
  '{"message":{"content":[{"type":"tool_result","tool_use_id":"q3","content":[{"type":"text","text":"── hcat: /x.json · ~9999999 tok → ~1 tok (100.0% saved)"}]}]}}' \
  > "$TMP/t_rquote_read.jsonl"
out=$(badge "$TMP/t_rquote_read.jsonl" claude-opus-4-8 sess-rq3)
check "review: non-Bash receipt not counted" "not compressing yet" "$out"

# genuine invocations still count in every real spelling
genuine_event() {  # genuine_event <id> <bash-command> — real receipt, 1000→400
  printf '%s\n%s\n' \
    "{\"timestamp\":\"$NOW\",\"message\":{\"content\":[{\"type\":\"tool_use\",\"id\":\"$1\",\"name\":\"Bash\",\"input\":{\"command\":\"$2\"}}]}}" \
    "{\"message\":{\"content\":[{\"type\":\"tool_result\",\"tool_use_id\":\"$1\",\"content\":[{\"type\":\"text\",\"text\":\"── hcat: /tmp/x.json · 10 lines · 5.0 KB · ~1000 tok → ~400 tok (60.0% saved) · original on disk\"}]}]}}"
}
genuine_event ga "/Users/abhi/.claude/hcat \\\"/tmp/x.json\\\"" > "$TMP/t_rlegacy.jsonl"
out=$(badge "$TMP/t_rlegacy.jsonl" claude-opus-4-8 sess-rg1)
check "review: legacy-path hcat counts" "●"   "$out"
check "review: legacy-path savings"     "600" "$out"
genuine_event gb "jq -c . /tmp/x.json | hcat /dev/stdin" > "$TMP/t_rpipe.jsonl"
out=$(badge "$TMP/t_rpipe.jsonl" claude-opus-4-8 sess-rg2)
check "review: piped hcat counts" "●" "$out"

# dangi, same attack: quoting a receipt in a grep is still a missed opportunity...
out=$(jq -n '{hook_event_name:"PostToolUse", tool_name:"Bash", session_id:"rev-d1",
  tool_input:{command:"grep -rn hcat-header notes"},
  tool_response:("── hcat: /x.json · ~9999999 tok → ~1 tok (100.0% saved)\n" + ("y"*9000))}' | bash "$DANGI")
check "review: dangi nudges on quoted receipt" "additionalContext" "$out"
# ...while a genuine hcat run stays exempt
out=$(jq -n '{hook_event_name:"PostToolUse", tool_name:"Bash", session_id:"rev-d2",
  tool_input:{command:"hcat \"/tmp/x.json\""},
  tool_response:("── hcat: /tmp/x.json · ~9000 tok → ~3000 tok (66.7% saved)\n" + ("y"*9000))}' | bash "$DANGI")
check_absent "review: dangi exempts genuine hcat run" "additionalContext" "$out"

# 34b. HOME unset (env -u HOME, set -u) must not kill any of the three scripts
NOHOME_TMP="$TMP/nohome"; mkdir -p "$NOHOME_TMP"
err=$(printf '{"transcript_path":"%s","model":{"id":"claude-opus-4-8"},"session_id":"rev-nh1"}' "$TMP/t_active.jsonl" \
  | env -u HOME -u HEADROOM_STATE_DIR TMPDIR="$NOHOME_TMP" bash "$SCRIPT" 2>&1 >"$TMP/nohome.badge"); rc=$?
check_eq "review: statusline survives unset HOME" "0" "$rc"
check "review: statusline still prints a badge" "headroom" "$(cat "$TMP/nohome.badge")"
if [ -z "$err" ]; then
  echo "ok - review: statusline stderr silent without HOME"; PASS=$((PASS+1))
else
  echo "FAIL - review: statusline stderr silent without HOME"
  echo "    got stderr: $err"; FAIL=$((FAIL+1))
fi
err=$(hook_input Bash 9000 rev-nh2 \
  | env -u HOME -u HEADROOM_STATE_DIR DANGI_NO_NOTIFY=1 TMPDIR="$NOHOME_TMP" bash "$DANGI" 2>&1 >/dev/null); rc=$?
check_eq "review: dangi survives unset HOME" "0" "$rc"
if [ -z "$err" ]; then
  echo "ok - review: dangi stderr silent without HOME"; PASS=$((PASS+1))
else
  echo "FAIL - review: dangi stderr silent without HOME"
  echo "    got stderr: $err"; FAIL=$((FAIL+1))
fi
out=$(gate_input "$TMP/hc_small.json" rev-nh3 | env -u HOME -u HEADROOM_STATE_DIR bash "$GATE" 2>&1); rc=$?
check_eq "review: gate survives unset HOME" "0" "$rc"
check_absent "review: gate quiet without HOME" "unbound" "$out"

# 34c. gate fails open when the resolved engine python cannot import headroom
BIGJSON="$TMP/rev_big.json"; head -c 20000 /dev/zero | tr '\0' 'x' > "$BIGJSON"
printf '#!/bin/sh\nexit 1\n' > "$TMP/rev_brokenpy"; chmod +x "$TMP/rev_brokenpy"
printf '#!/bin/sh\nexit 0\n' > "$TMP/rev_okpy";     chmod +x "$TMP/rev_okpy"
out=$(gate_input "$BIGJSON" rev-g1 | HCAT_PYTHON="$TMP/rev_brokenpy" bash "$GATE")
check_absent "review: gate fails open on import-broken engine" "deny" "$out"
out=$(gate_input "$BIGJSON" rev-g2 | HCAT_PYTHON="$TMP/rev_okpy" bash "$GATE")
check "review: gate still denies with importable engine" '"permissionDecision":"deny"' "$out"

# 34d. install-aware deny text: plugin layout claims PATH, legacy layout gives the abs path
check "review: plugin deny says on PATH" "on PATH" "$out"
LEGROOT="$TMP/legroot"; mkdir -p "$LEGROOT/legacy"
cp "$ROOT/scripts/hcat-gate.sh" "$LEGROOT/legacy/"
printf '#!/bin/sh\nexit 0\n' > "$LEGROOT/legacy/hcat"; chmod +x "$LEGROOT/legacy/hcat"
out=$(gate_input "$BIGJSON" rev-g3 | HCAT_PYTHON="$TMP/rev_okpy" bash "$LEGROOT/legacy/hcat-gate.sh")
check "review: legacy deny cites sibling hcat path" "$LEGROOT/legacy/hcat" "$out"
check_absent "review: legacy deny does not claim PATH" "on PATH" "$out"

# 34e. BSD awk honors LC_NUMERIC — money and totals must stay period-decimal
if locale -a 2>/dev/null | grep -qix 'de_DE.UTF-8'; then
  export HEADROOM_STATE_DIR="$TMP/state-locale"
  out=$(printf '{"transcript_path":"%s","model":{"id":"claude-opus-4-8"},"session_id":"rev-loc"}' "$TMP/t_active.jsonl" \
    | LC_ALL=de_DE.UTF-8 bash "$SCRIPT")
  check "review: de_DE money keeps period decimal" "0.25¢" "$out"
  check_absent "review: de_DE badge has no comma decimal" "0,25" "$out"
  tot=$(cat "$HEADROOM_STATE_DIR"/session-rev-loc.totals 2>/dev/null)
  check "review: de_DE totals keep period decimal" "0.002500" "$tot"
  check_absent "review: de_DE totals carry no comma" "," "$tot"
else
  echo "skip - de_DE.UTF-8 locale tests (locale not installed)"
fi

# --- 35. review fixes: doctor + resolution (v2.5 F2)
REVD="$TMP/rev"; mkdir -p "$REVD"
NOVENV="$REVD/novenv"   # never created — engine must resolve without it

# F1: pip --user / pipx layout — a `headroom` console script with NO sibling
# python. Its shebang names a stub interpreter that passes `import headroom`
# (exit 0 on any argv, e.g. -c) and echoes its invocation. The stub must be a
# real binary — kernels reject a shebang interpreter that is itself a script —
# so symlink /bin/echo (argv comes out on stdout, exit 0 always; a copy would
# be SIGKILLed by macOS signature checks).
SPY="$REVD/interp"; mkdir -p "$SPY"
ln -s /bin/echo "$SPY/python3.14"
CLI="$REVD/clibin"; mkdir -p "$CLI"
printf '#!%s\n# console script only — no sibling python in this dir\n' "$SPY/python3.14" > "$CLI/headroom"
chmod +x "$CLI/headroom"
FAKEHOME="$REVD/home"; mkdir -p "$FAKEHOME"

# the launcher only needs the CLI: `headroom` on PATH is used directly
out=$(env -u HCAT_PYTHON PATH="$CLI:/usr/bin:/bin" DOCTOR_VENV_DIR="$NOVENV" bash "$LAUNCHER" 2>&1); rc=$?
check "f1 launcher: console-script-only layout execs" "mcp serve" "$out"
check_eq "f1 launcher: exit 0" "0" "$rc"

# hcat needs an importing python: the console script's shebang interpreter
# (the echo-stub prints its argv, proving which interpreter hcat exec'd)
printf '{"k":1}' > "$REVD/tiny.json"
out=$(env -u HCAT_PYTHON HOME="$FAKEHOME" PATH="$CLI:/usr/bin:/bin" bash "$HCAT" "$REVD/tiny.json" 2>&1); rc=$?
check "f1 hcat: shebang interpreter resolved" "$REVD/tiny.json" "$out"
check_eq "f1 hcat: exit 0 (not 3)" "0" "$rc"

# ...including the `#!/usr/bin/env pythonX` shebang form, resolved via PATH
CLI2="$REVD/clibin2"; mkdir -p "$CLI2"
ln -s "$SPY/python3.14" "$CLI2/revpy"
printf '#!/usr/bin/env revpy\n' > "$CLI2/headroom"
chmod +x "$CLI2/headroom"
out=$(env -u HCAT_PYTHON HOME="$FAKEHOME" PATH="$CLI2:/usr/bin:/bin" bash "$HCAT" "$REVD/tiny.json" 2>&1)
check "f1 hcat: env-form shebang resolved" "$REVD/tiny.json" "$out"

# the doctor's engine check accepts the shebang interpreter too
CD35="$REVD/cd35"; mkdir -p "$CD35"
S35="$REVD/s35.json"; doc_settings_wired "$CD35" > "$S35"
out=$(env -u HCAT_PYTHON PATH="$CLI:$STUB:/usr/bin:/bin" DOCTOR_SETTINGS="$S35" \
      DOCTOR_CLAUDE_DIR="$CD35" DOCTOR_VENV_DIR="$NOVENV" bash "$DOCTOR" 2>&1)
check "f1 doctor: engine via console-script shebang" "engine python: $SPY/python3.14" "$out"

# F2: a dotfile-manager symlinked settings.json must survive --fix as a symlink,
# with the fix landing in the target. (Also carries stale copies for the F5
# project-level caveat note.)
SYMD="$REVD/sym"; mkdir -p "$SYMD/cd"
touch "$SYMD/cd/dangi-hook.sh" "$SYMD/cd/hcat-gate.sh"
doc_settings_legacy "$SYMD/cd" > "$SYMD/target.json"
ln -s target.json "$SYMD/settings.json"
out=$(env -u HCAT_PYTHON PATH="$STUB:/usr/bin:/bin" DOCTOR_SETTINGS="$SYMD/settings.json" \
      DOCTOR_CLAUDE_DIR="$SYMD/cd" DOCTOR_VENV_DIR="$DOCD/venv-boot" bash "$DOCTOR" --fix 2>&1)
if [ -L "$SYMD/settings.json" ]; then
  echo "ok - f2: settings.json is still a symlink after --fix"; PASS=$((PASS+1))
else
  echo "FAIL - f2: settings.json is still a symlink after --fix"; FAIL=$((FAIL+1))
fi
check_eq "f2: legacy hooks removed through the link" "0" \
  "$(jq '[.hooks // {} | to_entries[] | .value[]?.hooks[]? | select((.command // "") | test("dangi-hook|hcat-gate"))] | length' "$SYMD/target.json")"
check "f2: statusLine fix landed in the target" "headroom-statusline.sh" \
  "$(jq -r '.statusLine.command // empty' "$SYMD/target.json")"
check_eq "f7b: doctor-written statusLine has refreshInterval 1" "1" \
  "$(jq -r '.statusLine.refreshInterval // empty' "$SYMD/target.json")"
check "f5: stale-copy deletion notes project-level settings caveat" "project-level" "$out"

# F3: broken exported HCAT_PYTHON — --fix must FAIL and refuse to bootstrap
BADIMP="$REVD/badimp"; mkdir -p "$BADIMP"
printf '#!/bin/sh\nexit 1\n' > "$BADIMP/python"; chmod +x "$BADIMP/python"
F3="$REVD/f3"; mkdir -p "$F3/cd"
doc_settings_wired "$F3/cd" > "$F3/settings.json"
pyc0=$(wc -l < "$STUB/python3.calls" | tr -d ' ')
out=$(HCAT_PYTHON="$BADIMP/python" PATH="$STUB:/usr/bin:/bin" DOCTOR_SETTINGS="$F3/settings.json" \
      DOCTOR_CLAUDE_DIR="$F3/cd" DOCTOR_VENV_DIR="$REVD/f3venv" bash "$DOCTOR" --fix 2>&1); rc=$?
check "f3: broken HCAT_PYTHON reported as FAIL" "HCAT_PYTHON is set but broken" "$out"
check_absent "f3: no bootstrap claim" "engine bootstrapped" "$out"
if [ "$rc" -ne 0 ]; then
  echo "ok - f3: --fix exits nonzero"; PASS=$((PASS+1))
else
  echo "FAIL - f3: --fix exits nonzero (got rc=0)"; FAIL=$((FAIL+1))
fi
if [ ! -e "$REVD/f3venv" ]; then
  echo "ok - f3: no venv created"; PASS=$((PASS+1))
else
  echo "FAIL - f3: no venv created ($REVD/f3venv exists)"; FAIL=$((FAIL+1))
fi
cp "$F3/settings.json" "$REVD/f3.settings.run1"
out2=$(HCAT_PYTHON="$BADIMP/python" PATH="$STUB:/usr/bin:/bin" DOCTOR_SETTINGS="$F3/settings.json" \
       DOCTOR_CLAUDE_DIR="$F3/cd" DOCTOR_VENV_DIR="$REVD/f3venv" bash "$DOCTOR" --fix 2>&1)
check "f3: second --fix FAILs identically" "HCAT_PYTHON is set but broken" "$out2"
if [ ! -e "$REVD/f3venv" ] && cmp -s "$F3/settings.json" "$REVD/f3.settings.run1"; then
  echo "ok - f3: state byte-identical after two --fix runs"; PASS=$((PASS+1))
else
  echo "FAIL - f3: state byte-identical after two --fix runs"; FAIL=$((FAIL+1))
fi
check_eq "f3: python3 never invoked" "$pyc0" "$(wc -l < "$STUB/python3.calls" | tr -d ' ')"

# F4: corrupt settings.json — FAIL, and all settings-mutating fixes refuse
for shape in trailing twodoc; do
  C4="$REVD/cor-$shape"; mkdir -p "$C4/cd"
  if [ "$shape" = trailing ]; then
    printf '{"statusLine":{"type":"command","command":"x"}} trailing-garbage\n' > "$C4/settings.json"
  else
    printf '{}\n{"hooks":{"PostToolUse":[{"matcher":"*","hooks":[{"type":"command","command":"bash ~/.claude/dangi-hook.sh"}]}]}}\n' > "$C4/settings.json"
  fi
  cp "$C4/settings.json" "$C4/settings.orig"
  out=$(HCAT_PYTHON="$FENG/python" PATH="$STUB:/usr/bin:/bin" DOCTOR_SETTINGS="$C4/settings.json" \
        DOCTOR_CLAUDE_DIR="$C4/cd" DOCTOR_VENV_DIR="$NOVENV" bash "$DOCTOR" --fix 2>&1); rc=$?
  check "f4 ($shape): parse failure is a FAIL" "not a single valid JSON document" "$out"
  check_absent "f4 ($shape): no false legacy ok" "no legacy hook registrations" "$out"
  check_absent "f4 ($shape): nothing reported fixed" "fixed" "$out"
  if cmp -s "$C4/settings.json" "$C4/settings.orig"; then
    echo "ok - f4 ($shape): settings.json untouched by --fix"; PASS=$((PASS+1))
  else
    echo "FAIL - f4 ($shape): settings.json untouched by --fix"; FAIL=$((FAIL+1))
  fi
  if [ "$rc" -ne 0 ]; then
    echo "ok - f4 ($shape): exit nonzero"; PASS=$((PASS+1))
  else
    echo "FAIL - f4 ($shape): exit nonzero (got rc=0)"; FAIL=$((FAIL+1))
  fi
done

# F5 (v2.7 semantics): legacy hooks in settings.local.json are now FIXABLE —
# read-only reports them, --fix removes them (with backup) and may then also
# delete the stale copies they referenced.
F5="$REVD/f5"; mkdir -p "$F5/cd"
touch "$F5/cd/dangi-hook.sh" "$F5/cd/hcat"
doc_settings_wired "$F5/cd" > "$F5/settings.json"
doc_settings_legacy "$F5/cd" > "$F5/settings.local.json"
out=$(HCAT_PYTHON="$FENG/python" PATH="$STUB:/usr/bin:/bin" DOCTOR_SETTINGS="$F5/settings.json" \
      DOCTOR_CLAUDE_DIR="$F5/cd" DOCTOR_VENV_DIR="$NOVENV" bash "$DOCTOR" 2>&1)
check "f5: read-only reports local legacy as fixable" "fixable - legacy hooks in settings.local.json" "$out"
check "f5: read-only keeps stale copies" "stale copies" "$out"
out=$(HCAT_PYTHON="$FENG/python" PATH="$STUB:/usr/bin:/bin" DOCTOR_SETTINGS="$F5/settings.json" \
      DOCTOR_CLAUDE_DIR="$F5/cd" DOCTOR_VENV_DIR="$NOVENV" bash "$DOCTOR" --fix 2>&1)
check "f5: --fix cleans settings.local.json" "removed 2 legacy hook entries from settings.local.json" "$out"
check_eq "f5: local legacy entries gone" "0" \
  "$(jq '[.hooks // {} | to_entries[] | .value[]?.hooks[]? | select((.command // "") | test("dangi-hook|hcat-gate"))] | length' "$F5/settings.local.json")"
check "f5: unrelated hook preserved" "unrelated-hook" "$(cat "$F5/settings.local.json")"
if ls "$F5"/settings.local.json.bak.* >/dev/null 2>&1; then
  echo "ok - f5: settings.local.json backup written"; PASS=$((PASS+1))
else
  echo "FAIL - f5: settings.local.json backup written"; FAIL=$((FAIL+1))
fi
check "f5: stale copies removed after local fix" "removed stale copies" "$out"
if [ ! -e "$F5/cd/dangi-hook.sh" ] && [ ! -e "$F5/cd/hcat" ]; then
  echo "ok - f5: stale scripts deleted once nothing references them"; PASS=$((PASS+1))
else
  echo "FAIL - f5: stale scripts deleted once nothing references them"; FAIL=$((FAIL+1))
fi

# F6: Debian venv dead-end — half-created venv removed, actionable message
DEB="$REVD/deb"; mkdir -p "$DEB"
ln -sf "$(command -v jq)" "$DEB/jq"
cat > "$DEB/python3" <<'EOF'
#!/bin/sh
if [ "$1" = "-m" ] && [ "$2" = "venv" ]; then
  mkdir -p "$3/bin"
  ln -s /bin/sh "$3/bin/python"
  echo "Error: ensurepip is not available (python3-venv missing)" >&2
  exit 1
fi
exit 0
EOF
printf '#!/bin/sh\nexit 0\n' > "$DEB/apt-get"
chmod +x "$DEB/python3" "$DEB/apt-get"
F6="$REVD/f6"; mkdir -p "$F6/cd"
doc_settings_wired "$F6/cd" > "$F6/settings.json"
out=$(env -u HCAT_PYTHON PATH="$DEB:/usr/bin:/bin" DOCTOR_SETTINGS="$F6/settings.json" \
      DOCTOR_CLAUDE_DIR="$F6/cd" DOCTOR_VENV_DIR="$REVD/f6venv" bash "$DOCTOR" --fix 2>&1)
check "f6: failure message suggests python3-venv" "python3-venv" "$out"
check "f6: bootstrap failure is a FAIL" "FAIL" "$out"
if [ ! -e "$REVD/f6venv" ]; then
  echo "ok - f6: half-created venv removed"; PASS=$((PASS+1))
else
  echo "FAIL - f6: half-created venv removed ($REVD/f6venv remains)"; FAIL=$((FAIL+1))
fi
# ...but a venv dir the doctor did NOT create must never be deleted
mkdir -p "$REVD/f6bvenv"; touch "$REVD/f6bvenv/keep-me"
env -u HCAT_PYTHON PATH="$DEB:/usr/bin:/bin" DOCTOR_SETTINGS="$F6/settings.json" \
    DOCTOR_CLAUDE_DIR="$F6/cd" DOCTOR_VENV_DIR="$REVD/f6bvenv" bash "$DOCTOR" --fix >/dev/null 2>&1
if [ -e "$REVD/f6bvenv/keep-me" ]; then
  echo "ok - f6: pre-existing venv dir preserved on failure"; PASS=$((PASS+1))
else
  echo "FAIL - f6: pre-existing venv dir preserved on failure"; FAIL=$((FAIL+1))
fi

# F7a: merge-aware statusLine fix — custom command preserved and chained
F7R="$REVD/f7r"; mkdir -p "$F7R/cd"
jq -n '{statusLine:{type:"command",command:"bash ~/my-line.sh"}}' > "$F7R/settings.json"
out=$(HCAT_PYTHON="$FENG/python" PATH="$STUB:/usr/bin:/bin" DOCTOR_SETTINGS="$F7R/settings.json" \
      DOCTOR_CLAUDE_DIR="$F7R/cd" DOCTOR_VENV_DIR="$NOVENV" bash "$DOCTOR" 2>&1)
check "f7a: read-only reports custom statusLine as fixable" "fixable - statusLine" "$out"
F7="$REVD/f7"; mkdir -p "$F7/cd"
jq -n '{statusLine:{type:"command",command:"bash ~/my-line.sh"}}' > "$F7/settings.json"
out=$(HCAT_PYTHON="$FENG/python" PATH="$STUB:/usr/bin:/bin" DOCTOR_SETTINGS="$F7/settings.json" \
      DOCTOR_CLAUDE_DIR="$F7/cd" DOCTOR_VENV_DIR="$NOVENV" bash "$DOCTOR" --fix 2>&1)
check "f7a: fix reports a merge" "merged" "$out"
newcmd=$(jq -r '.statusLine.command' "$F7/settings.json")
check "f7a: custom command preserved in the chain" "my-line.sh" "$newcmd"
check "f7a: headroom badge appended" "headroom-statusline.sh" "$newcmd"
check "f7a: chained with the installer template" 'left=$(printf' "$newcmd"
check "f7a: original backed up" "bash ~/my-line.sh" \
      "$(jq -r '._headroomStatusLineBackup.command // empty' "$F7/settings.json")"
check_eq "f7a: merged entry has refreshInterval 1" "1" \
      "$(jq -r '.statusLine.refreshInterval // empty' "$F7/settings.json")"
cp "$F7/settings.json" "$REVD/f7.settings.run1"
out2=$(HCAT_PYTHON="$FENG/python" PATH="$STUB:/usr/bin:/bin" DOCTOR_SETTINGS="$F7/settings.json" \
       DOCTOR_CLAUDE_DIR="$F7/cd" DOCTOR_VENV_DIR="$NOVENV" bash "$DOCTOR" --fix 2>&1)
if cmp -s "$F7/settings.json" "$REVD/f7.settings.run1"; then
  echo "ok - f7a: second --fix run is idempotent"; PASS=$((PASS+1))
else
  echo "FAIL - f7a: second --fix run is idempotent"; FAIL=$((FAIL+1))
fi
check_absent "f7a: nothing fixable after the merge" "fixable" "$out2"

# F7c: stale ~/.claude statusline copy is detected and refreshed
F7C="$REVD/f7c"; mkdir -p "$F7C/cd"
doc_settings_wired "$F7C/cd" > "$F7C/settings.json"
printf '#!/bin/sh\n# stale old copy\n' > "$F7C/cd/headroom-statusline.sh"
chmod +x "$F7C/cd/headroom-statusline.sh"
out=$(HCAT_PYTHON="$FENG/python" PATH="$STUB:/usr/bin:/bin" DOCTOR_SETTINGS="$F7C/settings.json" \
      DOCTOR_CLAUDE_DIR="$F7C/cd" DOCTOR_VENV_DIR="$NOVENV" bash "$DOCTOR" 2>&1)
check "f7c: stale statusline copy is fixable" "statusline copy" "$out"
check "f7c: reported as fixable" "fixable" "$out"
# F7d: the doctor validates the bundled .mcp.json
check "f7d: .mcp.json checked and healthy" ".mcp.json registers the headroom MCP" "$out"
HCAT_PYTHON="$FENG/python" PATH="$STUB:/usr/bin:/bin" DOCTOR_SETTINGS="$F7C/settings.json" \
  DOCTOR_CLAUDE_DIR="$F7C/cd" DOCTOR_VENV_DIR="$NOVENV" bash "$DOCTOR" --fix >/dev/null 2>&1
if cmp -s "$F7C/cd/headroom-statusline.sh" "$ROOT/scripts/statusline.sh" && [ -x "$F7C/cd/headroom-statusline.sh" ]; then
  echo "ok - f7c: --fix refreshes the copy from the plugin"; PASS=$((PASS+1))
else
  echo "FAIL - f7c: --fix refreshes the copy from the plugin"; FAIL=$((FAIL+1))
fi

# F8: .mcp.json quotes CLAUDE_PLUGIN_ROOT exactly like hooks.json does
check "f8: .mcp.json command quoted like hooks.json" \
      '"${CLAUDE_PLUGIN_ROOT}"/scripts/mcp-launcher.sh' \
      "$(jq -r '.mcpServers.headroom.command' "$MCP_JSON")"

# --- 36. data-driven price table (data/model-prices.json)
PRICES_JSON="$ROOT/data/model-prices.json"
if jq -e '(.prices|type)=="array" and (.prices|length)>0' "$PRICES_JSON" >/dev/null 2>&1; then
  echo "ok - prices: bundled model-prices.json parses"; PASS=$((PASS+1))
else
  echo "FAIL - prices: bundled model-prices.json parses"; FAIL=$((FAIL+1))
fi
check "prices: opus-4-8 present in table" "opus-4-8" "$(cat "$PRICES_JSON")"
check "prices: fable-5 present in table"  "fable-5"  "$(cat "$PRICES_JSON")"

export HEADROOM_STATE_DIR="$TMP/state-prices"
# a NEW model present only in the JSON is priced — proving pricing is data, not code
PF="$TMP/prices-custom.json"
jq -n '{version:1, prices:[{match:"zeta-9", usd_per_mtok:8}]}' > "$PF"
out=$(HEADROOM_PRICES_FILE="$PF" badge "$TMP/t_active.jsonl" claude-zeta-9 sess-px1)  # 500 tok @ $8 = 0.40¢
check "prices: model from JSON is priced (data-driven)" "0.40¢" "$out"
# a model absent from an authoritative JSON is unknown → tokens-only, never a guess.
# Fresh state dir so an earlier session's all-time totals can't leak a ¢ in.
export HEADROOM_STATE_DIR="$TMP/state-prices-px2"
out=$(HEADROOM_PRICES_FILE="$PF" badge "$TMP/t_active.jsonl" some-absent-model sess-px2)
check "prices: unlisted model is tokens-only" "~500 tok" "$out"
check_absent "prices: unlisted model shows no cents" "¢" "$out"
# invalid or missing price file → built-in table still prices (zero-regression fallback)
printf 'not json{' > "$TMP/prices-bad.json"
out=$(HEADROOM_PRICES_FILE="$TMP/prices-bad.json" badge "$TMP/t_active.jsonl" claude-opus-4-8 sess-px3)
check "prices: invalid file falls back to built-in table" "0.25¢" "$out"
out=$(HEADROOM_PRICES_FILE="$TMP/does-not-exist.json" badge "$TMP/t_active.jsonl" claude-opus-4-8 sess-px4)
check "prices: missing file falls back to built-in table" "0.25¢" "$out"

# --- 37. dangi: file-aware nudge + batched suppression count
export HEADROOM_STATE_DIR="$TMP/state-dangi2"

# names the exact structured file drawn from the Bash command
out=$(jq -n '{hook_event_name:"PostToolUse", tool_name:"Bash", session_id:"faware-1",
  tool_input:{command:"cat /var/data/events.json"}, tool_response:("x"*9000)}' | bash "$DANGI")
check "dangi file-aware: nudge names the file" 'hcat \"/var/data/events.json\"' "$out"
# no command → generic <path> placeholder preserved (unchanged behavior)
out=$(hook_input Bash 9000 faware-2 | bash "$DANGI")
check "dangi file-aware: generic path when no command" 'hcat \"<path>\"' "$out"
# a command with no structured-file token → generic placeholder, no bad guess
out=$(jq -n '{hook_event_name:"PostToolUse", tool_name:"Bash", session_id:"faware-3",
  tool_input:{command:"echo hello world"}, tool_response:("x"*9000)}' | bash "$DANGI")
check "dangi file-aware: generic when no file token" 'hcat \"<path>\"' "$out"

# batching: big blobs suppressed during the cooldown are counted and surfaced on
# the next nudge. DANGI_NOW drives the cooldown clock deterministically.
padB=$(head -c 9000 /dev/zero | tr '\0' x)
fire() {  # fire <simulated-now> — one big Bash blob at that clock time
  jq -n --arg pad "$padB" \
    '{hook_event_name:"PostToolUse", tool_name:"Bash", session_id:"batch-1", tool_response:$pad}' \
    | DANGI_NOW="$1" bash "$DANGI"
}
o1=$(fire 100000)   # first: nudges, pending resets
check "dangi batch: first output nudges"        "additionalContext" "$o1"
check_absent "dangi batch: first has no count"  "slipped by"        "$o1"
o2=$(fire 100010); check_absent "dangi batch: second suppressed" "additionalContext" "$o2"
o3=$(fire 100020); check_absent "dangi batch: third suppressed"  "additionalContext" "$o3"
o4=$(fire 100100)   # >cooldown since last nudge: nudges again, names the 2 missed
check "dangi batch: nudges again after cooldown"    "additionalContext"     "$o4"
check "dangi batch: surfaces the suppressed count"  "2 more large outputs"  "$o4"

# --- 38. ambient health: last-error state, broken badge, session probe (v2.7)
PROBE="$ROOT/scripts/session-probe.sh"
export HEADROOM_STATE_DIR="$TMP/state-health"
mkdir -p "$HEADROOM_STATE_DIR"

# hcat with a dead HCAT_PYTHON records an engine error (and still exits 3)
printf '{"a":1}\n' > "$TMP/health.json"
HCAT_PYTHON=/nonexistent/python bash "$ROOT/bin/hcat" "$TMP/health.json" >/dev/null 2>&1; rc=$?
check_eq "health: hcat missing engine exits 3" "3" "$rc"
check "health: hcat wrote last-error" "engine" "$(cat "$HEADROOM_STATE_DIR/last-error" 2>/dev/null)"

# a fresh last-error takes over the badge and points at the doctor
tr_h="$TMP/t_health.jsonl"; compress_event th1 500 > "$tr_h"
out=$(badge "$tr_h" claude-opus-4-8 health-s1)
check "health: badge shows broken"     "broken"  "$out"
check "health: badge points at doctor" "/doctor" "$out"

# a stale entry (>24h by its own timestamp) no longer takes over
printf '%s engine old failure\n' "$(( $(date -u +%s) - 90000 ))" > "$HEADROOM_STATE_DIR/last-error"
out=$(badge "$tr_h" claude-opus-4-8 health-s2)
check_absent "health: stale error ignored" "broken" "$out"

# gate with a resolved-but-broken engine fails open AND records the breakage
rm -f "$HEADROOM_STATE_DIR/last-error"
big_h="$TMP/big-health.json"; head -c 20000 /dev/zero | tr '\0' x > "$big_h"
out=$(gate_input "$big_h" health-g1 | HCAT_PYTHON=/usr/bin/false bash "$ROOT/scripts/hcat-gate.sh"); rc=$?
check_eq "health: gate broken engine exit 0"       "0"    "$rc"
check_absent "health: gate broken engine fails open" "deny" "$out"
check "health: gate recorded the breakage" "import failed" \
      "$(cat "$HEADROOM_STATE_DIR/last-error" 2>/dev/null)"

# hooks.json registers the SessionStart probe
jq -e '.hooks.SessionStart[0].hooks[0].command | contains("session-probe.sh")' \
   "$ROOT/hooks/hooks.json" >/dev/null 2>&1 \
  && check "health: hooks.json registers the probe" "ok" "ok" \
  || check "health: hooks.json registers the probe" "ok" "MISSING"

# probe: healthy env is silent (existence-level checks only)
rm -f "$HEADROOM_STATE_DIR/last-error"
out=$(HCAT_PYTHON=/usr/bin/true bash "$PROBE"); rc=$?
check_eq "health: probe healthy silent" "" "$out"
check_eq "health: probe healthy exit 0" "0" "$rc"

# probe: an HCAT_PYTHON pointing nowhere is a breakage → context line + last-error
out=$(HCAT_PYTHON=/nonexistent/python bash "$PROBE"); rc=$?
check "health: probe flags broken override" "additionalContext" "$out"
check "health: probe wrote last-error" "engine" "$(cat "$HEADROOM_STATE_DIR/last-error" 2>/dev/null)"
check_eq "health: probe exit 0" "0" "$rc"

# probe: never-installed engine gets a pointer but does NOT flip the badge
rm -f "$HEADROOM_STATE_DIR/last-error"
out=$(env -u HCAT_PYTHON HOME="$TMP/nohome" PATH="$STUB:/usr/bin:/bin" bash "$PROBE")
check "health: probe notes missing engine" "not installed" "$out"
if [ -f "$HEADROOM_STATE_DIR/last-error" ]; then
  echo "FAIL - health: missing engine must not write last-error"; FAIL=$((FAIL+1))
else
  echo "ok - health: missing engine must not write last-error"; PASS=$((PASS+1))
fi

# probe: surfaces a fresh recorded failure even when its own checks pass
printf '%s runtime hcat: compression failed: boom\n' "$(date +%s)" > "$HEADROOM_STATE_DIR/last-error"
out=$(HCAT_PYTHON=/usr/bin/true bash "$PROBE")
check "health: probe surfaces recorded failure" "recent failure" "$out"

# a working compression clears engine/runtime errors (real engine required)
if [ -n "$HEADROOM_PY" ]; then
  printf '%s engine stale\n' "$(date +%s)" > "$HEADROOM_STATE_DIR/last-error"
  HCAT_PYTHON="$HEADROOM_PY" HEADROOM_WORKSPACE_DIR="$TMP/ws-health" \
    bash "$ROOT/bin/hcat" "$TMP/hc_big.json" >/dev/null 2>&1
  if [ -f "$HEADROOM_STATE_DIR/last-error" ]; then
    echo "FAIL - health: successful hcat clears engine error"; FAIL=$((FAIL+1))
  else
    echo "ok - health: successful hcat clears engine error"; PASS=$((PASS+1))
  fi

  # doctor: fully-clean run clears the state; fixable/failed runs keep it
  printf '%s engine stale2\n' "$(date +%s)" > "$HEADROOM_STATE_DIR/last-error"
  CDH="$TMP/doc-health"; mkdir -p "$CDH"
  SH="$TMP/doc-health-s.json"; doc_settings_wired "$CDH" > "$SH"
  out=$(HCAT_PYTHON="$HEADROOM_PY" DOCTOR_SETTINGS="$SH" DOCTOR_CLAUDE_DIR="$CDH" \
        DOCTOR_VENV_DIR="$TMP/doc-none" bash "$DOCTOR" 2>&1)
  check "health: doctor reports clearing" "cleared recorded failure" "$out"
  if [ -f "$HEADROOM_STATE_DIR/last-error" ]; then
    echo "FAIL - health: doctor clean run removes last-error"; FAIL=$((FAIL+1))
  else
    echo "ok - health: doctor clean run removes last-error"; PASS=$((PASS+1))
  fi
else
  echo "skip - health engine-clear tests (headroom venv not found)"
fi
printf '%s engine stale3\n' "$(date +%s)" > "$HEADROOM_STATE_DIR/last-error"
out=$(HCAT_PYTHON=/nonexistent/python DOCTOR_SETTINGS="$S2" DOCTOR_CLAUDE_DIR="$CD2" \
      DOCTOR_VENV_DIR="$DOCD/none" bash "$DOCTOR" 2>&1)
check "health: doctor keeps state while fixable" "failure state kept" "$out"
rm -f "$HEADROOM_STATE_DIR/last-error"

# --- 39. dangi router: true-size detection + tiered compress/delegate advice (v2.7)
export HEADROOM_STATE_DIR="$TMP/state-router"

# a 200 KB file read via Bash cat with a truncated (9 KB) payload → the nudge
# reports the TRUE size and advises delegation, not in-place compression
huge_f="$TMP/router-huge.json"; head -c 200000 /dev/zero | tr '\0' x > "$huge_f"
out=$(jq -n --arg cmd "cat $huge_f" '{hook_event_name:"PostToolUse", tool_name:"Bash",
  session_id:"router-1", tool_input:{command:$cmd}, tool_response:("x"*9000)}' | bash "$DANGI")
check "router: huge file → delegation advice" "disposable subagent" "$out"
check "router: huge file → true size reported" "195 KB" "$out"
check "router: huge file names the file" "router-huge.json" "$out"
check_absent "router: huge file → no in-place hcat advice" "run hcat" "$out"

# a 20 KB file stays in the compress-in-place tier and names the file for hcat
med_f="$TMP/router-med.json"; head -c 20000 /dev/zero | tr '\0' x > "$med_f"
out=$(jq -n --arg cmd "cat $med_f" '{hook_event_name:"PostToolUse", tool_name:"Bash",
  session_id:"router-2", tool_input:{command:$cmd}, tool_response:("x"*9000)}' | bash "$DANGI")
check "router: medium file → hcat advice" "run hcat" "$out"
check "router: medium file → true size reported" "19 KB" "$out"

# a huge raw (non-file-backed) payload also routes to delegation
out=$(hook_input Bash 140000 router-3 | bash "$DANGI")
check "router: huge raw payload → delegation" "disposable subagent" "$out"
check_absent "router: huge raw payload → no hcat advice" "run hcat" "$out"

# Read is now file-aware too: a big structured file read via Read names itself
out=$(jq -n --arg fp "$med_f" '{hook_event_name:"PostToolUse", tool_name:"Read",
  session_id:"router-4", tool_input:{file_path:$fp}, tool_response:("x"*9000)}' | bash "$DANGI")
check "router: Read names the file" "router-med.json" "$out"

# a written-but-never-read big file must NOT trigger on a small payload
out=$(jq -n --arg cmd "curl -o $huge_f https://x.test" '{hook_event_name:"PostToolUse",
  tool_name:"Bash", session_id:"router-5", tool_input:{command:$cmd},
  tool_response:"ok"}' | bash "$DANGI")
check_absent "router: small payload never triggers on file size" "additionalContext" "$out"

# a spacey/unsafe file path falls back to the generic placeholder (JSON safety)
sp_dir="$TMP/router sp"; mkdir -p "$sp_dir"
sp_f="$sp_dir/data.json"; head -c 20000 /dev/zero | tr '\0' x > "$sp_f"
out=$(jq -n --arg fp "$sp_f" '{hook_event_name:"PostToolUse", tool_name:"Read",
  session_id:"router-6", tool_input:{file_path:$fp}, tool_response:("x"*9000)}' | bash "$DANGI")
check "router: unsafe path → generic placeholder" 'hcat \"<path>\"' "$out"
printf '%s' "$out" | jq -e '.hookSpecificOutput.additionalContext' >/dev/null 2>&1 \
  && check "router: unsafe path output is valid JSON" "ok" "ok" \
  || check "router: unsafe path output is valid JSON" "ok" "INVALID"

# --- 40. gate rewrite extras + hcat TOON-lite lossless tier (v2.7)
export HEADROOM_STATE_DIR="$TMP/state-toon"

# The fake engine ($FENG/python exits 0 for everything, `import headroom`
# included) satisfies the gate's engine checks — these run venv or not.
big40="$TMP/hc_big40.json"
mkuniform "$big40"
# rewrite preserves sibling tool_input fields (full-object updatedInput)
out=$(jq -n --arg cmd "cat $big40" '{hook_event_name:"PreToolUse", tool_name:"Bash",
  session_id:"toon-g1", tool_input:{command:$cmd, description:"dump the file"}}' \
  | HCAT_PYTHON="$FENG/python" bash "$GATE")
check "rewrite: preserves other tool_input fields" '"description":"dump the file"' "$out"
# kill switch: HCAT_GATE_NO_REWRITE falls back to the deny redirect
out=$(bash_gate_input "cat $big40" toon-g2 | HCAT_PYTHON="$FENG/python" HCAT_GATE_NO_REWRITE=1 bash "$GATE")
check "rewrite: NO_REWRITE falls back to deny" '"permissionDecision":"deny"' "$out"

# TOON-lite: uniform JSON array compresses with no engine installed at all
uni="$TMP/toon-uniform.json"
jq -n '[range(0; 80) | {id:., user:("user_" + (.%7|tostring)), event:"click", ok:true}]' > "$uni"
out=$(env -u HCAT_PYTHON HOME="$TMP/nohome" PATH="$STUB:/usr/bin:/bin" bash "$ROOT/bin/hcat" "$uni"); rc=$?
check_eq "toon: no-engine uniform json exit 0" "0" "$rc"
check "toon: emits a receipt"          "── hcat:"          "$out"
check "toon: names the strategy"       "toon-lite"         "$out"
check "toon: receipt has token arrow"  " tok → ~"          "$out"
check "toon: header row present"       "id,user,event,ok"  "$out"

# non-uniform JSON without an engine still errors (exit 3)
nonu="$TMP/toon-nonuniform.json"
printf '{"a": {"nested": [1,2,3]}, "b": "x"}\n' > "$nonu"
env -u HCAT_PYTHON HOME="$TMP/nohome" PATH="$STUB:/usr/bin:/bin" bash "$ROOT/bin/hcat" "$nonu" >/dev/null 2>&1; rc=$?
check_eq "toon: no-engine non-uniform exit 3" "3" "$rc"

# CSV-special values get JSON-quoted so rows stay parseable
spec="$TMP/toon-special.json"
jq -n '[range(0; 40) | {id:., note:"a,b \"q\" line", n:(.*2)}]' > "$spec"
out=$(env -u HCAT_PYTHON HOME="$TMP/nohome" PATH="$STUB:/usr/bin:/bin" bash "$ROOT/bin/hcat" "$spec")
check "toon: special chars json-quoted" '\"q\"' "$out"

# --- 41. session ledger + next-session invoice (v2.7)
LEDGERH="$ROOT/scripts/ledger-hook.sh"
export HEADROOM_STATE_DIR="$TMP/state-ledger"
mkdir -p "$HEADROOM_STATE_DIR"

trL="$TMP/t_ledger.jsonl"
# One MCP save + two misses: the MCP-compress discount drops the SMALLEST miss
# (fillerA), leaving events.json as the surviving, named biggest miss.
{
  compress_event lg1 500
  printf '{"timestamp":"%s","message":{"model":"claude-opus-4-8","content":[{"type":"text","text":"hi"}]}}\n' "$NOW"
  jq -n '{message:{content:[{type:"tool_use",id:"lgf1",name:"Read",input:{file_path:"/var/data/fillerA.log"}}]}}'
  jq -n '{message:{content:[{type:"tool_result",tool_use_id:"lgf1",content:[{type:"text",text:("z"*5000)}]}]}}'
  jq -n '{message:{content:[{type:"tool_use",id:"lgm1",name:"Read",input:{file_path:"/var/data/events.json"}}]}}'
  jq -n '{message:{content:[{type:"tool_result",tool_use_id:"lgm1",content:[{type:"text",text:("z"*9000)}]}]}}'
} > "$trL"

printf '{"session_id":"ledger-s1","transcript_path":"%s"}' "$trL" | bash "$LEDGERH" >"$TMP/lh.out" 2>&1; rc=$?
lg="$HEADROOM_STATE_DIR/ledger.jsonl"
check_eq "ledger: exit 0" "0" "$rc"
check_eq "ledger: hook prints nothing" "" "$(cat "$TMP/lh.out")"
check "ledger: entry written"       "ledger-s1"                 "$(cat "$lg" 2>/dev/null)"
check "ledger: saves recorded"      '"save_tokens":500'         "$(cat "$lg" 2>/dev/null)"
check "ledger: miss recorded"       '"miss_count":1'            "$(cat "$lg" 2>/dev/null)"
check "ledger: miss path captured"  "/var/data/events.json"     "$(cat "$lg" 2>/dev/null)"
check "ledger: model captured"      "claude-opus-4-8"           "$(cat "$lg" 2>/dev/null)"
check "ledger: saves priced"        '"save_usd":"0.002500"'     "$(cat "$lg" 2>/dev/null)"
check "ledger: misses priced"       '"miss_usd"'                "$(cat "$lg" 2>/dev/null)"

# idempotent: an unchanged transcript must not append a second line
printf '{"session_id":"ledger-s1","transcript_path":"%s"}' "$trL" | bash "$LEDGERH"
check_eq "ledger: unchanged transcript not re-appended" "1" "$(wc -l < "$lg" | tr -d ' ')"

# growth → a new cumulative snapshot line (2nd compress + a 3rd smaller miss,
# so with the discount events.json still survives as the biggest miss)
{
  compress_event lg2 700
  jq -n '{message:{content:[{type:"tool_use",id:"lgf2",name:"Read",input:{file_path:"/var/data/fillerC.log"}}]}}'
  jq -n '{message:{content:[{type:"tool_result",tool_use_id:"lgf2",content:[{type:"text",text:("z"*6000)}]}]}}'
} >> "$trL"
printf '{"session_id":"ledger-s1","transcript_path":"%s"}' "$trL" | bash "$LEDGERH"
check_eq "ledger: grown transcript appends" "2" "$(wc -l < "$lg" | tr -d ' ')"
check "ledger: snapshot is cumulative" '"save_tokens":1200' "$(tail -1 "$lg")"

# an empty session leaves no trace
trE="$TMP/t_ledger_empty.jsonl"; printf '{"message":{"content":[{"type":"text","text":"hi"}]}}\n' > "$trE"
printf '{"session_id":"ledger-empty","transcript_path":"%s"}' "$trE" | bash "$LEDGERH"
check_absent "ledger: empty session not recorded" "ledger-empty" "$(cat "$lg")"

# the probe surfaces the invoice exactly once
out=$(HCAT_PYTHON=/usr/bin/true bash "$PROBE")
check "invoice: probe surfaces last session" "headroom invoice" "$out"
check "invoice: reports savings"             "saved ~1.2k tok"  "$out"
check "invoice: loss-frames the misses"      "left on the table" "$out"
check "invoice: names the biggest miss"      "/var/data/events.json" "$out"
out=$(HCAT_PYTHON=/usr/bin/true bash "$PROBE")
check_absent "invoice: surfaced only once" "invoice" "$out"

# hooks.json registers the ledger hook on Stop and SessionEnd
jq -e '.hooks.Stop[0].hooks[0].command | contains("ledger-hook.sh")' \
   "$ROOT/hooks/hooks.json" >/dev/null 2>&1 \
  && check "ledger: hooks.json Stop registered" "ok" "ok" \
  || check "ledger: hooks.json Stop registered" "ok" "MISSING"
jq -e '.hooks.SessionEnd[0].hooks[0].command | contains("ledger-hook.sh")' \
   "$ROOT/hooks/hooks.json" >/dev/null 2>&1 \
  && check "ledger: hooks.json SessionEnd registered" "ok" "ok" \
  || check "ledger: hooks.json SessionEnd registered" "ok" "MISSING"

# --- 42. detection that learns: offender memory + content sniff (v2.7)
export HEADROOM_STATE_DIR="$TMP/state-learn"
mkdir -p "$HEADROOM_STATE_DIR"

# dangi records a file-backed offender when the nudge fires
learn_f="$TMP/learn-offender.json"; head -c 20000 /dev/zero | tr '\0' x > "$learn_f"
jq -n --arg fp "$learn_f" '{hook_event_name:"PostToolUse", tool_name:"Read",
  session_id:"learn-1", tool_input:{file_path:$fp}, tool_response:("x"*9000)}' | bash "$DANGI" >/dev/null
check "learn: offender recorded" "$learn_f" "$(cat "$HEADROOM_STATE_DIR/offenders" 2>/dev/null)"

# re-offense updates in place — no duplicate lines
jq -n --arg fp "$learn_f" '{hook_event_name:"PostToolUse", tool_name:"Read",
  session_id:"learn-2", tool_input:{file_path:$fp}, tool_response:("x"*9000)}' | bash "$DANGI" >/dev/null
check_eq "learn: offender deduped" "1" "$(wc -l < "$HEADROOM_STATE_DIR/offenders" | tr -d ' ')"

# Gate checks run against the fake engine — no real venv needed (see 40).
# a learned offender with no structured extension is now gated
noext="$TMP/learn-noext"; head -c 20000 /dev/zero | tr '\0' x > "$noext"
printf '%s %s\n' "$(date +%s)" "$noext" > "$HEADROOM_STATE_DIR/offenders"
out=$(gate_input "$noext" learn-g1 | HCAT_PYTHON="$FENG/python" bash "$GATE")
check "learn: offender gated without extension" '"permissionDecision":"deny"' "$out"
# stale entries decay (default TTL 14 days)
printf '%s %s\n' "$(( $(date +%s) - 1300000 ))" "$noext" > "$HEADROOM_STATE_DIR/offenders"
out=$(gate_input "$noext" learn-g2 | HCAT_PYTHON="$FENG/python" bash "$GATE")
check_absent "learn: stale offender ignored" "deny" "$out"
rm -f "$HEADROOM_STATE_DIR/offenders"

# sniff: a big extensionless JSON array is gated on structure alone
sniff_f="$TMP/learn-sniff"
mkuniform "$sniff_f"
out=$(gate_input "$sniff_f" learn-g3 | HCAT_PYTHON="$FENG/python" bash "$GATE")
check "learn: sniff gates JSON-shaped file" '"permissionDecision":"deny"' "$out"
out=$(gate_input "$sniff_f" learn-g4 | HCAT_PYTHON="$FENG/python" HCAT_GATE_NO_SNIFF=1 bash "$GATE")
check_absent "learn: NO_SNIFF disables the sniff" "deny" "$out"

# CSV vitals: matching 3+ delimiter counts across the first two rows
csv_f="$TMP/learn-csv"
{ printf 'a,b,c,d,e\n'; i=0; while [ "$i" -lt 1600 ]; do printf '1,2,3,4,five\n'; i=$((i+1)); done; } > "$csv_f"
out=$(gate_input "$csv_f" learn-g5 | HCAT_PYTHON="$FENG/python" bash "$GATE")
check "learn: sniff gates CSV-shaped file" '"permissionDecision":"deny"' "$out"

# plain prose stays un-gated
prose_f="$TMP/learn-prose"; head -c 20000 /dev/zero | tr '\0' x > "$prose_f"
out=$(gate_input "$prose_f" learn-g6 | HCAT_PYTHON="$FENG/python" bash "$GATE")
check_absent "learn: prose not gated" "deny" "$out"

# --- 43. doctor: project-level settings scan + fix (v2.7)
PROJ43="$TMP/proj43"; mkdir -p "$PROJ43/.claude"
CD43="$TMP/proj43-cd"; mkdir -p "$CD43"
S43="$TMP/proj43-s.json"; doc_settings_wired "$CD43" > "$S43"
doc_settings_legacy "$CD43" > "$PROJ43/.claude/settings.json"
out=$(HCAT_PYTHON="$FENG/python" PATH="$STUB:/usr/bin:/bin" DOCTOR_SETTINGS="$S43" \
      DOCTOR_CLAUDE_DIR="$CD43" DOCTOR_VENV_DIR="$NOVENV" DOCTOR_PROJECT_DIR="$PROJ43" \
      bash "$DOCTOR" 2>&1)
check "proj: legacy hooks detected as fixable" "legacy hooks in project settings" "$out"
out=$(HCAT_PYTHON="$FENG/python" PATH="$STUB:/usr/bin:/bin" DOCTOR_SETTINGS="$S43" \
      DOCTOR_CLAUDE_DIR="$CD43" DOCTOR_VENV_DIR="$NOVENV" DOCTOR_PROJECT_DIR="$PROJ43" \
      bash "$DOCTOR" --fix 2>&1)
check "proj: --fix cleans project settings" \
      "removed 2 legacy hook entries from $PROJ43/.claude/settings.json" "$out"
check_eq "proj: entries gone" "0" \
  "$(jq '[.hooks // {} | to_entries[] | .value[]?.hooks[]? | select((.command // "") | test("dangi-hook|hcat-gate"))] | length' "$PROJ43/.claude/settings.json")"
check "proj: unrelated hook preserved" "unrelated-hook" "$(cat "$PROJ43/.claude/settings.json")"
if ls "$PROJ43"/.claude/settings.json.bak.* >/dev/null 2>&1; then
  echo "ok - proj: backup written"; PASS=$((PASS+1))
else
  echo "FAIL - proj: backup written"; FAIL=$((FAIL+1))
fi
out=$(HCAT_PYTHON="$FENG/python" PATH="$STUB:/usr/bin:/bin" DOCTOR_SETTINGS="$S43" \
      DOCTOR_CLAUDE_DIR="$CD43" DOCTOR_VENV_DIR="$NOVENV" DOCTOR_PROJECT_DIR="$PROJ43" \
      bash "$DOCTOR" 2>&1)
check "proj: clean project settings reported ok" \
      "no legacy hook registrations in $PROJ43/.claude/settings.json" "$out"

# unparseable project settings → FAIL, stale-copy gate stays shut
printf '{ broken\n' > "$PROJ43/.claude/settings.local.json"
touch "$CD43/dangi-hook.sh"
out=$(HCAT_PYTHON="$FENG/python" PATH="$STUB:/usr/bin:/bin" DOCTOR_SETTINGS="$S43" \
      DOCTOR_CLAUDE_DIR="$CD43" DOCTOR_VENV_DIR="$NOVENV" DOCTOR_PROJECT_DIR="$PROJ43" \
      bash "$DOCTOR" --fix 2>&1)
check "proj: unparseable project settings FAIL" "project settings did not parse" "$out"
check "proj: stale copies kept while project scan inconclusive" "stale copies kept" "$out"

# --- 44. v2.7 F1 review fixes: rewrite fidelity, learning precision, honest sizing
export HEADROOM_STATE_DIR="$TMP/state-v271"
mkdir -p "$HEADROOM_STATE_DIR"

big44="$TMP/v271-big.json"
mkuniform "$big44"

# the rewrite emits an UNQUOTED command word — the shape every attribution
# surface (dangi/statusline/ledger) recognises as an hcat invocation
out=$(bash_gate_input "cat $big44" v271-g1 | HCAT_PYTHON="$FENG/python" bash "$GATE")
check "fix/rewrite: unquoted hcat command word" '"command":"hcat \"' "$out"
check_absent "fix/rewrite: quoted command word gone" '"command":"\"hcat\"' "$out"
check "fix/rewrite: explains itself via additionalContext" '"additionalContext"' "$out"

# a multiline command is never rewritten — the other lines would be dropped
ml=$(printf 'git add notes.md\ncat %s' "$big44")
out=$(bash_gate_input "$ml" v271-g2 | HCAT_PYTHON="$FENG/python" bash "$GATE")
check_eq "fix/rewrite: multiline command untouched" "" "$out"

# the badge still counts the OLD quoted rewrite form living in past transcripts
printf '%s\n%s\n' \
  "{\"timestamp\":\"$NOW\",\"message\":{\"content\":[{\"type\":\"tool_use\",\"id\":\"vq1\",\"name\":\"Bash\",\"input\":{\"command\":\"\\\"hcat\\\" \\\"/tmp/x.json\\\"\"}}]}}" \
  "{\"message\":{\"content\":[{\"type\":\"tool_result\",\"tool_use_id\":\"vq1\",\"content\":[{\"type\":\"text\",\"text\":\"── hcat: /tmp/x.json · 10 lines · 5.0 KB · ~900 tok → ~300 tok (66.7% saved) · original on disk\"}]}]}}" \
  > "$TMP/t_v271_legacy.jsonl"
out=$(badge "$TMP/t_v271_legacy.jsonl" claude-opus-4-8 sess-v271a)
check "fix/attrib: legacy quoted rewrite counts" "600" "$out"

# ...while a mid-command quoted "hcat" (grep over docs) still counts as nothing
printf '%s\n%s\n' \
  "{\"timestamp\":\"$NOW\",\"message\":{\"content\":[{\"type\":\"tool_use\",\"id\":\"vq2\",\"name\":\"Bash\",\"input\":{\"command\":\"grep \\\"hcat\\\" README.md\"}}]}}" \
  "{\"message\":{\"content\":[{\"type\":\"tool_result\",\"tool_use_id\":\"vq2\",\"content\":[{\"type\":\"text\",\"text\":\"── hcat: /tmp/x.json · 10 lines · 5.0 KB · ~900 tok → ~300 tok (66.7% saved) · original on disk\"}]}]}}" \
  > "$TMP/t_v271_grep.jsonl"
out=$(badge "$TMP/t_v271_grep.jsonl" claude-opus-4-8 sess-v271b)
check_absent "fix/attrib: quoted hcat mid-command not an invocation" "●" "$out"

# exempt output classes are not "missed savings" — ledger and badge agree
trX="$TMP/t_v271_exempt.jsonl"
{
  compress_event vx1 500
  jq -n '{message:{content:[{type:"tool_use",id:"vx2",name:"WebFetch",input:{url:"https://x.test"}}]}}'
  jq -n '{message:{content:[{type:"tool_result",tool_use_id:"vx2",content:[{type:"text",text:("w"*9000)}]}]}}'
} > "$trX"
printf '{"session_id":"v271-led","transcript_path":"%s"}' "$trX" | bash "$LEDGERH"
check "fix/ledger: exempt class not a miss" '"miss_count":0' "$(grep v271-led "$HEADROOM_STATE_DIR/ledger.jsonl" 2>/dev/null)"
out=$(badge "$trX" claude-opus-4-8 sess-v271c)
check_absent "fix/badge: exempt class not missed" "missed" "$out"

# offender learning requires structure: a big source file is never recorded
py44="$TMP/v271-src.py"
{ i=0; while [ "$i" -lt 400 ]; do printf 'def fn_%s():\n    return "code line %s"\n' "$i" "$i"; i=$((i+1)); done; } > "$py44"
jq -n --arg fp "$py44" '{hook_event_name:"PostToolUse", tool_name:"Read",
  session_id:"v271-l1", tool_input:{file_path:$fp}, tool_response:("x"*9000)}' | bash "$DANGI" >/dev/null
check_absent "fix/learn: source file not recorded" "$py44" "$(cat "$HEADROOM_STATE_DIR/offenders" 2>/dev/null)"

# ...while a JSON-shaped extensionless file still is (sniff), stored canonical
sn44="$TMP/v271-sniff"
mkuniform "$sn44"
jq -n --arg fp "$sn44" '{hook_event_name:"PostToolUse", tool_name:"Read",
  session_id:"v271-l2", tool_input:{file_path:$fp}, tool_response:("x"*9000)}' | bash "$DANGI" >/dev/null
check "fix/learn: sniffed structured file recorded" "$sn44" "$(cat "$HEADROOM_STATE_DIR/offenders" 2>/dev/null)"

# a relative Bash token is recorded canonical so the gate's absolute lookup matches
rel44="$TMP/v271-rel.json"
mkuniform "$rel44"
( cd "$TMP" && jq -n '{hook_event_name:"PostToolUse", tool_name:"Bash", session_id:"v271-l3",
    tool_input:{command:"cat v271-rel.json"}, tool_response:("x"*9000)}' | bash "$DANGI" >/dev/null )
check "fix/learn: relative token stored canonical" "$rel44" "$(cat "$HEADROOM_STATE_DIR/offenders" 2>/dev/null)"

# size escalation only for whole-file ingests
gr44="$TMP/v271-filter.log"
head -c 200000 /dev/zero | tr '\0' x > "$gr44"
out=$(jq -n --arg cmd "grep ERROR $gr44" '{hook_event_name:"PostToolUse", tool_name:"Bash",
  session_id:"v271-l4", tool_input:{command:$cmd}, tool_response:("x"*6000)}' | bash "$DANGI")
check_absent "fix/size: filtered output not escalated" "too large to compress in place" "$out"
check "fix/size: filtered output reports payload size" "~5 KB" "$out"
out=$(jq -n --arg fp "$gr44" '{hook_event_name:"PostToolUse", tool_name:"Read",
  session_id:"v271-l5", tool_input:{file_path:$fp, offset:100, limit:50}, tool_response:("x"*6000)}' | bash "$DANGI")
check_absent "fix/size: bounded Read not escalated" "too large to compress in place" "$out"
out=$(jq -n --arg cmd "cat $gr44" '{hook_event_name:"PostToolUse", tool_name:"Bash",
  session_id:"v271-l6", tool_input:{command:$cmd}, tool_response:("x"*6000)}' | bash "$DANGI")
check "fix/size: whole-file cat still escalates" "195 KB" "$out"

# huge non-file payload: no literal <path> handed to a subagent
out=$(hook_input Bash 140000 v271-l7 | bash "$DANGI")
check "fix/nudge: non-file huge advises re-derive" "not traceable to a file" "$out"
check_absent "fix/nudge: no literal placeholder in huge advice" '<path>' "$out"

# huge extensionless file: the REAL path is named
out=$(jq -n --arg fp "$sn44" '{hook_event_name:"PostToolUse", tool_name:"Read",
  session_id:"v271-l8", tool_input:{file_path:$fp}, tool_response:("x"*9000)}' | DANGI_HUGE_BYTES=20000 bash "$DANGI")
check "fix/nudge: extensionless huge names the real path" "v271-sniff" "$out"
check "fix/nudge: extensionless huge routes to delegation" "too large to compress in place" "$out"

# health: never-installed engine leaves NO broken badge; dead override records one
pr44="$TMP/v271-prose.txt"; printf 'plain prose, nothing structured here\n' > "$pr44"
rm -f "$HEADROOM_STATE_DIR/last-error"
env -u HCAT_PYTHON HOME="$TMP/nohome" HEADROOM_STATE_DIR="$HEADROOM_STATE_DIR" \
  PATH="$STUB:/usr/bin:/bin" bash "$ROOT/bin/hcat" "$pr44" >/dev/null 2>&1; rc=$?
check_eq "fix/health: never-installed exit 3" "3" "$rc"
if [ -f "$HEADROOM_STATE_DIR/last-error" ]; then
  echo "FAIL - fix/health: never-installed leaves no last-error"; FAIL=$((FAIL+1))
else
  echo "ok - fix/health: never-installed leaves no last-error"; PASS=$((PASS+1))
fi
HCAT_PYTHON=/nonexistent/python bash "$ROOT/bin/hcat" "$pr44" >/dev/null 2>&1; rc=$?
check_eq "fix/health: dead override exit 3" "3" "$rc"
check "fix/health: dead override records engine error" "engine" "$(cat "$HEADROOM_STATE_DIR/last-error" 2>/dev/null)"
rm -f "$HEADROOM_STATE_DIR/last-error"

# TOON-lite losslessness: comma keys and scalar-looking strings stay quoted
tk44="$TMP/v271-toon.json"
jq -n '[range(0; 40) | {"a,b": (tostring), n:., s:"null"}]' > "$tk44"
out=$(env -u HCAT_PYTHON HOME="$TMP/nohome" PATH="$STUB:/usr/bin:/bin" bash "$ROOT/bin/hcat" "$tk44")
check 'fix/toon: comma key quoted in header' '"a,b",n,s' "$out"
check 'fix/toon: numeric string cell stays quoted' '"7",7' "$out"
check 'fix/toon: null-looking string stays quoted' '"null"' "$out"

# --- 45. v2.7 F2 review fixes: advice hygiene, ledger durability/accounting,
# path resolution, Bash true-size parity, shared-lib consolidation
export HEADROOM_STATE_DIR="$TMP/state-v272"
mkdir -p "$HEADROOM_STATE_DIR"

# #2 — Dangi advice rejects $/backtick paths (falls back to <path> placeholder)
danger_dir="$TMP/v272-\$(id)"; mkdir -p "$danger_dir"
danger_f="$danger_dir/data.json"; mkuniform "$danger_f"
out=$(jq -n --arg fp "$danger_f" '{hook_event_name:"PostToolUse", tool_name:"Read",
  session_id:"v272-d1", tool_input:{file_path:$fp}, tool_response:("x"*9000)}' | bash "$DANGI")
check "fix/advice: metachar path → generic placeholder" 'hcat \"<path>\"' "$out"
check_absent "fix/advice: metachar path not embedded" 'id)' "$out"
# a clean path is still named
clean_f="$TMP/v272-clean.json"; mkuniform "$clean_f"
out=$(jq -n --arg fp "$clean_f" '{hook_event_name:"PostToolUse", tool_name:"Read",
  session_id:"v272-d2", tool_input:{file_path:$fp}, tool_response:("x"*9000)}' | bash "$DANGI")
check "fix/advice: clean path still named" "v272-clean.json" "$out"

# #6 — gate DENY message single-quotes the suggested path (no runnable $(...))
dgate_dir="$TMP/v272g-\$(id)"; mkdir -p "$dgate_dir"
dgate_f="$dgate_dir/big.json"; mkuniform "$dgate_f"
out=$(gate_input "$dgate_f" v272-g1 | HCAT_PYTHON="$FENG/python" bash "$GATE")
check "fix/gate-deny: path single-quoted" "hcat '" "$out"
check_absent "fix/gate-deny: no double-quoted metachar command" 'hcat \"'"$dgate_dir" "$out"

# #12 — a relative Bash cat is resolved against the payload cwd, not the hook's
rel_dir="$TMP/v272-rel"; mkdir -p "$rel_dir"
rel_f="$rel_dir/r.json"; mkuniform "$rel_f"
out=$(jq -n --arg cmd "cat r.json" --arg cwd "$rel_dir" '{hook_event_name:"PreToolUse",
  tool_name:"Bash", session_id:"v272-r1", cwd:$cwd, tool_input:{command:$cmd}}' \
  | HCAT_PYTHON="$FENG/python" bash "$GATE")
check "fix/gate-cwd: relative cat resolved against payload cwd" "$rel_dir/r.json" "$out"
# no payload cwd for a relative token → gate stays silent (no wrong-file rewrite)
out=$(jq -n --arg cmd "cat r.json" '{hook_event_name:"PreToolUse", tool_name:"Bash",
  session_id:"v272-r2", tool_input:{command:$cmd}}' | HCAT_PYTHON="$FENG/python" bash "$GATE"); rc=$?
check_eq "fix/gate-cwd: relative cat with no cwd → silent" "" "$out"
check_eq "fix/gate-cwd: relative cat with no cwd → exit 0" "0" "$rc"

# AN-2 — Bash cat of an EXTENSIONLESS huge file is stat'd, tiered, and named
noext_huge="$rel_dir/dump"; head -c 200000 /dev/zero | tr '\0' x > "$noext_huge"
out=$(jq -n --arg cmd "cat $noext_huge" '{hook_event_name:"PostToolUse", tool_name:"Bash",
  session_id:"v272-an1", tool_input:{command:$cmd}, tool_response:("x"*9000)}' | bash "$DANGI")
check "fix/an2: Bash extensionless huge → delegation" "too large to compress in place" "$out"
check "fix/an2: Bash extensionless huge → true size" "195 KB" "$out"
check "fix/an2: Bash extensionless huge → names the file" "dump" "$out"

# #4 — a failed ledger append leaves the size-marker stale so the retry re-parses
led_dir="$TMP/state-v272-led"; mkdir -p "$led_dir"
trF="$TMP/t_v272_led.jsonl"
{
  compress_event lf1 500
  jq -n '{message:{content:[{type:"tool_use",id:"lfm1",name:"Read",input:{file_path:"/var/data/x.json"}}]}}'
  jq -n '{message:{content:[{type:"tool_result",tool_use_id:"lfm1",content:[{type:"text",text:("z"*9000)}]}]}}'
} > "$trF"
# make the append fail: ledger.jsonl is an unwritable directory
mkdir -p "$led_dir/ledger.jsonl"
HEADROOM_STATE_DIR="$led_dir" bash "$LEDGERH" <<EOF
{"session_id":"v272-lf","transcript_path":"$trF"}
EOF
if [ -f "$led_dir/session-v272-lf.ledgersize" ]; then
  echo "FAIL - fix/ledger: failed append must not mark size handled"; FAIL=$((FAIL+1))
else
  echo "ok - fix/ledger: failed append leaves size-marker stale"; PASS=$((PASS+1))
fi
# once the append can succeed, the snapshot IS recorded (not stranded)
rmdir "$led_dir/ledger.jsonl"
HEADROOM_STATE_DIR="$led_dir" bash "$LEDGERH" <<EOF
{"session_id":"v272-lf","transcript_path":"$trF"}
EOF
check "fix/ledger: retry after writable records the snapshot" "v272-lf" "$(cat "$led_dir/ledger.jsonl" 2>/dev/null)"

# #7 — a blob later MCP-compressed is not priced as a miss (ledger matches badge)
trM="$TMP/t_v272_mcp.jsonl"
{
  # one big output that is ALSO covered by an MCP compress call
  jq -n '{message:{content:[{type:"tool_use",id:"mm1",name:"Bash",input:{command:"echo hi"}}]}}'
  jq -n '{message:{content:[{type:"tool_result",tool_use_id:"mm1",content:[{type:"text",text:("q"*9000)}]}]}}'
  compress_event mm2 700
} > "$trM"
export HEADROOM_STATE_DIR="$TMP/state-v272-mcp"; mkdir -p "$HEADROOM_STATE_DIR"
bash "$LEDGERH" <<EOF
{"session_id":"v272-mcp","transcript_path":"$trM"}
EOF
lgm=$(grep v272-mcp "$HEADROOM_STATE_DIR/ledger.jsonl" 2>/dev/null)
check "fix/ledger: MCP-compressed blob discounted from misses" '"miss_count":0' "$lgm"
out=$(badge "$trM" claude-opus-4-8 sess-v272mcp)
check_absent "fix/badge: same blob not shown as missed" "missed" "$out"

# #5 — Python-tier TOON-lite (<5% engine savings) via a fake headroom shim,
# so the lossless quoting path is exercised WITHOUT a real engine install.
REALPY=$(PATH=/usr/bin:/bin:/usr/local/bin command -v python3 2>/dev/null || echo /usr/bin/python3)
if [ -x "$REALPY" ]; then
  hshim="$TMP/hshim"; mkdir -p "$hshim/headroom"
  : > "$hshim/headroom/__init__.py"
  cat > "$hshim/headroom/compress.py" <<'PYSHIM'
class _R:
    def __init__(self, raw):
        self.messages = [{"content": raw}]
        self.tokens_before = 1000
        self.tokens_after = 980   # 2% savings → <5% → TOON-lite fallback path
def compress(_msgs):
    return _R(_msgs[0]["content"])
PYSHIM
  cat > "$hshim/headroom/paths.py" <<'PYSHIM'
import os, pathlib
def workspace_dir():
    return pathlib.Path(os.environ.get("HEADROOM_WORKSPACE_DIR", "/tmp/hshim-ws"))
def session_stats_path():
    return workspace_dir() / "stats.jsonl"
PYSHIM
  pywrap="$TMP/hshim-python"
  printf '#!/bin/sh\nexport PYTHONPATH="%s:${PYTHONPATH:-}"\nexec "%s" "$@"\n' "$hshim" "$REALPY" > "$pywrap"
  chmod +x "$pywrap"
  ptoon="$TMP/v272-ptoon.json"
  jq -n '[range(0; 40) | {"a,b": (tostring), n:., s:"null"}]' > "$ptoon"
  out=$(HCAT_PYTHON="$pywrap" HEADROOM_WORKSPACE_DIR="$TMP/hshim-ws" bash "$ROOT/bin/hcat" "$ptoon"); rc=$?
  check_eq "fix/ptoon: python <5% engine path exit 0" "0" "$rc"
  check "fix/ptoon: python tier used (lossless, not engine-absent)" "toon-lite lossless)" "$out"
  check_absent "fix/ptoon: not the engine-absent jq tier" "engine absent" "$out"
  check 'fix/ptoon: comma key quoted' '"a,b",n,s' "$out"
  check 'fix/ptoon: numeric string quoted' '"7",7' "$out"
  check 'fix/ptoon: null-looking string quoted' '"null"' "$out"
  check "fix/ptoon: stats event strategy toon-lite" '"strategy":"toon-lite"' "$(cat "$TMP"/hshim-ws/*.jsonl 2>/dev/null)"
else
  echo "skip - python-tier TOON-lite test (no python3)"
fi

# lib-missing degrade: hooks source a flat sibling; with NO lib present they
# must still run (exit 0, single JSON decision), features simply off.
nolib="$TMP/nolib"; mkdir -p "$nolib"
cp "$ROOT/scripts/dangi-hook.sh" "$ROOT/scripts/hcat-gate.sh" "$ROOT/scripts/session-probe.sh" "$nolib/"
cp "$ROOT/bin/hcat" "$nolib/hcat"
chmod +x "$nolib"/*.sh "$nolib/hcat"
nolib_f="$TMP/nolib-in.json"; mkuniform "$nolib_f"
out=$(jq -n --arg fp "$nolib_f" '{hook_event_name:"PostToolUse", tool_name:"Read",
  session_id:"nolib-1", tool_input:{file_path:$fp}, tool_response:("x"*9000)}' \
  | HEADROOM_STATE_DIR="$TMP/nolib-state" bash "$nolib/dangi-hook.sh"); rc=$?
check_eq "fix/nolib: dangi still exits 0 without lib" "0" "$rc"
check "fix/nolib: dangi still nudges without lib" "additionalContext" "$out"
out=$(gate_input "$nolib_f" nolib-2 | HEADROOM_STATE_DIR="$TMP/nolib-state" HCAT_PYTHON="$FENG/python" bash "$nolib/hcat-gate.sh"); rc=$?
check_eq "fix/nolib: gate still exits 0 without lib" "0" "$rc"
check "fix/nolib: gate still gates .json by extension without lib" "deny" "$out"

# --- shellcheck (when available) — warning severity: info-level findings
# (e.g. SC2016 on intentionally-literal single quotes) don't fail the suite
if command -v shellcheck >/dev/null 2>&1; then
  if shellcheck --severity=warning "$SCRIPT" "$DANGI" "$ROOT/scripts/hcat-gate.sh" \
       "$ROOT/scripts/doctor.sh" "$ROOT/scripts/mcp-launcher.sh" \
       "$ROOT/scripts/session-probe.sh" "$ROOT/scripts/ledger-hook.sh" \
       "$ROOT/scripts/lib/headroom-state.sh"; then
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
