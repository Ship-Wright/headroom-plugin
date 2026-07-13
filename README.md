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
| `○ headroom idle (not compressing yet)` — or `○ headroom idle · 4 big blobs uncompressed` | 🔴 red | headroom hasn't compressed anything yet this session; the count appears when large tool outputs are going uncompressed |
| `● headroom · ~2.4k tok · $0.007 · 3× \| $1.83 all-time  😴 dangi` | 🟢 green | a compression just happened — tokens saved, **money saved**, how many times, and your all-time total |
| `○ headroom idle · ~2.4k tok · $0.007 · 3× · 2 missed \| $1.83 all-time  🤖 dangi: 2!` | ⚪ grey | quiet for 60s — dims, but keeps the totals; `· N missed` counts big results beyond what you've compressed |

- The **token count is the running total for the whole session** (it adds up every compression).
- It **resets to red** when you start a brand-new Claude session.

## How the money number works

The badge prices the tokens headroom saved at the **input rate of the model your session is running** (e.g. $5/MTok on Opus, $10/MTok on Fable). If the model isn't in the built-in price table, the badge just shows tokens — it never guesses a dollar figure. `all-time` is the sum across all your sessions on this machine (stored in `~/.claude/headroom-indicator/`).

This is a deliberately **conservative floor**: compressed content would otherwise re-enter the context on every later API turn (mostly at the cheaper cache-read rate), so the true savings compound above the number shown.

## What counts as a "missed opportunity"

Any tool result of 4 KB or more that wasn't produced by headroom itself. Each compression you run forgives one big blob (compressing doesn't remove the original from the transcript, so a plain count would nag you about blobs you already handled). It's a size-only heuristic — a big code file you're editing may be a deliberate non-compression; treat the number as a nudge, not an accusation.

## Meet Dangi 🤖

Dangi is the plugin's real-time detector. The badge tells you what you missed; Dangi catches it **as it happens**:

- the moment a tool spits out ≥ 4 KB that isn't compressed, Dangi whispers to Claude (an in-context nudge, max once a minute) so it can compress right away;
- if it keeps happening, you get a macOS notification (max once per 5 minutes);
- and he lives at the end of your status line: `😴 dangi` when all is well, `🤖 dangi: 3!` when compression chances are slipping by.

Installed automatically as a Claude Code PostToolUse hook by the same installer. Set `DANGI_NO_NOTIFY=1` to silence the notifications.

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

Remove the `"statusLine"` block from `~/.claude/settings.json` (or ask Claude to "remove the headroom status line"), then `/plugin uninstall headroom-usage-indicator@headroom-tools`. Also remove `~/.claude/headroom-statusline.sh` and `~/.claude/headroom-indicator/`, plus the `hooks.PostToolUse` entry referencing `dangi-hook.sh` and `~/.claude/dangi-hook.sh`.

---

## FAQ

**It always says "idle" — why?**
headroom (Step 1) probably isn't installed or isn't registered. This package can only report on headroom; if headroom isn't there, there's nothing to show. Verify `mcp__headroom__headroom_compress` exists in your session.

**Do I still have to remember to compress things?**
This is a *reminder/gauge*, not an auto-compressor. headroom (with its own instructions) decides when to compress; this badge just shows you whether it happened.

**I already have a custom status line — will this wipe it?**
No. The installer is **merge-aware**: it *appends* the headroom badge to your existing status line (so you keep `Model · ctx · dir (branch)` and gain the headroom dot) and backs up your original under `_headroomStatusLineBackup` in `settings.json`. To restore, copy that key back over `statusLine`.

**Can I change the colours / the 60-second decay / show a different tool?**
Yes — see the **Customize** section in `skills/headroom-usage-indicator/SKILL.md`. The same pattern works for any MCP tool (`mcp__server__tool`), not just headroom.

**Is any of this sent anywhere?**
No. It's a local shell command reading your local session file. Nothing leaves your machine.

---

## What's inside

- `skills/headroom-usage-indicator/SKILL.md` — the full, tested skill: a safe Python installer that copies `scripts/statusline.sh` to `~/.claude/headroom-statusline.sh` and merges the status line into your settings, how it works, a common-mistakes table, verification steps, and customization notes.

## License

MIT
