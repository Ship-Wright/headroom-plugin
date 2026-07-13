# headroom-usage-indicator

A tiny **status-line indicator for Claude Code** that shows — at a glance, at the bottom of your screen — whether the **headroom** context-compression MCP is actually being used in your current session, and how many tokens it has saved you.

No more wondering *"did I remember to compress that huge file, or did I just burn context?"* — the indicator tells you, honestly, in real time.

---

## ⚠️ Read this first: you need TWO things

This package does **not** compress anything by itself. It only *shows* whether **headroom** is working. So there are two separate pieces, in order:

1. **headroom** — the MCP server that actually does the compression. **You must install and register this in Claude Code first.** → https://github.com/headroomlabs-ai/headroom  It's working when its tools show up as `mcp__headroom__headroom_compress`.
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
| `● headroom · ~2.4k tok · $0.007 · 3× \| $1.83 all-time` | 🟢 green | a compression just happened — tokens saved, **money saved**, how many times, and your all-time total |
| `○ headroom idle · ~2.4k tok · $0.007 · 3× \| $1.83 all-time` | ⚪ grey | quiet for 60s — dims, but keeps the totals |

- The **token count is the running total for the whole session** (it adds up every compression).
- It **resets to red** when you start a brand-new Claude session.

## How the money number works

The badge prices the tokens headroom saved at the **input rate of the model your session is running** (e.g. $5/MTok on Opus, $10/MTok on Fable). If the model isn't in the built-in price table, the badge just shows tokens — it never guesses a dollar figure. `all-time` is the sum across all your sessions on this machine (stored in `~/.claude/headroom-indicator/`).

This is a deliberately **conservative floor**: compressed content would otherwise re-enter the context on every later API turn (mostly at the cheaper cache-read rate), so the true savings compound above the number shown.

---

## Install (3 steps, all typed inside Claude Code)

You do everything right in the Claude Code chat box — no terminal needed.

### Step 1 — Install headroom (the engine)
Install and register the **headroom** MCP server in Claude Code — **https://github.com/headroomlabs-ai/headroom**. It's working when its tools appear as `mcp__headroom__headroom_compress` in your session. You also need `jq` installed (most machines already have it; if not: `brew install jq` or `apt install jq`).

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
Then ask Claude once more: *"set up the headroom usage indicator"* — this refreshes the copied script at `~/.claude/headroom-statusline.sh`.

## Uninstall

Remove the `"statusLine"` block from `~/.claude/settings.json` (or ask Claude to "remove the headroom status line"), then `/plugin uninstall headroom-usage-indicator@headroom-tools`. Also remove `~/.claude/headroom-statusline.sh` and `~/.claude/headroom-indicator/`.

---

## FAQ

**It always says "idle" — why?**
headroom (Step 1) probably isn't installed or isn't registered. This package can only report on headroom; if headroom isn't there, there's nothing to show. Verify `mcp__headroom__headroom_compress` exists in your session.

**Do I still have to remember to compress things?**
This is a *reminder/gauge*, not an auto-compressor. headroom (with its own instructions) decides when to compress; this badge just shows you whether it happened.

**I already have a custom status line — will this wipe it?**
No. As of v1.2.0 the installer is **merge-aware**: it *appends* the headroom badge to your existing status line (so you keep `Model · ctx · dir (branch)` and gain the headroom dot) and backs up your original under `_headroomStatusLineBackup` in `settings.json`. To restore, copy that key back over `statusLine`.

**Can I change the colours / the 60-second decay / show a different tool?**
Yes — see the **Customize** section in `skills/headroom-usage-indicator/SKILL.md`. The same pattern works for any MCP tool (`mcp__server__tool`), not just headroom.

**Is any of this sent anywhere?**
No. It's a local shell command reading your local session file. Nothing leaves your machine.

---

## What's inside

- `skills/headroom-usage-indicator/SKILL.md` — the full, tested skill: the ready-to-paste `statusLine` config, a safe Python installer that merges into your settings, how it works, a common-mistakes table, verification steps, and customization notes.

## License

MIT
