# headroom-usage-indicator v2.0.0 — Design

Date: 2026-07-13
Status: Approved

## Goal

Extend the status-line indicator from "tokens saved" to a full improvement pass:
money saved (priced against the session's actual model), the logic moved out of
the embedded settings.json one-liner into a shipped script, per-render
performance caching, lifetime totals across sessions, and a test script.

## Current state (v1.2.0)

- `skills/headroom-usage-indicator/SKILL.md` documents a Python installer that
  writes a ~1,500-char shell one-liner into `~/.claude/settings.json` →
  `statusLine.command`.
- Every second the one-liner `jq -s` parses the entire session transcript,
  counts `mcp__headroom__headroom_compress` tool_use blocks, sums their
  `tokens_saved` (linked by `tool_use_id`), and renders a red/green/grey badge.
- The installer is merge-aware: an existing custom status line is preserved,
  backed up under `_headroomStatusLineBackup`, and the headroom segment is
  appended. Re-running never double-appends.

## Design

### 1. Shipped script replaces the one-liner

New file: `scripts/statusline.sh` (bash, jq-dependent, same as today).

- Reads the status-line stdin JSON **once**; prints only the headroom badge
  segment (ANSI-colored, no trailing newline).
- The installer copies it to `~/.claude/headroom-statusline.sh` — a stable path
  that survives plugin cache version-directory changes — and writes a small
  `statusLine.command`:
  - standalone: `bash ~/.claude/headroom-statusline.sh`
  - merged: keep the existing capture-stdin-once pattern; feed `$in` to both
    the user's original command and `bash ~/.claude/headroom-statusline.sh`.
- Installer keeps all v1 merge/backup/idempotency semantics unchanged. It also
  re-copies the script on every run (upgrade path).

### 2. Money saved — session model, floor price

- Read `model.id` from the status-line stdin JSON.
- Embedded price table (input $/MTok, from the Claude API pricing reference,
  matched by substring on the model id):

  | Match | $/MTok |
  |---|---|
  | `fable-5`, `mythos` | 10 |
  | `opus-4-8`, `opus-4-7`, `opus-4-6`, `opus-4-5` | 5 |
  | `opus-4-1`, `opus-4-0`, `opus-4-2025`, `3-opus` | 15 |
  | `sonnet` (any) | 3 |
  | `haiku-4-5` | 1 |
  | `3-5-haiku` | 0.80 |
  | `3-haiku` | 0.25 |

  Note: Sonnet 5 has an intro price ($2/MTok through 2026-08-31); the table
  deliberately uses the standard $3 for simplicity (decision approved).
- `usd = tokens_saved × price / 1_000_000` (computed with awk for float math).
- **Unknown model id → tokens-only badge** (never show a wrong dollar figure).
- Formatting: `usd ≥ $0.01` → `$0.03` (2 dp); below → cents, e.g. `0.42¢`.
- README gets an honesty note: this is the conservative floor — the compressed
  content would have re-entered context on every subsequent API call (mostly at
  the 0.1× cache-read rate), so true savings compound above this figure.

### 3. Performance caching

- State dir: `~/.claude/headroom-indicator/` (created on demand).
- Per-session cache file keyed by `session_id` from stdin:
  `session-<id>.cache` containing `transcript_size|count|tokens_saved|last_ts`.
- Each render: `stat` the transcript (GNU `stat -c%s` with BSD `stat -f%z`
  fallback). If size matches the cache, skip the jq parse entirely; only the
  decay age (now − `last_ts`) is recomputed. Size changed or no cache → full
  jq parse, rewrite cache.
- This drops the steady-state per-second cost from O(transcript bytes) to one
  `stat` call.

### 4. Lifetime totals

- Each session's cache write also updates `session-<id>.totals` (tokens, usd).
- Lifetime = sum over all `session-*.totals` files (awk one-pass). Displayed
  only when > 0.
- Badge format (colors unchanged: green active ≤60s, dim grey decayed,
  red never-used):

  `● headroom · ~2.4k tok · $0.007 · 3× | $1.83 all-time`

  Token count abbreviates ≥1000 as `N.Nk`. The `| $X all-time` suffix is
  omitted when lifetime equals the current session (first-ever session).

### 5. Tests and docs

- `test.sh`: drives `scripts/statusline.sh` with synthetic stdin + transcript
  fixtures:
  1. compress call + linked result → green badge, correct tokens and dollars
     for a known model id;
  2. `headroom_stats`-only transcript → red idle (no false positive);
  3. unknown model id → tokens-only badge (no `$`);
  4. cache: unchanged transcript size → second render skips jq (verified via a
     jq-call counter shim or timing-independent marker);
  5. transcript growth → cache invalidated, totals update.
  Runs `shellcheck scripts/statusline.sh` when shellcheck is on PATH.
- SKILL.md rewritten around the script (install = copy + small settings
  command; the giant one-liner reference section is dropped).
- README: new badge format, money explanation + floor-estimate note.
- `plugin.json` / `marketplace.json` descriptions updated; version → 2.0.0.

## Error handling

- Missing/unreadable transcript, missing jq output, unparsable stdin → same as
  v1: fall back to safe defaults (n=0, saved=0), never emit a broken badge.
- State dir not writable → operate cache-less (fall back to full parse, no
  lifetime segment); the badge must still render.
- awk unavailable is not handled (POSIX awk is assumed present, like jq).

## Out of scope

- Compounding/cache-read savings estimates (documented as a note only).
- Percent-of-context framing (dropped from this pass — YAGNI until asked).
- Programmatic price updates; the table is hand-maintained per release.
