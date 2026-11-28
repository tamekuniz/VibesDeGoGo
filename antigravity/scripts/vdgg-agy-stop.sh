#!/bin/bash
# vdgg-agy-stop.sh - Antigravity Stop adapter for VibesDeGoGo!.
#
# Reads the latest assistant reply from Antigravity's transcript.jsonl,
# delegates the stop check to the Codex edition's vdgg-hook-stop.sh, and
# translates {"decision":"block"} to Antigravity's {"decision":"continue"}.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd -P)"
# shellcheck source=vdgg-agy-common.sh
. "$SCRIPT_DIR/vdgg-agy-common.sh"

INPUT=$(cat)

if ! command -v jq >/dev/null 2>&1; then
  printf '{}\n'
  exit 0
fi

# Never trap user cancellations or hard engine limits.
TERM_REASON=$(printf '%s' "$INPUT" | jq -r '.terminationReason // empty')
case "$TERM_REASON" in
  USER_CANCELED|MAX_INVOCATIONS|MAX_FORCED_INVOCATIONS|MAX_TOKEN_BUDGET_EXCEEDED)
    printf '{}\n'
    exit 0
    ;;
esac

# Cap forced continuations within one turn so a wedged gate cannot loop forever.
CONT_ACTIVE=$(printf '%s' "$INPUT" | jq -r '.continuationActive // false')
EXEC_NUM=$(printf '%s' "$INPUT" | jq -r '.executionNum // 0')
case "$EXEC_NUM" in ''|*[!0-9]*) EXEC_NUM=0 ;; esac
if [ "$CONT_ACTIVE" = "true" ] && [ "$EXEC_NUM" -ge 3 ]; then
  printf '{}\n'
  exit 0
fi

RAW_CWD=$(printf '%s' "$INPUT" | jq -r '.cwd // .workspacePaths[0] // empty')
ROOT=$(_vdgg_agy_resolve_root "$RAW_CWD")

if ! _vdgg_agy_active_id "$ROOT" >/dev/null 2>&1; then
  printf '{}\n'
  exit 0
fi

if ! CODEX_SKILL_DIR=$(_vdgg_agy_resolve_codex_skill_dir); then
  printf '{}\n'
  exit 0
fi

TRANSCRIPT_PATH=$(printf '%s' "$INPUT" | jq -r '.transcriptPath // empty')
LAST_MESSAGE=""
if [ -n "$TRANSCRIPT_PATH" ] && [ -f "$TRANSCRIPT_PATH" ]; then
  # Antigravity transcript.jsonl records assistant turns as PLANNER_RESPONSE
  # entries with a top-level string .content field.
  LAST_MESSAGE=$(jq -rs '
    [.[] | select(.type == "PLANNER_RESPONSE" and (.content | type) == "string" and (.content | length) > 0)]
    | last | .content // ""
  ' "$TRANSCRIPT_PATH" 2>/dev/null || true)
fi

PAYLOAD=$(jq -nc \
  --arg cwd "$ROOT" \
  --arg last_assistant_message "$LAST_MESSAGE" \
  '{cwd: $cwd, last_assistant_message: $last_assistant_message}')

VERDICT=$(env -u VDGG_CWD -u VDGG_STATE_DIR -u VDGG_TASKS_DIR \
  VDGG_CODEX_SKILL_DIR="$CODEX_SKILL_DIR" \
  bash "$CODEX_SKILL_DIR/scripts/vdgg-hook-stop.sh" <<< "$PAYLOAD" 2>/dev/null || true)

DECISION=$(printf '%s' "$VERDICT" | jq -r '.decision // empty' 2>/dev/null || true)
if [ "$DECISION" = "block" ]; then
  REASON=$(printf '%s' "$VERDICT" | jq -r '.reason // empty' 2>/dev/null || true)
  [ -n "$REASON" ] || REASON="VibesDeGoGo! is still active. Continue the workflow or output [Intentional Stop] with a reason."
  _vdgg_agy_json_continue "$REASON"
  exit 0
fi

printf '{}\n'
exit 0
