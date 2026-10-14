#!/bin/bash
set -euo pipefail
# 内部の sort や出力整形は C で動かし、チェックには呼び出し元のロケールを渡す(user_locale)。
if [ -n "${LC_ALL+1}" ]; then ORIG_LC=(LC_ALL="$LC_ALL"); else ORIG_LC=(-u LC_ALL); fi
export LC_ALL=C
shopt -s nullglob

MARKER="$PWD/.claude/.vdgg-watch-active"
PLACEHOLDER='(未記入: エージェントがここに修正案を書く)'
TICK_CHILD_PID=""

usage() {
    echo "usage: vdgg-watch.sh start <G> | done | lock <G> | run <G> | tick <G> <秒>" >&2
    exit 1
}

if command -v shasum >/dev/null 2>&1; then
    sha() { shasum -a 256 "$@"; }
else
    sha() { sha256sum "$@"; }
fi

hashes() {
    (cd "$1/checks" && find . -type f | sort | while IFS= read -r f; do sha "$f"; done)
}

allow_line() {
    local line
    line="$(grep -m1 '^allow_tools:' "$1" 2>/dev/null || true)"
    echo "${line:-allow_tools:}"
}

abs_dir() {
    [ -n "${1:-}" ] && [ -d "$1" ] || usage
    (cd "$1" && pwd)
}

# 呼び出し元の LC_ALL(未設定なら未設定)で "$@" を実行する。
# fork 後のサブシェルで LC_ALL を書き換えると macOS の bash が CoreFoundation 経由で落ちるので、env で子にだけ渡す。
user_locale() {
    env "${ORIG_LC[@]}" "$@"
}

has_symlink() {
    [ -n "$(find "$1/checks" -type l -print -quit 2>/dev/null)" ]
}

# GNU の stat -f はファイルシステム情報を exit 0 で返すので、数字かどうかで BSD/GNU を見分ける。
# 両方失敗したら 0 を返す(存在しないファイルで set -e に落とされないため)。
mtime() {
    local m
    m="$(stat -f %m "$1" 2>/dev/null)" || m=""
    case "$m" in ''|*[!0-9]*) m="$(stat -c %Y "$1" 2>/dev/null)" || m="" ;; esac
    case "$m" in ''|*[!0-9]*) m=0 ;; esac
    echo "$m"
}

# <G>/proposal.md があり、「## 修正案」が空かプレースホルダのままなら真を返す。
fix_missing() {
    local fix
    [ -f "$1/proposal.md" ] || return 1
    fix="$(awk '/^## /{on=($0=="## 修正案");next} on&&NF' "$1/proposal.md")"
    [ -z "$fix" ] || [ "$fix" = "$PLACEHOLDER" ]
}

# プロセスグループを止める。生きていれば TERM を送り、締め切り5秒まで待ち、残っていれば KILL する。
stop_group() {
    local pgid="$1" deadline
    kill -0 -- -"$pgid" 2>/dev/null || return 0
    kill -TERM -- -"$pgid" 2>/dev/null || true
    deadline=$(( $(date +%s) + 5 ))
    while kill -0 -- -"$pgid" 2>/dev/null && [ "$(date +%s)" -lt "$deadline" ]; do
        sleep 1
    done
    kill -0 -- -"$pgid" 2>/dev/null && kill -KILL -- -"$pgid" 2>/dev/null || true
}

# tick の EXIT/TERM/INT/HUP トラップから呼ぶ。子のプロセスグループを止め、自分のマーカーだけを消す。
tick_cleanup() {
    local ec=$? line2
    [ -n "$TICK_CHILD_PID" ] && stop_group "$TICK_CHILD_PID"
    if [ -e "$MARKER" ]; then
        line2="$(sed -n '2p' "$MARKER")"
        case "$line2" in
            "tick $$"|"tick $$ "*) rm -f "$MARKER" ;;
        esac
    fi
    exit "$ec"
}

cmd_start() {
    local g
    g="$(abs_dir "${1:-}")"
    if [ -e "$MARKER" ]; then
        echo "already watching: $(head -n 1 "$MARKER")" >&2
        exit 1
    fi
    mkdir -p "$(dirname "$MARKER")"
    echo "$g" > "$MARKER"
}

cmd_done() {
    [ -e "$MARKER" ] || exit 0
    local g
    g="$(head -n 1 "$MARKER")"
    if fix_missing "$g"; then
        echo "proposal.md の「## 修正案」が未記入のため終了できない" >&2
        exit 1
    fi
    rm -f "$MARKER"
}

cmd_lock() {
    local g
    g="$(abs_dir "${1:-}")"
    if has_symlink "$g"; then
        echo "checks/ にシンボリックリンクがある" >&2
        exit 1
    fi
    local checks=("$g"/checks/*.sh)
    if [ "${#checks[@]}" -eq 0 ]; then
        echo "checks/*.sh がない" >&2
        exit 1
    fi
    if [ -e "$g/checks.lock" ] && [ ! -e "$g/approvals/relock" ]; then
        echo "再 lock には approvals/relock の承認が要る" >&2
        exit 1
    fi
    { hashes "$g"; allow_line "$g/goal.md"; } > "$g/checks.lock"
    rm -f "$g/approvals/relock"
}

cmd_run() {
    local g
    g="$(abs_dir "${1:-}")"
    if [ ! -e "$g/checks.lock" ]; then
        echo "先に lock が要る" >&2
        exit 1
    fi
    if has_symlink "$g"; then
        echo "checks/ にシンボリックリンクがある" >&2
        exit 4
    fi
    local cur locked
    cur="$(hashes "$g")"
    locked="$(grep -v '^allow_tools:' "$g/checks.lock" || true)"
    if [ "$cur" != "$locked" ]; then
        echo "checks が lock 後に変更された:" >&2
        { diff <(echo "$locked") <(echo "$cur") || true; } | sed -n 's/^[<>] [0-9a-f]*  //p' | sort -u >&2
        exit 4
    fi

    mkdir -p "$g/evidence"
    local log broken="" key="" c name out rc
    log="$g/evidence/$(date -u +%Y%m%dT%H%M%SZ)-$$.log"
    : > "$log"

    record() {
        { echo "== $1 (exit $2)"; echo "$3"; } >> "$log"
        if [ "$2" -ne 0 ]; then
            key="${key}$1 $2 $(printf '%s' "$3" | cksum)
"
            broken="${broken}- $1
$(echo "$3" | tail -n 5 | sed 's/^/    /')
"
        fi
    }

    for c in "$g"/checks/*.sh; do
        name="$(basename "$c")"
        rc=0
        out="$(cd "$g" && user_locale bash "$c" 2>&1)" || rc=$?
        record "$name" "$rc" "$out"
    done

    rc=0
    [ -n "$(find "$g/artifact" -type f -print -quit 2>/dev/null)" ] || rc=1
    record "artifact に成果物がある" "$rc" ""

    rc=0
    { grep -q '^## 過剰' "$g/fit.md" && grep -q '^## 不足' "$g/fit.md"; } 2>/dev/null || rc=1
    record "fit.md に過剰・不足の見出しがある" "$rc" ""

    local last="$g/evidence/.last-broken"
    if [ -z "$broken" ]; then
        rm -f "$g/proposal.md" "$last"
        exit 0
    fi
    # 前回と同じチェックが同じ終了コード・同じ出力全文(cksum で比べる)で崩れ、修正案も記入済みなら、証拠ログだけ残して proposal.md を保ち黙る。
    if [ -f "$g/proposal.md" ] && printf '%s' "$key" | cmp -s - "$last" && ! fix_missing "$g"; then
        exit 5
    fi
    printf '%s' "$key" > "$last"
    cat > "$g/proposal.md" <<PROPOSAL
## 何が崩れたか
$broken
## 根拠
$log

## 修正案
$PLACEHOLDER

## 承認の仕方
approvals/<ツール名> を作ると、そのツールを1回だけ許可する。
checks や goal.md の変更は、approvals/relock を作ってから lock する。
PROPOSAL
    exit 3
}

cmd_tick() {
    local g interval extra tool tools
    local script_dir hook_path settings_json allowed
    local prompt skill_md claude_bin timeout_sec
    local marker_line tag pid pgid age now_epoch latest f t
    local last_tick_file last_tick_log deadline
    local child rc timed_out

    interval="${2:-}"
    [[ "$interval" =~ ^[1-9][0-9]{0,8}$ ]] || usage

    g="$(abs_dir "${1:-}")"
    script_dir="$(cd "$(dirname "$0")" && pwd)"
    cd "$g"
    MARKER="$g/.claude/.vdgg-watch-active"
    last_tick_file="$g/.claude/last-tick"
    last_tick_log="$g/.claude/last-tick.log"

    extra="$(allow_line "$g/checks.lock")"
    extra="${extra#allow_tools:}"
    extra="$(printf '%s' "$extra" | sed 's/[[:space:]]*,[[:space:]]*/,/g; s/^[[:space:]]*//; s/[[:space:]]*$//')"
    if [ -n "$extra" ]; then
        tools=()
        IFS=',' read -r -a tools <<< "$extra"
        for tool in "${tools[@]}"; do
            [[ "$tool" =~ ^[A-Za-z0-9_*-]+$ ]] || { echo "checks.lock の allow_tools が不正: $tool" >&2; exit 2; }
        done
    fi

    claude_bin="${VDGG_WATCH_CLAUDE:-claude}"
    # ponytail: 既定の上限は3600秒。短くする場合は VDGG_WATCH_TIMEOUT で渡す。
    timeout_sec="${VDGG_WATCH_TIMEOUT:-3600}"

    if [ -e "$MARKER" ]; then
        now_epoch="$(date +%s)"
        age=$(( now_epoch - $(mtime "$MARKER") ))
        marker_line="$(sed -n '2p' "$MARKER")"
        case "$marker_line" in
            "tick "*)
                read -r tag pid pgid <<< "$marker_line"
                if [[ "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null && [ "$age" -lt $(( timeout_sec + 60 )) ]; then
                    exit 0
                fi
                [ -n "${pgid:-}" ] && stop_group "$pgid"
                rm -f "$MARKER"
                ;;
            *)
                if [ "$age" -lt $(( interval * 2 )) ]; then
                    exit 0
                fi
                rm -f "$MARKER"
                ;;
        esac
    fi

    latest=0
    f="$(ls -t "$g/evidence" 2>/dev/null | head -n1 || true)"
    if [ -n "$f" ] && [ -f "$g/evidence/$f" ]; then
        latest="$(mtime "$g/evidence/$f")"
    fi
    if [ -f "$last_tick_file" ]; then
        t="$(mtime "$last_tick_file")"
        [ "$t" -gt "$latest" ] && latest="$t"
    fi
    if [ "$latest" -gt 0 ]; then
        now_epoch="$(date +%s)"
        age=$(( now_epoch - latest ))
        [ "$age" -lt "$interval" ] && exit 0
    fi

    mkdir -p "$(dirname "$MARKER")"
    # ponytail: launchd は同じジョブを重ねて起動しない前提。rm 直後の noclobber 作成の競合はここでは扱わない。
    if ! ( set -C; printf '%s\ntick %s\n' "$g" "$$" > "$MARKER" ) 2>/dev/null; then
        exit 0
    fi
    trap tick_cleanup EXIT
    trap 'exit 143' TERM INT HUP

    hook_path="$script_dir/vdgg-watch-hook.sh"
    # 構文確認は hook の呼び出しごとに bash -n で行う。引数 tick は印で、hook はこれを見てマーカーの欠落・不正を拒否する。
    settings_json="$(jq -nc --arg h "$hook_path" '{hooks:{PreToolUse:[{matcher:"",hooks:[{type:"command",command:("bash -n " + ($h|@sh) + " && bash " + ($h|@sh) + " tick || exit 2")}]}]}}')"

    allowed="Read,Grep,Glob,WebSearch,WebFetch,Write,Edit,Bash"
    [ -n "$extra" ] && allowed="$allowed,$extra"

    skill_md="$(cd "$script_dir/.." && pwd)/SKILL.md"
    prompt="vdgg-watch の定期実行。目標: $g

$skill_md を Read し、その手順に従え。見張りは既に開始されているので start と done は呼ばず run から始めよ。"

    touch "$last_tick_file"
    set -m
    "$claude_bin" -p "$prompt" --permission-mode dontAsk --settings "$settings_json" --allowedTools "$allowed" </dev/null >"$last_tick_log" 2>&1 &
    child=$!
    set +m
    TICK_CHILD_PID="$child"
    printf '%s\ntick %s %s\n' "$g" "$$" "$child" > "$MARKER"

    deadline=$(( $(date +%s) + timeout_sec ))
    timed_out=0
    while kill -0 "$child" 2>/dev/null; do
        if [ "$(date +%s)" -ge "$deadline" ]; then
            timed_out=1
            break
        fi
        sleep 1
    done
    stop_group "$child"
    rc=0
    wait "$child" 2>/dev/null || rc=$?
    TICK_CHILD_PID=""
    [ "$timed_out" -eq 1 ] && rc=124

    if fix_missing "$g"; then
        echo "proposal.md の「## 修正案」が未記入" >&2
    fi

    exit "$rc"
}

case "${1:-}" in
    start) shift; cmd_start "$@" ;;
    done) cmd_done ;;
    lock) shift; cmd_lock "$@" ;;
    run) shift; cmd_run "$@" ;;
    tick) shift; cmd_tick "$@" ;;
    *) usage ;;
esac
