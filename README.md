# headroom-usage-indicator

A Claude Code plugin that adds a **status-line indicator** telling you, at a glance and at all times, whether the [headroom](https://github.com/) MCP context-compression is actually being used in the current session:

- 🔴 `○ headroom idle (not compressing yet)` — until `headroom_compress` is called this session
- 🟢 `● headroom active — N compression(s)` — once it has been

It detects **real usage** from the session transcript (counting `tool_use` calls to `mcp__headroom__headroom_compress`), so it can't be fooled — inspecting headroom with `stats`/`retrieve` does **not** flip it to active.

## Prerequisites

- The **headroom MCP server** registered in Claude Code (tools appear as `mcp__headroom__headroom_compress`).
- `jq` available on your `PATH`.

## Install

```
/plugin marketplace add Ship-Wright/headroom-plugin
/plugin install headroom-usage-indicator@headroom-tools
```

Or from a local checkout:

```
/plugin marketplace add ~/Desktop/headroom-plugin
/plugin install headroom-usage-indicator@headroom-tools
```

Installing the plugin makes the `headroom-usage-indicator` skill available. Invoke the skill (or ask Claude to "set up the headroom usage indicator") and it will merge the verified `statusLine` config into your `~/.claude/settings.json`, preserving your existing settings.

## What's inside

- `skills/headroom-usage-indicator/SKILL.md` — the full, tested skill: ready-to-paste `statusLine` block, a Python merge-installer, how-it-works, a common-mistakes table (the `grep` false-positive trap, `stats` vs `compress`, glyph/ANSI escaping), verification steps, and a customize section that generalizes the pattern to any `mcp__server__tool`.

## Customize

Swap the matched tool name to indicate any MCP tool, change colors/labels, or adjust the refresh cadence — see the skill's **Customize** section.

## License

MIT
