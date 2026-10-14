#!/bin/bash
set -euo pipefail
export LC_ALL=C
shopt -s nullglob

MARKER="$PWD/.claude/.vdgg-watch-active"
PLACEHOLDER='(未記入: エージェントがここに修正案を書く)'

usage() {
    echo "usage: vdgg-watch.sh start <G> | done | lock <G> | run <G>" >&2
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
    line="$(grep -m1 '^allow_tools:' "$1/goal.md" 2>/dev/null || true)"
    echo "${line:-allow_tools:}"
}

abs_dir() {
    [ -n "${1:-}" ] && [ -d "$1" ] || usage
    (cd "$1" && pwd)
}

has_symlink() {
    [ -n "$(find "$1/checks" -type l -print -quit 2>/dev/null)" ]
}

cmd_start() {
    local g
    g="$(abs_dir "${1:-}")"
    if [ -e "$MARKER" ]; then
        echo "already watching: $(cat "$MARKER")" >&2
        exit 1
    fi
    mkdir -p "$(dirname "$MARKER")"
    echo "$g" > "$MARKER"
}

cmd_done() {
    [ -e "$MARKER" ] || exit 0
    local g fix
    g="$(cat "$MARKER")"
    if [ -f "$g/proposal.md" ]; then
        fix="$(awk '/^## /{on=($0=="## 修正案");next} on&&NF' "$g/proposal.md")"
        if [ -z "$fix" ] || [ "$fix" = "$PLACEHOLDER" ]; then
            echo "proposal.md の「## 修正案」が未記入のため終了できない" >&2
            exit 1
        fi
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
    { hashes "$g"; allow_line "$g"; } > "$g/checks.lock"
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
    local log broken="" c name out rc
    log="$g/evidence/$(date -u +%Y%m%dT%H%M%SZ).log"
    : > "$log"

    record() {
        { echo "== $1 (exit $2)"; echo "$3"; } >> "$log"
        if [ "$2" -ne 0 ]; then
            broken="${broken}- $1
$(echo "$3" | tail -n 5 | sed 's/^/    /')
"
        fi
    }

    for c in "$g"/checks/*.sh; do
        name="$(basename "$c")"
        rc=0
        out="$(cd "$g" && bash "$c" 2>&1)" || rc=$?
        record "$name" "$rc" "$out"
    done

    rc=0
    [ -n "$(find "$g/artifact" -type f -print -quit 2>/dev/null)" ] || rc=1
    record "artifact に成果物がある" "$rc" ""

    rc=0
    { grep -q '^## 過剰' "$g/fit.md" && grep -q '^## 不足' "$g/fit.md"; } 2>/dev/null || rc=1
    record "fit.md に過剰・不足の見出しがある" "$rc" ""

    if [ -z "$broken" ]; then
        rm -f "$g/proposal.md"
        exit 0
    fi
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

case "${1:-}" in
    start) shift; cmd_start "$@" ;;
    done) cmd_done ;;
    lock) shift; cmd_lock "$@" ;;
    run) shift; cmd_run "$@" ;;
    *) usage ;;
esac
