# headroom-usage-indicator v2.0.0 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move the status-line logic into a shipped bash script and extend it with money-saved (priced against the session's model), per-render caching, and lifetime totals.

**Architecture:** `scripts/statusline.sh` reads the Claude Code status-line stdin JSON once and prints only the headroom badge segment. The Python installer (documented in SKILL.md) copies it to `~/.claude/headroom-statusline.sh` and writes a short `statusLine.command` that invokes it (standalone, or merged after the user's existing status line). All state lives in `~/.claude/headroom-indicator/` (overridable via `HEADROOM_STATE_DIR` for tests).

**Tech Stack:** bash, jq, awk, POSIX coreutils. No new dependencies. Repo: `/Users/abhi/Desktop/headroom-plugin` (a Claude Code plugin — no build system; test via `./test.sh`).

## Global Constraints

- Runs on macOS **and** Linux: every `stat`/`date` call needs GNU→BSD fallback (`stat -c%s || stat -f%z`; `date -d || date -j -u -f "%Y-%m-%dT%H:%M:%S"`).
- The badge must **never** render broken: any missing/unreadable input falls back to safe defaults (`n=0`, `saved=0`, no money segment). Unwritable state dir → run cache-less, still render.
- Never show a wrong dollar figure: unknown `model.id` → tokens-only badge.
- Colors (unchanged from v1): active `\033[32m` green `●`, decayed `\033[90m` dim `○`, never-used `\033[31m` red `○`. Decay window: 60 seconds since last compress.
- Detect real usage only: count `tool_use` blocks named exactly `mcp__headroom__headroom_compress`; sum `tokens_saved` from results linked by `tool_use_id`. Never grep the transcript for raw strings (`headroom_stats` and prose mentions are false positives).
- State dir: `${HEADROOM_STATE_DIR:-$HOME/.claude/headroom-indicator}`.
- Price table (input $/MTok): fable-5/mythos → 10; opus-4-8/4-7/4-6/4-5 → 5; opus-4-1/opus-4-0/opus-4-2025*/3-opus → 15; haiku-4-5 → 1; 3-5-haiku → 0.80; 3-haiku → 0.25; sonnet (any) → 3. Sonnet 5 deliberately uses the standard $3, not the intro $2.
- Money formatting: `usd ≥ 0.01` → `$%.2f`; below → `%.2f¢` (cents).
- Version: 2.0.0 in both `.claude-plugin/plugin.json` and `.claude-plugin/marketplace.json`.
- Work happens in `/Users/abhi/Desktop/headroom-plugin` on branch `main`. Commit after every task.

---

### Task 1: `scripts/statusline.sh` core + test harness (v1 badge parity)

**Files:**
- Create: `scripts/statusline.sh`
- Create: `test.sh` (repo root)

**Interfaces:**
- Consumes: status-line stdin JSON with `transcript_path` (string). Later tasks also read `model.id` and `session_id` from the same JSON.
- Produces: `scripts/statusline.sh` — reads stdin, prints the ANSI badge with **no trailing newline**. Shell variables later tasks build on: `in` (raw stdin), `tp` (transcript path), `n` (compress count), `saved` (tokens), `last_ts` (ISO timestamp of last compress), `age` (seconds since), function `compute()` (fills `n`/`saved`/`last_ts` from `$tp`), function `fmt_tok <int>` (`2400` → `2.4k`). test.sh helpers all later tests use: `check <name> <expected-substring> <actual>`, `check_absent <name> <forbidden-substring> <actual>`, `badge <transcript> <model-id> <session-id>` (builds stdin JSON, runs the script), `compress_event <tool-use-id> <tokens-saved>` (prints a 2-line transcript fixture: tool_use stamped `$NOW` + linked tool_result).

- [ ] **Step 1: Write the failing tests**

Create `test.sh` (mode 755):

```bash
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

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd /Users/abhi/Desktop/headroom-plugin && chmod +x test.sh && ./test.sh`
Expected: all checks FAIL (script does not exist → empty output), exit code 1.

- [ ] **Step 3: Write the script**

Create `scripts/statusline.sh` (mode 755):

```bash
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
```

Then: `chmod +x scripts/statusline.sh`

- [ ] **Step 4: Run tests to verify they pass**

Run: `./test.sh`
Expected: `ok` × 4, `4 passed, 0 failed`, exit 0.

- [ ] **Step 5: Commit**

```bash
git add scripts/statusline.sh test.sh
git commit -m "feat: shipped statusline.sh script + synthetic-transcript test harness"
```

---

### Task 2: Money saved (session-model floor price)

**Files:**
- Modify: `scripts/statusline.sh`
- Modify: `test.sh`

**Interfaces:**
- Consumes: `in`, `saved`, badge printf block from Task 1.
- Produces: functions `price_per_mtok <model-id>` (echoes $/MTok or empty), `usd_of <tokens> <price>` (echoes dollars, 6 dp), `fmt_usd <dollars>` (`$0.03` or `0.42¢`); variables `model` (from stdin `.model.id`) and `money` (badge fragment `" · $0.03"` or empty). Task 4 reuses `price_per_mtok`, `usd_of`, `fmt_usd`.

- [ ] **Step 1: Write the failing tests**

In `test.sh`, insert before the `echo`/summary block:

```bash
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
```

- [ ] **Step 2: Run tests to verify the new ones fail**

Run: `./test.sh`
Expected: Task 1 checks still `ok`; `money: cents`, `money: dollars` FAIL (no money segment yet); the unknown-model checks pass trivially. Exit 1.

- [ ] **Step 3: Implement**

In `scripts/statusline.sh`:

(a) After the `tp=` line, parse the model:

```bash
model=$(printf '%s' "$in" | jq -r '.model.id // empty' 2>/dev/null) || model=""
```

(b) After `fmt_tok()`, add:

```bash
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
```

(c) After the `age` block, before the badge:

```bash
money=""
price=$(price_per_mtok "$model")
if [ -n "$price" ] && [ "$saved" -gt 0 ] 2>/dev/null; then
  money=" · $(fmt_usd "$(usd_of "$saved" "$price")")"
fi
```

(d) Replace the two non-red printf lines to include the money segment:

```bash
    printf '\033[32m● headroom · ~%s tok%s · %s×\033[0m' "$tok" "$money" "$n"
```
```bash
    printf '\033[90m○ headroom idle · ~%s tok%s · %s×\033[0m' "$tok" "$money" "$n"
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `./test.sh`
Expected: `10 passed, 0 failed`, exit 0.

- [ ] **Step 5: Commit**

```bash
git add scripts/statusline.sh test.sh
git commit -m "feat: money saved priced against the session model (floor estimate)"
```

---

### Task 3: Per-render performance cache

**Files:**
- Modify: `scripts/statusline.sh`
- Modify: `test.sh`

**Interfaces:**
- Consumes: `compute()`, `in` from Task 1.
- Produces: variables `STATE_DIR`, `sid` (from stdin `.session_id`), `size`, `cache` (path `$STATE_DIR/session-$sid.cache`, format `size|n|saved|last_ts`, one line). Task 4 hooks its totals-write into the cache-miss branch created here.

- [ ] **Step 1: Write the failing tests**

In `test.sh`, insert before the summary block:

```bash
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
```

- [ ] **Step 2: Run tests to verify the new ones fail**

Run: `./test.sh`
Expected: `cache: same-size rewrite…` FAILs (without a cache the mangled transcript re-parses to 0 events → red badge). The other new checks pass. Exit 1.

- [ ] **Step 3: Implement**

In `scripts/statusline.sh`:

(a) After `TOOL=…`, add:

```bash
STATE_DIR="${HEADROOM_STATE_DIR:-$HOME/.claude/headroom-indicator}"
```

(b) After the `model=` line, parse the session id:

```bash
sid=$(printf '%s' "$in" | jq -r '.session_id // empty' 2>/dev/null) || sid=""
```

(c) Replace the block

```bash
if [ -n "$tp" ] && [ -f "$tp" ]; then
  compute
fi
```

with:

```bash
if [ -n "$tp" ] && [ -f "$tp" ]; then
  size=$(stat -c%s "$tp" 2>/dev/null || stat -f%z "$tp" 2>/dev/null || echo "")
  cache=""
  [ -n "$sid" ] && cache="$STATE_DIR/session-$sid.cache"
  hit=0
  if [ -n "$cache" ] && [ -n "$size" ] && [ -f "$cache" ]; then
    IFS='|' read -r csize cn csaved clast < "$cache" || true
    if [ "${csize:-}" = "$size" ]; then
      n=${cn:-0}; saved=${csaved:-0}; last_ts=${clast:-}
      hit=1
    fi
  fi
  if [ "$hit" -ne 1 ]; then
    compute
    if [ -n "$cache" ] && mkdir -p "$STATE_DIR" 2>/dev/null; then
      printf '%s|%s|%s|%s\n' "${size:-0}" "$n" "$saved" "$last_ts" > "$cache" 2>/dev/null || true
    fi
  fi
fi
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `./test.sh`
Expected: `15 passed, 0 failed`, exit 0.

- [ ] **Step 5: Commit**

```bash
git add scripts/statusline.sh test.sh
git commit -m "perf: cache per-session results keyed on transcript size"
```

---

### Task 4: Lifetime totals

**Files:**
- Modify: `scripts/statusline.sh`
- Modify: `test.sh`

**Interfaces:**
- Consumes: cache-miss branch (Task 3), `price_per_mtok` / `usd_of` / `fmt_usd` (Task 2).
- Produces: totals files `$STATE_DIR/session-<sid>.totals` (one line: `<tokens> <usd>`); badge suffix `" | $1.83 all-time"` (variable `lifetime`), shown only when >1 totals file exists and the summed usd > 0.

- [ ] **Step 1: Write the failing tests**

In `test.sh`, insert before the summary block:

```bash
# --- 7. lifetime totals across sessions
rm -rf "$HEADROOM_STATE_DIR"   # reset state accumulated by earlier tests
compress_event a1 500 > "$TMP/t_life_a.jsonl"
compress_event b1 500 > "$TMP/t_life_b.jsonl"
out=$(badge "$TMP/t_life_a.jsonl" claude-opus-4-8 sess-life-a)
check_absent "lifetime: hidden on first-ever session" "all-time" "$out"
out=$(badge "$TMP/t_life_b.jsonl" claude-opus-4-8 sess-life-b)
check "lifetime: shown from 2nd session" "all-time"       "$out"
check "lifetime: summed usd"             "0.50¢ all-time" "$out"
```

- [ ] **Step 2: Run tests to verify the new ones fail**

Run: `./test.sh`
Expected: `lifetime: shown from 2nd session` and `lifetime: summed usd` FAIL; the `check_absent` passes trivially. Exit 1.

- [ ] **Step 3: Implement**

In `scripts/statusline.sh`:

(a) Inside the cache-miss branch, extend the state write (after the `printf … > "$cache"` line, inside the same `if`):

```bash
      t_price=$(price_per_mtok "$model")
      t_usd=0
      [ -n "$t_price" ] && t_usd=$(usd_of "$saved" "$t_price")
      printf '%s %s\n' "$saved" "$t_usd" > "$STATE_DIR/session-$sid.totals" 2>/dev/null || true
```

(b) After the `money=` block, before the badge:

```bash
lifetime=""
totals_count=$(find "$STATE_DIR" -name 'session-*.totals' 2>/dev/null | wc -l | tr -d ' ')
if [ "${totals_count:-0}" -gt 1 ] 2>/dev/null; then
  lt_usd=$(cat "$STATE_DIR"/session-*.totals 2>/dev/null | awk '{u+=$2} END{printf "%.6f", u+0}')
  if awk -v u="$lt_usd" 'BEGIN{exit !(u>0)}'; then
    lifetime=" | $(fmt_usd "$lt_usd") all-time"
  fi
fi
```

(c) Replace the two non-red printf lines to append the lifetime segment:

```bash
    printf '\033[32m● headroom · ~%s tok%s · %s×%s\033[0m' "$tok" "$money" "$n" "$lifetime"
```
```bash
    printf '\033[90m○ headroom idle · ~%s tok%s · %s×%s\033[0m' "$tok" "$money" "$n" "$lifetime"
```

**Complete final `scripts/statusline.sh` for reference** (the file must match this exactly after Tasks 1–4):

```bash
#!/usr/bin/env bash
# headroom-usage-indicator — status-line segment for Claude Code.
# Reads the status-line stdin JSON once; prints the headroom badge (ANSI, no newline).
# State: ${HEADROOM_STATE_DIR:-~/.claude/headroom-indicator}

set -u

TOOL="mcp__headroom__headroom_compress"
STATE_DIR="${HEADROOM_STATE_DIR:-$HOME/.claude/headroom-indicator}"

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
  size=$(stat -c%s "$tp" 2>/dev/null || stat -f%z "$tp" 2>/dev/null || echo "")
  cache=""
  [ -n "$sid" ] && cache="$STATE_DIR/session-$sid.cache"
  hit=0
  if [ -n "$cache" ] && [ -n "$size" ] && [ -f "$cache" ]; then
    IFS='|' read -r csize cn csaved clast < "$cache" || true
    if [ "${csize:-}" = "$size" ]; then
      n=${cn:-0}; saved=${csaved:-0}; last_ts=${clast:-}
      hit=1
    fi
  fi
  if [ "$hit" -ne 1 ]; then
    compute
    if [ -n "$cache" ] && mkdir -p "$STATE_DIR" 2>/dev/null; then
      printf '%s|%s|%s|%s\n' "${size:-0}" "$n" "$saved" "$last_ts" > "$cache" 2>/dev/null || true
      t_price=$(price_per_mtok "$model")
      t_usd=0
      [ -n "$t_price" ] && t_usd=$(usd_of "$saved" "$t_price")
      printf '%s %s\n' "$saved" "$t_usd" > "$STATE_DIR/session-$sid.totals" 2>/dev/null || true
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

if [ "$n" -gt 0 ] 2>/dev/null; then
  tok=$(fmt_tok "$saved")
  if [ "$age" -le 60 ] 2>/dev/null; then
    printf '\033[32m● headroom · ~%s tok%s · %s×%s\033[0m' "$tok" "$money" "$n" "$lifetime"
  else
    printf '\033[90m○ headroom idle · ~%s tok%s · %s×%s\033[0m' "$tok" "$money" "$n" "$lifetime"
  fi
else
  printf '\033[31m○ headroom idle (not compressing yet)\033[0m'
fi
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `./test.sh`
Expected: `18 passed, 0 failed`, exit 0.

- [ ] **Step 5: Commit**

```bash
git add scripts/statusline.sh test.sh
git commit -m "feat: lifetime money-saved totals across sessions"
```

---

### Task 5: Installer rewrite (SKILL.md), README, manifests, shellcheck

**Files:**
- Modify: `skills/headroom-usage-indicator/SKILL.md` (full rewrite, content below)
- Modify: `README.md` (sections listed below)
- Modify: `.claude-plugin/plugin.json`, `.claude-plugin/marketplace.json` (version + description)
- Modify: `test.sh` (shellcheck step)

**Interfaces:**
- Consumes: `scripts/statusline.sh` (final form from Task 4); the installer copies it to `~/.claude/headroom-statusline.sh`.
- Produces: v2 install flow. `statusLine.command` becomes `bash "<home>/.claude/headroom-statusline.sh"` (standalone) or the merged capture-stdin-once form. Marker strings for idempotency: new `headroom-statusline.sh`, legacy `mcp__headroom__headroom_compress`.

- [ ] **Step 1: Add the shellcheck check to test.sh**

Insert before the summary block:

```bash
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
```

Run: `./test.sh` — expected: all pass (fix any shellcheck findings in `scripts/statusline.sh` if it flags something; directives like `# shellcheck disable=SC2015` are acceptable for intentional `a && b` patterns).

- [ ] **Step 2: Rewrite SKILL.md**

Replace the entire contents of `skills/headroom-usage-indicator/SKILL.md` with:

````markdown
---
name: headroom-usage-indicator
description: Use when you want a persistent visual reminder of whether the headroom MCP compression is actually being used this session — an always-visible status line that stays "idle" until headroom_compress is called, flips to "active" with the tokens AND money it saved (priced against the session's model), then decays back to idle after a quiet period. Also shows an all-time money-saved total across sessions.
---

# Headroom Usage Indicator

## Overview

The headroom MCP compresses large, structured tool outputs to save context — but it's easy to *forget* to use it. This skill adds a Claude Code **status line** that is an honest, always-on indicator:

- 🔴 `○ headroom idle (not compressing yet)` — until `headroom_compress` runs this session
- 🟢 `● headroom · ~2.4k tok · $0.007 · 3× | $1.83 all-time` — for 60s after a compression
- ⚪ `○ headroom idle · ~2.4k tok · $0.007 · 3× | $1.83 all-time` — after 60s of quiet (keeps the totals)

**Core principle:** detect real usage from the session transcript, not from intent. It counts `tool_use` calls to `mcp__headroom__headroom_compress` and sums the `tokens_saved` those calls actually reported — so it can't lie. The dollar figure prices those tokens at the **session model's input rate** (a conservative floor — see below).

## Prerequisites

- The headroom MCP server is registered (tools appear as `mcp__headroom__headroom_compress`, `…_retrieve`, `…_stats`).
- `jq` on PATH.

## How It Works

All logic lives in one shipped script, `scripts/statusline.sh` (in this plugin, two directories above this SKILL.md). The installer copies it to `~/.claude/headroom-statusline.sh` and points `statusLine.command` at it. Per render it:

1. Reads the status-line **stdin JSON once** — `transcript_path`, `model.id`, `session_id`.
2. **Counts & sums** — `tool_use` blocks named `mcp__headroom__headroom_compress`; `tokens_saved` from results linked by `tool_use_id` (never grep for raw strings — `headroom_stats` results and prose mentions are false positives).
3. **Money** — `tokens_saved × input-$/MTok` for the session's `model.id`, from a table in `price_per_mtok()`. Unknown model → tokens-only badge (never a wrong dollar figure). This is the *floor*: compressed content would have re-entered context on later turns (mostly at the 0.1× cache-read rate), so real savings compound above it.
4. **Cache** — per-session results cached in `~/.claude/headroom-indicator/session-<id>.cache` keyed on transcript byte size; unchanged size skips the jq parse (a `stat` call instead of an O(transcript) parse every second).
5. **Lifetime** — each session writes `session-<id>.totals` (`tokens usd`); the badge sums them into `| $X all-time` once more than one session exists.
6. **Decay** — timestamp of the last compress; within 60s → bright green, else dim (totals retained).

## Install

Two steps: copy the script, then wire the status line. **Use the Python installer below — do not hand-write the `statusLine`.** It is *merge-aware*: an existing custom status line is preserved (backed up under `_headroomStatusLineBackup`) and the headroom segment appended. Re-running is idempotent and also refreshes the copied script (the upgrade path).

Set `PLUGIN_ROOT` to this plugin's root — the directory **two levels above this SKILL.md** (it contains `scripts/statusline.sh`):

```bash
python3 - <<'PY'
import json, pathlib, shutil

PLUGIN_ROOT = pathlib.Path("<absolute path of the directory two levels above this SKILL.md>")

src = PLUGIN_ROOT / "scripts" / "statusline.sh"
dest = pathlib.Path.home() / ".claude" / "headroom-statusline.sh"
dest.parent.mkdir(parents=True, exist_ok=True)
shutil.copyfile(src, dest)
dest.chmod(0o755)

p = pathlib.Path.home() / ".claude" / "settings.json"
data = json.loads(p.read_text()) if p.exists() else {}
MARK = "headroom-statusline.sh"                    # v2 marker
OLD_MARK = "mcp__headroom__headroom_compress"      # v1 one-liner marker
HR = 'bash "' + str(dest) + '"'

existing = data.get("statusLine"); backup = data.get("_headroomStatusLineBackup"); base = None
if isinstance(backup, dict) and backup.get("type") == "command" and backup.get("command"):
    base = backup                                  # re-run/upgrade after a merge → re-merge onto true original
elif isinstance(existing, dict) and existing.get("type") == "command" and existing.get("command") \
        and MARK not in existing["command"] and OLD_MARK not in existing["command"]:
    base = existing                                # a real pre-existing custom status line
if base is not None:
    data["_headroomStatusLineBackup"] = base
    cmd = ('in=$(cat); left=$(printf \'%s\' "$in" | { ' + base["command"] + '; }); '
           'hr=$(printf \'%s\' "$in" | ' + HR + '); printf \'%s  %s\' "$left" "$hr"')
    mode = "merged (appended to your existing status line)"
else:
    cmd = HR
    mode = "installed (standalone)"
data["statusLine"] = {"type": "command", "command": cmd, "refreshInterval": 1}
p.write_text(json.dumps(data, indent=2, ensure_ascii=False) + "\n")
print("headroom status line", mode)
PY
```

Upgrading from v1 is the same command: a v1 standalone one-liner (contains `OLD_MARK`) is replaced outright; a v1 merged install re-merges from the backup.

**To restore** the user's original status line: copy `_headroomStatusLineBackup` back over `statusLine`, delete the backup key, and optionally remove `~/.claude/headroom-statusline.sh` and `~/.claude/headroom-indicator/`.

## Verify Before Trusting It

Run the plugin's test suite from the plugin root — it drives the script with synthetic transcripts (active badge, stats-only false positive, money math, unknown-model fallback, cache behavior, lifetime totals):

```bash
./test.sh
```

Or drive the installed copy by hand:

```bash
NOW=$(date -u +%Y-%m-%dT%H:%M:%S.000Z)
printf '%s\n' \
 "{\"timestamp\":\"$NOW\",\"message\":{\"content\":[{\"type\":\"tool_use\",\"id\":\"t1\",\"name\":\"mcp__headroom__headroom_compress\"}]}}" \
 '{"message":{"content":[{"type":"tool_result","tool_use_id":"t1","content":[{"type":"text","text":"{\"tokens_saved\": 500}"}]}]}}' > /tmp/hr.jsonl
printf '{"transcript_path":"/tmp/hr.jsonl","model":{"id":"claude-opus-4-8"},"session_id":"verify"}' \
  | bash ~/.claude/headroom-statusline.sh; echo    # → green ● … ~500 tok · 0.25¢ · 1×
rm -f /tmp/hr.jsonl
```

## Common Mistakes

| Mistake | Fix |
|---|---|
| `grep`-ing the transcript for the tool name or `tokens_saved` | Use `jq` on `.type=="tool_use"` / link results by `tool_use_id` (as the script does). Raw strings appear in prose, `stats` results (`total_tokens_saved`), and your own outputs — all false positives. |
| Counting `headroom_stats`/`retrieve` too | Count only `headroom_compress` — inspecting headroom shouldn't flip it to active. |
| Hand-editing `~/.claude/headroom-statusline.sh` | It's a copy; re-running the installer overwrites it. Edit `scripts/statusline.sh` in the plugin and re-run the installer. |
| Guessing a price for an unknown model | Don't — the script deliberately falls back to tokens-only. Add the model to `price_per_mtok()` instead. |
| Clobbering an existing status line | Use the merge-aware installer; never blindly overwrite `statusLine`. |
| A merged status line reading stdin twice | stdin is consumable once. The merged command does `in=$(cat)` first and feeds `$in` to both segments. |
| Timestamp/size parsing breaking on one OS | The script ships GNU→BSD fallbacks for `date` and `stat` — keep both when editing. |

## Reload Caveat

Claude Code's settings watcher reliably reloads files that existed at session start. After installing, the line should appear on the next render; if not, open `/statusline` or `/config` once to force a reload, or it will be there next session.

## Customize

All knobs live in `scripts/statusline.sh` (edit, then re-run the installer):

- **Decay window:** the `60` in `[ "$age" -le 60 ]`.
- **Prices:** the `price_per_mtok()` case table (input $/MTok; hand-maintained per release).
- **State dir:** `HEADROOM_STATE_DIR` env var (used by tests).
- **Colors:** `\033[32m` green (active), `\033[90m` dim (decayed), `\033[31m` red (never used).
- **Different MCP tool:** change `TOOL=` (drop the `tokens_saved` sum if that tool doesn't report one).
````

- [ ] **Step 3: Update README.md**

(a) Replace the "What it shows" table with:

```markdown
| Badge | Colour | Meaning |
|---|---|---|
| `○ headroom idle (not compressing yet)` | 🔴 red | headroom hasn't compressed anything yet this session |
| `● headroom · ~2.4k tok · $0.007 · 3× \| $1.83 all-time` | 🟢 green | a compression just happened — tokens saved, **money saved**, how many times, and your all-time total |
| `○ headroom idle · ~2.4k tok · $0.007 · 3× \| $1.83 all-time` | ⚪ grey | quiet for 60s — dims, but keeps the totals |
```

(b) Add a new section after "What it shows":

```markdown
## How the money number works

The badge prices the tokens headroom saved at the **input rate of the model your session is running** (e.g. $5/MTok on Opus, $10/MTok on Fable). If the model isn't in the built-in price table, the badge just shows tokens — it never guesses a dollar figure. `all-time` is the sum across all your sessions on this machine (stored in `~/.claude/headroom-indicator/`).

This is a deliberately **conservative floor**: compressed content would otherwise re-enter the context on every later API turn (mostly at the cheaper cache-read rate), so the true savings compound above the number shown.
```

(c) In the "Updating" section, append after the `/plugin marketplace update` line:

```markdown
Then ask Claude once more: *"set up the headroom usage indicator"* — this refreshes the copied script at `~/.claude/headroom-statusline.sh`.
```

(d) In the "Uninstall" section, add `~/.claude/headroom-statusline.sh` and `~/.claude/headroom-indicator/` to the list of things to remove.

- [ ] **Step 4: Bump manifests**

In both `.claude-plugin/plugin.json` and `.claude-plugin/marketplace.json`:
- `"version": "2.0.0"`
- `"description"`: `"Status-line indicator showing whether the headroom MCP context-compression is being used this session — idle until headroom_compress runs, then active with the tokens AND money it saved (priced against the session model), decaying back to idle after a quiet period. Tracks an all-time money-saved total across sessions."`

- [ ] **Step 5: Full verification**

Run: `./test.sh` — expected: all checks pass (18 + shellcheck when installed), exit 0.
Run: `python3 -c "import json; json.load(open('.claude-plugin/plugin.json')); json.load(open('.claude-plugin/marketplace.json')); print('manifests OK')"` — expected: `manifests OK`.

- [ ] **Step 6: Commit**

```bash
git add skills/headroom-usage-indicator/SKILL.md README.md .claude-plugin/plugin.json .claude-plugin/marketplace.json test.sh
git commit -m "feat: v2.0.0 — script-based install, money saved, lifetime totals, shellcheck"
```
