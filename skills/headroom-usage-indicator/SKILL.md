---
name: headroom-usage-indicator
description: Use when you want a persistent visual reminder of whether the headroom MCP compression is actually being used this session — an always-visible status line that stays "idle" until headroom_compress is called, flips to "active" with the tokens it saved, then decays back to idle after a quiet period. Also applies to surfacing whether any specific MCP tool (mcp__server__tool) has been invoked in the current Claude Code session.
---

# Headroom Usage Indicator

## Overview

The headroom MCP compresses large, structured tool outputs to save context — but it's easy to *forget* to use it, and there's no built-in signal telling you whether you did. This skill adds a Claude Code **status line** that is an honest, always-on indicator:

- 🔴 `○ headroom idle (not compressing yet)` — until `headroom_compress` runs this session
- 🟢 `● headroom · ~770 tok saved · 2×` — for 60s after a compression (bright, "active")
- ⚪ `○ headroom idle · ~770 tok saved · 2×` — after 60s of no compression (dims, but keeps the session total)

**Core principle:** detect real usage from the session transcript, not from intent. It counts `tool_use` calls to `mcp__headroom__headroom_compress` and sums the `tokens_saved` those calls actually reported — so it can't lie.

## When to Use

- You have the headroom MCP installed and want a nudge to actually use it.
- You want to see at a glance whether compression fired and how much it saved this session.
- Generalize the same pattern to indicate whether *any* MCP tool (`mcp__server__tool`) has been called this session.

**Not for:** non-MCP built-in tools (they aren't name-encoded as `mcp__…`).

## Prerequisites

- The headroom MCP server is registered (tools appear as `mcp__headroom__headroom_compress`, `…_retrieve`, `…_stats`).
- `jq` is on PATH.

## How It Works

Claude Code pipes a JSON blob to the status-line command on **stdin**, containing `transcript_path` — the current session's JSONL file. The command reads it once and derives three things:

1. **Call count** — `tool_use` blocks whose `name` is `mcp__headroom__headroom_compress`.
2. **Tokens saved** — for each compress `tool_use.id`, find the `tool_result` with the matching `tool_use_id`, parse its inner JSON text, and sum `tokens_saved`. **Link by id — never grep the file for `tokens_saved`:** that substring also appears in `total_tokens_saved` (from `stats`) and in your own tool outputs that mention the field, both of which would corrupt the total.
3. **Decay** — the timestamp of the last compress `tool_use`; if it's within 60s, show bright/active, else dim to idle (retaining the running total).

## Install

**Use the Python installer below — do not hand-write the `statusLine`.** It is *merge-aware*: if the user already has a custom status line, it **appends** the headroom segment to it (backing the original up under `_headroomStatusLineBackup`) instead of clobbering it. If there's no existing status line, it installs the headroom segment standalone. It's idempotent — re-running never double-appends. **Never** just overwrite `statusLine` yourself; that silently destroys the user's existing prompt.

```bash
python3 - <<'PY'
import json, pathlib
p = pathlib.Path.home() / ".claude" / "settings.json"
data = json.loads(p.read_text()) if p.exists() else {}
MARK = "mcp__headroom__headroom_compress"
# headroom segment: consumes already-captured stdin in $in, sets $hr
HR_CORE = (
    "tp=$(printf '%s' \"$in\" | jq -r '.transcript_path // empty' 2>/dev/null); n=0; saved=0; age=999999; "
    "if [ -n \"$tp\" ] && [ -f \"$tp\" ]; then "
    "n=$(jq -s '[.[]|.message.content[]?|select(.type==\"tool_use\" and .name==\"mcp__headroom__headroom_compress\")]|length' \"$tp\" 2>/dev/null); "
    "saved=$(jq -s '([.[]|.message.content[]?|select(.type==\"tool_use\" and .name==\"mcp__headroom__headroom_compress\")|.id]) as $ids|[.[]|.message.content[]?|select(.type==\"tool_result\" and ((.tool_use_id) as $t|($ids|index($t))!=null))|.content[]?|.text? // empty|(try (fromjson.tokens_saved) catch 0)]|add // 0' \"$tp\" 2>/dev/null); "
    "last=$(jq -r 'select(.message.content)|select(any(.message.content[]?;.type==\"tool_use\" and .name==\"mcp__headroom__headroom_compress\"))|.timestamp' \"$tp\" 2>/dev/null | tail -1); "
    "if [ -n \"$last\" ]; then le=$(date -d \"$last\" +%s 2>/dev/null || date -j -u -f \"%Y-%m-%dT%H:%M:%S\" \"${last%%.*}\" +%s 2>/dev/null); [ -n \"$le\" ] && age=$(( $(date -u +%s) - le )); fi; "
    "fi; n=${n:-0}; saved=${saved:-0}; "
    "if [ \"$n\" -gt 0 ] 2>/dev/null; then "
    "if [ \"$age\" -le 60 ] 2>/dev/null; then hr=$(printf '\\033[32m● headroom · ~%s tok saved · %s×\\033[0m' \"$saved\" \"$n\"); "
    "else hr=$(printf '\\033[90m○ headroom idle · ~%s tok saved · %s×\\033[0m' \"$saved\" \"$n\"); fi; "
    "else hr=$(printf '\\033[31m○ headroom idle (not compressing yet)\\033[0m'); fi"
)
existing = data.get("statusLine"); backup = data.get("_headroomStatusLineBackup"); base = None
if isinstance(backup, dict) and backup.get("type") == "command" and backup.get("command"):
    base = backup                                          # re-run after a merge → re-merge onto true original
elif isinstance(existing, dict) and existing.get("type") == "command" \
        and existing.get("command") and MARK not in existing["command"]:
    base = existing                                        # a real pre-existing custom status line
if base is not None:
    data["_headroomStatusLineBackup"] = base
    cmd = ("in=$(cat); left=$(printf '%s' \"$in\" | { " + base["command"] + "; }); "
           + HR_CORE + "; printf '%s  %s' \"$left\" \"$hr\"")
    mode = "merged (appended to your existing status line)"
else:
    cmd = "in=$(cat); " + HR_CORE + "; printf '%s' \"$hr\""
    mode = "installed (standalone)"
data["statusLine"] = {"type": "command", "command": cmd, "refreshInterval": 1}
p.parent.mkdir(parents=True, exist_ok=True)
p.write_text(json.dumps(data, indent=2, ensure_ascii=False) + "\n")
print("headroom status line", mode)
PY
```

**To restore** the user's original status line later: copy `_headroomStatusLineBackup` back over `statusLine` and delete the backup key.

<details>
<summary>The raw headroom segment (reference — what the installer writes when there's no existing status line)</summary>

```json
  "statusLine": {
    "type": "command",
    "command": "in=$(cat); tp=$(printf '%s' \"$in\" | jq -r '.transcript_path // empty' 2>/dev/null); n=0; saved=0; age=999999; if [ -n \"$tp\" ] && [ -f \"$tp\" ]; then n=$(jq -s '[.[]|.message.content[]?|select(.type==\"tool_use\" and .name==\"mcp__headroom__headroom_compress\")]|length' \"$tp\" 2>/dev/null); saved=$(jq -s '([.[]|.message.content[]?|select(.type==\"tool_use\" and .name==\"mcp__headroom__headroom_compress\")|.id]) as $ids|[.[]|.message.content[]?|select(.type==\"tool_result\" and ((.tool_use_id) as $t|($ids|index($t))!=null))|.content[]?|.text? // empty|(try (fromjson.tokens_saved) catch 0)]|add // 0' \"$tp\" 2>/dev/null); last=$(jq -r 'select(.message.content)|select(any(.message.content[]?;.type==\"tool_use\" and .name==\"mcp__headroom__headroom_compress\"))|.timestamp' \"$tp\" 2>/dev/null | tail -1); if [ -n \"$last\" ]; then le=$(date -d \"$last\" +%s 2>/dev/null || date -j -u -f \"%Y-%m-%dT%H:%M:%S\" \"${last%%.*}\" +%s 2>/dev/null); [ -n \"$le\" ] && age=$(( $(date -u +%s) - le )); fi; fi; n=${n:-0}; saved=${saved:-0}; if [ \"$n\" -gt 0 ] 2>/dev/null; then if [ \"$age\" -le 60 ] 2>/dev/null; then printf '\\033[32m● headroom · ~%s tok saved · %s×\\033[0m' \"$saved\" \"$n\"; else printf '\\033[90m○ headroom idle · ~%s tok saved · %s×\\033[0m' \"$saved\" \"$n\"; fi; else printf '\\033[31m○ headroom idle (not compressing yet)\\033[0m'; fi",
    "refreshInterval": 1
  }
```
</details>

## Verify Before Trusting It

Confirm valid JSON, then drive the states with synthetic stdin:

```bash
jq -e '.statusLine.command' ~/.claude/settings.json >/dev/null && echo "JSON OK"
CMD=$(jq -r '.statusLine.command' ~/.claude/settings.json)

# active — a compress call "now" + its linked result with tokens_saved → green, tokens shown
NOW=$(date -u +%Y-%m-%dT%H:%M:%S.000Z)
printf '%s\n' \
 "{\"timestamp\":\"$NOW\",\"message\":{\"content\":[{\"type\":\"tool_use\",\"id\":\"t1\",\"name\":\"mcp__headroom__headroom_compress\"}]}}" \
 '{"message":{"content":[{"type":"tool_result","tool_use_id":"t1","content":[{"type":"text","text":"{\"tokens_saved\": 500}"}]}]}}' > /tmp/hr.jsonl
echo '{"transcript_path":"/tmp/hr.jsonl"}' | bash -c "$CMD"; echo   # → green ● headroom · ~500 tok saved · 1×

# never used — a stats call only (no compress) → red idle, no false positive
printf '%s\n' '{"message":{"content":[{"type":"tool_use","id":"s1","name":"mcp__headroom__headroom_stats"}]}}' > /tmp/hr.jsonl
echo '{"transcript_path":"/tmp/hr.jsonl"}' | bash -c "$CMD"; echo   # → red ○ idle (not compressing yet)
rm -f /tmp/hr.jsonl
```

## Common Mistakes

| Mistake | Fix |
|---|---|
| `grep`-ing the transcript for the tool name or `tokens_saved` | Use `jq` on `.type=="tool_use"` / link results by `tool_use_id`. The raw strings appear in prose, `stats` results (`total_tokens_saved`), and your own tool outputs — all false positives. |
| Counting `headroom_stats`/`retrieve` too | Count only `headroom_compress` — inspecting headroom shouldn't flip it to active. |
| `.text?//empty` fails to parse | jq reads `?//` as one bad token — write `.text? // empty` **with spaces**. |
| Glyphs print as literal `●` / `—` | Put real UTF-8 characters in the command, not `\u` escapes — shell `printf` won't decode `\uXXXX`. |
| ANSI shows as text | `\033` isn't valid JSON; it must be `\\033` in settings.json so the shell sees `\033`. The Python installer handles this. |
| Timestamp parse fails on Linux/macOS | Use GNU `date -d "$ts"` with a BSD `date -j -u -f … "${ts%%.*}"` fallback (as shipped). |
| `transcript_path` read fails | Capture **stdin once** (`in=$(cat)`) then parse — the JSON arrives on stdin, and the transcript file is read separately by path. |
| Clobbering an existing status line | The user may already have a custom `statusLine`. Use the merge-aware installer (it appends + backs up to `_headroomStatusLineBackup`); never blindly overwrite `statusLine`. |
| A status line reads stdin twice | stdin is consumable once. The merged command does `in=$(cat)` first, then feeds the original via `printf '%s' "$in" \| { orig; }` and reuses `$in` for the headroom segment. |

## Reload Caveat

Claude Code's settings watcher reliably reloads files that existed at session start. After installing, the line should appear on the next render; if not, open `/statusline` or `/config` once to force a reload, or it will be present next session. You can't trigger that reload from inside a turn.

## Customize

- **Decay window:** the `60` in `[ "$age" -le 60 ]` is the seconds-since-last-compress before it dims back to idle. Raise/lower to taste; set it huge to make "active" sticky for the whole session.
- **Different MCP tool:** swap the `mcp__headroom__headroom_compress` string for any `mcp__server__tool` (drop the `tokens_saved` sum if that tool doesn't report one).
- **Colors:** `\033[32m` green (active), `\033[90m` dim grey (decayed), `\033[31m` red (never used).
- **Refresh cadence:** `refreshInterval` seconds (also re-renders on message events).
