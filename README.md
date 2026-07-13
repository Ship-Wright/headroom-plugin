# headroom-usage-indicator

A tiny **status-line indicator for Claude Code** that shows — at a glance, at the bottom of your screen — whether the **headroom** context-compression MCP is actually being used in your current session, and how many tokens it has saved you.

No more wondering *"did I remember to compress that huge file, or did I just burn context?"* — the indicator tells you, honestly, in real time.

---

## Quickstart (two commands and the doctor)

Type these into the Claude Code prompt:

```
/plugin marketplace add Ship-Wright/headroom-plugin
/plugin install headroom-usage-indicator@headroom-tools
```

Then ask Claude, in plain English: **"run the headroom doctor"** (or invoke it directly: `/headroom-usage-indicator:doctor`). It checks everything — `jq`, the headroom compression engine, the MCP server, the hooks, the status line — and, with your consent, fixes whatever is missing, including the one thing a plugin can't do by itself: writing the `statusLine` entry into your `~/.claude/settings.json`.

That's it. As of v2.5 the plugin is self-contained: the hooks (Dangi and the hcat gate) register themselves the moment the plugin is enabled, `hcat` is already on Claude's Bash PATH, and the headroom MCP server registration comes bundled — no scripts to copy, no `settings.json` hook surgery. If you installed an earlier version by hand, see [Migrating from a pre-v2.5 install](#migrating-from-a-pre-v25-manual-install).

## Verify it works

Paste this into the Claude Code prompt:

> Create a roughly 100 KB JSON file at /tmp/hr-demo.json (an array of a few thousand small objects), then show me what's in it.

You should see, in order:

1. the **hcat gate** step in — instead of raw-reading the file, Claude gets redirected to run `hcat /tmp/hr-demo.json`;
2. the output open with a receipt line like `── hcat: /tmp/hr-demo.json · 1 lines · 98.3 KB · ~25000 tok → ~7500 tok (70.0% saved) · original on disk …`;
3. the badge at the bottom of your screen flip green within a second or two: `● headroom · ~17.5k tok · $… · 1× …`.

If any of those three don't happen, ask Claude to **run the headroom doctor** — diagnosing exactly this is its whole job.

<!-- DEMO-GIF: docs/demo-badge.gif — screen capture of the badge flipping red → green as an hcat receipt lands. Replace this comment with the image when recorded. -->
*(A short demo GIF of the badge flipping green will live here.)*

---

## The gauge and the engine

This plugin does **not** compress anything by itself — the actual compression is done by **headroom**, a local Python engine (→ https://github.com/headroomlabs-ai/headroom). Think of it like a fuel gauge: **headroom is the engine, this plugin is the gauge** (plus, since v2.3, a hand that reaches for the fuel-saver button for you).

The good news: you no longer have to plumb the engine in yourself. The plugin bundles the MCP server registration (its tools appear as `mcp__headroom__headroom_compress` and friends), and if the engine itself is missing, the **doctor** offers to bootstrap it into `~/.headroom-venv`. If headroom is absent and you decline, everything stays politely silent — the badge sits at "idle", the gate lets Reads through — nothing breaks.

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

Dangi ships as a plugin hook — registered automatically while the plugin is enabled, gone when it isn't. Set `DANGI_NO_NOTIFY=1` to silence the notifications. Dangi ignores edit tools (`Edit`/`Write`) — those echo code you're changing, which is never a compression target.

## hcat: stop the tokens *before* they're spent (v2.3) 🚰

The badge and Dangi are honest, but they share a limit: by the time Claude *could* call `headroom_compress`, the big output is already in context — those tokens are spent, and re-sending the blob to the compressor costs output tokens on top. `headroom_compress` genuinely pays off inside subagents (compress before returning), but in the main session it's mostly consolation.

v2.3 adds the **prevention layer**:

- **`hcat <file>`** (shipped in the plugin's `bin/`, on Claude's Bash PATH while the plugin is enabled) compresses a structured file through headroom's local pipeline **before it ever enters context** — you get a compact schema+rows rendering (typically 70 %+ token reduction on JSON) plus a header citing the original path. Need an exact detail later? `Read` the original with an offset/limit — the file on disk is the source of truth. Savings are reported into `headroom_stats`.
- **The hcat gate** (a plugin PreToolUse hook) catches Claude *about to* raw-read a big (≥ 16 KB) `.json/.jsonl/.ndjson/.csv/.tsv/.log` file — via `Read`, or a bare `cat <file>` in Bash — and redirects it to `hcat`, **once per file per session**; re-reading the same file passes, so it's a redirect, never a wall. If headroom isn't installed the gate stays silent. Kill switch: `HCAT_GATE_OFF=1`.

Both ship with the plugin — there is nothing to copy or register.

**v2.4:** the badge finally *sees* hcat. Every `hcat` run leaves a receipt in the transcript (`── hcat: … ~18899 tok → ~9351 tok (50.5% saved)`); the status line now parses those receipts and folds them into the token count, the dollar figure, the `N×` counter, the freshness dot, and the all-time total — passthrough receipts (files hcat couldn't shrink) count as nothing, and a big receipt is never a "missed" blob (it *is* the compression). Before v2.4 the badge only counted `headroom_compress` MCP calls, so a session that saved everything via hcat still read "idle (not compressing yet)". **v2.4.1:** Dangi recognizes receipts too — an output carrying an hcat header is a compression, not something to nudge about.

---

## What installing actually sets up

For the curious — after the Quickstart, here is where everything lives:

| Piece | Where | How it got there |
|---|---|---|
| Dangi + the hcat gate | `hooks/hooks.json` inside the plugin | auto-registered while the plugin is enabled |
| `hcat` | `bin/hcat` inside the plugin | on Claude's Bash PATH automatically |
| headroom MCP registration | `.mcp.json` inside the plugin | bundled; the launcher finds your engine |
| headroom engine (Python) | `~/.headroom-venv` (or your own install) | the doctor bootstraps it with your consent |
| status line | `statusLine` in `~/.claude/settings.json`, pointing at a copy of `scripts/statusline.sh` at `~/.claude/headroom-statusline.sh` | **the one manual step** — the doctor writes it for you (merge-aware: an existing custom status line is kept and backed up under `_headroomStatusLineBackup`) |

If you'd rather wire the status line by hand, the merge-aware installer lives in `skills/headroom-usage-indicator/SKILL.md`; the standalone entry it writes boils down to (with your real home directory in place of `~`):

```json
"statusLine": { "type": "command", "command": "bash \"~/.claude/headroom-statusline.sh\"", "refreshInterval": 1 }
```

If the badge doesn't appear at the bottom right away, type `/statusline` once to refresh — or it'll be there next session.

## Updating

New versions arrive through the plugin marketplace:

```
/plugin marketplace update headroom-tools
/plugin update headroom-usage-indicator@headroom-tools
```

The hooks, `hcat`, and the MCP definition update with the plugin — nothing to re-copy. The one exception is the status-line script, which runs from a copy at `~/.claude/headroom-statusline.sh`: if a release changes it, ask Claude to run the doctor once and it refreshes the copy. Legacy (pre-v2.5) manual installs get none of this for free — every update means re-running the installer, which is one more reason to migrate.

## Uninstall

Leaving should be as easy as arriving:

```
/plugin uninstall headroom-usage-indicator@headroom-tools
```

That removes the hooks, `hcat`, and the MCP registration in one go. Then tidy the two things that live outside the plugin:

1. remove the `"statusLine"` block from `~/.claude/settings.json` (or ask Claude to *"remove the headroom status line"* — if you had a custom status line before, restore it from `_headroomStatusLineBackup`);
2. delete the state and the script copy:

```bash
rm -f ~/.claude/headroom-statusline.sh
rm -rf ~/.claude/headroom-indicator
```

If you ever did a pre-v2.5 manual install, also remove the old copies and their `settings.json` hook entries — see the migration note below. The headroom engine itself (`~/.headroom-venv`, if the doctor created it) is yours to keep or `rm -rf` as you please.

## Migrating from a pre-v2.5 manual install

Before v2.5, the installer copied scripts into `~/.claude/` and registered hooks directly in your `settings.json`. If those leftovers are still present alongside the plugin, **the hooks double-fire** (two Dangis, both polite, still one too many). Ask the doctor to clean up — with your consent it removes:

- the `hooks.PostToolUse` entry referencing `dangi-hook.sh` and the `hooks.PreToolUse` entry referencing `hcat-gate.sh` from `~/.claude/settings.json`;
- the copies `~/.claude/dangi-hook.sh`, `~/.claude/hcat-gate.sh`, and `~/.claude/hcat`.

The status-line copy (`~/.claude/headroom-statusline.sh`) stays — that one is still how the badge runs.

---

## FAQ

**It always says "idle" — why?**
Most likely the headroom engine isn't installed or the MCP isn't loading. Ask Claude to **run the headroom doctor** — it checks each link in the chain and tells you which one is broken. (Manual check: `mcp__headroom__headroom_compress` should exist in your session's tools.)

**Do I still have to remember to compress things?**
Less than you used to. The hcat gate redirects big structured-file reads automatically, and Dangi nudges Claude about the rest. The badge is the honest scorekeeper on top.

**I already have a custom status line — will this wipe it?**
No. The status-line setup is **merge-aware**: it *appends* the headroom badge to your existing status line (so you keep `Model · ctx · dir (branch)` and gain the headroom dot) and backs up your original under `_headroomStatusLineBackup` in `settings.json`. To restore, copy that key back over `statusLine`.

**Can I change the colours / the 60-second decay / show a different tool?**
Yes — see the **Customize** section in `skills/headroom-usage-indicator/SKILL.md`. The same pattern works for any MCP tool (`mcp__server__tool`), not just headroom.

**Is any of this sent anywhere?**
No. It's a local shell command reading your local session file. The engine runs offline (`HF_HUB_OFFLINE=1`, update checks off). Nothing leaves your machine.

---

## Appendix: Manual / legacy install (no plugin)

If you can't (or won't) use the plugin marketplace, the copy-everything-to-`~/.claude` flow still works. Clone this repo, then follow the **legacy fallback installer** at the bottom of `skills/headroom-usage-indicator/SKILL.md` — it copies `statusline.sh`, `dangi-hook.sh`, `hcat-gate.sh`, and `hcat` into `~/.claude/` and registers the hooks in your `settings.json` itself.

Two honest caveats about the legacy flow:

- **`hcat` is NOT on Claude's PATH** in a legacy install — the "on PATH" convenience only exists while the plugin is enabled. Claude must invoke it by full path: `~/.claude/hcat <file>`. The gate still fires and redirects, but the command in its message reads bare `` `hcat "<path>"` `` (and claims it's on PATH) — in a legacy install, run `~/.claude/hcat "<path>"` instead.
- You must also install and register the **headroom engine and MCP server yourself** (→ https://github.com/headroomlabs-ai/headroom), and you need `jq` (`brew install jq` or `apt install jq`).

Do **not** run the legacy installer if the plugin is installed — you'd register every hook twice.

## What's inside

- `skills/headroom-usage-indicator/SKILL.md` — the status-line skill: the merge-aware installer, how the badge works, a common-mistakes table, verification steps, and customization notes.
- `skills/doctor/SKILL.md` — the doctor: checks `jq`, the engine, the MCP, the hooks, and the status line; fixes what you consent to, including legacy-install cleanup.
- `hooks/hooks.json` — plugin-native registration for Dangi (PostToolUse) and the hcat gate (PreToolUse).
- `bin/hcat` — compress-at-the-source, on Claude's PATH while the plugin is enabled.
- `scripts/` — `statusline.sh`, `dangi-hook.sh`, `hcat-gate.sh` (the working parts).
- `.mcp.json` — bundled headroom MCP server definition (the launcher finds your engine).
- `test.sh` — the synthetic-transcript test suite; run it from the repo root.

## License

MIT
