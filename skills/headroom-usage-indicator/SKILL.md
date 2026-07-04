---
name: headroom-usage-indicator
description: Use when you want a persistent visual reminder of whether the headroom MCP compression is actually being used this session — an always-visible status line that stays "idle" until headroom_compress is called and flips to "active" with a count once it is. Also applies to surfacing whether any specific MCP tool (mcp__server__tool) has been invoked in the current Claude Code session.
---

# Headroom Usage Indicator

## Overview

The headroom MCP compresses large, structured tool outputs to save context — but it's easy to *forget* to use it, and there's no built-in signal telling you whether you did. This skill adds a Claude Code **status line** that is an honest, always-on indicator: **red "idle"** until `headroom_compress` runs this session, **green "active — N compressions"** once it does.

**Core principle:** detect real usage from the session transcript, not from intent. The status line counts actual `tool_use` calls to `mcp__headroom__headroom_compress` in the current session's `.jsonl` transcript — so it can't lie.

## When to Use

- You have the headroom MCP installed and want a nudge to actually use it.
- You want to verify at a glance whether compression fired this session.
- Generalize the same pattern to indicate whether *any* MCP tool (`mcp__server__tool`) has been called this session.

**Not for:** counting tokens saved precisely (the transcript doesn't expose a stable savings field — count of calls is the reliable signal). **Not for:** non-MCP built-in tools (they aren't name-encoded as `mcp__…`).

## Prerequisites

- The headroom MCP server is registered (tools appear as `mcp__headroom__headroom_compress`, `…_retrieve`, `…_stats`).
- `jq` is on PATH.

## How It Works

Claude Code pipes a JSON blob to the status-line command on **stdin**, containing `transcript_path` — the current session's JSONL file. Each line is a message; assistant tool calls live at `.message.content[]` as `{"type":"tool_use","name":"mcp__…"}`. The command reads `transcript_path`, counts `tool_use` blocks whose `name` is exactly `mcp__headroom__headroom_compress`, and renders idle/active.

Match the **structured `tool_use` name** via `jq`, never a raw `grep` of the file: the literal string `mcp__headroom__headroom_compress` also appears in system reminders, prose, and tool *results*, so `grep` false-positives to "active" before anything compressed. Filtering on `.type=="tool_use"` avoids that.

## Install

Merge this into `~/.claude/settings.json` (global). This exact block is verified working:

```json
"statusLine": {
  "type": "command",
  "command": "tp=$(jq -r '.transcript_path // empty' 2>/dev/null); n=0; if [ -n \"$tp\" ] && [ -f \"$tp\" ]; then n=$(jq -s '[.[]|select(.message.content)|.message.content[]?|select(.type==\"tool_use\" and .name==\"mcp__headroom__headroom_compress\")]|length' \"$tp\" 2>/dev/null); fi; n=${n:-0}; if [ \"$n\" -gt 0 ] 2>/dev/null; then printf '\\033[32m● headroom active — %s compression%s\\033[0m' \"$n\" \"$([ \"$n\" -eq 1 ] || echo s)\"; else printf '\\033[31m○ headroom idle (not compressing yet)\\033[0m'; fi",
  "refreshInterval": 5
}
```

Don't hand-edit the escaping — merge programmatically so existing settings are preserved and JSON stays valid:

```bash
python3 - <<'PY'
import json, pathlib
p = pathlib.Path.home() / ".claude" / "settings.json"
data = json.loads(p.read_text()) if p.exists() else {}
data["statusLine"] = {
    "type": "command",
    "command": (
        "tp=$(jq -r '.transcript_path // empty' 2>/dev/null); n=0; "
        "if [ -n \"$tp\" ] && [ -f \"$tp\" ]; then "
        "n=$(jq -s '[.[]|select(.message.content)|.message.content[]?|"
        "select(.type==\"tool_use\" and .name==\"mcp__headroom__headroom_compress\")]|length' \"$tp\" 2>/dev/null); "
        "fi; n=${n:-0}; "
        "if [ \"$n\" -gt 0 ] 2>/dev/null; then "
        "printf '\\033[32m● headroom active — %s compression%s\\033[0m' \"$n\" \"$([ \"$n\" -eq 1 ] || echo s)\"; "
        "else printf '\\033[31m○ headroom idle (not compressing yet)\\033[0m'; fi"
    ),
    "refreshInterval": 5,
}
p.parent.mkdir(parents=True, exist_ok=True)
p.write_text(json.dumps(data, indent=2, ensure_ascii=False) + "\n")
print("headroom status line installed")
PY
```

## Verify Before Trusting It

First confirm the merge produced valid JSON, then pipe synthetic stdin at the stored command. Test the idle path against a transcript that has a *non-compress* headroom call (`stats`) — this exercises the real false-positive guard, which `echo '{}'` alone skips (empty path short-circuits before the count):

```bash
jq -e '.statusLine.command' ~/.claude/settings.json >/dev/null && echo "JSON OK"
CMD=$(jq -r '.statusLine.command' ~/.claude/settings.json)

# idle — transcript has a stats call but NO compress call → must stay red
printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"mcp__headroom__headroom_stats"}]}}' > /tmp/hr.jsonl
echo '{"transcript_path":"/tmp/hr.jsonl"}' | bash -c "$CMD"; echo   # → red ○ idle

# active — one compress call → green, singular
printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"mcp__headroom__headroom_compress"}]}}' > /tmp/hr.jsonl
echo '{"transcript_path":"/tmp/hr.jsonl"}' | bash -c "$CMD"; echo   # → green ● active — 1 compression
rm -f /tmp/hr.jsonl
```

## Common Mistakes

| Mistake | Fix |
|---|---|
| `grep`-ing the transcript for the tool name | Use `jq` filtered on `.type=="tool_use"` — the raw string appears in prose/results and false-positives to "active". |
| Counting `headroom_stats`/`retrieve` too | Count only `headroom_compress` — inspecting headroom shouldn't flip it to "active". |
| Glyphs print as literal `●` / `—` | Put real UTF-8 characters (`●`, `○`, `—`) in the command, not `\u` escapes — shell `printf` won't decode `\uXXXX` here. |
| ANSI shows as text | `\033` isn't valid JSON; it must be `\\033` in settings.json so the shell sees `\033`. The Python installer handles this. |
| `transcript_path` read fails | The status line's **stdin** carries the JSON — read it (`jq -r '.transcript_path'`) before touching the transcript file; the file is read separately by path. |
| Overwriting other settings | Merge (read → add `statusLine` → write), never replace the whole file. |

## Reload Caveat

Claude Code's settings watcher reliably reloads files that existed at session start. After installing, the line should appear on the next render; if not, open `/statusline` or `/config` once to force a reload, or it will be present next session. You can't trigger that reload from inside a turn.

## Customize

- **Different MCP tool:** swap the `mcp__headroom__headroom_compress` string for any `mcp__server__tool`.
- **Colors/labels:** `\033[32m` green, `\033[31m` red, `\033[33m` amber; edit the label text freely.
- **Refresh cadence:** `refreshInterval` seconds (also re-renders on message events).
