---
name: doctor
description: Use when the headroom setup needs a health check or repair — the statusline badge never appears, hcat is missing from PATH, the headroom MCP tools are unavailable, hooks seem to fire twice, right after installing or updating the headroom-usage-indicator plugin, or whenever the user says headroom is not working or asks to check, fix, verify, or bootstrap their headroom install. Runs the plugin's read-only doctor script, explains the findings in plain language, and re-runs with --fix only after explicit user consent.
---

# Headroom Doctor

## Overview

`scripts/doctor.sh` validates the whole headroom setup end-to-end: jq, the
headroom engine python (`$HCAT_PYTHON` → sibling of `headroom` on PATH → the
`headroom` console script's shebang interpreter, which covers pip --user and
pipx layouts → `~/.headroom-venv`), a real `bin/hcat` smoke compression of a
generated ~26 KB JSON, the plugin-native `hooks/hooks.json` (SessionStart,
PreToolUse, PostToolUse, Stop, SessionEnd), the bundled
`.mcp.json` (parses and its launcher is executable **exactly as spawned** —
MCP commands run without a shell, so a command carrying literal quotes is
broken and `--fix` unquotes it in place), the bundled
`data/model-prices.json` badge price table (parses; `--fix` copies it beside the
statusline copy), that
`~/.claude/settings.json` is a single valid JSON document, legacy pre-plugin
hook entries still registered in `~/.claude/settings.json`,
`~/.claude/settings.local.json`, **and the current project's**
`.claude/settings.json` / `.claude/settings.local.json` (override the project
directory with `DOCTOR_PROJECT_DIR`, default the current working directory) —
they all double-fire alongside the plugin-native hooks — the statusLine
wiring (including a doctor-blessed custom, hand-wired path, not just the
canonical `~/.claude/headroom-statusline.sh` copy), that the wired copy
matches the plugin's script **and that its runtime deps (`attribution.jq`,
`headroom-state.sh`) are present and current** — under `~/.claude/lib/`, or,
for the legacy full-manual install layout, as flat siblings next to the copy
(without them the badge is stuck at a permanent "idle" showing zero savings),
stale pre-plugin script copies in `~/.claude`, and whether a recorded
ambient-health failure (the `last-error` file that flips the statusline badge
to "broken") can now be cleared.

A companion SessionStart hook, `scripts/session-probe.sh`, runs a much
lighter version of this check automatically every session (jq present, `hcat`
executable, engine python resolvable by existence only, price table parses)
and stays silent when healthy — this doctor is the deeper, on-demand check
Claude runs when something actually needs diagnosis or repair.

Invoked as `/headroom-usage-indicator:doctor`.

## Step 1 — run the read-only checks

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/doctor.sh"
```

If `CLAUDE_PLUGIN_ROOT` is not set in your Bash environment, the script lives
at `../../scripts/doctor.sh` relative to this SKILL.md's directory.

## Step 2 — interpret the output plainly

Each line is aligned `<status> - <what>`:

- `ok` — healthy, nothing to do. If a previously recorded ambient-health
  failure (`last-error`) existed at the start of the run and the run finished
  fully clean, this is also where the doctor reports "cleared recorded
  failure state — badge restored".
- `FAIL` — genuinely broken; the doctor exits nonzero. Explain what broke and
  what the line suggests (e.g. install jq, reinstall the engine). A corrupt
  settings.json, legacy hooks in settings.local.json or a project's settings,
  or a broken exported `HCAT_PYTHON` are reported here — the doctor refuses
  to edit settings or bootstrap around them.
- `fixable` — the doctor can repair this itself with `--fix`:
  - engine missing → bootstrap `python3 -m venv ~/.headroom-venv` +
    `pip install "headroom-ai[all]"`
  - legacy hook entries → removed from `~/.claude/settings.json`,
    `~/.claude/settings.local.json`, and the current project's
    `.claude/settings.json` / `.claude/settings.local.json` (a timestamped
    `.bak.*` is written first for each file actually touched)
  - statusLine unwired → statusline script copied to
    `~/.claude/headroom-statusline.sh` and settings.json pointed at it
    (backup first); merge-aware: an existing non-headroom statusLine command
    is preserved under `_headroomStatusLineBackup` and chained ahead of the
    badge, never clobbered
  - statusLine wired but script missing → `scripts/statusline.sh` re-copied to
    `~/.claude/headroom-statusline.sh` (settings already point at it, in any
    spelling — absolute or tilde), with its `lib/` deps re-provisioned (the
    price table too, best-effort); the same wiring pointed at a hand-edited
    custom path whose script is gone is reported `FAIL` instead — the doctor
    will not guess where to place a copy; a custom path whose script IS
    present but whose `lib/` deps are missing or stale, or whose script itself
    is present but stale (differs from the plugin's current
    `scripts/statusline.sh`), is likewise `FAIL`, not `fixable` — the doctor
    detects a custom install's health but never writes into it
  - statusLine names the canonical file by a respelling bash can never expand
    at spawn time (a quoted `~`, which the shell never unwraps inside double
    quotes) → `settings.json`'s `statusLine.command` is rewritten to the
    absolute path (its own timestamped backup first) — this fires whether or
    not the script already exists at `~/.claude/headroom-statusline.sh` (if
    it's missing too, it's re-copied first, same as above); doctor never
    reports this wiring as healthy even when the file is present, since the
    wired command itself would still never resolve it
  - quoted `.mcp.json` command → literal quotes around `${CLAUDE_PLUGIN_ROOT}`
    stripped in place (timestamped `.bak.*` first) — MCP stdio commands are
    spawned without a shell, so the quotes 404 the launcher and the bundled
    server never connects (the `/plugin` ✗)
  - stale statusline copy → refreshed from the plugin's `scripts/statusline.sh`
  - missing/stale statusline lib deps → `attribution.jq` and
    `headroom-state.sh` (re)installed into `~/.claude/lib/`; these are what the
    badge needs to attribute savings, so without them it silently reads zero
  - stale `~/.claude` copies → deleted, but only once plugin-native hooks are
    confirmed and no legacy entries remain in `settings.json`,
    `settings.local.json`, or the current project's settings — project-level
    `.claude` settings in **other** directories are not scanned (this one
    was); the doctor notes that caveat when it deletes
- `skip` — could not be checked (e.g. hcat smoke without an engine, or
  settings.json unparseable).
- `note` — a supplementary caveat attached to the fixed/ok line just above it
  (e.g. that stale-copy deletion only scanned this project's `.claude`
  settings, not every project on disk); not counted toward the ok/fixable/
  failed/skipped tally.

Summarize for the user in one or two sentences: what is healthy, what is
broken, what the doctor could fix.

## Step 3 — get consent, then fix

Never run `--fix` unprompted. If anything is `fixable`, list exactly what
`--fix` would change (it may edit `~/.claude/settings.json`,
`~/.claude/settings.local.json`, and the current project's
`.claude/settings.json` / `.claude/settings.local.json`, each with its own
timestamped backup; may create a venv and run pip; may delete stale script
copies; may rewrite the plugin's bundled `.mcp.json` in place to unquote its
command, with its own timestamped backup; may re-copy the statusline script
plus its `lib/` deps and price table to `~/.claude` — both when wiring
statusLine for the first time and when settings already point at a missing
canonical copy; and may rewrite `statusLine.command` to an absolute path (same
settings.json backup) whenever the wiring named the canonical file by a
respelling bash can never expand — whether or not the script already exists;
never writes into a doctor-detected custom-path install, only reports its
health) and ask the user for consent. Only after they agree:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/doctor.sh" --fix
```

If the user wants the project-settings scan pointed at a different directory
than the current working one, set `DOCTOR_PROJECT_DIR` before running either
command.

All fixes are idempotent — a second `--fix` run changes nothing. After fixing,
report the `fixed` lines back, and suggest one more plain doctor run if the
engine was just bootstrapped (the hcat smoke test is skipped in the same run).
