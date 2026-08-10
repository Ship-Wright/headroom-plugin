---
name: headroom-usage-indicator
description: Use when you want a persistent visual reminder of whether the headroom MCP compression is actually being used this session — an always-visible status line that stays "idle" until headroom_compress is called, flips to "active" with the tokens AND money it saved (priced against the session's model), then decays back to idle after a quiet period. When idle, it also counts large tool results that were never compressed and shows them as an actionable nudge. A yellow "broken" state takes over the badge when a hook or hcat records a real engine failure, until /doctor clears it. Also shows an all-time money-saved total across sessions. A companion PostToolUse hook ("Dangi") nudges Claude in real time when a big uncompressed output lands, with an optional desktop notification (macOS or Linux), and a 😴/🤖 mascot sits at the end of the badge. A Stop/SessionEnd hook logs a per-session savings/misses ledger, surfaced as a one-time invoice line at the next session's start.
---

# Headroom Usage Indicator

## Overview

The headroom MCP compresses large, structured tool outputs to save context — but it's easy to *forget* to use it. This skill adds a Claude Code **status line** that is an honest, always-on indicator:

- 🔴 `○ headroom idle (not compressing yet)` — until `headroom_compress` runs this session; becomes `○ headroom idle · 4 big blobs uncompressed` when large tool results are going uncompressed
- 🟢 `● headroom · ~2.4k tok · $0.01 · 3× | $1.83 all-time` — for 60s after a compression
- ⚪ `○ headroom idle · ~2.4k tok · $0.01 · 3× · 2 missed | $1.83 all-time` — after 60s of quiet (keeps the totals; ` · N missed` appears when more big results arrived than you've compressed)
- 🟡 `▲ headroom broken (engine) · run /doctor` (v2.7) — takes over the badge for up to 24h after a hook or `hcat` records a genuine engine failure (not "never installed" — "resolved and then broken"); cleared by a working `hcat` compression or a clean `/doctor` run
- 🤖 `😴 dangi` / `🤖 dangi: 3!` — the mascot at the right end of every badge: asleep when nothing is being missed, awake with the count when big results are going uncompressed. Its hook twin nudges Claude the moment such an output lands.

v2.3 adds the **prevention layer**: `hcat` compresses structured files *at the source* (raw bytes never enter context — the only path that saves tokens on the first pass), and a PreToolUse **gate** redirects Claude from raw Reads of big structured files to `hcat`, once per file per session. v2.4 closes the loop: the badge counts hcat runs too, by parsing the `── hcat: … ~B tok → ~A tok` receipts hcat leaves in the transcript (passthrough receipts count as nothing; a receipt is never a "missed" blob).

**v2.7 adds three more layers**, all detailed in "How It Works" below: **ambient health** (real engine failures flip the badge yellow instead of silently reading as idle; a new SessionStart hook, `scripts/session-probe.sh`, runs a fast per-session check), a **session ledger** (`scripts/ledger-hook.sh`, Stop/SessionEnd) that prices both what was saved and what was missed and surfaces it as a one-time invoice at the next session's start, and **learned detection** (Dangi remembers file-backed offenders so the hcat gate can catch them again even off its static extension list, and a bare Bash `cat` of a gated file gets rewritten to `hcat` in place instead of denied).

**v2.5 — this skill's job has shrunk.** Dangi, the hcat gate, `hcat`-on-PATH, and the headroom MCP registration all ship *inside the plugin* now (`hooks/hooks.json`, `bin/hcat`, `.mcp.json`) and register automatically while the plugin is enabled. What remains for this skill:

1. **Status line setup** — the one piece a plugin cannot register itself; use the statusLine-only installer below (or defer to the `doctor` skill, which does the same with a consent step).
2. **Legacy migration** — pre-v2.5 installs copied scripts to `~/.claude/` and registered hooks in `settings.json`; those double-fire next to the plugin's own hooks. Defer to the `doctor` skill for cleanup rather than hand-editing.
3. **Manual fallback** — the full copy-to-`~/.claude` installer, kept as the last install section below for setups without the plugin marketplace (v2.7: it also copies `session-probe.sh` and `ledger-hook.sh` and registers SessionStart/Stop/SessionEnd, since the plugin's `hooks/hooks.json` would otherwise be the only place those fire).

**Core principle:** detect real usage from the session transcript, not from intent. It counts `tool_use` calls to `mcp__headroom__headroom_compress` plus hcat receipts, and sums the `tokens_saved` / receipt deltas those actually reported — so it can't lie. The dollar figure prices those tokens at the **session model's input rate** (a conservative floor — see below).

## Prerequisites

- The headroom MCP server is available (tools appear as `mcp__headroom__headroom_compress`, `…_retrieve`, `…_stats`). Plugin installs bundle the registration via `.mcp.json`; the engine itself, if missing, can be bootstrapped into `~/.headroom-venv` by the `doctor` skill. Legacy installs must register it by hand.
- `jq` on PATH.

## How It Works

All logic lives in one shipped script, `scripts/statusline.sh` (in this plugin, two directories above this SKILL.md). The installer copies it to `~/.claude/headroom-statusline.sh` and points `statusLine.command` at it. Per render it:

1. Reads the status-line **stdin JSON once** — `transcript_path`, `model.id`, `session_id`.
2. **Counts & sums** — `tool_use` blocks named `mcp__headroom__headroom_compress`; `tokens_saved` from results linked by `tool_use_id` (never grep for raw strings — `headroom_stats` results and prose mentions are false positives).
3. **Missed opportunities** — counts `tool_result` blocks ≥ 4 KB (`NUDGE_BYTES=4096`) that don't belong to a headroom tool, then subtracts the number of compressions (each compression "forgives" one big blob, since compressing doesn't remove the original from the transcript). Shown on the red and grey idle badges only — never while actively compressing.
4. **Money** — `tokens_saved × input-$/MTok` for the session's `model.id`. The price table is **data-driven** (v2.6): `data/model-prices.json` (an ordered list matched by model-id substring, first match wins) is read when present — so adding a model is a data edit, not a code change — with the built-in `price_per_mtok()` case table as a zero-regression offline fallback when the file is absent or invalid. The installer/doctor copies the JSON next to the statusline copy (`~/.claude/headroom-model-prices.json`); `HEADROOM_PRICES_FILE` overrides the path. Unknown model → tokens-only badge (never a wrong dollar figure). This is the *floor*: compressed content would have re-entered context on later turns (mostly at the 0.1× cache-read rate), so real savings compound above it.
5. **Cache** — per-session results cached in `~/.claude/headroom-indicator/session-<id>.cache` keyed on transcript byte size; unchanged size skips the jq parse (a `stat` call instead of an O(transcript) parse every second). Cache format: `size|n|saved|last_ts|missed`.
6. **Lifetime** — a session writes `session-<id>.totals` (`tokens usd`) only once it has actually saved tokens (sessions that never compress anything don't leave a file behind); if the session's model changes mid-session, the recorded usd is only ever raised, never lowered, by re-pricing at the new rate — a switch to a cheaper or unpriced model can't shrink what's already been credited. The badge sums existing totals files into `| $X all-time` once more than one session exists.
7. **Decay** — timestamp of the last compress; within 60s → bright green, else dim (totals retained).
8. **Dangi (real-time)** — a PostToolUse hook (`scripts/dangi-hook.sh`, registered automatically by the plugin's `hooks/hooks.json`; legacy installs run a copy at `~/.claude/dangi-hook.sh`) inspects every tool result as it lands; when one is ≥ 4 KB and not exempt, it injects a one-line `additionalContext` nudge for Claude (at most once per 60 s per session) pointing at `hcat` for file-backed content and `headroom_compress`/disposable-subagent for the rest.

   **v2.7 — true size, not payload size.** Claude Code truncates very large tool outputs before hooks see them (per docs, ~10,000 chars with file-reference replacement) — that used to mean a huge blob could evade real-time sizing entirely. Dangi now resolves the file behind the blob (a `Read`'s `tool_input.file_path`, or the structured-file token — `.json/.jsonl/.ndjson/.csv/.tsv/.log` — in a Bash command) and `stat`s it on disk; for **whole-file ingests** (a bare `cat`/`hcat` of exactly that file, or a `Read` with no offset/limit) the reported KB and the size tier below both use `max(payload size, file size)`. A file merely *named* in a filter command (`grep ERROR big.log`) or read bounded keeps the payload size — that output really was small. The *trigger* still fires on payload size only, so a file that was written but never read still doesn't nudge. This only defeats the truncation for file-backed reads — non-file-backed content is still measured from the (possibly truncated) payload, and the badge's transcript-based `missed` counter remains the backstop there.

   **v2.7 — size-tiered advice.** Below `DANGI_HUGE_BYTES` (default `131072`, 128 KiB) the nudge is the usual hcat/MCP-compress suggestion. At or above it, Dangi advises **delegation instead of compression**: spawn a disposable subagent (Agent tool) to read/analyze the file and return only conclusions or an hcat-compressed digest — compressing that much content in place would still flood the window.

   Two v2.6 touches make the nudge actionable: when the source names a structured file, it substitutes that path into the `hcat "<file>"` suggestion instead of a generic `<path>` (v2.7 extends this from Bash-only to `Read`'s `file_path` too, whenever the path is JSON-safe — no quotes/spaces/backslashes); and because the nudge is rate-limited, big blobs suppressed during the cooldown are counted and the next nudge reports how many were missed in the gap (batched, not one-per-blob). It also fires a desktop notification (at most once per 300 s; `osascript` on macOS, falling back to `notify-send` on Linux — skipped when neither is present or `DANGI_NO_NOTIFY` is set). Exempt from nudging: headroom's own tools; edit tools (`Edit`/`Write`/`MultiEdit`/`NotebookEdit` echo the code being changed); web results (`WebFetch`/`WebSearch` return prose); image-bearing responses (base64, not text); and the output of a genuine `hcat` run — recognized *structurally* (only a Bash command that actually invoked `hcat`, not a result that merely quotes a receipt line).

   **v2.7 — it remembers.** A nudge on a file-backed blob whose file is ≥ 4 KB **and looks structured** (innate extension, or the same 512-byte sniff the gate uses — a big source file must not get itself compression-gated) also appends `<epoch> <canonical-absolute-path>` to `$STATE_DIR/offenders` (deduped, TTL-pruned by `HEADROOM_OFFENDER_TTL`) — see step 11 below for how the hcat gate uses it. The hook always exits 0 and prints nothing except the single JSON nudge.
9. **hcat (compress at the source)** — `hcat <file>` (shipped in the plugin's `bin/`, on Claude's Bash PATH while the plugin is enabled; a legacy install keeps a copy at `~/.claude/hcat`, which is NOT on PATH and must be invoked by full path) compresses a structured file through headroom's local pipeline *before* it enters context: prints a header (`path · lines · KB · ~tokens before → after · % saved`) plus the compressed rendering; the original on disk is the source of truth (Read it with offset/limit for exact details — no retrieval store involved, so hashes and TTLs don't apply). Falls back to raw passthrough when compression would save < 5 %.

   **v2.7 — TOON-lite lossless tier.** When no engine python resolves at all, `hcat` tries one more thing before giving up: a pure-`jq` **TOON-lite** reformat — a uniform JSON array of same-shaped flat objects becomes one header row plus CSV-like rows (typically 30–60% smaller, lossless, no dependency beyond `jq`). Its receipt reads `… (NN.N% saved · toon-lite lossless, engine absent) …`; the before/after token figures are ~4-bytes/token estimates, since there's no engine tokenizer available. Non-uniform files (nested values, mismatched keys per row, not a top-level array) still exit 3 with the "headroom python not found" message. When the engine *is* present but its semantic compressor would save under 5% on a file, the *same* TOON-lite reformat is tried in Python before falling back to raw passthrough — receipt `… (NN.N% saved · toon-lite lossless) …`, appended to the stats file with `strategy:"toon-lite"` instead of `"hcat"`. Either path is only taken when it actually saves ≥ 5%.

   Appends a `strategy:"hcat"` (or `"toon-lite"`, v2.7) event to headroom's shared session-stats file so `headroom_stats` counts the savings (they appear under `sub_agents`/`combined`); the statusline badge counts hcat separately, by parsing the transcript receipts (v2.4) — attributed *structurally* (v2.5): a receipt counts only when its `tool_result` links to a Bash `tool_use` whose command actually invoked `hcat`, so a result that merely quotes a receipt line (a grep/cat over docs or tests) counts as nothing, and as a missed opportunity if it is big. Exit codes: 0 ok (including a TOON-lite reformat), 2 usage/unreadable file, 3 no engine python *and* no viable TOON-lite reformat, 4 compression failed (the engine raised — this also records an ambient-health `runtime` failure, see step 12). This is the piece that saves tokens on the *first pass* — `headroom_compress` can only shrink content that is already in context.
10. **hcat gate (PreToolUse)** — `scripts/hcat-gate.sh` (auto-registered by the plugin's `hooks/hooks.json` on `Read|Bash`; legacy installs register a copy at `~/.claude/hcat-gate.sh` on `Read` only): fires on a ≥ 16 KB (`HCAT_GATE_BYTES`) file that is gate-eligible — a structured extension (`.json/.jsonl/.ndjson/.csv/.tsv/.log`), OR (v2.7) a fresh entry in the learned offender list (step 11), OR (v2.7, unless `HCAT_GATE_NO_SNIFF=1`) a 512-byte structural sniff: first non-space byte is `{`/`[`, or the first two lines carry the same ≥3 comma/tab count.

    For a `Read`, the gate still **denies once per file per session** with the exact `hcat` command to run instead; re-Reading the same file passes (escape hatch — the gate is a redirect, never a wall). For a bare, single-line `cat <file>` in Bash (no pipes/redirects/`;`/`&`/substitution/newlines — a raw whole-file dump only; a multiline command is never touched, since rewriting one line would silently drop the others), **v2.7 rewrites the command instead of denying it**: it returns `permissionDecision:"allow"` with `updatedInput` swapping the command for `hcat "<file>"` in one shot (the command word stays unquoted — the shape the attribution regexes recognise, so a rewrite counts as a save, never a miss) — no deny→re-plan→retry round trip, the hcat receipt in the output makes the substitution visible, and an `additionalContext` line tells Claude its command was rewritten. Set `HCAT_GATE_NO_REWRITE=1` to restore the pre-v2.7 deny-and-suggest behavior for Bash. Either way the once-per-file-per-session state applies to both paths (a rewrite counts too, so a failing `hcat` can't wedge Claude into a rewrite loop — the raw `cat` passes on the retry), and any path containing shell metacharacters always falls through to the deny path rather than risk building an injectable command line.

    It allows everything when headroom isn't installed, and can be disabled entirely with `HCAT_GATE_OFF=1`. A *resolved-but-broken* engine (python not executable, or `import headroom` fails) records an ambient-health failure (step 12) and fails open — the Read/Bash goes through unmodified rather than denying against a dead end. Always exits 0.

11. **Detection that learns (offenders list, v2.7)** — every Dangi nudge on a file-backed blob whose file is ≥ 4 KB and looks structured (innate extension or 512-byte sniff) appends `<epoch> <canonical-absolute-path>` to `$STATE_DIR/offenders` (deduped by path; entries older than `HEADROOM_OFFENDER_TTL` seconds, default `1209600` / 14 days, are pruned on every write). The hcat gate (step 10) treats a fresh entry as gate-eligible regardless of extension, so an extensionless dump or mislabeled `.txt` JSON that burned context once gets caught on its next access. Plain text — inspect or delete `$STATE_DIR/offenders` to see or reset what's been learned.

12. **Ambient health (v2.7)** — every hook above fails *silently* by design (a hook that prints anything but its one JSON decision breaks every tool call), which normally means "headroom missing → stay quiet." That's indistinguishable from a *real* breakage (a broken `HCAT_PYTHON`, a half-created venv, a compression that raised) unless something records it. Hooks and `hcat` write `<epoch> <component> <message>` to `$STATE_DIR/last-error` on a genuine engine/runtime failure (never for a plain "not installed" — that's ordinary idle). The statusline treats a fresh entry (< 24h old) as authoritative over the usual active/idle state: `▲ headroom broken (<component>) · run /doctor`, yellow. `hcat` clears its own `engine`/`runtime` errors the moment a compression succeeds; `doctor.sh` clears the file on a fully clean run (no `FAIL`, nothing `fixable`) and reports "cleared recorded failure state — badge restored". A new SessionStart hook, `scripts/session-probe.sh`, runs a fast subset of the doctor's checks once per session — `jq` present, `hcat` executable, engine python resolvable by existence only (the gate/hcat verify the actual `import` at use time and record failures themselves), the bundled price table parses — and stays silent when healthy, emitting one `additionalContext` line prefixed `🤖 headroom probe:` on a problem. A never-installed engine gets a friendly pointer to `/doctor --fix` here too, but that alone does not flip the badge to broken.

13. **Session ledger + next-session invoice (v2.7)** — a Stop/SessionEnd hook, `scripts/ledger-hook.sh`, walks the transcript with the same structural attribution as steps 2–3 above and appends one cumulative JSON snapshot per session to `$STATE_DIR/ledger.jsonl`: `{ts, session_id, model, save_count, save_tokens, miss_count, miss_chars, miss_est_tokens, top_misses:[{bytes,path}], save_usd, miss_usd}`. Saves are priced the same way the badge is; misses are priced too, at a ~4-chars/token estimate against the same `data/model-prices.json` table (`_usd` fields are `null` when the model isn't in the table). A per-session checksum marker (`session-<id>.ledgermark`) skips the append when the snapshot is unchanged since the last write, so a busy session's many `Stop` firings don't spam the file; a session that neither saved nor missed anything writes nothing. The hook always exits 0 and prints nothing — a Stop hook that speaks can block the session from ending. At the *next* session's start, `session-probe.sh` reads the ledger's last line and, tracked by a `last-invoice-mark` file so it surfaces exactly once, emits `🤖 headroom invoice: last session: saved ~X tok (~$Y) · N big output(s) went uncompressed (~Z tok ≈ $W left on the table — biggest: <path>)`.

## Install (plugin) — wire the status line only

With the plugin installed from the marketplace, the hooks, `hcat`, and the MCP registration are already live — the **only** thing left to set up is the status line. Prefer deferring to the `doctor` skill (`/headroom-usage-indicator:doctor`), which does this same wiring after a full diagnosis and a consent step. To do just the statusLine piece directly, use the installer below — **do not hand-write the `statusLine`.** It is *merge-aware*: an existing custom status line is preserved (backed up under `_headroomStatusLineBackup`) and the headroom segment appended. Re-running is idempotent and also refreshes the copied script (the upgrade path).

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

## Migrating from a pre-v2.5 manual install

Pre-v2.5 installs copied `dangi-hook.sh`, `hcat-gate.sh`, and `hcat` into `~/.claude/` and registered the hooks directly in `settings.json`. Alongside the plugin's own `hooks/hooks.json` those entries **double-fire** every hook. Do not hand-edit the user's `settings.json` for this — defer to the `doctor` skill, which detects the legacy registration and, with consent, removes the `hooks.PostToolUse` entry referencing `dangi-hook.sh`, the `hooks.PreToolUse` entry referencing `hcat-gate.sh`, and the copies `~/.claude/dangi-hook.sh`, `~/.claude/hcat-gate.sh`, and `~/.claude/hcat` (with a timestamped `settings.json` backup). The status-line copy at `~/.claude/headroom-statusline.sh` stays — that is still how the badge runs.

## Legacy fallback: full manual install (no plugin)

Only for setups that can't use the plugin marketplace — **never run this alongside the plugin** (every hook would fire twice). It copies everything into `~/.claude/` and registers the hooks in `settings.json` itself — including, as of v2.7, the `SessionStart` probe and the `Stop`/`SessionEnd` ledger hook, which the plugin's own `hooks/hooks.json` would otherwise be the only thing registering. Two caveats unique to this flow: `hcat` is **not** on Claude's Bash PATH here — it must be invoked by full path, `~/.claude/hcat "<file>"` (the gate's deny message suggests bare `hcat`; read it accordingly) — and the headroom engine + MCP server must be installed and registered by hand (https://github.com/headroomlabs-ai/headroom).

Set `PLUGIN_ROOT` to the cloned repo root, then run:

```bash
python3 - <<'PY'
import json, pathlib, shutil

PLUGIN_ROOT = pathlib.Path("<absolute path of the cloned repo root>")

src = PLUGIN_ROOT / "scripts" / "statusline.sh"
dest = pathlib.Path.home() / ".claude" / "headroom-statusline.sh"
dest.parent.mkdir(parents=True, exist_ok=True)
shutil.copyfile(src, dest)
dest.chmod(0o755)

hook_src = PLUGIN_ROOT / "scripts" / "dangi-hook.sh"
hook_dest = pathlib.Path.home() / ".claude" / "dangi-hook.sh"
shutil.copyfile(hook_src, hook_dest)
hook_dest.chmod(0o755)

hcat_dest = pathlib.Path.home() / ".claude" / "hcat"
shutil.copyfile(PLUGIN_ROOT / "bin" / "hcat", hcat_dest)
hcat_dest.chmod(0o755)
gate_dest = pathlib.Path.home() / ".claude" / "hcat-gate.sh"
shutil.copyfile(PLUGIN_ROOT / "scripts" / "hcat-gate.sh", gate_dest)
gate_dest.chmod(0o755)

probe_dest = pathlib.Path.home() / ".claude" / "session-probe.sh"
shutil.copyfile(PLUGIN_ROOT / "scripts" / "session-probe.sh", probe_dest)
probe_dest.chmod(0o755)
ledger_dest = pathlib.Path.home() / ".claude" / "ledger-hook.sh"
shutil.copyfile(PLUGIN_ROOT / "scripts" / "ledger-hook.sh", ledger_dest)
ledger_dest.chmod(0o755)

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

HOOK_MARK = "dangi-hook.sh"
hooks = data.get("hooks")
hooks = data["hooks"] = hooks if isinstance(hooks, dict) else {}
ptu = hooks.get("PostToolUse")
ptu = hooks["PostToolUse"] = ptu if isinstance(ptu, list) else []
if not any(HOOK_MARK in json.dumps(e) for e in ptu):
    ptu.append({
        "matcher": "*",
        "hooks": [{"type": "command", "command": 'bash "' + str(hook_dest) + '"', "timeout": 10}],
    })

GATE_MARK = "hcat-gate.sh"
pre = hooks.get("PreToolUse")
pre = hooks["PreToolUse"] = pre if isinstance(pre, list) else []
if not any(GATE_MARK in json.dumps(e) for e in pre):
    pre.append({
        "matcher": "Read",
        "hooks": [{"type": "command", "command": 'bash "' + str(gate_dest) + '"', "timeout": 10}],
    })

PROBE_MARK = "session-probe.sh"
ss = hooks.get("SessionStart")
ss = hooks["SessionStart"] = ss if isinstance(ss, list) else []
if not any(PROBE_MARK in json.dumps(e) for e in ss):
    ss.append({
        "hooks": [{"type": "command", "command": 'bash "' + str(probe_dest) + '"', "timeout": 10}],
    })

LEDGER_MARK = "ledger-hook.sh"
for event_name in ("Stop", "SessionEnd"):
    lst = hooks.get(event_name)
    lst = hooks[event_name] = lst if isinstance(lst, list) else []
    if not any(LEDGER_MARK in json.dumps(e) for e in lst):
        lst.append({
            "hooks": [{"type": "command", "command": 'bash "' + str(ledger_dest) + '"', "timeout": 10}],
        })

p.write_text(json.dumps(data, indent=2, ensure_ascii=False) + "\n")
print("headroom status line", mode, "+ dangi hook + hcat gate + session-probe + ledger hook registered")
PY
```

**To remove a legacy install:** restore the status line as above, remove the `hooks.PostToolUse` entry referencing `dangi-hook.sh`, the `hooks.PreToolUse` entry referencing `hcat-gate.sh`, the `hooks.SessionStart` entry referencing `session-probe.sh`, and the `hooks.Stop`/`hooks.SessionEnd` entries referencing `ledger-hook.sh` from `settings.json`; then delete `~/.claude/dangi-hook.sh`, `~/.claude/hcat-gate.sh`, `~/.claude/hcat`, `~/.claude/session-probe.sh`, and `~/.claude/ledger-hook.sh`.

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
| Adding `echo` / debug prints to `dangi-hook.sh` | Anything on stdout besides the single JSON object corrupts the hook output for every tool call. Debug to a file (`>> /tmp/dangi.log`) instead. |

## Reload Caveat

Claude Code's settings watcher reliably reloads files that existed at session start. After installing, the line should appear on the next render; if not, open `/statusline` or `/config` once to force a reload, or it will be there next session.

## Customize

All knobs live in `scripts/statusline.sh` (edit, then re-run the installer):

- **Decay window:** the `60` in `[ "$age" -le 60 ]`.
- **Prices:** edit `data/model-prices.json` (ordered `{match, usd_per_mtok}` list, first substring match wins) — data, not code. The `price_per_mtok()` case table is only the offline fallback when that file is missing. `HEADROOM_PRICES_FILE` overrides the path.
- **State dir:** `HEADROOM_STATE_DIR` env var (used by tests).
- **Colors:** `\033[32m` green (active), `\033[90m` dim (decayed), `\033[31m` red (never used).
- **Different MCP tool:** change `TOOL=` (drop the `tokens_saved` sum if that tool doesn't report one).
- **Nudge threshold:** `NUDGE_BYTES` (default 4096) — minimum tool-result size that counts as a missed compression opportunity. Raise it if code-file reads trigger false nags.
- **Dangi cooldowns:** `NUDGE_COOLDOWN` (60 s between context nudges) and `NOTIFY_COOLDOWN` (300 s between notifications) in `dangi-hook.sh`; set `DANGI_NO_NOTIFY=1` in your environment to disable notifications entirely.
- **Dangi delegation tier (v2.7):** `DANGI_HUGE_BYTES` (default `131072`, 128 KiB) — the true on-disk size at/above which Dangi's nudge switches from "compress it" to "delegate to a disposable subagent."
- **Offender TTL (v2.7):** `HEADROOM_OFFENDER_TTL` (default `1209600`, 14 days) — how long a file Dangi flagged stays gate-eligible in `$STATE_DIR/offenders`, shared by `dangi-hook.sh` and `hcat-gate.sh`.
- **Gate threshold:** `HCAT_GATE_BYTES` (default 16384) — minimum file size the gate fires on; `HCAT_GATE_OFF=1` disables the gate entirely; the gated extension list is the `case` in `hcat-gate.sh`.
- **Gate rewrite (v2.7):** `HCAT_GATE_NO_REWRITE=1` — makes a bare Bash `cat <file>` deny-and-suggest like `Read` does, instead of the default in-place rewrite to `hcat "<file>"`.
- **Gate sniff (v2.7):** `HCAT_GATE_NO_SNIFF=1` — turns off the 512-byte structural sniff, so only the static extension list and the learned offender list make a file gate-eligible.
- **hcat python:** `HCAT_PYTHON` — explicit path to headroom's venv python (authoritative override; otherwise resolved from `headroom` on PATH, then `~/.headroom-venv/bin/python`).
