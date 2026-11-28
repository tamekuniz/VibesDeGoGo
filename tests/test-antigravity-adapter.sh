#!/bin/bash
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "$ROOT/tests/lib/assert.sh"

AGY_DIR="$ROOT/antigravity"
PRE="$AGY_DIR/scripts/vdgg-agy-pretool.sh"
POST="$AGY_DIR/scripts/vdgg-agy-posttool.sh"
STOP="$AGY_DIR/scripts/vdgg-agy-stop.sh"
PREINV="$AGY_DIR/scripts/vdgg-agy-preinvocation.sh"
CX_STATE="$ROOT/.agents/skills/vibesdegogo/scripts/vdgg-state.sh"

# --- Manifest & syntax checks ------------------------------------------------

assert_file_exists "$AGY_DIR/plugin.json" "antigravity plugin.json exists"
assert_file_exists "$AGY_DIR/hooks.json" "antigravity hooks.json exists"
assert_file_exists "$AGY_DIR/skills/vibesdegogo-agy/SKILL.md" "antigravity SKILL.md exists"

jq -e '.name == "vibesdegogo"' "$AGY_DIR/plugin.json" >/dev/null 2>&1
assert_exit_code 0 "$?" "plugin.json has valid name"

jq -e '.vibesdegogo.PreToolUse[0].matcher == "*" and (.vibesdegogo.Stop | type) == "array" and (.vibesdegogo.PreInvocation | type) == "array"' "$AGY_DIR/hooks.json" >/dev/null 2>&1
assert_exit_code 0 "$?" "hooks.json has valid Antigravity structure"

for s in "$AGY_DIR"/scripts/*.sh; do
  bash -n "$s"
  assert_exit_code 0 "$?" "bash -n passes for $(basename "$s")"
done

# --- Fixture repo ------------------------------------------------------------

TMP_REPO=$(mktemp -d "${TMPDIR:-/tmp}/vdgg-agy-test.XXXXXX")
trap 'rm -rf "$TMP_REPO"' EXIT

git -C "$TMP_REPO" init -q
git -C "$TMP_REPO" config user.email "test@example.com"
git -C "$TMP_REPO" config user.name "Test"
printf 'hello\nworld\n' > "$TMP_REPO/app.txt"
git -C "$TMP_REPO" add app.txt
git -C "$TMP_REPO" commit -q -m "init"

# Resolve physical path (macOS /var -> /private/var)
TMP_REPO=$(cd "$TMP_REPO" && pwd -P)

run_pre() {
  bash "$PRE" <<< "$1"
}
run_post() {
  bash "$POST" <<< "$1"
}
run_stop() {
  bash "$STOP" <<< "$1"
}
run_preinv() {
  bash "$PREINV" <<< "$1"
}

# --- 1. Unarmed repo: fail-open ----------------------------------------------

OUT=$(run_pre "$(jq -nc --arg cwd "$TMP_REPO" '{cwd:$cwd, toolCall:{name:"edit_file", args:{Path:"app.txt"}}}')")
assert_eq "allow" "$(printf '%s' "$OUT" | jq -r '.decision')" "unarmed edit_file is allowed"

OUT=$(run_preinv "$(jq -nc --arg cwd "$TMP_REPO" '{cwd:$cwd}')")
assert_eq "{}" "$OUT" "unarmed preinvocation returns empty json"

OUT=$(run_stop "$(jq -nc --arg cwd "$TMP_REPO" '{cwd:$cwd, terminationReason:"NO_TOOL_CALL"}')")
assert_eq "{}" "$OUT" "unarmed stop returns empty json"

# --- 2. VDGG_REQUIRED=on entry gate ------------------------------------------

printf 'VDGG_REQUIRED=on\n' > "$TMP_REPO/.vdgg-target"

OUT=$(run_pre "$(jq -nc --arg cwd "$TMP_REPO" '{cwd:$cwd, toolCall:{name:"edit_file", args:{Path:"app.txt"}}}')")
assert_eq "deny" "$(printf '%s' "$OUT" | jq -r '.decision')" "VDGG_REQUIRED=on denies unarmed edit_file"

OUT=$(run_pre "$(jq -nc --arg cwd "$TMP_REPO" '{cwd:$cwd, toolCall:{name:"read_file", args:{Path:"app.txt"}}}')")
assert_eq "allow" "$(printf '%s' "$OUT" | jq -r '.decision')" "VDGG_REQUIRED=on allows read_file"

rm -f "$TMP_REPO/.vdgg-target"

# --- 3. Armed session: PreInvocation & Step 3 read_file evidence -------------

(
  cd "$TMP_REPO"
  . "$CX_STATE"
  vdgg_state_init >/dev/null
  ID=$(vdgg_get_id)
  mkdir -p "tasks/vdgg/$ID"
  printf '## Goal\ntest\n\n## Constraints\nnone\n\n## Acceptance criteria\npass\n\n## Lessons Applied\nNone applicable\n' > "tasks/vdgg/$ID/requirements.md"
  vdgg_state_advance 2 requirements >/dev/null
  vdgg_state_advance 3 investigating >/dev/null
)
VDGG_ID=$(cat "$TMP_REPO/.codex/.vdgg-active")

OUT=$(run_preinv "$(jq -nc --arg cwd "$TMP_REPO" '{cwd:$cwd}')")
MSG=$(printf '%s' "$OUT" | jq -r '.injectSteps[0].systemMessage.systemMessage // empty')
assert_contains "$MSG" "id=${VDGG_ID}" "preinvocation injects active id"
assert_contains "$MSG" "phase=investigating" "preinvocation injects active phase"

# Direct edit during investigating must be denied
OUT=$(run_pre "$(jq -nc --arg cwd "$TMP_REPO" '{cwd:$cwd, toolCall:{name:"edit_file", args:{Path:"app.txt"}}}')")
assert_eq "deny" "$(printf '%s' "$OUT" | jq -r '.decision')" "edit_file is denied during investigating"

# Successful read_file records read evidence in PostToolUse
OUT=$(run_post "$(jq -nc --arg cwd "$TMP_REPO" --arg p "$TMP_REPO/app.txt" '{cwd:$cwd, toolCall:{name:"read_file", args:{Path:$p}}}')")
assert_eq "{}" "$OUT" "posttool returns empty json for read_file"
assert_file_exists "$TMP_REPO/.codex/.vdgg-read-${VDGG_ID}" "read log created by read_file PostToolUse"
grep -qxF "app.txt" "$TMP_REPO/.codex/.vdgg-read-${VDGG_ID}"
assert_exit_code 0 "$?" "read log contains normalized app.txt"

# Failed read_file does NOT record read evidence
OUT=$(run_post "$(jq -nc --arg cwd "$TMP_REPO" --arg p "$TMP_REPO/missing.txt" '{cwd:$cwd, error:"file not found", toolCall:{name:"read_file", args:{Path:$p}}}')")
! grep -qxF "missing.txt" "$TMP_REPO/.codex/.vdgg-read-${VDGG_ID}"
assert_exit_code 0 "$?" "failed read_file is not recorded in read log"

# --- 4. PostToolUse error tracking & [Error Acknowledged] --------------------

OUT=$(run_post "$(jq -nc --arg cwd "$TMP_REPO" '{cwd:$cwd, error:"exit status 1", toolCall:{name:"run_command", args:{CommandLine:"false"}}}')")
assert_eq "{}" "$OUT" "posttool returns empty json on failed run_command"
assert_file_exists "$TMP_REPO/.codex/.vdgg-error-pending" "error-pending flag created after failed run_command"

OUT=$(run_pre "$(jq -nc --arg cwd "$TMP_REPO" '{cwd:$cwd, toolCall:{name:"run_command", args:{CommandLine:"echo next"}}}')")
assert_eq "deny" "$(printf '%s' "$OUT" | jq -r '.decision')" "next run_command without [Error Acknowledged] is denied"

OUT=$(run_pre "$(jq -nc --arg cwd "$TMP_REPO" '{cwd:$cwd, toolCall:{name:"run_command", args:{CommandLine:"# [Error Acknowledged] retrying\necho next"}}}')")
assert_eq "allow" "$(printf '%s' "$OUT" | jq -r '.decision')" "run_command with [Error Acknowledged] is allowed"

# --- 5. Stop hook: transcript parsing, Intentional Stop, cancel, cap ---------

TRANSCRIPT="$TMP_REPO/transcript.jsonl"
cat > "$TRANSCRIPT" <<'EOF'
{"step_index":0,"source":"USER_EXPLICIT","type":"USER_INPUT","content":"do it"}
{"step_index":1,"source":"MODEL","type":"PLANNER_RESPONSE","content":"I finished part of it."}
EOF

OUT=$(run_stop "$(jq -nc --arg cwd "$TMP_REPO" --arg tp "$TRANSCRIPT" '{cwd:$cwd, transcriptPath:$tp, terminationReason:"NO_TOOL_CALL", continuationActive:false, executionNum:0}')")
assert_eq "continue" "$(printf '%s' "$OUT" | jq -r '.decision')" "active session without [Intentional Stop] returns continue"

cat > "$TRANSCRIPT" <<'EOF'
{"step_index":0,"source":"USER_EXPLICIT","type":"USER_INPUT","content":"do it"}
{"step_index":1,"source":"MODEL","type":"PLANNER_RESPONSE","content":"[Intentional Stop] Waiting for user approval."}
EOF

OUT=$(run_stop "$(jq -nc --arg cwd "$TMP_REPO" --arg tp "$TRANSCRIPT" '{cwd:$cwd, transcriptPath:$tp, terminationReason:"NO_TOOL_CALL", continuationActive:false, executionNum:0}')")
assert_eq "{}" "$OUT" "stop with [Intentional Stop] in PLANNER_RESPONSE allows stop"

# USER_CANCELED always allows stop
cat > "$TRANSCRIPT" <<'EOF'
{"step_index":1,"source":"MODEL","type":"PLANNER_RESPONSE","content":"stopped mid-way"}
EOF
OUT=$(run_stop "$(jq -nc --arg cwd "$TMP_REPO" --arg tp "$TRANSCRIPT" '{cwd:$cwd, transcriptPath:$tp, terminationReason:"USER_CANCELED", continuationActive:false, executionNum:0}')")
assert_eq "{}" "$OUT" "USER_CANCELED allows stop"

# continuationActive cap at executionNum >= 3 prevents infinite loop
OUT=$(run_stop "$(jq -nc --arg cwd "$TMP_REPO" --arg tp "$TRANSCRIPT" '{cwd:$cwd, transcriptPath:$tp, terminationReason:"NO_TOOL_CALL", continuationActive:true, executionNum:3}')")
assert_eq "{}" "$OUT" "continuationActive with executionNum=3 allows stop"

# --- 6. Step 6 patch-first enforcement on edit_file / write_file -------------

(
  cd "$TMP_REPO"
  . "$CX_STATE"
  ID=$(vdgg_get_id)
  cat > "tasks/vdgg/$ID/investigation.md" <<'EOF'
## 1. Related files
- `app.txt`
## 2. Existing implementation patterns
plain text
## 3. Impact surface
app.txt
## 4. Prior similar implementations
none
## 5. Side effects and risks
low
## 6. Constraints
none
## 7. Verification strategy
grep
EOF
  vdgg_state_advance 4 planning >/dev/null
  cat > "tasks/vdgg/$ID/todo.md" <<'EOF'
## T1: update greeting

### Location
`app.txt:1`

### Excerpt
```txt
hello
world
```

### Intent
Change hello to hi.
EOF
  printf '# Progress\n' > "tasks/vdgg/$ID/progress.md"
  vdgg_state_advance 5 task-selected >/dev/null
  vdgg_task_begin "T1: update greeting" app.txt >/dev/null
  vdgg_state_advance 6 implementing >/dev/null
)

OUT=$(run_pre "$(jq -nc --arg cwd "$TMP_REPO" '{cwd:$cwd, toolCall:{name:"edit_file", args:{Path:"app.txt"}}}')")
assert_eq "deny" "$(printf '%s' "$OUT" | jq -r '.decision')" "direct edit_file on implementation file is denied in Step 6"

OUT=$(run_pre "$(jq -nc --arg cwd "$TMP_REPO" --arg p "tasks/vdgg/${VDGG_ID}/patch/T1.patch" '{cwd:$cwd, toolCall:{name:"write_file", args:{Path:$p}}}')")
assert_eq "allow" "$(printf '%s' "$OUT" | jq -r '.decision')" "write_file on task patch note is allowed in Step 6"

echo "PASS: antigravity adapter tests"
