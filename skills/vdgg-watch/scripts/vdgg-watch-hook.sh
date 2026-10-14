#!/bin/bash
set -euo pipefail
trap 'rc=$?; [ "$rc" -eq 0 ] || exit 2' EXIT

deny() {
    echo "$1" >&2
    echo "見張りを終えるなら vdgg-watch.sh done、規則を変えるならユーザーが approvals/relock を置いてから vdgg-watch.sh lock すること" >&2
    exit 2
}

# $g の approvals/<tool_arg> を原子的に claim して消す。claim できた呼び出しだけが成功する。
consume_approval() {
    local claim
    claim="$g/approvals/.claim.$$.$RANDOM"
    [ -e "$g/approvals/$1" ] || return 1
    mv "$g/approvals/$1" "$claim" 2>/dev/null || return 1
    rm -f "$claim"
    return 0
}

is_safe_path() {
    case "$1" in
        *[!A-Za-z0-9._/~\ -]*) return 1 ;;
    esac
    return 0
}

command -v jq >/dev/null 2>&1 || exit 2

json="$(cat)"

cwd="$(printf '%s' "$json" | jq -r '.cwd // empty')"
marker="$cwd/.claude/.vdgg-watch-active"
[ -e "$marker" ] || exit 0

g="$(cat "$marker")"
[ -d "$g" ] || deny "マーカーが指す目標ディレクトリが無い: $g"

tool_name="$(printf '%s' "$json" | jq -r '.tool_name // empty')"
tool_input="$(printf '%s' "$json" | jq -c '.tool_input // {}')"

case "$tool_name" in
Write|Edit|MultiEdit|NotebookEdit)
    tgt_path="$(printf '%s' "$tool_input" | jq -r '.file_path // .notebook_path // empty')"
    case "$tgt_path" in
        /*) ;;
        *) deny "対象パスが絶対パスではない" ;;
    esac
    case "$tgt_path" in
        *'//'*|*'/./'*|*'/../'*|*'/.'|*'/..')
            deny "パスに // や . .. の成分を含む" ;;
    esac
    [ -L "$tgt_path" ] && deny "対象自身がシンボリックリンクのため拒否"
    skill_dir="$(cd "$(dirname "$0")/.." && pwd)"
    if [ "$tgt_path" -ef "$g/checks.lock" ] || [ "$tgt_path" -ef "$g/goal.md" ]; then
        deny "対象が保護ファイル(checks.lock・goal.md)と同一実体のため拒否"
    fi
    g_prefix=""
    w_rest="${tgt_path#/}"
    w_cur=""
    while [ -n "$w_rest" ]; do
        case "$w_rest" in
            */*) w_comp="${w_rest%%/*}"; w_rest="${w_rest#*/}" ;;
            *) w_comp="$w_rest"; w_rest="" ;;
        esac
        w_cur="$w_cur/$w_comp"
        if [ -n "$g_prefix" ] && [ -L "$w_cur" ]; then
            deny "<G> 配下の経路にシンボリックリンクがあるため拒否"
        fi
        if [ "$w_cur" -ef "$cwd/.claude" ] || [ "$w_cur" -ef "$skill_dir" ]; then
            deny "対象が制御ファイルの置き場(<cwd>/.claude・スキルのディレクトリ)と同一実体の経路を含むため拒否"
        fi
        if [ "$w_cur" -ef "$g/checks" ] || [ "$w_cur" -ef "$g/approvals" ] || [ "$w_cur" -ef "$g/evidence" ]; then
            deny "対象が保護領域(checks/・approvals/・evidence/)と同一実体の経路を含むため拒否"
        fi
        if [ -z "$g_prefix" ] && [ "$w_cur" -ef "$g" ]; then
            g_prefix="$w_cur"
        fi
    done
    allowed=0
    w_rel=""
    if [ -n "$g_prefix" ]; then
        w_rel="${tgt_path#"$g_prefix"}"
        w_rel="${w_rel#/}"
        w_rel_lc="$(printf '%s' "$w_rel" | tr '[:upper:]' '[:lower:]')"
        case "$w_rel_lc" in
            checks|checks/*|approvals|approvals/*|evidence|evidence/*)
                deny "対象が保護領域(checks/・approvals/・evidence/)で承認があっても拒否" ;;
            checks.lock|goal.md)
                deny "対象が保護ファイル(checks.lock・goal.md)で承認があっても拒否" ;;
        esac
        case "$w_rel" in
            artifact/*|fit.md|proposal.md|sources.md)
                allowed=1 ;;
        esac
        # 表記ゆれで保護名に畳まれうるのは <G> の中の artifact/ 以外だけ。<G> の外と artifact/ の下は日本語名も通す。
        case "$w_rel" in
            artifact/*) ;;
            *)
                is_safe_path "$tgt_path" || deny "<G> の中の artifact/ 以外のパスに安全な文字(英数字と._/~ -)以外が含まれる"
                ;;
        esac
    fi
    [ "$allowed" -eq 1 ] && exit 0
    consume_approval "$tool_name" && exit 0
    deny "対象が許可リスト(artifact/配下・fit.md・proposal.md・sources.md)の外で、approvals/$tool_name も無い"
    ;;
Bash)
    command="$(printf '%s' "$tool_input" | jq -r '.command // empty')"
    script_dir="$(cd "$(dirname "$0")" && pwd)"
    watch="$script_dir/vdgg-watch.sh"
    is_safe_path "$watch$g" || deny "パスに安全な文字(英数字と._/~ -)以外が含まれるため Bash は常に拒否"
    case "$command" in
        "bash \"$watch\" lock \"$g\""|"bash \"$watch\" run \"$g\""|"bash \"$watch\" done")
            exit 0 ;;
    esac
    consume_approval Bash && exit 0
    deny "Bash は vdgg-watch.sh の lock/run/done(スクリプトと<G>を二重引用符で囲んだ完全一致)のみ許可"
    ;;
Read|Grep|Glob|WebSearch|WebFetch)
    exit 0
    ;;
*)
    [ -n "$tool_name" ] || deny "tool_name が空"
    allow_tools=""
    if [ -f "$g/checks.lock" ]; then
        allow_line="$(grep -m1 '^allow_tools:' "$g/checks.lock" || true)"
        allow_tools="${allow_line#allow_tools:}"
    fi
    allow_list="$(printf '%s' "$allow_tools" | sed 's/[[:space:]]*,[[:space:]]*/,/g; s/^[[:space:]]*//; s/[[:space:]]*$//')"
    case ",$allow_list," in
        *",$tool_name,"*) exit 0 ;;
    esac
    consume_approval "$tool_name" && exit 0
    deny "$tool_name は allow_tools にない。approvals/$tool_name を1回分の承認として置くか、goal.md の allow_tools に加えて vdgg-watch.sh lock すること"
    ;;
esac
