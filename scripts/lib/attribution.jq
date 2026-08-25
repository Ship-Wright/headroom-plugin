# attribution.jq — the ONE definition of "what counts as a genuine hcat
# compression" in a transcript, shared by statusline.sh and ledger-hook.sh
# via `jq -L <libdir> 'include "attribution"; ...'`. dangi-hook.sh keeps a
# shell-regex cousin of is_hcat_cmd (it has no jq attribution pass) — keep
# the two in sync when the receipt or command shape changes.
#
# One asymmetry the cousin must NOT copy: dangi-hook reads its PostToolUse
# payload, which carries the command AFTER any hook rewrite, so it sees a
# gate-rewritten `cat` as the hcat run it became and needs no extra handling.
# The transcript consumers here see the command BEFORE the rewrite, which is
# why gate_rewritten_ids below exists. Adding it to dangi would be redundant;
# dropping it here silently un-attributes every gate rewrite.

def txt: (.content | if type=="string" then .
                     elif type=="array" then ([.[]? | .text? // ""] | join(""))
                     else "" end);

def is_receipt: test("(^|\\n)── hcat: ");

# A command "invokes hcat" when the hcat word sits in command position
# (start/newline/pipe/;/&/subshell/absolute path). The second alternative
# tolerates the whole-command quoted form ("hcat" "file", "/abs/hcat" "file")
# that pre-F1 v2.7 gate rewrites emitted into older transcripts — anchored to
# the command start so a `grep "hcat" docs` never counts.
# The leading type coercion is load-bearing, not defensive noise: jq's test()
# THROWS on a non-string input, and an uncaught throw aborts the whole program
# — which here means the badge silently renders empty and the ledger drops the
# session, for the rest of that session. The inputs are third-party (any
# PreToolUse hook's announced command, any recorded tool_input.command), so a
# non-string is a `{"command": 42}` away. Coerce to "" and simply not match.
def is_hcat_cmd:
  (if type == "string" then . else "" end)
  | test("(^|\\n|[|;&]\\s*|[$][(]\\s*|/)hcat(\\s|$)")
    or test("(^|\\n)\"([^\"]*/)?hcat\"(\\s|$)");

# O(1) membership set from a list of tool_use ids (index() rescans are
# quadratic over big transcripts — see ledger-hook).
def idset($ids): ($ids | map({key: (. // ""), value: true}) | from_entries);

def tool_uses: [.[] | .message.content[]? | select(.type=="tool_use")];

def mcp_ids($tool): [tool_uses[] | select(.name==$tool) | .id];
def headroom_ids($pfx): [tool_uses[] | select((.name // "")|startswith($pfx)) | .id];

# The hcat gate REWRITES a raw `cat <big file>` into an hcat run by returning
# updatedInput from PreToolUse. Claude Code hands the rewritten command to the
# tool (so the compression really happens, and PostToolUse consumers like
# dangi-hook see the hcat form) but records the ORIGINAL `cat …` in the
# assistant's tool_use — which is what a transcript pass reads. So is_hcat_cmd
# over tool_uses alone can never see a rewrite: the receipt would fail the
# genuineness check and score as a MISS, i.e. the badge would blame the user
# for the very compression the gate just performed.
#
# The rewrite IS in the transcript, structurally linked by toolUseID, in the
# hook_success attachment that carries the gate's own stdout. Parse that stdout
# and apply the SAME is_hcat_cmd test to the updatedInput command it announced,
# so this stays a structural check: a hook whose output merely MENTIONS hcat,
# or any prose quoting a rewrite, can never qualify.
def gate_rewritten_ids:
  # The command-based half of hcat_bash_ids is implicitly Bash-only (it reads
  # a Bash tool_use's .input.command). Keep that invariant here rather than
  # trusting any hook on any tool: only a Bash tool_use can be an hcat run.
  idset([tool_uses[] | select((.name // "") == "Bash") | .id]) as $bash
  | [ .[] | select((.type? // "") == "attachment")
        | .attachment? // empty
        | select((.type? // "") == "hook_success")
        | select((.hookEvent? // "") == "PreToolUse")
        | . as $a
        # Bound the parse: this runs on every status-line render, and stdout
        # belongs to whatever hook produced it. The gate's own output is ~1 KB.
        | select((($a.stdout? // "") | length) < 65536)
        | (($a.stdout? // "") | try fromjson catch null) as $o
        | select($o != null)
        | select(((($o.hookSpecificOutput? // {}).updatedInput? // {}).command? // "") | is_hcat_cmd)
        | ($a.toolUseID? // empty)
        | select($bash[.] // false) ];

# Both shapes of a genuine hcat run: the model invoking hcat itself, and the
# gate rewriting a `cat` into one on its behalf.
def hcat_bash_ids: [tool_uses[] | select((.name // "")=="Bash"
    and ((.input.command? // "") | is_hcat_cmd)) | .id]
  + gate_rewritten_ids;

def tool_results: [.[] | .message.content[]? | select(.type=="tool_result")
    | {id: (.tool_use_id // ""), t: txt}];

# Output classes that are never compression candidates (mirrors the exemption
# case in dangi-hook.sh) plus subagent digests, which are already distilled —
# counting these as "missed savings" would price the unpriceable.
def exempt_tools: ["Edit","Write","MultiEdit","NotebookEdit","WebFetch","WebSearch","Task","Agent"];
