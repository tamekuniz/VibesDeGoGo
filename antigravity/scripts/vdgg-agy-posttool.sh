#!/bin/bash
# vdgg-agy-posttool.sh - Antigravity PostToolUse adapter for VibesDeGoGo!.
#
# Records Step 3 read evidence for successful native read/search tools, and
# forwards command/file tool outcomes to the Codex edition's posttool hook
# (error tracking and review-sentinel modification detection).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd -P)"
# shellcheck source=vdgg-agy-common.sh
. "$SCRIPT_DIR/vdgg-agy-common.sh"

INPUT=$(cat)

if ! command -v jq >/dev/null 2>&1; then
  printf '{}\n'
  exit 0
fi

RAW_CWD=$(printf '%s' "$INPUT" | jq -r '.cwd // .workspacePaths[0] // empty')
ROOT=$(_vdgg_agy_resolve_root "$RAW_CWD")

if ! VDGG_ID=$(_vdgg_agy_active_id "$ROOT" 2>/dev/null); then
  printf '{}\n'
  exit 0
fi

if ! CODEX_SKILL_DIR=$(_vdgg_agy_resolve_codex_skill_dir); then
  printf '{}\n'
  exit 0
fi

STATE_FILE="$ROOT/.codex/.vdgg-state-${VDGG_ID}"
PHASE=$(_vdgg_agy_state_get phase "$STATE_FILE")
TOOL_NAME=$(printf '%s' "$INPUT" | jq -r '.toolCall.name // empty')
ERROR_MSG=$(printf '%s' "$INPUT" | jq -r '.error // empty')

# Record Step 3 read evidence only after a native read/search tool succeeds.
case "$TOOL_NAME" in
  read_file|view_file|view_file_outline|view_code_item|grep_search|find_by_name|list_dir)
    if [ "$PHASE" = "investigating" ] && [ -z "$ERROR_MSG" ]; then
      READ_PATH=$(printf '%s' "$INPUT" | jq -r '.toolCall.args.Path // .toolCall.args.AbsolutePath // .toolCall.args.SearchPath // .toolCall.args.SearchDirectory // .toolCall.args.DirectoryPath // empty')
      if [ -n "$READ_PATH" ] && [ -f "$CODEX_SKILL_DIR/scripts/vdgg-evidence.sh" ]; then
        # shellcheck source=/dev/null
        . "$CODEX_SKILL_DIR/scripts/vdgg-evidence.sh"
        printf '%s\n' "$READ_PATH" | _vdgg_ev_record_reads "$ROOT/.codex/.vdgg-read-${VDGG_ID}" "$ROOT" || true
      fi
    fi
    printf '{}\n'
    exit 0
    ;;
esac

MAPPED_TOOL=""
MAPPED_INPUT=""

case "$TOOL_NAME" in
  run_command)
    MAPPED_TOOL="Bash"
    CMD=$(printf '%s' "$INPUT" | jq -r '.toolCall.args.CommandLine // .toolCall.args.command // empty')
    MAPPED_INPUT=$(jq -nc --arg command "$CMD" '{command: $command}')
    ;;
  edit_file|replace_file_content|multi_replace_file_content)
    MAPPED_TOOL="Edit"
    FPATH=$(printf '%s' "$INPUT" | jq -r '.toolCall.args.Path // .toolCall.args.TargetFile // .toolCall.args.file_path // empty')
    MAPPED_INPUT=$(jq -nc --arg file_path "$FPATH" '{file_path: $file_path}')
    ;;
  write_file|write_to_file)
    MAPPED_TOOL="Write"
    FPATH=$(printf '%s' "$INPUT" | jq -r '.toolCall.args.Path // .toolCall.args.TargetFile // .toolCall.args.file_path // empty')
    MAPPED_INPUT=$(jq -nc --arg file_path "$FPATH" '{file_path: $file_path}')
    ;;
  *)
    printf '{}\n'
    exit 0
    ;;
esac

EXIT_CODE=0
if [ -n "$ERROR_MSG" ]; then
  # Extract numeric exit status when present (e.g. "exit status 1" or "code 1").
  # Default to 2 for unknown failures so they never masquerade as grep no-match (1).
  PARSED_CODE=$(printf '%s' "$ERROR_MSG" | sed -nE 's/.*(exit status|exit code|code)[[:space:]]*[:=]?[[:space:]]*([0-9]+).*/\2/p' | head -1 || true)
  case "$PARSED_CODE" in
    ''|*[!0-9]*|0) EXIT_CODE=2 ;;
    *) EXIT_CODE="$PARSED_CODE" ;;
  esac
fi

PAYLOAD=$(jq -nc \
  --arg cwd "$ROOT" \
  --arg tool_name "$MAPPED_TOOL" \
  --argjson tool_input "$MAPPED_INPUT" \
  --argjson exit_code "$EXIT_CODE" \
  --arg stderr "$ERROR_MSG" \
  '{cwd: $cwd, tool_name: $tool_name, tool_input: $tool_input, tool_response: {exit_code: $exit_code, stderr: $stderr}}')

env -u VDGG_CWD -u VDGG_STATE_DIR -u VDGG_TASKS_DIR \
  VDGG_CODEX_SKILL_DIR="$CODEX_SKILL_DIR" \
  bash "$CODEX_SKILL_DIR/scripts/vdgg-hook-posttool.sh" <<< "$PAYLOAD" >/dev/null 2>&1 || true

printf '{}\n'
exit 0
