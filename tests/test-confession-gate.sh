#!/bin/bash
# test-confession-gate.sh — Claude Code edition: the Step 8.5 confession gate,
# driven through the real PreToolUse hook (JSON in, exit code out) and the real
# state helpers. `vdgg_state_advance 9 commit` from progress needs a complete
# confession.md and an audit bound to that exact confession.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "$ROOT/tests/lib/assert.sh"

PRETOOL="$ROOT/skills/vibesdegogo/scripts/vdgg-hook-pretool.sh"
STATE_SH="$ROOT/skills/vibesdegogo/scripts/vdgg-state.sh"
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
TASKS="$T/tasks/vdgg/test-id"
ADV9='vdgg_state_advance 9 commit'

mkdir -p "$T/.claude" "$TASKS/evidence"
printf 'test-id\n' > "$T/.claude/.vdgg-active"
cat > "$T/.claude/.vdgg-state-test-id" <<'EOF'
step=8
phase=progress
loop_count=0
current_task=T1: x
vdgg_id=test-id
last_updated=2026-10-16T00:00:00Z
EOF

run_hook() {
    printf '%s' "$1" | bash "$PRETOOL" >/dev/null 2>"$T/hook.err"
    # zsh: $status is read-only, so the exit code goes to rc.
    local rc=$?
    printf '%s\n' "$rc"
}

bash_json() {
    jq -nc --arg c "$1" --arg cwd "$T" '{tool_name:"Bash",cwd:$cwd,tool_input:{command:$c}}'
}

write_json() {
    jq -nc --arg f "$1" --arg cwd "$T" '{tool_name:"Write",cwd:$cwd,tool_input:{file_path:$f,content:"x"}}'
}

# Mark the audit as passed for the confession as it is now.
audit_ok() {
    (cd "$T" && . "$ROOT/skills/vibesdegogo/scripts/vdgg-evidence.sh" \
        && printf 'confession=%s\n' "$(_vdgg_ev_hash "$TASKS/confession.md")") > "$T/.claude/.vdgg-audit-test-id"
}

printf '## Acceptance criteria\n- builds without warnings\n- toggles a model on and off\n' > "$TASKS/requirements.md"
printf 'progress\n' > "$TASKS/progress.md"
printf 'cargo build ok\n' > "$TASKS/evidence/build.txt"
printf 'toggled\n' > "$TASKS/evidence/toggle.txt"
printf -- '- F1 [medium] slow lsof → low（根拠: 実測 60ms）\n- F2 [high] crash → 修正\n- F3 [low] naming → followup\n' > "$TASKS/findings.md"

# A complete confession; each case below breaks one thing.
good_confession() {
    cat > "$TASKS/confession.md" <<'EOF'
## 受け入れ条件の照合表
- [検証済み] 警告なしでビルドできる — cargo build を実行 — evidence/build.txt
- [検証済み] モデルをオンオフできる — 画面で切り替えた — evidence/toggle.txt

## severity 格下げ
- F1 lsof の呼び出し回数 medium → low。根拠: 実測 60ms

## ゲートの形式回避
なし（確認方法: friction ログに deny がないことを確認）

## 範囲縮小
なし（確認方法: progress.md に residue がないことを確認）

## ゲート誤合格
なし（確認方法: すべてのゲートの終了コードを見直した）
EOF
}

# ------------------------------------------------------------- complete case
good_confession
audit_ok
assert_exit_code 0 "$(run_hook "$(bash_json "$ADV9")")" "a complete, audited confession opens Step 9"

# ---------------------------------------------------------------- confession
rm -f "$TASKS/confession.md"
assert_exit_code 2 "$(run_hook "$(bash_json "$ADV9")")" "no confession blocks Step 9"
assert_contains "$(cat "$T/hook.err")" "confession.md is missing" "the refusal names the missing confession"

good_confession
sed -i.bak '/^## ゲート誤合格/,$d' "$TASKS/confession.md" && rm -f "$TASKS/confession.md.bak"
audit_ok
assert_exit_code 2 "$(run_hook "$(bash_json "$ADV9")")" "a missing section blocks Step 9"
assert_contains "$(cat "$T/hook.err")" "ゲート誤合格" "the refusal names the missing section"

good_confession
sed -i.bak 's/^なし（確認方法: すべてのゲートの終了コードを見直した）$/なし/' "$TASKS/confession.md" && rm -f "$TASKS/confession.md.bak"
audit_ok
assert_exit_code 2 "$(run_hook "$(bash_json "$ADV9")")" "なし without 確認方法 blocks Step 9"
assert_contains "$(cat "$T/hook.err")" "確認方法" "the refusal asks how it was checked"

# -------------------------------------------------------------------- ledger
good_confession
sed -i.bak '/evidence\/toggle.txt/d' "$TASKS/confession.md" && rm -f "$TASKS/confession.md.bak"
audit_ok
assert_exit_code 2 "$(run_hook "$(bash_json "$ADV9")")" "a ledger missing a criterion blocks Step 9"
assert_contains "$(cat "$T/hook.err")" "1 rows but requirements.md lists 2" "the refusal compares the counts"

good_confession
sed -i.bak 's/^- \[検証済み\] モデルをオンオフできる.*/- [未検証] モデルをオンオフできる — 時間がなかった/' "$TASKS/confession.md" && rm -f "$TASKS/confession.md.bak"
audit_ok
assert_exit_code 2 "$(run_hook "$(bash_json "$ADV9")")" "an unverified criterion blocks Step 9"
assert_contains "$(cat "$T/hook.err")" "cannot waive" "the refusal says the user cannot waive it"

good_confession
sed -i.bak 's/ — evidence\/toggle.txt//' "$TASKS/confession.md" && rm -f "$TASKS/confession.md.bak"
audit_ok
assert_exit_code 2 "$(run_hook "$(bash_json "$ADV9")")" "a verified row without evidence blocks Step 9"

good_confession
rm -f "$TASKS/evidence/toggle.txt"
audit_ok
assert_exit_code 2 "$(run_hook "$(bash_json "$ADV9")")" "a missing evidence file blocks Step 9"
assert_contains "$(cat "$T/hook.err")" "evidence/toggle.txt" "the refusal names the missing file"
printf 'toggled\n' > "$TASKS/evidence/toggle.txt"

# -------------------------------------------------------------- downgrades
good_confession
sed -i.bak 's/^- F1 .*/なし（確認方法: findings.md を見た）/' "$TASKS/confession.md" && rm -f "$TASKS/confession.md.bak"
audit_ok
assert_exit_code 2 "$(run_hook "$(bash_json "$ADV9")")" "an unfixed medium finding missing from the downgrades blocks Step 9"
assert_contains "$(cat "$T/hook.err")" "F1" "the refusal names the finding"

mv "$TASKS/findings.md" "$TASKS/findings.md.keep"
good_confession
audit_ok
assert_exit_code 2 "$(run_hook "$(bash_json "$ADV9")")" "no findings.md blocks Step 9"
mv "$TASKS/findings.md.keep" "$TASKS/findings.md"

# ------------------------------------------------- friction log and residue
good_confession
audit_ok
printf 'deny phase=implementing loop=0 tool=Bash gate=429\n' > "$T/.claude/.vdgg-friction-test-id"
assert_exit_code 2 "$(run_hook "$(bash_json "$ADV9")")" "refused calls with 形式回避 なし block Step 9"
assert_contains "$(cat "$T/hook.err")" "refused tool calls" "the refusal points at the friction log"
rm -f "$T/.claude/.vdgg-friction-test-id"

printf -- '- TF1 residue: cosmetic\n' > "$TASKS/progress.md"
assert_exit_code 2 "$(run_hook "$(bash_json "$ADV9")")" "residue with 範囲縮小 なし blocks Step 9"
printf 'progress\n' > "$TASKS/progress.md"

# --------------------------------------------------------------------- audit
good_confession
rm -f "$T/.claude/.vdgg-audit-test-id"
assert_exit_code 2 "$(run_hook "$(bash_json "$ADV9")")" "no audit blocks Step 9"
assert_contains "$(cat "$T/hook.err")" "vdgg_audit_run" "the refusal names the audit helper"
audit_ok
printf '\n' >> "$TASKS/confession.md"
assert_exit_code 2 "$(run_hook "$(bash_json "$ADV9")")" "editing the confession after the audit blocks Step 9"

# The audit helper runs a fresh-context claude (a fake one here) and records
# the verdict only for 一致.
mkdir -p "$T/bin"
cat > "$T/bin/claude" <<'EOF'
#!/bin/sh
cat >/dev/null
printf '食い違い: なし\n%s\n' "$FAKE_VERDICT"
EOF
chmod +x "$T/bin/claude"
good_confession
rm -f "$T/.claude/.vdgg-audit-test-id"
(
    cd "$T" && PATH="$T/bin:$PATH" FAKE_VERDICT='監査判定: 不一致' VDGG_CONFIG_DIR="$T/cfg" bash -c ". '$STATE_SH' && vdgg_audit_run" >/dev/null 2>&1
)
assert_file_not_exists "$T/.claude/.vdgg-audit-test-id" "a 不一致 verdict records no audit"
assert_file_exists "$TASKS/audit-input.md" "the auditor's input is written"
assert_contains "$(cat "$TASKS/audit-input.md")" "===== confession.md =====" "the auditor reads the confession"
(
    cd "$T" && PATH="$T/bin:$PATH" FAKE_VERDICT='監査判定: 一致' VDGG_CONFIG_DIR="$T/cfg" bash -c ". '$STATE_SH' && vdgg_audit_run" >/dev/null 2>&1
)
assert_file_exists "$T/.claude/.vdgg-audit-test-id" "a 一致 verdict records the audit"
assert_exit_code 0 "$(run_hook "$(bash_json "$ADV9")")" "the recorded audit opens Step 9"

# -------------------------------------------------- writes during progress
assert_exit_code 0 "$(run_hook "$(write_json "$TASKS/confession.md")")" "confession.md is writable in progress"
assert_exit_code 0 "$(run_hook "$(write_json "$TASKS/evidence/shot.png")")" "evidence files are writable in progress"
assert_exit_code 0 "$(run_hook "$(write_json "$TASKS/findings.md")")" "findings.md is writable in progress"
assert_exit_code 2 "$(run_hook "$(write_json "$T/.claude/.vdgg-audit-test-id")")" "the audit sentinel is not writable"

# ------------------------------------------------- summary and lessons on clear
OUT=$(cd "$T" && bash -c ". '$STATE_SH' && vdgg_state_clear" 2>/dev/null)
assert_contains "$OUT" "confession=未検証 0 件 ／ 格下げ 1 件 ／ 回避 0 件" "clear prints the summary line"
assert_contains "$(cat "$TASKS/lessons.md")" "[告白: severity 格下げ] F1" "clear carries the downgrade into lessons.md"

echo "confession gate: all checks passed"
