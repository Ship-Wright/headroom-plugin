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
5. **Lifetime** — a session writes `session-<id>.totals` (`tokens usd`) only once it has actually saved tokens (sessions that never compress anything don't leave a file behind); if the session's model changes mid-session, the recorded usd is only ever raised, never lowered, by re-pricing at the new rate — a switch to a cheaper or unpriced model can't shrink what's already been credited. The badge sums existing totals files into `| $X all-time` once more than one session exists.
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
