# headroom-usage-indicator

A tiny **status-line indicator for Claude Code** that shows — at a glance, at the bottom of your screen — whether the **headroom** context-compression MCP is actually being used in your current session, and how many tokens it has saved you.

No more wondering *"did I remember to compress that huge file, or did I just burn context?"* — the indicator tells you, honestly, in real time.

---

## ⚠️ Read this first: you need TWO things

This package does **not** compress anything by itself. It only *shows* whether **headroom** is working. So there are two separate pieces, in order:

1. **headroom** — the MCP server that actually does the compression. **You must install and register this in Claude Code first** (however you obtained it — the offline/local headroom MCP). It's working when its tools show up as `mcp__headroom__headroom_compress`.
2. **this package** (`headroom-usage-indicator`) — the little status-line badge that watches headroom and reports on it.

> Think of it like a fuel gauge: **headroom is the engine, this package is the gauge.** A gauge with no engine does nothing. Install the engine first.

If headroom is not installed, this indicator will just sit at "idle" forever, because there's nothing for it to detect.

---

## What it does

Every second, it looks at what your Claude session has actually done and updates a small badge in your status line. It reads the real session activity (not guesses), so it can't be fooled — just *looking* at headroom's stats does **not** make it say "active"; only a real compression does.

## What it shows

| Badge | Colour | Meaning |
|---|---|---|
| `○ headroom idle (not compressing yet)` | 🔴 red | headroom hasn't compressed anything yet this session |
| `● headroom · ~770 tok saved · 2×` | 🟢 green | a compression just happened — shows **tokens saved** and **how many times** (`2×`) |
| `○ headroom idle · ~770 tok saved · 2×` | ⚪ grey | it's been quiet for 60s, so it dims back to idle — but keeps your session's total tokens saved |

- The **token count is the running total for the whole session** (it adds up every compression).
- It **resets to red** when you start a brand-new Claude session.

---

## Install (3 steps, all typed inside Claude Code)

You do everything right in the Claude Code chat box — no terminal needed.

### Step 1 — Install headroom (the engine)
Install and register the **headroom** MCP server in Claude Code (the offline/local context-compression MCP). It's working when its tools appear as `mcp__headroom__headroom_compress` in your session. You also need `jq` installed (most machines already have it; if not: `brew install jq` or `apt install jq`).

### Step 2 — Add this package
Type these two lines into the Claude Code prompt:
```
/plugin marketplace add Ship-Wright/headroom-plugin
/plugin install headroom-usage-indicator@headroom-tools
```

### Step 3 — Turn on the indicator
Just ask Claude, in plain English:
> set up the headroom usage indicator

Claude will write the status-line config into your `~/.claude/settings.json` (keeping your existing settings). If the badge doesn't appear at the bottom right away, type `/statusline` once to refresh — or it'll be there next session.

**That's it.** From now on the badge tells you whether headroom is pulling its weight.

---

## Updating

When a new version ships:
```
/plugin marketplace update headroom-tools
```

## Uninstall

Remove the `"statusLine"` block from `~/.claude/settings.json` (or ask Claude to "remove the headroom status line"), then `/plugin uninstall headroom-usage-indicator@headroom-tools`.

---

## FAQ

**It always says "idle" — why?**
headroom (Step 1) probably isn't installed or isn't registered. This package can only report on headroom; if headroom isn't there, there's nothing to show. Verify `mcp__headroom__headroom_compress` exists in your session.

**Do I still have to remember to compress things?**
This is a *reminder/gauge*, not an auto-compressor. headroom (with its own instructions) decides when to compress; this badge just shows you whether it happened.

**Can I change the colours / the 60-second decay / show a different tool?**
Yes — see the **Customize** section in `skills/headroom-usage-indicator/SKILL.md`. The same pattern works for any MCP tool (`mcp__server__tool`), not just headroom.

**Is any of this sent anywhere?**
No. It's a local shell command reading your local session file. Nothing leaves your machine.

---

## What's inside

- `skills/headroom-usage-indicator/SKILL.md` — the full, tested skill: the ready-to-paste `statusLine` config, a safe Python installer that merges into your settings, how it works, a common-mistakes table, verification steps, and customization notes.

## License

MIT
