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
generated ~26 KB JSON, the plugin-native `hooks/hooks.json`, the bundled
`.mcp.json` (parses and its launcher is executable), that
`~/.claude/settings.json` is a single valid JSON document, legacy pre-plugin
hook entries still registered in `~/.claude/settings.json` or
`~/.claude/settings.local.json` (they double-fire alongside the plugin-native
hooks), the statusLine wiring, that the `~/.claude/headroom-statusline.sh`
copy matches the plugin's script, and stale pre-plugin script copies in
`~/.claude`.

Invoked as `/headroom-usage-indicator:doctor`.

## Step 1 — run the read-only checks

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/doctor.sh"
```

If `CLAUDE_PLUGIN_ROOT` is not set in your Bash environment, the script lives
at `../../scripts/doctor.sh` relative to this SKILL.md's directory.

## Step 2 — interpret the output plainly

Each line is aligned `<status> - <what>`:

- `ok` — healthy, nothing to do.
- `FAIL` — genuinely broken; the doctor exits nonzero. Explain what broke and
  what the line suggests (e.g. install jq, reinstall the engine). A corrupt
  settings.json, legacy hooks in settings.local.json, or a broken exported
  `HCAT_PYTHON` are reported here — the doctor refuses to edit settings or
  bootstrap around them.
- `fixable` — the doctor can repair this itself with `--fix`:
  - engine missing → bootstrap `python3 -m venv ~/.headroom-venv` +
    `pip install headroom`
  - legacy hook entries → removed from settings.json (timestamped
    `settings.json.bak.*` written first)
  - statusLine unwired → statusline script copied to
    `~/.claude/headroom-statusline.sh` and settings.json pointed at it
    (backup first); merge-aware: an existing non-headroom statusLine command
    is preserved under `_headroomStatusLineBackup` and chained ahead of the
    badge, never clobbered
  - stale statusline copy → refreshed from the plugin's `scripts/statusline.sh`
  - stale `~/.claude` copies → deleted, but only once plugin-native hooks are
    confirmed and no legacy entries remain in settings.json or
    settings.local.json (project-level `.claude/settings.json` files are not
    scanned — the doctor notes this caveat when it deletes)
- `skip` — could not be checked (e.g. hcat smoke without an engine, or
  settings.json unparseable).

Summarize for the user in one or two sentences: what is healthy, what is
broken, what the doctor could fix.

## Step 3 — get consent, then fix

Never run `--fix` unprompted. If anything is `fixable`, list exactly what
`--fix` would change (it edits `~/.claude/settings.json` with a timestamped
backup, may create a venv and run pip, may delete stale script copies) and ask
the user for consent. Only after they agree:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/doctor.sh" --fix
```

All fixes are idempotent — a second `--fix` run changes nothing. After fixing,
report the `fixed` lines back, and suggest one more plain doctor run if the
engine was just bootstrapped (the hcat smoke test is skipped in the same run).
