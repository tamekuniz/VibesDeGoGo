#!/bin/bash
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "$ROOT/tests/lib/assert.sh"

SCRIPT="$ROOT/skills/vdgg-watch/scripts/vdgg-watch.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# 全チェック合格・成果物あり・fit.md 完備の目標ディレクトリを作る
mkgoal() {
    mkdir -p "$1/checks" "$1/artifact" "$1/approvals"
    printf 'goal\nallow_tools: Bash\n' > "$1/goal.md"
    echo "exit 0" > "$1/checks/ok.sh"
    echo "x" > "$1/artifact/a.md"
    printf '## 過剰\n\n## 不足\n' > "$1/fit.md"
}

w() { bash "$SCRIPT" "$@" >/dev/null 2>&1; }

# start / done
W="$TMP/w"; mkdir -p "$W"
G="$TMP/g1"; mkgoal "$G"
(cd "$W" && w start "$TMP/none"); rc=$?
assert_exit_code 1 "$rc" "start: missing dir"
(cd "$W" && w start "$G"); rc=$?
assert_exit_code 0 "$rc" "start"
assert_file_exists "$W/.claude/.vdgg-watch-active" "marker created"
(cd "$W" && w start "$G"); rc=$?
assert_exit_code 1 "$rc" "start while watching"
(cd "$W" && w done); rc=$?
assert_exit_code 0 "$rc" "done"
assert_file_not_exists "$W/.claude/.vdgg-watch-active" "marker removed"
(cd "$W" && w done); rc=$?
assert_exit_code 0 "$rc" "done without marker"

# lock
G0="$TMP/g0"; mkgoal "$G0"; rm "$G0/checks/ok.sh"
w lock "$G0"; rc=$?
assert_exit_code 1 "$rc" "lock with no checks"

# run before lock
w run "$G"; rc=$?
assert_exit_code 1 "$rc" "run before lock"

# all pass
w lock "$G"; rc=$?
assert_exit_code 0 "$rc" "lock"
assert_contains "$(cat "$G/checks.lock")" "allow_tools: Bash" "lock records allow_tools"
w run "$G"; rc=$?
assert_exit_code 0 "$rc" "run all pass"
assert_eq 1 "$(ls "$G/evidence" | wc -l | tr -d ' ')" "one evidence log"
assert_file_not_exists "$G/proposal.md" "no proposal on pass"

# empty artifact
rm "$G/artifact/a.md"
w run "$G"; rc=$?
assert_exit_code 3 "$rc" "empty artifact"
echo x > "$G/artifact/a.md"

# fit.md headings missing
echo '## 過剰' > "$G/fit.md"
w run "$G"; rc=$?
assert_exit_code 3 "$rc" "fit.md missing heading"
printf '## 過剰\n\n## 不足\n' > "$G/fit.md"

# failing check -> proposal with 4 headings
G2="$TMP/g2"; mkgoal "$G2"
printf 'echo boom\nexit 1\n' > "$G2/checks/bad.sh"
w lock "$G2"
w run "$G2"; rc=$?
assert_exit_code 3 "$rc" "failing check"
P="$(cat "$G2/proposal.md")"
for h in "## 何が崩れたか" "## 根拠" "## 修正案" "## 承認の仕方"; do
    assert_contains "$P" "$h" "proposal heading"
done
assert_contains "$P" "bad.sh" "proposal names failed check"
assert_contains "$P" "boom" "proposal shows output"

# done is blocked until 修正案 is filled
(cd "$W" && w start "$G2")
(cd "$W" && w done); rc=$?
assert_exit_code 1 "$rc" "done with placeholder"
printf '## 修正案\nfix it\n\n## 承認の仕方\n' > "$G2/proposal.md"
(cd "$W" && w done); rc=$?
assert_exit_code 0 "$rc" "done after filling"
assert_file_not_exists "$W/.claude/.vdgg-watch-active" "marker removed after fill"

# tamper
echo "# x" >> "$G/checks/ok.sh"
err="$(bash "$SCRIPT" run "$G" 2>&1 >/dev/null)"; rc=$?
assert_exit_code 4 "$rc" "tampered check"
assert_contains "$err" "ok.sh" "tamper names file"

# relock
w lock "$G"; rc=$?
assert_exit_code 1 "$rc" "relock without approval"
touch "$G/approvals/relock"
w lock "$G"; rc=$?
assert_exit_code 0 "$rc" "relock with approval"
assert_file_not_exists "$G/approvals/relock" "relock approval consumed"
w run "$G"; rc=$?
assert_exit_code 0 "$rc" "run after relock"

# empty 修正案 is rejected too, not just the placeholder text
G3="$TMP/g3"; mkgoal "$G3"
printf 'exit 1\n' > "$G3/checks/bad.sh"
w lock "$G3"
w run "$G3"
printf '## 修正案\n\n## 承認の仕方\n' > "$G3/proposal.md"
(cd "$W" && w start "$G3")
(cd "$W" && w done); rc=$?
assert_exit_code 1 "$rc" "done with empty 修正案"
rm -f "$G3/proposal.md"
(cd "$W" && w done)

# tampering a non-.sh helper file under checks/ is detected too
G4="$TMP/g4"; mkgoal "$G4"
echo "helper data" > "$G4/checks/helper.txt"
w lock "$G4"; rc=$?
assert_exit_code 0 "$rc" "lock with non-.sh helper file"
echo "tampered" >> "$G4/checks/helper.txt"
err="$(bash "$SCRIPT" run "$G4" 2>&1 >/dev/null)"; rc=$?
assert_exit_code 4 "$rc" "tampered non-.sh helper file"
assert_contains "$err" "helper.txt" "tamper names non-.sh file"

# symlinks in checks/ are rejected by lock and run
G5="$TMP/g5"; mkgoal "$G5"
ln -s "$G5/artifact/a.md" "$G5/checks/evil.sh"
w lock "$G5"; rc=$?
assert_exit_code 1 "$rc" "lock rejects symlink in checks"

G6="$TMP/g6"; mkgoal "$G6"
w lock "$G6"; rc=$?
assert_exit_code 0 "$rc" "lock before symlink added"
ln -s "$G6/artifact/a.md" "$G6/checks/evil.sh"
w run "$G6"; rc=$?
assert_exit_code 4 "$rc" "run rejects symlink in checks"

echo "PASS: test-watch"
