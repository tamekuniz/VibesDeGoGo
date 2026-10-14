#!/bin/bash
set -u
export LC_ALL=en_US.UTF-8
if [ "$(locale charmap 2>/dev/null)" != "UTF-8" ]; then
    echo "NOTE: en_US.UTF-8 が無いため UTF-8 での回帰は未検証" >&2
fi
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "$ROOT/tests/lib/assert.sh"

HOOK="$ROOT/skills/vdgg-watch/scripts/vdgg-watch-hook.sh"
/bin/bash -n "$HOOK"; rc=$?
assert_exit_code 0 "$rc" "hook parses under /bin/bash"
WATCH="$ROOT/skills/vdgg-watch/scripts/vdgg-watch.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

mkgoal() {
    mkdir -p "$1/checks" "$1/artifact" "$1/approvals" "$1/evidence"
    echo "exit 0" > "$1/checks/a.sh"
}

h() { printf '%s' "$1" | /bin/bash "$HOOK" >/dev/null 2>&1; }
wjson() { jq -nc --arg cwd "$1" --arg t "$2" --arg p "$3" '{cwd:$cwd,tool_name:$t,tool_input:{file_path:$p}}'; }
bjson() { jq -nc --arg cwd "$1" --arg c "$2" '{cwd:$cwd,tool_name:"Bash",tool_input:{command:$c}}'; }
tjson() { jq -nc --arg cwd "$1" --arg t "$2" '{cwd:$cwd,tool_name:$t,tool_input:{}}'; }
njson() { jq -nc --arg cwd "$1" --arg p "$2" '{cwd:$cwd,tool_name:"NotebookEdit",tool_input:{notebook_path:$p}}'; }

G="$TMP/g"; mkgoal "$G"
W="$TMP/w"; mkdir -p "$W/.claude"
printf '%s\n' "$G" > "$W/.claude/.vdgg-watch-active"

W0="$TMP/w0"; mkdir -p "$W0"
h "$(bjson "$W0" "rm -rf /")"; rc=$?
assert_exit_code 0 "$rc" "no marker: any tool allowed"

h "$(tjson "$W" Read)"; rc=$?
assert_exit_code 0 "$rc" "Read allowed"
h "$(tjson "$W" WebFetch)"; rc=$?
assert_exit_code 0 "$rc" "WebFetch allowed"

h "not json"; rc=$?
assert_exit_code 2 "$rc" "broken json denied"
h "$(tjson "$W" "")"; rc=$?
assert_exit_code 2 "$rc" "empty tool_name denied"

h "$(wjson "$W" Write "$G/artifact/x.md")"; rc=$?
assert_exit_code 0 "$rc" "write to artifact allowed"
h "$(wjson "$W" Write "$G/fit.md")"; rc=$?
assert_exit_code 0 "$rc" "write to fit.md allowed"
h "$(wjson "$W" Write "$G/proposal.md")"; rc=$?
assert_exit_code 0 "$rc" "write to proposal.md allowed"
h "$(wjson "$W" Write "$G/sources.md")"; rc=$?
assert_exit_code 0 "$rc" "write to sources.md allowed"

h "$(wjson "$W" Write "$G/checks/a.sh")"; rc=$?
assert_exit_code 2 "$rc" "write to checks denied"
h "$(wjson "$W" Write "$G/approvals/x")"; rc=$?
assert_exit_code 2 "$rc" "write to approvals denied"
h "$(wjson "$W" Write "$G/goal.md")"; rc=$?
assert_exit_code 2 "$rc" "write to goal.md denied"
h "$(wjson "$W" Write "$TMP/outside.md")"; rc=$?
assert_exit_code 2 "$rc" "write outside G denied"
h "$(njson "$W" "$TMP/outside.ipynb")"; rc=$?
assert_exit_code 2 "$rc" "NotebookEdit outside G denied"

h "$(wjson "$W" Write "$G/Approvals/x")"; rc=$?
assert_exit_code 2 "$rc" "case-insensitive approvals bypass denied"
h "$(wjson "$W" Write "$G/CHECKS/a.sh")"; rc=$?
assert_exit_code 2 "$rc" "case-insensitive checks bypass denied"
h "$(wjson "$W" Write "$G//approvals/x")"; rc=$?
assert_exit_code 2 "$rc" "double-slash approvals bypass denied"
h "$(wjson "$W" Write "evidence/e")"; rc=$?
assert_exit_code 2 "$rc" "relative path write denied"

h "$(wjson "$W" Write "$G/artifact/../checks/a.sh")"; rc=$?
assert_exit_code 2 "$rc" "path containing /../ denied"
h "$(wjson "$W" Write "$G/artifact/./x.md")"; rc=$?
assert_exit_code 2 "$rc" "path containing /./ denied"

h "$(bjson "$W" "bash \"$WATCH\" run \"$G\"")"; rc=$?
assert_exit_code 0 "$rc" "double-quoted watch run call allowed"
h "$(bjson "$W" "bash $WATCH run $G")"; rc=$?
assert_exit_code 2 "$rc" "unquoted watch run call denied"
h "$(bjson "$W" "bash '$WATCH' run '$G'")"; rc=$?
assert_exit_code 2 "$rc" "single-quoted watch run call denied"
h "$(bjson "$W" "bash \"$WATCH\" run \"$G\"; rm -rf /")"; rc=$?
assert_exit_code 2 "$rc" "semicolon-chained command denied"
h "$(bjson "$W" "bash \"$WATCH\" run \"\$(rm -rf /)\"")"; rc=$?
assert_exit_code 2 "$rc" "command substitution denied"
h "$(bjson "$W" "ls -la")"; rc=$?
assert_exit_code 2 "$rc" "unrelated bash command denied"
h "$(bjson "$W" "bash \"$WATCH\" start \"$G\"")"; rc=$?
assert_exit_code 2 "$rc" "start denied while watching"
h "$(bjson "$W" "bash \"$WATCH\" lock \"$G/artifact\"")"; rc=$?
assert_exit_code 2 "$rc" "lock argument not exactly G denied"
h "$(bjson "$W" "bash \"$WATCH\" run \"/other\"")"; rc=$?
assert_exit_code 2 "$rc" "run argument not exactly G denied"
h "$(bjson "$W" "bash \"$WATCH\" lock \"$G\"")"; rc=$?
assert_exit_code 0 "$rc" "double-quoted lock call allowed"
h "$(bjson "$W" "bash \"$WATCH\" done")"; rc=$?
assert_exit_code 0 "$rc" "double-quoted done call allowed"

GBAD="$TMP/g\$bad"; mkgoal "$GBAD"
WBAD="$TMP/wbad"; mkdir -p "$WBAD/.claude"
printf '%s\n' "$GBAD" > "$WBAD/.claude/.vdgg-watch-active"
touch "$GBAD/approvals/Bash"
h "$(bjson "$WBAD" "bash \"$WATCH\" run \"$GBAD\"")"; rc=$?
assert_exit_code 2 "$rc" "unsafe chars in G deny Bash even with approvals/Bash"
assert_file_exists "$GBAD/approvals/Bash" "unsafe-G denial does not consume Bash approval"

touch "$G/approvals/Bash"
h "$(bjson "$W" "ls -la")"; rc=$?
assert_exit_code 0 "$rc" "approvals/Bash allows arbitrary bash once"
assert_file_not_exists "$G/approvals/Bash" "Bash approval consumed"
h "$(bjson "$W" "ls -la")"; rc=$?
assert_exit_code 2 "$rc" "Bash approval is one-shot"

h "$(tjson "$W" mcp__mail__send)"; rc=$?
assert_exit_code 2 "$rc" "unknown tool denied without approval"
touch "$G/approvals/mcp__mail__send"
h "$(tjson "$W" mcp__mail__send)"; rc=$?
assert_exit_code 0 "$rc" "unknown tool allowed with approval"
assert_file_not_exists "$G/approvals/mcp__mail__send" "approval consumed"
h "$(tjson "$W" mcp__mail__send)"; rc=$?
assert_exit_code 2 "$rc" "approval is one-shot"

printf 'allow_tools: mcp__x__read\n' > "$G/checks.lock"
h "$(tjson "$W" mcp__x__read)"; rc=$?
assert_exit_code 0 "$rc" "allow_tools in checks.lock grants tool"
rm -f "$G/checks.lock"
printf 'goal\nallow_tools: mcp__x__read\n' > "$G/goal.md"
h "$(tjson "$W" mcp__x__read)"; rc=$?
assert_exit_code 2 "$rc" "goal.md allow_tools is not read"

printf 'allow_tools:\n' > "$G/checks.lock"
h "$(tjson "$W" mcp__x__read)"; rc=$?
assert_exit_code 2 "$rc" "empty allow_tools denies unknown tool"
rm -f "$G/checks.lock"

printf 'allow_tools: Bash, Write\n' > "$G/checks.lock"
h "$(bjson "$W" "ls -la")"; rc=$?
assert_exit_code 2 "$rc" "allow_tools cannot unlock arbitrary Bash"
h "$(wjson "$W" Write "$G/checks/a.sh")"; rc=$?
assert_exit_code 2 "$rc" "allow_tools cannot unlock checks write"
rm -f "$G/checks.lock"

ln -s "$G/checks/a.sh" "$G/link"
h "$(wjson "$W" Write "$G/link")"; rc=$?
assert_exit_code 2 "$rc" "write through symlink denied"
rm -f "$G/link"
ln -s "$G/checks/a.sh" "$G/artifact/link.md"
h "$(wjson "$W" Write "$G/artifact/link.md")"; rc=$?
assert_exit_code 2 "$rc" "write through symlink inside artifact denied"
rm -f "$G/artifact/link.md"

touch "$G/approvals/Write"
h "$(wjson "$W" Write "$G/evidence/x")"; rc=$?
assert_exit_code 2 "$rc" "approval cannot unlock evidence write"
h "$(wjson "$W" Write "$G/checks.lock")"; rc=$?
assert_exit_code 2 "$rc" "approval cannot unlock checks.lock write"
assert_file_exists "$G/approvals/Write" "protected write denial does not consume approval"
h "$(wjson "$W" Write "$G/note.txt")"; rc=$?
assert_exit_code 0 "$rc" "approval allows write outside allowlist once"
assert_file_not_exists "$G/approvals/Write" "write approval consumed"
h "$(wjson "$W" Write "$G/note.txt")"; rc=$?
assert_exit_code 2 "$rc" "write approval is one-shot"

touch "$G/approvals/Write"
if [ -d "/private$G" ]; then
    h "$(wjson "$W" Write "/private$G/approvals/Bash")"; rc=$?
    assert_exit_code 2 "$rc" "/private-aliased approvals path denied even with approval"
fi
h "$(wjson "$W" Write "../g/approvals/Bash")"; rc=$?
assert_exit_code 2 "$rc" "relative approvals path denied even with approval"
h "$(wjson "$W" Write "$G/Approvals/x")"; rc=$?
assert_exit_code 2 "$rc" "mixed-case approvals path denied even with approval"
h "$(wjson "$W" Write "$G/GOAL.md")"; rc=$?
assert_exit_code 2 "$rc" "uppercase goal.md denied even with approval"
ln -s .. "$G/artifact/a"
h "$(wjson "$W" Write "$G/artifact/a/approvals/Bash")"; rc=$?
assert_exit_code 2 "$rc" "ancestor symlink into approvals denied even with approval"
rm -f "$G/artifact/a"

rm -rf "$G/evidence"
ln -s .. "$G/artifact/self"
h "$(wjson "$W" Write "$G/artifact/self/checks.lock")"; rc=$?
assert_exit_code 2 "$rc" "symlinked prefix to checks.lock denied even with approval"
h "$(wjson "$W" Write "$G/artifact/self/evidence/x.log")"; rc=$?
assert_exit_code 2 "$rc" "symlinked prefix to evidence denied even with approval"
assert_file_exists "$G/approvals/Write" "symlinked prefix denial does not consume approval"
rm -f "$G/artifact/self"
mkdir -p "$G/evidence"

ln -s "$TMP" "$G/artifact/out"
rm -f "$G/approvals/Write"
h "$(wjson "$W" Write "$G/artifact/out/x.md")"; rc=$?
assert_exit_code 2 "$rc" "symlinked artifact entry to outside dir denied without approval"
touch "$G/approvals/Write"
h "$(wjson "$W" Write "$G/artifact/out/x.md")"; rc=$?
assert_exit_code 2 "$rc" "symlinked artifact entry to outside dir denied even with approval"
assert_file_exists "$G/approvals/Write" "symlinked artifact entry denial does not consume approval"
rm -f "$G/artifact/out"

[ -f "$G/goal.md" ] || echo goal > "$G/goal.md"
ln "$G/goal.md" "$G/artifact/h.md"
h "$(wjson "$W" Write "$G/artifact/h.md")"; rc=$?
assert_exit_code 2 "$rc" "hard-linked goal.md inside artifact denied even with approval"
assert_file_exists "$G/approvals/Write" "hard-linked goal.md denial does not consume approval"
rm -f "$G/artifact/h.md"

h "$(wjson "$W" Write "$TMP/outside-approved.md")"; rc=$?
assert_exit_code 0 "$rc" "approvals/Write allows outside write once"
assert_file_not_exists "$G/approvals/Write" "approvals/Write consumed by outside write"
h "$(wjson "$W" Write "$TMP/outside-approved.md")"; rc=$?
assert_exit_code 2 "$rc" "approvals/Write is one-shot for outside write"

W2="$TMP/w2"; mkdir -p "$W2/.claude"
printf '%s\n' "$TMP/no-such-g" > "$W2/.claude/.vdgg-watch-active"
h "$(tjson "$W2" Read)"; rc=$?
assert_exit_code 2 "$rc" "marker pointing to missing G denied"

BIN="$TMP/bin"; mkdir -p "$BIN"
nojq() { printf '%s' "$1" | PATH="$BIN" /bin/bash "$HOOK" >/dev/null 2>&1; }
nojq "$(wjson "$W" Write "$G/artifact/x.md")"; rc=$?
assert_exit_code 2 "$rc" "jq missing with active marker denies"
nojq "$(tjson "$W0" Read)"; rc=$?
assert_exit_code 2 "$rc" "jq missing denies even without active marker"

touch "$G/approvals/Write"
h "$(wjson "$W" Write "$G/artifact/nope/../../approvals/Bash")"; rc=$?
assert_exit_code 2 "$rc" "dot-dot through a missing dir denied even with approval"
assert_file_exists "$G/approvals/Write" "denied write does not consume approval"
rm -f "$G/approvals/Write"

touch "$G/approvals/Write"
h "$(wjson "$W" Write "$G/chec$(printf '\xe2\x84\xaa')s.lock")"; rc=$?
assert_exit_code 2 "$rc" "non-ASCII kelvin-sign checks.lock lookalike denied"
assert_file_exists "$G/approvals/Write" "non-ASCII path denial does not consume approval"

GR="$(cd -P "$G" && pwd -P)"
if [ -d "/System/Volumes/Data$GR" ]; then
    h "$(wjson "$W" Write "/System/Volumes/Data$GR/checks.lock")"; rc=$?
    assert_exit_code 2 "$rc" "/System/Volumes/Data-aliased checks.lock denied by name even without checks.lock present"
    h "$(wjson "$W" Write "/System/Volumes/Data$GR/goal.md")"; rc=$?
    assert_exit_code 2 "$rc" "/System/Volumes/Data-aliased goal.md denied by file identity"
fi

rm -rf "$G/evidence"
h "$(wjson "$W" Write "$G/evidence")"; rc=$?
assert_exit_code 2 "$rc" "removed evidence directory itself denied as protected name"
mkdir -p "$G/evidence"

ln -s ../approvals "$G/artifact/ap"
h "$(wjson "$W" Write "$G/artifact/ap/Bash")"; rc=$?
assert_exit_code 2 "$rc" "symlinked artifact entry into approvals denied even with approval"
rm -f "$G/artifact/ap"

assert_file_exists "$G/approvals/Write" "all new protected-path cases leave approval unconsumed"
rm -f "$G/approvals/Write"

touch "$G/approvals/Write"
ln -s "$G/approvals" "$TMP/ap"
h "$(wjson "$W" Write "$TMP/ap/Bash")"; rc=$?
assert_exit_code 2 "$rc" "outside-G link into approvals denied even with approval"
assert_file_exists "$G/approvals/Write" "denied outside link does not consume approval"
rm -f "$TMP/ap"
ln -s "$G/checks/a.sh" "$TMP/l"
h "$(wjson "$W" Write "$TMP/l")"; rc=$?
assert_exit_code 2 "$rc" "outside-G link to a check file denied even with approval"
assert_file_exists "$G/approvals/Write" "denied link target does not consume approval"
rm -f "$TMP/l" "$G/approvals/Write"

touch "$G/approvals/Write"
ln -s "$G" "$TMP/gl"
h "$(wjson "$W" Write "$TMP/gl/調査.md")"; rc=$?
assert_exit_code 2 "$rc" "outside-G symlink to G root denied even with approval"
assert_file_exists "$G/approvals/Write" "denied symlink-to-G-root write does not consume approval"
rm -f "$TMP/gl" "$G/approvals/Write"

h "$(wjson "$W" Write "$G/artifact/調査.md")"; rc=$?
assert_exit_code 0 "$rc" "Japanese artifact name allowed"
touch "$G/approvals/Write"
h "$(wjson "$W" Write "$G/調査.md")"; rc=$?
assert_exit_code 2 "$rc" "non-ASCII name outside artifact denied even with approval"
assert_file_exists "$G/approvals/Write" "denied non-ASCII write does not consume approval"
rm -f "$G/approvals/Write"

WA="$G/artifact/w"; mkdir -p "$WA/.claude"
printf '%s\n' "$G" > "$WA/.claude/.vdgg-watch-active"
h "$(wjson "$WA" Write "$WA/.claude/.vdgg-watch-active")"; rc=$?
assert_exit_code 2 "$rc" "marker inside artifact cannot be rewritten"
h "$(wjson "$W" Write "$G/artifact/x.md")"; rc=$?
assert_exit_code 0 "$rc" "artifact write still allowed from the normal cwd"
h "$(wjson "$WA" Write "$WA/.claude/settings.local.json")"; rc=$?
assert_exit_code 2 "$rc" "control files under cwd/.claude inside artifact denied"
rm -rf "$WA"

SK="$G/artifact/sk"; mkdir -p "$SK"
cp -R "$ROOT/skills/vdgg-watch/." "$SK/"
hk() { printf '%s' "$1" | /bin/bash "$SK/scripts/vdgg-watch-hook.sh" >/dev/null 2>&1; }
hk "$(wjson "$W" Write "$SK/SKILL.md")"; rc=$?
assert_exit_code 2 "$rc" "skill directory under artifact cannot be rewritten"
hk "$(wjson "$W" Write "$G/artifact/x.md")"; rc=$?
assert_exit_code 0 "$rc" "artifact write allowed when the skill sits under artifact"
rm -rf "$SK"

h "$(wjson "$W" Write "$TMP/報告.md")"; rc=$?
assert_exit_code 2 "$rc" "Japanese path outside G denied without approval"
touch "$G/approvals/Write"
h "$(wjson "$W" Write "$TMP/報告.md")"; rc=$?
assert_exit_code 0 "$rc" "Japanese path outside G allowed once with approval"
assert_file_not_exists "$G/approvals/Write" "approval consumed for outside Japanese path"

touch "$G/approvals/Write"
h "$(wjson "$W" Write "$G/caf$(printf '\xc3\xa9').md")"; rc=$?
assert_exit_code 2 "$rc" "non-ASCII letter outside artifact denied under a UTF-8 locale"
assert_file_exists "$G/approvals/Write" "UTF-8 locale denial does not consume approval"
rm -f "$G/approvals/Write"

# tick 起動中（マーカー2行目が tick ...）は done を拒否し、run は通す
WT="$TMP/wt"; mkdir -p "$WT/.claude"
printf '%s\ntick 1 1\n' "$G" > "$WT/.claude/.vdgg-watch-active"
h "$(bjson "$WT" "bash \"$WATCH\" done")"; rc=$?
assert_exit_code 2 "$rc" "done denied while tick owns the watch"
h "$(bjson "$WT" "bash \"$WATCH\" run \"$G\"")"; rc=$?
assert_exit_code 0 "$rc" "run allowed while tick owns the watch (first marker line is G)"
h "$(bjson "$W" "bash \"$WATCH\" done")"; rc=$?
assert_exit_code 0 "$rc" "done allowed for a manual watch"

echo "PASS: test-watch-hook"
