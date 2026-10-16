#!/bin/bash
# vdgg-hook-pretool.sh - PreToolUse hook for VibesDeGoGo! step enforcement.

set -euo pipefail

INPUT=$(cat)

if ! command -v jq >/dev/null 2>&1; then
    # Keep jq install-command detection and guidance aligned across the Claude
    # pretool/posttool and Codex pretool hooks. Their activation checks differ;
    # Codex posttool intentionally exits 0 without jq and has no install guidance.
    # Without jq the hook JSON cannot be parsed properly. Best-effort: extract
    # cwd with grep/sed and check for an active VibesDeGoGo! session there. No
    # active session -> stay out of the way so unrelated repositories are never
    # blocked by a missing dependency.
    FALLBACK_CWD=$(printf '%s' "$INPUT" | grep -oE '"cwd"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed -E 's/.*:[[:space:]]*"([^"]*)"$/\1/')
    FALLBACK_CWD="${FALLBACK_CWD:-$PWD}"
    if [ ! -f "$FALLBACK_CWD/.claude/.vdgg-active" ]; then
        # Unarmed session. When the repository opts in with VDGG_REQUIRED=on,
        # tools cannot be classified without jq, so fall through to the
        # fail-closed branch below; otherwise stay out of the way.
        FALLBACK_REQUIRED=$(grep -m1 '^VDGG_REQUIRED=' "$FALLBACK_CWD/.vdgg-target" 2>/dev/null | sed -E 's/^[^=]*=//; s/^"(.*)"$/\1/' || true)
        if [ "$FALLBACK_REQUIRED" != "on" ]; then
            exit 0
        fi
    fi
    # An active session must not run unguarded. Fail closed, but allow the
    # current Bash command through if it is itself an attempt to install jq,
    # so the user can run `brew install jq` / `apt-get install jq` etc.
    if printf '%s' "$INPUT" | grep -qE '"command"[[:space:]]*:[[:space:]]*"[^"]*(brew[[:space:]]+(install|reinstall)|apt(-get)?[[:space:]]+install|apk[[:space:]]+add|dnf[[:space:]]+install|yum[[:space:]]+install|pacman[[:space:]]+-S)[[:space:]]+[^"]*jq'; then
        exit 0
    fi
    {
        echo "VibesDeGoGo! hook: jq is required for hooks but was not found on PATH."
        echo "  macOS:               brew install jq"
        echo "  Debian/Ubuntu/WSL:   sudo apt-get install jq"
        echo "  Alpine:              apk add jq"
        echo "  Fedora/RHEL:         sudo dnf install jq"
    } >&2
    exit 2
fi

# Portable mtime in epoch seconds. Tries BSD/macOS first, then GNU/Linux, then 0.
_vdgg_mtime() {
    # BSD/macOS `stat -f %m` gives the epoch. On GNU/Linux `-f` means
    # --file-system and prints non-numeric text with exit 0, so the raw `||`
    # chain is not enough: validate the result is all-digits and fall back to
    # `stat -c %Y`, then to 0.
    local m
    m=$(stat -f %m "$1" 2>/dev/null || true)
    case "$m" in ''|*[!0-9]*) m=$(stat -c %Y "$1" 2>/dev/null || true) ;; esac
    case "$m" in ''|*[!0-9]*) m=0 ;; esac
    printf '%s\n' "$m"
}

# `git commit` を単語として捉えるパターン。commit guard の 3 箇所が
# 同じ判定を共有するため、ここ 1 箇所で定義する。
GIT_COMMIT_PATTERN='(^|[^a-zA-Z0-9_-])git[[:space:]]+commit($|[[:space:]])'

TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // empty')

# CWD is required to locate the repository-local state files.
CWD=$(echo "$INPUT" | jq -r '.cwd // empty')
if [ -z "$CWD" ]; then
    exit 0
fi

# Entry gate (VDGG_REQUIRED): normally an unarmed session (no active id or
# state) leaves the hook fail-open so unrelated repositories are never
# touched. A repository can opt out of that leniency with VDGG_REQUIRED=on in
# .vdgg-target: code-modifying tools are then denied until a session is armed
# through vdgg_state_init. This closes the hole where an agent that ignores
# the workflow contract simply never arms the gates (arming must not be a
# voluntary act). Only the literal value `on` activates the gate; anything
# else keeps the historical fail-open behavior.
_vdgg_required() {
    local target="$CWD/.vdgg-target" v
    [ -f "$target" ] || return 1
    v=$(grep -m1 '^VDGG_REQUIRED=' "$target" | sed -E 's/^[^=]*=//; s/^"(.*)"$/\1/')
    [ "$v" = "on" ]
}

_vdgg_entry_deny() {
    echo "VibesDeGoGo! entry gate: this repository sets VDGG_REQUIRED=on in .vdgg-target and no VibesDeGoGo! session is armed. Code-modifying tools are blocked until Step 1 runs: source \"\$HOME/.claude/skills/vibesdegogo/scripts/vdgg-state.sh\" && vdgg_state_init. Only a human may relax this by editing .vdgg-target." >&2
    exit 2
}

# Decide an unarmed tool call under VDGG_REQUIRED=on. Mirrors the armed
# path's tool classification: known read-only tools pass, file edits are
# denied, unknown tools exposing a file path are denied (fail-closed), and
# Bash is denied per segment when it writes files or commits. Agent passes
# because a subagent's own tool calls go through this same hook. Known limit
# (same as the sidecar guard): a write hidden behind a shell variable or an
# interpreter one-liner evades the literal segment match; see
# references/hook_rules.md.
_vdgg_entry_gate() {
    case "$TOOL_NAME" in
        Read|Glob|Grep|LS|NotebookRead|TodoWrite|WebFetch|WebSearch|BashOutput|KillShell|Agent)
            exit 0
            ;;
        Edit|Write|NotebookEdit)
            _vdgg_entry_deny
            ;;
        Bash)
            local cmd segs seg seg_checked verb
            cmd=$(echo "$INPUT" | jq -r '.tool_input.command // empty')
            segs="$cmd"
            segs="${segs//&&/$'\n'}"
            segs="${segs//||/$'\n'}"
            segs="${segs//;/$'\n'}"
            segs="${segs//|/$'\n'}"
            while IFS= read -r seg; do
                # Redirections to /dev/null|stdout|stderr do not modify the
                # repository; strip them (fd dups like 2>&1 are already
                # excluded by the [^&] below) so read-only idioms such as
                # `grep x f 2>/dev/null` are not falsely denied.
                seg_checked=$(printf '%s' "$seg" | sed -E 's#[0-9]*>>?[[:space:]]*/dev/(null|stdout|stderr)##g')
                if echo "$seg_checked" | grep -qE '(>[^&]|>>|(^|[[:space:]])tee([[:space:]]|$))'; then
                    _vdgg_entry_deny
                fi
                if echo "$seg" | grep -qE "$GIT_COMMIT_PATTERN"; then
                    _vdgg_entry_deny
                fi
                verb=$(printf '%s' "$seg" | sed -E 's/^[[:space:]]*//; s/[[:space:]].*//')
                case "$verb" in
                    rm|mv|cp|dd|install|truncate|touch|ln|patch|mkfifo)
                        _vdgg_entry_deny
                        ;;
                    sed|perl)
                        if echo "$seg" | grep -qE '(^|[[:space:]])-[a-zA-Z]*i'; then
                            _vdgg_entry_deny
                        fi
                        ;;
                esac
            done <<< "$segs"
            exit 0
            ;;
        *)
            FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // .tool_input.notebook_path // empty')
            if [ -n "$FILE_PATH" ]; then
                _vdgg_entry_deny
            fi
            exit 0
            ;;
    esac
}

# Unarmed exit: with the VDGG_REQUIRED opt-in the entry gate decides
# (always exits); without it the hook stays out of the way.
_vdgg_unarmed_exit() {
    if _vdgg_required; then
        _vdgg_entry_gate
    fi
    exit 0
}

# Active file stores the current VibesDeGoGo! id.
ACTIVE_FILE="$CWD/.claude/.vdgg-active"
if [ ! -f "$ACTIVE_FILE" ]; then
    _vdgg_unarmed_exit
fi

VDGG_ID=$(cat "$ACTIVE_FILE")
if [ -z "$VDGG_ID" ]; then
    _vdgg_unarmed_exit
fi

# Load the state file for the active id.
STATE_FILE="$CWD/.claude/.vdgg-state-${VDGG_ID}"
if [ ! -f "$STATE_FILE" ]; then
    _vdgg_unarmed_exit
fi

# 状態ファイルから 1 フィールドを読む。値に `=` を含みうるので常に f2- を使う。
_vdgg_state_get() {
    grep "^$1=" "$2" | head -1 | cut -d= -f2- || true
}

PHASE=$(_vdgg_state_get phase "$STATE_FILE")
STEP=$(_vdgg_state_get step "$STATE_FILE")
LOOP_COUNT=$(_vdgg_state_get loop_count "$STATE_FILE")
LOOP_COUNT="${LOOP_COUNT:-0}"
TASK_ALLOWLIST_FILE=$(_vdgg_state_get task_allowlist_file "$STATE_FILE")
TASK_GATE_FILE="$CWD/.claude/.vdgg-task-gate-${VDGG_ID}-${LOOP_COUNT}"

# Friction log: record that a gate refused this tool call, so Step 6-R can name
# where a loop kept catching. One EXIT trap covers all 30-odd `exit 2` sites
# below instead of editing each one.
#
# `gate` is the line number of the `exit` that fired, which lets one trap
# identify a gate as precisely as editing every site would. `phase` cannot --
# under `implementing` alone it merges four guards (test commands, sidecar
# writes, out-of-allowlist edits, the runaway-loop cap). Line numbers move
# whenever this file is edited, so they only mean anything within the session
# that wrote them; anything durable must quote the gate's rule, not its number.
#
# The line comes from a DEBUG trap rather than BASH_LINENO or LINENO: bash 5
# resets both to 1 once the EXIT trap starts, while bash 3.2 does not. The DEBUG
# trap keeps the last two line numbers and fires once more for the EXIT trap's
# own command on both versions, so the older of the two is the `exit` line.
# That holds only while the EXIT trap string stays a single command. DEBUG
# traps are not inherited by functions, so an `exit` inside a function reports
# the line before the call, not the `exit` itself; nothing below this point
# exits that way. A `set -e` death inside a function mislocates it the same
# way; the calls below are all assignments or `if !` conditions, where errexit
# does not propagate.
#
# Known limit: exit status 2 is a proxy for "a gate refused this". grep and jq
# also exit 2 on their own errors, so a defect in this hook can be logged as
# user friction, and a gate that ever answers with a JSON permissionDecision
# would stop being counted. Both are miscounts in a log, not failures of the
# gate itself.
#
# Everything above this line runs before VDGG_ID exists (the jq-missing exit,
# the entry gate), so pre-arm refusals are out of scope structurally: move this
# block up there and `set -u` fails on VDGG_ID rather than silently widening
# what counts as friction. FRICTION_FILE must stay global -- the trap fires
# after this point in a scope where a `local` would be gone, and under `set -u`
# that dies during expansion, before `2>/dev/null` or `|| true` can apply.
FRICTION_FILE="$CWD/.claude/.vdgg-friction-${VDGG_ID}"
_vdgg_friction_on_exit() {
    [ "${1:-0}" = "2" ] || return 0
    # Append-only and short: concurrent pretool invocations write under
    # O_APPEND well below PIPE_BUF, so no write can clobber another.
    # Failing to log must never change whether the call is refused.
    printf 'deny phase=%s loop=%s tool=%s gate=%s\n' \
        "${PHASE:-}" "${LOOP_COUNT:-}" "${TOOL_NAME:-}" "${_vdgg_prev_line:-}" \
        2>/dev/null >> "$FRICTION_FILE" || true
}
trap '_vdgg_friction_on_exit $?' EXIT
trap '_vdgg_prev_line=${_vdgg_line:-}; _vdgg_line=$LINENO' DEBUG

if [ -z "$PHASE" ]; then
    exit 0
fi

# Task directory for the active id, used for phase-specific write allowances.
TASKS_DIR="$CWD/tasks/vdgg/${VDGG_ID}"

# Strip the project prefix (or ./) to compare against allowlist entries.
_vdgg_normalize_project_path() {
    local p="$1"
    case "$p" in
        "$CWD"/*) p="${p#"$CWD"/}" ;;
        ./*) p="${p#./}" ;;
    esac
    printf '%s\n' "$p"
}

# True when the path names one of the active session's task notes. A tool may
# hand us an absolute path, a bare relative one, or a ./-prefixed one, so
# normalize before matching: comparing the raw path against "$TASKS_DIR"/*
# silently missed the ./ form, and left the directory name unquoted so any
# path containing a glob character matched by accident.
_vdgg_is_task_note() {
    case "$(_vdgg_normalize_project_path "$1")" in
        "tasks/vdgg/${VDGG_ID}/"*) return 0 ;;
    esac
    return 1
}

# Evidence gates shared with the Codex edition (vdgg-evidence.sh, kept
# byte-identical): the Step 3 read log, the Step 4 plan excerpts, the Step 6
# patch chain and the Step 7 plan reconciliation. Loaded only by the branches
# that use it.
_VDGG_HOOK_DIR=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)
# A partial install must not quietly open the gates.
if [ ! -f "${_VDGG_HOOK_DIR}/vdgg-evidence.sh" ]; then
    echo "VibesDeGoGo! [${VDGG_ID}]: vdgg-evidence.sh is missing next to the hook; reinstall the skill." >&2
    exit 2
fi
_vdgg_load_evidence() {
    # shellcheck source=vdgg-evidence.sh
    . "${_VDGG_HOOK_DIR}/vdgg-evidence.sh"
}
READ_LOG="$CWD/.claude/.vdgg-read-${VDGG_ID}"

# Step 3 read evidence: while investigating, append every path the agent
# reads to the read log: here the Read/Grep/Glob/LS/NotebookRead targets
# (these tools exit just below), and at the end of this hook the files a Bash
# reader such as cat, sed -n, head or rg names, once no guard refused the
# command. The Step 3 -> 4 gate compares '## 1. Related files' against it.
# Recording never refuses a tool call.
if [ "$PHASE" = "investigating" ]; then
    _vdgg_load_evidence
    case "$TOOL_NAME" in
        Read|NotebookRead)
            echo "$INPUT" | jq -r '.tool_input.file_path // .tool_input.notebook_path // empty' \
                | _vdgg_ev_record_reads "$READ_LOG" "$CWD" || true
            ;;
        Grep|Glob|LS)
            echo "$INPUT" | jq -r '.tool_input.path // empty' \
                | _vdgg_ev_record_reads "$READ_LOG" "$CWD" || true
            ;;
    esac
fi

# Extract only the fields needed for the current tool type.
GATE_COMMAND=""

case "$TOOL_NAME" in
    Edit|Write|NotebookEdit)
        FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // .tool_input.notebook_path // empty')
        ;;
    Bash)
        COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty')
        # Transition gates match `vdgg_state_* <step> <phase>` literally;
        # quoting an argument ("4" planning) must not step around them, so
        # they match an unquoted copy. COMMAND itself stays as typed.
        GATE_COMMAND=$(printf '%s' "$COMMAND" | tr -d "\"'")
        # Anything else in that position (a variable, $'...', a backslash)
        # cannot be judged, so it is refused rather than let through.
        if [ -f "${_VDGG_HOOK_DIR}/vdgg-evidence.sh" ]; then
            _vdgg_load_evidence
            if ! _vdgg_ev_transitions_literal "$COMMAND"; then
                echo "VibesDeGoGo! [${VDGG_ID}]: write vdgg_state_advance/loop/write with a literal step and phase (e.g. vdgg_state_advance 4 planning); variables, escapes and \$'...' cannot be checked against the gates." >&2
                exit 2
            fi
        fi
        ;;
    Agent)
        # Agent calls are phase-gated below.
        ;;
    Read|Glob|Grep|LS|NotebookRead|TodoWrite|WebFetch|WebSearch|BashOutput|KillShell)
        # Known read-only / non-file-mutating tools are always allowed.
        exit 0
        ;;
    *)
        # Unknown tool: it may mutate files. Extract a file path if the tool
        # exposes one and let the phase guards below apply (fail-closed for file
        # writes). A read-only tool with no file path still falls through to the
        # allow at the end, so this does not block genuine reads.
        FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // .tool_input.notebook_path // empty')
        ;;
esac

# Error acknowledgement gate: after a failed Bash command, the next Bash
# command must contain [Error Acknowledged] in its text (e.g. in a leading
# comment). Same contract as the Codex edition; no transcript parsing.
ERROR_FLAG="$CWD/.claude/.vdgg-error-pending"
if [ "$TOOL_NAME" = "Bash" ] && [ -f "$ERROR_FLAG" ]; then
    if echo "$COMMAND" | grep -qF '[Error Acknowledged]'; then
        rm -f "$ERROR_FLAG"
    else
        ERROR_REASON=$(_vdgg_state_get reason "$ERROR_FLAG")
        ERROR_REASON="${ERROR_REASON:-unknown}"
        echo "VibesDeGoGo! [${VDGG_ID}]: Previous Bash command failed ($ERROR_REASON). Include [Error Acknowledged] with a short plan in your next Bash command." >&2
        exit 2
    fi
fi

# Guard 4: block direct edits to any .claude/.vdgg-* sidecar (state, active,
# sentinels) and to .vdgg-target in all phases. Sentinel forgery would bypass
# the review gate; and .vdgg-target holds trusted config (REVIEW_COMMAND) that
# is executed, so letting the agent write it would let it self-author a passing
# review.
if [ "$TOOL_NAME" = "Edit" ] || [ "$TOOL_NAME" = "Write" ]; then
    if [[ "$FILE_PATH" == *".claude/.vdgg-"* ]] || [[ "$FILE_PATH" == *".vdgg-target" ]]; then
        echo "VibesDeGoGo! [${VDGG_ID}]: Direct edits to VibesDeGoGo! sidecar/target files are blocked. Use vdgg_state_* helpers; .vdgg-target must be set by a human." >&2
        exit 2
    fi
fi
if [ "$TOOL_NAME" = "Bash" ]; then
    # Sidecar files (.claude/.vdgg-*) may only be written through vdgg_state_*
    # helpers, never directly, or the review/gate sentinels could be forged.
    # Check each shell segment independently so a `git commit` segment (whose
    # message may legitimately mention a sidecar path) cannot shield a
    # sidecar-mutating segment in the same command line, e.g.
    #   git commit -m x && rm -f .claude/.vdgg-active
    # Whitelist model (fail-closed): a segment that mentions a sidecar path is
    # allowed only when it is a git-commit segment, or a genuine read -- a
    # leading read-only verb with no output redirection or tee. Everything else
    # (interpreters like python/perl, dd/install/truncate, redirects, file ops)
    # is denied. Known limit: a segment that hides the sidecar path behind a
    # shell variable or command substitution can evade the literal match; see
    # references/hook_rules.md.
    _vdgg_segs="$COMMAND"
    _vdgg_segs="${_vdgg_segs//&&/$'\n'}"
    _vdgg_segs="${_vdgg_segs//||/$'\n'}"
    _vdgg_segs="${_vdgg_segs//;/$'\n'}"
    _vdgg_segs="${_vdgg_segs//|/$'\n'}"
    while IFS= read -r _vdgg_seg; do
        case "$_vdgg_seg" in
            *".claude/.vdgg-"*|*".vdgg-target"*) ;;
            *) continue ;;
        esac
        if echo "$_vdgg_seg" | grep -qE "$GIT_COMMIT_PATTERN"; then
            continue
        fi
        _vdgg_verb=$(printf '%s' "$_vdgg_seg" | sed -E 's/^[[:space:]]*//; s/[[:space:]].*//')
        _vdgg_read_ok=0
        case "$_vdgg_verb" in
            cat|grep|egrep|fgrep|test|'['|ls|head|tail|wc|diff|cmp|stat|od|hexdump|file|realpath|readlink)
                # Strip `2>/dev/null` before the redirect test: silencing stderr is
                # not a write, and a segment that also writes keeps its `>`.
                # SECURITY: /dev/null ONLY -- never widen to the entry gate's
                # /dev/stdout|stderr. This pattern has no terminator, so
                # `>/dev/stdout/<path>` would be swallowed whole, and fd 1 can be
                # aimed into the repo with `1<.`. /dev/null is a character device,
                # so `/dev/null/<x>` is always ENOTDIR.
                # See skills/vibesdegogo/references/hook_rules.md.
                _vdgg_seg_checked=$(printf '%s' "$_vdgg_seg" | sed -E 's#[0-9]*>>?[[:space:]]*/dev/null##g')
                if ! echo "$_vdgg_seg_checked" | grep -qE '(>[^&]|>>|(^|[[:space:]])tee([[:space:]]|$))'; then
                    _vdgg_read_ok=1
                fi
                ;;
        esac
        if [ "$_vdgg_read_ok" -ne 1 ]; then
            echo "VibesDeGoGo! [${VDGG_ID}]: Direct writes to VibesDeGoGo! sidecar files are blocked. Use vdgg_state_* helpers. To read one, lead with a read-only verb such as cat/grep/head and add no output redirection (only /dev/null is exempt)." >&2
            exit 2
        fi
    done <<< "$_vdgg_segs"
fi

# Guard 5: tests must run only after the workflow enters testing.
# The default command pattern can be extended through `.vdgg-target`.
if [ "$TOOL_NAME" = "Bash" ] && [ "$PHASE" = "implementing" ]; then
    TEST_PATTERN_DEFAULT='swift[[:space:]]+test|xcodebuild[[:space:]]+[^|]*[[:space:]]test|pytest|npm[[:space:]]+(run[[:space:]]+)?test|pnpm[[:space:]]+(run[[:space:]]+)?test|yarn[[:space:]]+(run[[:space:]]+)?test|go[[:space:]]+test|cargo[[:space:]]+test|jest|vitest|mocha'
    TEST_PATTERN_EXTRA=""
    if [ -f "$CWD/.vdgg-target" ]; then
        TEST_PATTERN_EXTRA=$(grep '^TEST_COMMAND_PATTERN=' "$CWD/.vdgg-target" 2>/dev/null | sed -E 's/^[^=]*=//; s/^"(.*)"$/\1/' | head -1)
    fi
    TEST_PATTERN="$TEST_PATTERN_DEFAULT"
    if [ -n "$TEST_PATTERN_EXTRA" ]; then
        TEST_PATTERN="${TEST_PATTERN}|${TEST_PATTERN_EXTRA}"
    fi
    if echo "$COMMAND" | grep -qE "(^|[[:space:];&|(])(${TEST_PATTERN})([[:space:]]|$)"; then
        echo "VibesDeGoGo! Step ${STEP} (${PHASE}) [${VDGG_ID}]: This action is blocked in the current phase." >&2
        exit 2
    fi
fi

# Loop-count safety: block mutating tools after an obviously runaway retry loop.
# Read-like tools returned earlier, so only Edit/Write/Bash/Agent reach this.
if [ "$PHASE" = "implementing" ] || [ "$PHASE" = "testing" ]; then
    if [ "$LOOP_COUNT" -ge 99 ]; then
        echo "VibesDeGoGo! [${VDGG_ID:-unknown}]: Tool call blocked by VibesDeGoGo! hook." >&2
        exit 2
    fi
fi

# Phase-specific guards.

case "$PHASE" in
    declare|requirements)
        # Agent work is blocked until requirements are fixed.
        if [ "$TOOL_NAME" = "Agent" ]; then
            echo "VibesDeGoGo! [${VDGG_ID:-unknown}]: Tool call blocked by VibesDeGoGo! hook." >&2
            exit 2
        fi
        # During declaration/requirements, only task files may be written.
        if [ -n "${FILE_PATH:-}" ]; then
            if [ -n "$FILE_PATH" ]; then
                if _vdgg_is_task_note "$FILE_PATH"; then
                    exit 0
                fi
                echo "VibesDeGoGo! [${VDGG_ID:-unknown}]: Tool call blocked by VibesDeGoGo! hook." >&2
                exit 2
            fi
        fi
        # requirements.md is mandatory before investigation starts, and it must
        # include a '## Lessons Applied' heading with a non-empty body so the
        # session can never skip consulting user-memory / AIB lessons at the
        # earliest structural point where they still shape the requirements.
        if [ "$PHASE" = "requirements" ] && [ "$TOOL_NAME" = "Bash" ]; then
            if echo "$GATE_COMMAND" | grep -qE 'vdgg_state_(advance|loop|write)[[:space:]]+3[[:space:]]+investigating([^[:alnum:]_-]|$)'; then
                REQ_FILE="${TASKS_DIR}/requirements.md"
                if [ ! -f "$REQ_FILE" ]; then
                    echo "VibesDeGoGo! Step ${STEP} (requirements) [${VDGG_ID}]: requirements.md is required before investigation." >&2
                    exit 2
                fi
                if ! awk '
                    /^## Lessons Applied[[:space:]]*$/ { in_section=1; next }
                    in_section && /^## / { in_section=0 }
                    in_section && /[^[:space:]]/ { found=1 }
                    END { exit found ? 0 : 1 }
                ' "$REQ_FILE"; then
                    echo "VibesDeGoGo! Step ${STEP} (requirements) [${VDGG_ID}]: requirements.md must include a '## Lessons Applied' heading with a non-empty body (write 'None applicable' when nothing fits)." >&2
                    exit 2
                fi
            fi
        fi
        ;;

    investigating|planning)
        # Investigation and planning may only update task documentation.
        if [ -n "${FILE_PATH:-}" ]; then
            if [ -n "$FILE_PATH" ]; then
                if _vdgg_is_task_note "$FILE_PATH"; then
                    exit 0
                fi
                echo "VibesDeGoGo! [${VDGG_ID:-unknown}]: Tool call blocked by VibesDeGoGo! hook." >&2
                exit 2
            fi
        fi
        # investigation.md is mandatory before planning starts, and it must
        # contain all seven required headings each with a non-empty body so the
        # session cannot advance to Step 4 on a shallow or skeleton investigation.
        # The seven headings are the canonical Step 3 output contract defined in
        # references/subagent_prompts.md.
        if [ "$PHASE" = "investigating" ] && [ "$TOOL_NAME" = "Bash" ]; then
            if echo "$GATE_COMMAND" | grep -qE 'vdgg_state_(advance|loop|write)[[:space:]]+4[[:space:]]+planning([^[:alnum:]_-]|$)'; then
                INV_FILE="${TASKS_DIR}/investigation.md"
                if [ ! -f "$INV_FILE" ]; then
                    echo "VibesDeGoGo! Step ${STEP} (investigating) [${VDGG_ID}]: investigation.md is required before planning." >&2
                    exit 2
                fi
                # Seven direct pattern-action blocks mirror the Step 2->3 gate style
                # above. Adding or renaming a heading requires editing this block,
                # SKILL.md's Step 3 list, and references/subagent_prompts.md together;
                # a drift test in tests/ enforces that they stay in sync.
                if ! awk '
                    BEGIN { current = 0 }
                    /^## 1\. Related files[[:space:]]*$/                { seen[1]=1; current=1; next }
                    /^## 2\. Existing implementation patterns[[:space:]]*$/ { seen[2]=1; current=2; next }
                    /^## 3\. Impact surface[[:space:]]*$/               { seen[3]=1; current=3; next }
                    /^## 4\. Prior similar implementations[[:space:]]*$/ { seen[4]=1; current=4; next }
                    /^## 5\. Side effects and risks[[:space:]]*$/       { seen[5]=1; current=5; next }
                    /^## 6\. Constraints[[:space:]]*$/                  { seen[6]=1; current=6; next }
                    /^## 7\. Verification strategy[[:space:]]*$/        { seen[7]=1; current=7; next }
                    current > 0 && /^## /               { current = 0 }
                    current > 0 && /[^[:space:]]/       { body[current] = 1 }
                    END { for (i = 1; i <= 7; i++) if (!seen[i] || !body[i]) exit 1 }
                ' "$INV_FILE"; then
                    echo "VibesDeGoGo! Step ${STEP} (investigating) [${VDGG_ID}]: investigation.md must include all seven required Step 3 headings each with a non-empty body (see SKILL.md Step 3 or references/subagent_prompts.md)." >&2
                    exit 2
                fi
                # Read evidence: every file under '## 1. Related files' must
                # exist and have been read during this phase (see the read log
                # above). Headings alone can be written without opening a file.
                _vdgg_load_evidence
                if ! READ_PROBLEMS=$(_vdgg_ev_check_related "$INV_FILE" "$READ_LOG" "$CWD"); then
                    {
                        echo "VibesDeGoGo! Step ${STEP} (investigating) [${VDGG_ID}]: Step 3 read evidence is missing. Every file listed under '## 1. Related files' must exist and be read during investigating (Read/Grep, or cat, sed -n, head, rg in Bash):"
                        printf '%s\n' "$READ_PROBLEMS" | sed 's/^/  - /'
                    } >&2
                    exit 2
                fi
            fi
        fi
        # Plan evidence: leaving Step 4 (vdgg_state_advance 5, or
        # vdgg_task_begin, which also writes step 5) needs todo.md tasks whose
        # excerpts match the current code verbatim and whose intent carries
        # no code. progress.md must exist as before.
        if [ "$PHASE" = "planning" ] && [ "$TOOL_NAME" = "Bash" ]; then
            if echo "$GATE_COMMAND" | grep -qE '(vdgg_state_(advance|loop|write)[[:space:]]+5[[:space:]]+task-selected|vdgg_task_begin)([^[:alnum:]_-]|$)'; then
                _vdgg_load_evidence
                if ! PLAN_PROBLEMS=$(_vdgg_ev_check_plan "${TASKS_DIR}/todo.md" "$CWD"); then
                    {
                        echo "VibesDeGoGo! Step ${STEP} (planning) [${VDGG_ID}]: todo.md does not carry plan evidence. Each '## T<n>' task needs '### Location', '### Excerpt' (the current code there, copied verbatim in one fenced block, or 新規 for a new file) and '### Intent' (prose, no code):"
                        printf '%s\n' "$PLAN_PROBLEMS" | sed 's/^/  - /'
                    } >&2
                    exit 2
                fi
                if [ ! -f "${TASKS_DIR}/progress.md" ]; then
                    echo "VibesDeGoGo! Step ${STEP} (planning) [${VDGG_ID}]: progress.md is required before Step 5." >&2
                    exit 2
                fi
                # Plan review seat 4R: only when the session's Formation
                # names an external AI there (needs the Formation helpers).
                FORMATION=$(_vdgg_state_get formation "$STATE_FILE")
                if [ -n "$FORMATION" ]; then
                    VDGG_CWD="$CWD"
                    VDGG_STATE_DIR="$CWD/.claude"
                    VDGG_TASKS_DIR="$CWD/tasks/vdgg"
                    # shellcheck source=vdgg-state.sh
                    . "${_VDGG_HOOK_DIR}/vdgg-state.sh"
                    if ! REVIEW_PROBLEMS=$(_vdgg_ev_check_plan_review "$TASKS_DIR" "$FORMATION"); then
                        echo "VibesDeGoGo! Step ${STEP} (planning) [${VDGG_ID}]: ${REVIEW_PROBLEMS}" >&2
                        exit 2
                    fi
                fi
            fi
        fi
        ;;

    task-selected)
        # Once a task is selected, advance to implementing before editing files.
        if [ -n "${FILE_PATH:-}" ]; then
            echo "VibesDeGoGo! [${VDGG_ID:-unknown}]: Tool call blocked by VibesDeGoGo! hook." >&2
            exit 2
        fi
        ;;

    implementing|testing)
        # Implementation edits must stay inside the task allowlist declared by
        # vdgg_task_begin. Task notes under tasks/vdgg/{id}/ stay editable.
        if [ -n "${FILE_PATH:-}" ]; then
            if [ -n "$FILE_PATH" ] && ! _vdgg_is_task_note "$FILE_PATH"; then
                # Step 6 is patch first: implementation files change only
                # through vdgg_patch_apply / vdgg_codemod_apply, which the
                # 6 -> 7 gate below checks. Testing refuses direct edits too:
                # a review fix goes through reflection and the next loop's
                # patch, so no code enters the tree without one.
                if [ "$PHASE" = "implementing" ] || [ "$PHASE" = "testing" ]; then
                    echo "VibesDeGoGo! Step ${STEP} (${PHASE}) [${VDGG_ID}]: Review fixes too go through reflection and a patch. Step 6 is patch first: write the change as a unified diff under tasks/vdgg/${VDGG_ID}/patch/ and apply it with vdgg_patch_apply <file> (mechanical bulk edits: vdgg_codemod_apply <expected-files> <command>)." >&2
                    exit 2
                fi
                if [ -z "$TASK_ALLOWLIST_FILE" ] || [ ! -f "$TASK_ALLOWLIST_FILE" ]; then
                    echo "VibesDeGoGo! Step ${STEP} (${PHASE}) [${VDGG_ID}]: No active task allowlist. Run vdgg_task_begin before editing implementation files." >&2
                    exit 2
                fi
                NORMALIZED_PATH=$(_vdgg_normalize_project_path "$FILE_PATH")
                if ! grep -qxF "$NORMALIZED_PATH" "$TASK_ALLOWLIST_FILE"; then
                    echo "VibesDeGoGo! Step ${STEP} (${PHASE}) [${VDGG_ID}]: Task allowlist blocks edit: ${NORMALIZED_PATH}" >&2
                    exit 2
                fi
            fi
        fi
        # Commit only after verification and progress are complete.
        if [ "$TOOL_NAME" = "Bash" ]; then
            if echo "$COMMAND" | grep -qE "$GIT_COMMIT_PATTERN"; then
                echo "VibesDeGoGo! [${VDGG_ID:-unknown}]: Tool call blocked by VibesDeGoGo! hook." >&2
                exit 2
            fi
            # Patch evidence: 6 -> 7 needs at least one vdgg_patch_apply or
            # vdgg_codemod_apply for this task, and the allowlisted files must
            # still hold exactly what the last one left.
            if [ "$PHASE" = "implementing" ] && echo "$GATE_COMMAND" | grep -qE 'vdgg_state_(advance|loop|write)[[:space:]]+7[[:space:]]+testing([^[:alnum:]_-]|$)'; then
                _vdgg_load_evidence
                if ! CHAIN_PROBLEMS=$(_vdgg_ev_chain_check "$CWD/.claude/.vdgg-task-patchchain-${VDGG_ID}" "$TASK_ALLOWLIST_FILE" "$CWD"); then
                    echo "VibesDeGoGo! Step ${STEP} (implementing) [${VDGG_ID}]: Step 6 patch evidence is missing: ${CHAIN_PROBLEMS}. Apply changes with vdgg_patch_apply (or vdgg_codemod_apply); after an out-of-band edit, vdgg_task_rollback and re-apply it as a patch." >&2
                    exit 2
                fi
            fi
            # A failed test must go through reflection before more implementation.
            if [ "$PHASE" = "testing" ] && echo "$GATE_COMMAND" | grep -qE 'vdgg_state_(loop|advance|write)[[:space:]]+[0-9]+[[:space:]]+implementing'; then
                echo "VibesDeGoGo! Step ${STEP} (${PHASE}) [${VDGG_ID}]: This action is blocked in the current phase." >&2
                exit 2
            fi
            # verified requires a review gate: either the simplify sentinel or the
            # explicit review sentinel written by vdgg_review_run,
            # and the review must not have edited implementation code.
            if [ "$PHASE" = "testing" ] && echo "$GATE_COMMAND" | grep -qE 'vdgg_state_(advance|loop|write)[[:space:]]+[0-9]+[[:space:]]+verified'; then
                # When a task allowlist is active, the task gate must have passed.
                if [ -n "$TASK_ALLOWLIST_FILE" ] && [ -f "$TASK_ALLOWLIST_FILE" ] && [ ! -f "$TASK_GATE_FILE" ]; then
                    echo "VibesDeGoGo! Step ${STEP} (${PHASE}) [${VDGG_ID}]: Run vdgg_task_gate successfully before verified." >&2
                    exit 2
                fi
                # Plan reconciliation: a task from todo.md needs a record in
                # progress.md of how the diff compares with its plan
                # (vdgg_plan_diff). Discrepancies are allowed; silence is not.
                _vdgg_load_evidence
                if ! RECON_PROBLEMS=$(_vdgg_ev_check_reconciliation "${TASKS_DIR}/todo.md" "${TASKS_DIR}/progress.md" "$(_vdgg_state_get current_task "$STATE_FILE")"); then
                    echo "VibesDeGoGo! Step ${STEP} (${PHASE}) [${VDGG_ID}]: ${RECON_PROBLEMS}" >&2
                    exit 2
                fi
                SIMPLIFY_SENTINEL="$CWD/.claude/.vdgg-simplify-sentinel-${VDGG_ID}-${LOOP_COUNT}"
                REVIEW_SENTINEL="$CWD/.claude/.vdgg-review-sentinel-${VDGG_ID}-${LOOP_COUNT}"
                GATE_FILE=""
                if [ -f "$SIMPLIFY_SENTINEL" ]; then
                    GATE_FILE="$SIMPLIFY_SENTINEL"
                elif [ -f "$REVIEW_SENTINEL" ]; then
                    GATE_FILE="$REVIEW_SENTINEL"
                fi
                if [ -z "$GATE_FILE" ]; then
                    echo "VibesDeGoGo! [${VDGG_ID:-unknown}]: Tool call blocked by VibesDeGoGo! hook." >&2
                    exit 2
                fi
                MODIFIED=$(grep '^modified=' "$GATE_FILE" | head -1 | sed 's/^modified=//')
                if [ "$MODIFIED" = "1" ]; then
                    echo "VibesDeGoGo! Step ${STEP} (${PHASE}) [${VDGG_ID}]: This action is blocked in the current phase." >&2
                    exit 2
                fi
                # Layer 4 consistency: delegate to the canonical helper.
                # Strict 0/1 exit + stdout tag ("layer4" | "legacy") lets the
                # hook branch without a set -e shield.
                _VDGG_HOOK_SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)
                # shellcheck source=vdgg-state.sh
                . "${_VDGG_HOOK_SCRIPT_DIR}/vdgg-state.sh"
                if ! _vdgg_sentinel_class=$(_vdgg_validate_sentinel_fields "$GATE_FILE"); then
                    echo "VibesDeGoGo! Step ${STEP} (${PHASE}) [${VDGG_ID}]: sentinel invariant violation; refusing verified." >&2
                    exit 2
                fi
                # Layer 3 gate-read policy: block verified when a clean
                # primary skipped vdgg_review_countersign. Legacy sentinels
                # have no countersign_required field, so this is a no-op there.
                if ! _vdgg_review_gate_ready "$GATE_FILE"; then
                    echo "VibesDeGoGo! Step ${STEP} (${PHASE}) [${VDGG_ID}]: Layer 3 countersign missing for a clean primary review; refusing verified. Run vdgg_review_countersign before advancing." >&2
                    exit 2
                fi
                if [ "$_vdgg_sentinel_class" = "legacy" ]; then
                    echo "VibesDeGoGo! [${VDGG_ID}]: verified via legacy sentinel (pre-Layer-4). Consider re-running review with --review-output for Layer 1 validation." >&2
                fi
                # Consume the sentinels so they cannot be reused by a later cycle.
                rm -f "$SIMPLIFY_SENTINEL" "$REVIEW_SENTINEL"
            fi
        fi
        ;;

    reflection)
        # Reflection can only update retry investigation notes and progress.
        if [ -n "${FILE_PATH:-}" ]; then
            if [ -n "$FILE_PATH" ]; then
                if [[ "$FILE_PATH" == "${TASKS_DIR}/progress.md" ]] \
                    || [[ "$FILE_PATH" == "${TASKS_DIR}"/investigation-r*.md ]]; then
                    exit 0
                fi
            fi
            echo "VibesDeGoGo! reflection [${VDGG_ID}]: Reflection must update retry investigation and progress before returning to implementation." >&2
            exit 2
        fi
        # Reflection may use Bash, but it may not jump directly to verified.
        if [ "$TOOL_NAME" = "Bash" ]; then
            # verified is only reachable from testing after review.
            if echo "$GATE_COMMAND" | grep -qE 'vdgg_state_(advance|loop|write)[[:space:]]+[0-9]+[[:space:]]+verified'; then
                echo "VibesDeGoGo! Step ${STEP} (${PHASE}) [${VDGG_ID}]: This action is blocked in the current phase." >&2
                exit 2
            fi
            if echo "$GATE_COMMAND" | grep -qE 'vdgg_state_(loop|advance|write)[[:space:]]+6[[:space:]]+implementing'; then
                PROGRESS_FILE="${TASKS_DIR}/progress.md"
                RETRY_INVESTIGATION_FILE="${TASKS_DIR}/investigation-r${LOOP_COUNT}.md"
                if [ ! -f "$RETRY_INVESTIGATION_FILE" ]; then
                    echo "VibesDeGoGo! Step ${STEP} (${PHASE}) [${VDGG_ID}]: This action is blocked in the current phase." >&2
                    exit 2
                fi
                if [ ! -f "$PROGRESS_FILE" ]; then
                    echo "VibesDeGoGo! Step ${STEP} (${PHASE}) [${VDGG_ID}]: This action is blocked in the current phase." >&2
                    exit 2
                fi
                STATE_MTIME=$(_vdgg_mtime "$STATE_FILE")
                RETRY_INVESTIGATION_MTIME=$(_vdgg_mtime "$RETRY_INVESTIGATION_FILE")
                PROGRESS_MTIME=$(_vdgg_mtime "$PROGRESS_FILE")
                if [ "$RETRY_INVESTIGATION_MTIME" -le "$STATE_MTIME" ]; then
                    echo "VibesDeGoGo! Step ${STEP} (${PHASE}) [${VDGG_ID}]: This action is blocked in the current phase." >&2
                    exit 2
                fi
                if [ "$PROGRESS_MTIME" -le "$STATE_MTIME" ]; then
                    echo "VibesDeGoGo! Step ${STEP} (${PHASE}) [${VDGG_ID}]: This action is blocked in the current phase." >&2
                    exit 2
                fi
            fi
        fi
        ;;

    verified|progress|commit)
        # No code edits after verification; only progress/version metadata may change.
        if [ -n "${FILE_PATH:-}" ]; then
            if { [ "$PHASE" = "progress" ] || [ "$PHASE" = "commit" ]; } && [ -n "$FILE_PATH" ]; then
                # progress.md remains editable for validation and commit notes;
                # the Step 8.5 confession and its records are written here too.
                if [[ "$FILE_PATH" == "${TASKS_DIR}/progress.md" ]] \
                    || [[ "$FILE_PATH" == "${TASKS_DIR}/confession.md" ]] \
                    || [[ "$FILE_PATH" == "${TASKS_DIR}/findings.md" ]] \
                    || [[ "$FILE_PATH" == "${TASKS_DIR}"/evidence/* ]]; then
                    exit 0
                fi
                # Version files explicitly configured in `.vdgg-target` are allowed.
                TARGET_FILE="$CWD/.vdgg-target"
                if [ -f "$TARGET_FILE" ]; then
                    ALLOWED_PATHS=$(grep -E '^VERSION_FILE_[0-9]+_PATH=' "$TARGET_FILE" \
                        | sed -E 's/^[^=]*=//' \
                        | sed -E 's/^"(.*)"$/\1/' \
                        | sed -E "s/^'(.*)'\$/\\1/" \
                        | grep -v '^$' || true)
                    while IFS= read -r allowed; do
                        [ -z "$allowed" ] && continue
                        if [[ "$FILE_PATH" == "${allowed}" ]] \
                            || [[ "$FILE_PATH" == "$CWD/${allowed}" ]]; then
                            exit 0
                        fi
                    done <<< "$ALLOWED_PATHS"
                fi
            fi
            echo "VibesDeGoGo! Step ${STEP} (${PHASE}) [${VDGG_ID}]: This action is blocked in the current phase." >&2
            exit 2
        fi
        # Step 8.5 confession: leaving Step 8 for the commit needs a confession
        # that passes the mechanical checks and an audit of that very text.
        if [ "$TOOL_NAME" = "Bash" ] && [ "$PHASE" = "progress" ] \
            && echo "$GATE_COMMAND" | grep -qE 'vdgg_state_(advance|loop|write)[[:space:]]+9[[:space:]]+commit([^[:alnum:]_-]|$)'; then
            _vdgg_load_evidence
            if ! CONF_PROBLEMS=$(_vdgg_ev_check_confession "$TASKS_DIR" "$CWD/.claude/.vdgg-friction-${VDGG_ID}"); then
                {
                    echo "VibesDeGoGo! Step ${STEP} (progress) [${VDGG_ID}]: Step 8.5 confession is not complete (SKILL.md Step 8.5):"
                    printf '%s\n' "$CONF_PROBLEMS" | sed 's/^/  - /'
                } >&2
                exit 2
            fi
            if ! AUDIT_PROBLEMS=$(_vdgg_ev_check_audit "$CWD/.claude/.vdgg-audit-${VDGG_ID}" "${TASKS_DIR}/confession.md"); then
                echo "VibesDeGoGo! Step ${STEP} (progress) [${VDGG_ID}]: Step 8.5 audit: ${AUDIT_PROBLEMS}" >&2
                exit 2
            fi
        fi
        # branch-pr workflow forbids committing or pushing directly on the base branch.
        if [ "$TOOL_NAME" = "Bash" ] && [ "$PHASE" = "commit" ]; then
            # Defaults match SKILL.md unless `.vdgg-target` overrides them.
            WF=branch-pr; BB=""
            if [ -f "$CWD/.vdgg-target" ]; then
                WF=$( { grep -E '^WORKFLOW=' "$CWD/.vdgg-target" 2>/dev/null || true; } | tail -1 | sed -E 's/^[^=]*=//; s/^"//; s/"$//')
                BB=$( { grep -E '^BASE_BRANCH=' "$CWD/.vdgg-target" 2>/dev/null || true; } | tail -1 | sed -E 's/^[^=]*=//; s/^"//; s/"$//')
                WF=${WF:-branch-pr}
            fi
            if [ "$WF" != "trunk" ]; then
                if [ -z "$BB" ]; then
                    BB=$(git -C "$CWD" symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null || true)
                    BB=${BB#origin/}
                    BB=${BB:-main}
                fi
                CURBR=$(git -C "$CWD" rev-parse --abbrev-ref HEAD 2>/dev/null || true)
                # Escape base branch for grep -E before matching push commands.
                BB_RE=$(printf '%s' "$BB" | sed 's/[^[:alnum:]]/\\&/g')
                if echo "$COMMAND" | grep -qE '(^|[^a-zA-Z0-9_-])git[[:space:]]+(commit|push)([^[:alnum:]_-]|$)'; then
                    if [ "$CURBR" = "$BB" ]; then
                        echo "VibesDeGoGo! Step ${STEP} (commit) [${VDGG_ID}]: branch-pr workflow requires committing/pushing the feature branch and opening a PR." >&2
                        exit 2
                    fi
                    if echo "$COMMAND" | grep -qE '(^|[^a-zA-Z0-9_-])git[[:space:]]+push' \
                        && echo "$COMMAND" | grep -qE "(^|[^a-zA-Z0-9_/.-])${BB_RE}([^a-zA-Z0-9_/.-]|\$)"; then
                        echo "VibesDeGoGo! Step ${STEP} (commit) [${VDGG_ID}]: branch-pr workflow requires committing/pushing the feature branch and opening a PR." >&2
                        exit 2
                    fi
                fi
            fi
        fi
        ;;

    *)
        # Unknown phase: fail closed. Read-like tools already returned 0 at the
        # tool-name switch, so only mutating tools (Edit/Write/Bash/Agent) reach
        # here. A crafted state file (or any future phase the guards don't know)
        # must not silently disable enforcement. vdgg_state_write also rejects
        # unknown phases at the source; this is defense in depth.
        echo "VibesDeGoGo! [${VDGG_ID:-unknown}]: Unknown workflow phase '${PHASE}'. Tool call blocked by VibesDeGoGo! hook." >&2
        exit 2
        ;;
esac

# Step 3 read evidence from Bash, recorded only for a command no guard refused.
if [ "$PHASE" = "investigating" ] && [ "$TOOL_NAME" = "Bash" ]; then
    _vdgg_load_evidence
    _vdgg_ev_bash_read_paths "$COMMAND" | _vdgg_ev_record_reads "$READ_LOG" "$CWD" || true
fi

exit 0
