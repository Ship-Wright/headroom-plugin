# attribution.jq — the ONE definition of "what counts as a genuine hcat
# compression" in a transcript, shared by statusline.sh and ledger-hook.sh
# via `jq -L <libdir> 'include "attribution"; ...'`. dangi-hook.sh keeps a
# shell-regex cousin of is_hcat_cmd (it has no jq attribution pass) — keep
# the two in sync when the receipt or command shape changes.

def txt: (.content | if type=="string" then .
                     elif type=="array" then ([.[]? | .text? // ""] | join(""))
                     else "" end);

def is_receipt: test("(^|\\n)── hcat: ");

# A command "invokes hcat" when the hcat word sits in command position
# (start/newline/pipe/;/&/subshell/absolute path). The second alternative
# tolerates the whole-command quoted form ("hcat" "file", "/abs/hcat" "file")
# that pre-F1 v2.7 gate rewrites emitted into older transcripts — anchored to
# the command start so a `grep "hcat" docs` never counts.
def is_hcat_cmd:
  test("(^|\\n|[|;&]\\s*|[$][(]\\s*|/)hcat(\\s|$)")
  or test("(^|\\n)\"([^\"]*/)?hcat\"(\\s|$)");

# O(1) membership set from a list of tool_use ids (index() rescans are
# quadratic over big transcripts — see ledger-hook).
def idset($ids): ($ids | map({key: (. // ""), value: true}) | from_entries);

def tool_uses: [.[] | .message.content[]? | select(.type=="tool_use")];

def mcp_ids($tool): [tool_uses[] | select(.name==$tool) | .id];
def headroom_ids($pfx): [tool_uses[] | select((.name // "")|startswith($pfx)) | .id];
def hcat_bash_ids: [tool_uses[] | select((.name // "")=="Bash"
    and ((.input.command? // "") | is_hcat_cmd)) | .id];

def tool_results: [.[] | .message.content[]? | select(.type=="tool_result")
    | {id: (.tool_use_id // ""), t: txt}];

# Output classes that are never compression candidates (mirrors the exemption
# case in dangi-hook.sh) plus subagent digests, which are already distilled —
# counting these as "missed savings" would price the unpriceable.
def exempt_tools: ["Edit","Write","MultiEdit","NotebookEdit","WebFetch","WebSearch","Task","Agent"];
