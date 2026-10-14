#!/bin/bash
set -u
export LC_ALL=en_US.UTF-8
if [ "$(locale charmap 2>/dev/null)" != "UTF-8" ]; then
    echo "NOTE: en_US.UTF-8 が無いため UTF-8 での回帰は未検証" >&2
fi
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
assert_file_not_exists "$G/evidence/.last-broken" "pass clears last failure record"

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

# 同じ崩れが続く間は記入済みの proposal.md を保って黙り、崩れ方が変われば再通知する
G30="$TMP/g30"; mkgoal "$G30"
printf 'cat artifact/a.md\nexit 1\n' > "$G30/checks/bad.sh"
w lock "$G30"
w run "$G30"; rc=$?
assert_exit_code 3 "$rc" "first failure notifies"
w run "$G30"; rc=$?
assert_exit_code 3 "$rc" "same failure with unfilled 修正案 notifies again"
printf '## 修正案\nfix it\n' > "$G30/proposal.md"
n="$(ls "$G30/evidence" | wc -l | tr -d ' ')"
w run "$G30"; rc=$?
assert_exit_code 5 "$rc" "same failure stays quiet"
assert_contains "$(cat "$G30/proposal.md")" "fix it" "same failure keeps filled proposal"
assert_eq "$((n + 1))" "$(ls "$G30/evidence" | wc -l | tr -d ' ')" "same failure still saves evidence"
echo y > "$G30/artifact/a.md"
w run "$G30"; rc=$?
assert_exit_code 3 "$rc" "changed failure notifies again"
assert_contains "$(cat "$G30/proposal.md")" "(未記入" "changed failure resets 修正案"
# proposal に載る末尾5行より上だけが変わっても、崩れ方の変化として再通知する
printf 'a\n1\n2\n3\n4\n5\n' > "$G30/artifact/a.md"
w run "$G30"
printf '## 修正案\nfix it\n' > "$G30/proposal.md"
printf 'b\n1\n2\n3\n4\n5\n' > "$G30/artifact/a.md"
w run "$G30"; rc=$?
assert_exit_code 3 "$rc" "change above the last 5 output lines notifies again"

# チェックには呼び出し元のロケールが渡り、元が未設定なら未設定のまま渡る
G31="$TMP/g31"; mkgoal "$G31"
printf 'echo "lc=${LC_ALL-unset}"\nexit 1\n' > "$G31/checks/lc.sh"
w lock "$G31"
w run "$G31"
assert_contains "$(cat "$G31/proposal.md")" "lc=en_US.UTF-8" "check sees caller LC_ALL"
(unset LC_ALL; w run "$G31")
assert_contains "$(cat "$G31/proposal.md")" "lc=unset" "check sees unset LC_ALL"

# tick: 証拠ログの鮮度でキックするかどうかを判定する
mkfake() {
    local bin="$1" marker="$2" calls="$3" mline="$4" pidfile="$5"
    local selfsleep="${6:-0}" childsleep="${7:-1}" ignoreterm="${8:-0}"
    : > "$bin"
    printf '#!/bin/bash\n' >> "$bin"
    printf 'printf "CALL\\n" >> %s\n' "$calls" >> "$bin"
    printf 'printf "%%s\\n" "$@" >> %s\n' "$calls" >> "$bin"
    printf 'if [ -e %s ]; then sed -n 2p %s > %s; else : > %s; fi\n' "$marker" "$marker" "$mline" "$mline" >> "$bin"
    if [ "$ignoreterm" = "1" ]; then
        printf 'trap "" TERM\n' >> "$bin"
    fi
    printf 'sleep %s &\n' "$childsleep" >> "$bin"
    printf 'printf "%%s\\n%%s\\n" "$$" "$!" > %s\n' "$pidfile" >> "$bin"
    printf 'sleep %s\n' "$selfsleep" >> "$bin"
    printf 'exit 0\n' >> "$bin"
    chmod +x "$bin"
}
CALLS="$TMP/claude-calls"; MLINE="$TMP/claude-mline"; FAKE="$TMP/fake-claude.sh"; PIDFILE="$TMP/claude-pids"
# tick を出力を捨てて呼ぶ。引数: claude の代わり 上限秒 <G> 間隔秒(PID を使う背景実行はここを通さない)
tk() {
    local c="$1" t="$2"
    shift 2
    VDGG_WATCH_CLAUDE="$c" VDGG_WATCH_TIMEOUT="$t" bash "$SCRIPT" tick "$@" >/dev/null 2>&1
}

# (a) 新しい証拠があれば呼ばれない
G8="$TMP/g8"; mkdir -p "$G8/evidence"
echo x > "$G8/evidence/fresh.log"
mkfake "$FAKE" "$G8/.claude/.vdgg-watch-active" "$CALLS" "$MLINE" "$PIDFILE"
rm -f "$CALLS"
tk "$FAKE" 5 "$G8" 3600; rc=$?
assert_exit_code 0 "$rc" "tick: fresh evidence exits 0"
assert_file_not_exists "$CALLS" "tick: fresh evidence does not call claude"

# (b) 証拠が無ければ1回呼ばれ、引数・マーカー・checks.lock の allow_tools が仕様どおり
G7="$TMP/g7"; mkgoal "$G7"
printf 'goal\nallow_tools: Bash,Task\n' > "$G7/goal.md"
w lock "$G7"
MARKER7="$G7/.claude/.vdgg-watch-active"
mkfake "$FAKE" "$MARKER7" "$CALLS" "$MLINE" "$PIDFILE"
rm -f "$CALLS" "$MLINE" "$PIDFILE"
tk "$FAKE" 5 "$G7" 60; rc=$?
assert_exit_code 0 "$rc" "tick: no evidence calls claude"
assert_file_exists "$CALLS" "tick: claude was invoked"
ARGS="$(cat "$CALLS")"
if ! grep -Fxq -- "-p" "$CALLS"; then
    fail "tick args: -p must appear as its own argument"
fi
if ! awk '$0=="--permission-mode"{getline nxt; if (nxt=="dontAsk") f=1} END{exit !f}' "$CALLS"; then
    fail "tick args: --permission-mode must be immediately followed by dontAsk"
fi
assert_contains "$ARGS" "--settings" "tick args: settings flag"
assert_contains "$ARGS" "vdgg-watch-hook.sh" "tick args: hook path in settings"
if ! grep -Eq "vdgg-watch-hook\.sh['\"]? tick( |\$)" "$CALLS"; then
    fail "tick args: hook command must pass the tick mark"
fi
assert_contains "$ARGS" "SKILL.md" "tick args: SKILL.md path in prompt"
assert_contains "$ARGS" "目標: $G7" "tick args: goal in prompt"
assert_contains "$ARGS" "Task" "tick args: checks.lock allow_tools tool present"
case "$ARGS" in
    *Skill*) fail "tick args: Skill must not be in allowedTools" ;;
esac
MLINE_CONTENT="$(cat "$MLINE")"
case "$MLINE_CONTENT" in
    "tick "*) ;;
    *) fail "tick: marker during call was not 'tick <pid>' (got '$MLINE_CONTENT')" ;;
esac
assert_file_not_exists "$MARKER7" "tick: marker removed after claude exits"

# (c) 古い証拠があれば呼ばれる
G9="$TMP/g9"; mkdir -p "$G9/evidence"
touch -t 202001010000 "$G9/evidence/old.log"
mkfake "$FAKE" "$G9/.claude/.vdgg-watch-active" "$CALLS" "$MLINE" "$PIDFILE"
rm -f "$CALLS"
tk "$FAKE" 5 "$G9" 5; rc=$?
assert_exit_code 0 "$rc" "tick: old evidence calls claude"
assert_file_exists "$CALLS" "tick: old evidence triggers claude"

# (d) 生きた PID のマーカーがあれば呼ばれない
G10="$TMP/g10"; mkdir -p "$G10/.claude"
sleep 60 &
ALIVE=$!
printf '%s\ntick %s\n' "$G10" "$ALIVE" > "$G10/.claude/.vdgg-watch-active"
rm -f "$CALLS"
tk "$FAKE" 5 "$G10" 5; rc=$?
assert_exit_code 0 "$rc" "tick: alive tick pid does not call claude"
assert_file_not_exists "$CALLS" "tick: alive pid blocks claude"
assert_file_exists "$G10/.claude/.vdgg-watch-active" "tick: alive-pid marker left in place"
kill "$ALIVE" 2>/dev/null || true
wait "$ALIVE" 2>/dev/null || true

# (e) 死んだ PID のマーカーは消されて呼ばれる
G11="$TMP/g11"; mkdir -p "$G11/.claude"
( exit 0 ) &
DEADPID=$!
wait "$DEADPID" 2>/dev/null || true
printf '%s\ntick %s\n' "$G11" "$DEADPID" > "$G11/.claude/.vdgg-watch-active"
rm -f "$CALLS"
tk "$FAKE" 5 "$G11" 5; rc=$?
assert_exit_code 0 "$rc" "tick: dead pid marker gets cleaned and claude runs"
assert_file_exists "$CALLS" "tick: dead-pid marker triggers claude"

# (f) 間隔が不正なら usage
for bad in abc 0 010; do
    tk "$FAKE" 5 "$TMP/whatever" "$bad"; rc=$?
    assert_exit_code 1 "$rc" "tick: invalid interval '$bad' is rejected"
done

# (g) 起動元の cwd に関わらずマーカーは G 直下に作られる
G12="$TMP/g12"; mkgoal "$G12"; w lock "$G12"
mkfake "$FAKE" "$G12/.claude/.vdgg-watch-active" "$CALLS" "$MLINE" "$PIDFILE"
rm -f "$CALLS" "$MLINE"
(cd "$TMP" && tk "$FAKE" 5 "$G12" 5); rc=$?
assert_exit_code 0 "$rc" "tick: runs from outside G"
MLINE_CONTENT="$(cat "$MLINE")"
case "$MLINE_CONTENT" in
    "tick "*) ;;
    *) fail "tick: marker not created under G when invoked from outside cwd" ;;
esac
assert_file_not_exists "$G12/.claude/.vdgg-watch-active" "tick: marker cleaned up after run (cwd test)"

# (i) 上限時間を超えたら子を止めて exit 124
G13="$TMP/g13"; mkdir -p "$G13"
SLOWCLAUDE="$TMP/slow-claude.sh"
printf '#!/bin/bash\nsleep 5\n' > "$SLOWCLAUDE"
chmod +x "$SLOWCLAUDE"
start_ts=$(date +%s)
tk "$SLOWCLAUDE" 1 "$G13" 5; rc=$?
end_ts=$(date +%s)
assert_exit_code 124 "$rc" "tick: exceeding timeout returns 124"
elapsed=$(( end_ts - start_ts ))
if [ "$elapsed" -ge 5 ]; then
    fail "tick: timeout did not actually stop the child early (elapsed=${elapsed}s)"
fi
assert_file_not_exists "$G13/.claude/.vdgg-watch-active" "tick: marker removed after timeout kill"

# (j) 手動マーカー(1行のみ)が新しければ claude を呼ばず残る
G14="$TMP/g14"; mkdir -p "$G14/.claude"
printf '%s\n' "$G14" > "$G14/.claude/.vdgg-watch-active"
rm -f "$CALLS"
tk "$FAKE" 5 "$G14" 5; rc=$?
assert_exit_code 0 "$rc" "tick: fresh manual marker blocks claude"
assert_file_not_exists "$CALLS" "tick: fresh manual marker does not call claude"
assert_file_exists "$G14/.claude/.vdgg-watch-active" "tick: fresh manual marker left in place"

# (k) 手動マーカーが古ければ消されて claude が呼ばれる
G15="$TMP/g15"; mkdir -p "$G15/.claude"
printf '%s\n' "$G15" > "$G15/.claude/.vdgg-watch-active"
touch -t 202001010000 "$G15/.claude/.vdgg-watch-active"
mkfake "$FAKE" "$G15/.claude/.vdgg-watch-active" "$CALLS" "$MLINE" "$PIDFILE"
rm -f "$CALLS"
tk "$FAKE" 5 "$G15" 5; rc=$?
assert_exit_code 0 "$rc" "tick: stale manual marker is cleared and claude runs"
assert_file_exists "$CALLS" "tick: stale manual marker triggers claude"

# (l) 生きた PID でも上限+60秒より古いマーカーは消されて呼ばれる
G16="$TMP/g16"; mkdir -p "$G16/.claude"
sleep 60 &
ALIVE2=$!
printf '%s\ntick %s\n' "$G16" "$ALIVE2" > "$G16/.claude/.vdgg-watch-active"
touch -t 202001010000 "$G16/.claude/.vdgg-watch-active"
mkfake "$FAKE" "$G16/.claude/.vdgg-watch-active" "$CALLS" "$MLINE" "$PIDFILE"
rm -f "$CALLS"
tk "$FAKE" 5 "$G16" 5; rc=$?
assert_exit_code 0 "$rc" "tick: stale alive-pid marker (older than limit+60) is cleared and claude runs"
assert_file_exists "$CALLS" "tick: stale alive-pid marker triggers claude"
kill "$ALIVE2" 2>/dev/null || true
wait "$ALIVE2" 2>/dev/null || true

# (m) 証拠が増えないまま2回目の tick を呼んでも、間隔内なら再実行しない
G17="$TMP/g17"; mkdir -p "$G17"
mkfake "$FAKE" "$G17/.claude/.vdgg-watch-active" "$CALLS" "$MLINE" "$PIDFILE"
rm -f "$CALLS"
tk "$FAKE" 5 "$G17" 3600; rc=$?
assert_exit_code 0 "$rc" "tick: first run with no evidence calls claude"
assert_file_exists "$CALLS" "tick: first run invoked claude"
rm -f "$CALLS"
tk "$FAKE" 5 "$G17" 3600; rc=$?
assert_exit_code 0 "$rc" "tick: second run shortly after a failed run backs off"
assert_file_not_exists "$CALLS" "tick: last-tick timestamp prevents immediate re-run"

# (n) allow_tools が不正なら exit 2 になり、マーカーも作られない
G18="$TMP/g18"; mkgoal "$G18"
printf 'goal\nallow_tools: Bash,ba;d\n' > "$G18/goal.md"
w lock "$G18"
rm -f "$CALLS"
tk "$FAKE" 5 "$G18" 60; rc=$?
assert_exit_code 2 "$rc" "tick: invalid allow_tools exits 2"
assert_file_not_exists "$CALLS" "tick: invalid allow_tools does not call claude"
assert_file_not_exists "$G18/.claude/.vdgg-watch-active" "tick: invalid allow_tools leaves no marker"

# (o) 孫プロセスは上限超過後に残らない。TERM を無視する子にも上限+猶予で強制終了して exit 124。呼び出しは1回だけ。
G19="$TMP/g19"; mkdir -p "$G19"
STUCKCLAUDE="$TMP/stuck-claude.sh"
mkfake "$STUCKCLAUDE" "$G19/.claude/.vdgg-watch-active" "$CALLS" "$MLINE" "$PIDFILE" 300 30 1
rm -f "$CALLS" "$PIDFILE"
start_ts=$(date +%s)
tk "$STUCKCLAUDE" 1 "$G19" 5; rc=$?
end_ts=$(date +%s)
assert_exit_code 124 "$rc" "tick: TERM-ignoring child is force-killed and returns 124"
elapsed=$(( end_ts - start_ts ))
if [ "$elapsed" -ge 15 ]; then
    fail "tick: force-kill grace period took too long (elapsed=${elapsed}s)"
fi
assert_eq 1 "$(grep -c '^CALL$' "$CALLS")" "tick: stuck claude invoked exactly once"
sleep 1
CHILD19="$(sed -n '1p' "$PIDFILE")"
GRANDCHILD19="$(sed -n '2p' "$PIDFILE")"
if kill -0 "$GRANDCHILD19" 2>/dev/null; then
    kill -KILL "$GRANDCHILD19" 2>/dev/null || true
    fail "tick: grandchild (sleep 30) survived force-kill"
fi
if kill -0 "$CHILD19" 2>/dev/null; then
    kill -KILL "$CHILD19" 2>/dev/null || true
    fail "tick: stuck claude process survived force-kill"
fi
assert_file_not_exists "$G19/.claude/.vdgg-watch-active" "tick: marker removed after force-kill"

# (p) tick に TERM を送ると、TERM を無視する子・孫も後始末される
G25="$TMP/g25"; mkdir -p "$G25"
mkfake "$FAKE" "$G25/.claude/.vdgg-watch-active" "$CALLS" "$MLINE" "$PIDFILE" 300 30 1
rm -f "$CALLS" "$PIDFILE"
VDGG_WATCH_CLAUDE="$FAKE" VDGG_WATCH_TIMEOUT=600 bash "$SCRIPT" tick "$G25" 60 >/dev/null 2>&1 &
TICKPID=$!
wait_elapsed=0
while [ ! -s "$PIDFILE" ] && [ "$wait_elapsed" -lt 5 ]; do
    sleep 1
    wait_elapsed=$((wait_elapsed + 1))
done
assert_file_exists "$PIDFILE" "tick: TERM-test child recorded its pid before the signal"
CHILDPID25="$(sed -n '1p' "$PIDFILE")"
GRANDCHILDPID25="$(sed -n '2p' "$PIDFILE")"
kill -TERM "$TICKPID" 2>/dev/null || true
wait "$TICKPID" 2>/dev/null; rc=$?
assert_exit_code 143 "$rc" "tick: TERM to the tick process exits 143"
sleep 1
if kill -0 "$CHILDPID25" 2>/dev/null; then
    kill -KILL "$CHILDPID25" 2>/dev/null || true
    fail "tick: TERM-ignoring child survived TERM to tick"
fi
if kill -0 "$GRANDCHILDPID25" 2>/dev/null; then
    kill -KILL "$GRANDCHILDPID25" 2>/dev/null || true
    fail "tick: grandchild survived TERM to tick"
fi
assert_file_not_exists "$G25/.claude/.vdgg-watch-active" "tick: marker removed after TERM to tick"

# (q) 正常終了後に孫プロセスが残らない
G22="$TMP/g22"; mkdir -p "$G22"
mkfake "$FAKE" "$G22/.claude/.vdgg-watch-active" "$CALLS" "$MLINE" "$PIDFILE" 0 5 0
rm -f "$CALLS" "$PIDFILE"
tk "$FAKE" 5 "$G22" 60; rc=$?
assert_exit_code 0 "$rc" "tick: normal exit returns 0"
assert_file_exists "$PIDFILE" "tick: claude wrote pidfile before exiting"
GRANDCHILD22="$(sed -n '2p' "$PIDFILE")"
if kill -0 "$GRANDCHILD22" 2>/dev/null; then
    kill -KILL "$GRANDCHILD22" 2>/dev/null || true
    fail "tick: grandchild survived a normal exit"
fi

# (r) tick を SIGKILL した後、次の tick は旧グループを止めてから1回だけ起動する
G21="$TMP/g21"; mkdir -p "$G21"
mkfake "$FAKE" "$G21/.claude/.vdgg-watch-active" "$CALLS" "$MLINE" "$PIDFILE" 300 300 0
rm -f "$CALLS" "$PIDFILE"
VDGG_WATCH_CLAUDE="$FAKE" VDGG_WATCH_TIMEOUT=600 bash "$SCRIPT" tick "$G21" 5 >/dev/null 2>&1 &
TICK1=$!
wait_elapsed=0
while [ ! -s "$PIDFILE" ] && [ "$wait_elapsed" -lt 5 ]; do
    sleep 1
    wait_elapsed=$((wait_elapsed + 1))
done
assert_file_exists "$PIDFILE" "tick: SIGKILL-test child recorded its pid before the kill"
OLDCHILD="$(sed -n '1p' "$PIDFILE")"
OLDGRANDCHILD="$(sed -n '2p' "$PIDFILE")"
kill -KILL "$TICK1" 2>/dev/null || true
wait "$TICK1" 2>/dev/null
rm -f "$CALLS"
# last-tick が新しいので次の tick は起動しない（後退）が、孤児になった旧グループは先に止める
tk "$FAKE" 600 "$G21" 5; rc=$?
assert_exit_code 0 "$rc" "tick: next tick after a SIGKILLed tick succeeds"
assert_file_not_exists "$CALLS" "tick: next tick backs off while last-tick is fresh"
if kill -0 "$OLDCHILD" 2>/dev/null; then
    kill -KILL "$OLDCHILD" 2>/dev/null || true
    fail "tick: old child group leader survived SIGKILL recovery"
fi
if kill -0 "$OLDGRANDCHILD" 2>/dev/null; then
    kill -KILL "$OLDGRANDCHILD" 2>/dev/null || true
    fail "tick: old grandchild survived SIGKILL recovery"
fi
# last-tick を古くすると、ちょうど1回だけ起動する
touch -t 202001010000 "$G21/.claude/last-tick"
mkfake "$FAKE" "$G21/.claude/.vdgg-watch-active" "$CALLS" "$MLINE" "$PIDFILE"
tk "$FAKE" 5 "$G21" 5; rc=$?
assert_exit_code 0 "$rc" "tick: run resumes once last-tick is old"
assert_eq 1 "$(grep -c '^CALL$' "$CALLS")" "tick: resumed tick invokes claude exactly once"

# (s) allow_tools がカンマの後に空白を含んでいても正規化されて動く
G24="$TMP/g24"; mkgoal "$G24"
printf 'goal\nallow_tools: Bash, Task\n' > "$G24/goal.md"
w lock "$G24"
mkfake "$FAKE" "$G24/.claude/.vdgg-watch-active" "$CALLS" "$MLINE" "$PIDFILE"
rm -f "$CALLS"
tk "$FAKE" 5 "$G24" 60; rc=$?
assert_exit_code 0 "$rc" "tick: allow_tools with a space after the comma still runs"
if ! awk '$0=="--allowedTools"{getline nxt; if (nxt ~ /Bash,Task$/) f=1} END{exit !f}' "$CALLS"; then
    fail "tick args: --allowedTools must end with Bash,Task once normalized"
fi

# (t) 自分のものでないマーカーは tick_cleanup で消さない
G23="$TMP/g23"; mkdir -p "$G23"
MARKER23="$G23/.claude/.vdgg-watch-active"
FOREIGN="$TMP/foreign-claude.sh"
: > "$FOREIGN"
printf '#!/bin/bash\n' >> "$FOREIGN"
printf 'printf "%%s\\nforeign\\n" "%s" > "%s"\n' "$G23" "$MARKER23" >> "$FOREIGN"
printf 'exit 0\n' >> "$FOREIGN"
chmod +x "$FOREIGN"
tk "$FOREIGN" 5 "$G23" 60; rc=$?
assert_exit_code 0 "$rc" "tick: exits 0 even when the marker was rewritten mid-flight"
assert_file_exists "$MARKER23" "tick: tick_cleanup does not remove a marker it does not own"
assert_eq "foreign" "$(sed -n '2p' "$MARKER23")" "tick: foreign marker content is preserved"

# checks.lock に allow_tools 行が無くても tick は落ちずに起動する
G20="$TMP/g20"; mkgoal "$G20"; printf 'abc  ./ok.sh\n' > "$G20/checks.lock"
tk /usr/bin/true 5 "$G20" 60; rc=$?
assert_exit_code 0 "$rc" "tick: checks.lock without allow_tools line still runs"
assert_file_not_exists "$G20/.claude/.vdgg-watch-active" "tick: marker cleaned after run without allow_tools line"

echo "PASS: test-watch"
