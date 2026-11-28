#!/bin/bash
# vdgg-agy-pretool.sh - Antigravity PreToolUse adapter for VibesDeGoGo!.
#
# Translates Antigravity's camelCase PreToolUse JSON payload into the Codex
# edition's hook contract, invokes vdgg-hook-pretool.sh, and maps its exit
# status + stderr back to Antigravity's {"decision":"allow"|"deny"} JSON.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd -P)"
# shellcheck source=vdgg-agy-common.sh
. "$SCRIPT_DIR/vdgg-agy-common.sh"

INPUT=$(cat)

if ! command -v jq >/dev/null 2>&1; then
  FALLBACK_CWD=$(printf '%s' "$INPUT" | grep -oE '"cwd"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed -E 's/.*:[[:space:]]*"([^"]*)"$/\1/' || true)
  FALLBACK_CWD=$(_vdgg_agy_resolve_root "${FALLBACK_CWD:-$PWD}")
  if [ ! -f "$FALLBACK_CWD/.codex/.vdgg-active" ] && ! _vdgg_agy_is_required "$FALLBACK_CWD"; then
    _vdgg_agy_json_allow
    exit 0
  fi
  if printf '%s' "$INPUT" | grep -qE '"CommandLine"[[:space:]]*:[[:space:]]*"[^"]*(brew[[:space:]]+(install|reinstall)|apt(-get)?[[:space:]]+install|apk[[:space:]]+add|dnf[[:space:]]+install|yum[[:space:]]+install|pacman[[:space:]]+-S)[[:space:]]+[^"]*jq'; then
    _vdgg_agy_json_allow
    exit 0
  fi
  printf '{"decision":"deny","reason":"VibesDeGoGo! for Antigravity: jq is required for hooks but was not found on PATH. Install it (e.g. brew install jq)."}\n'
  exit 0
fi

RAW_CWD=$(printf '%s' "$INPUT" | jq -r '.cwd // .workspacePaths[0] // empty')
ROOT=$(_vdgg_agy_resolve_root "$RAW_CWD")

VDGG_ID=""
ARMED=0
if VDGG_ID=$(_vdgg_agy_active_id "$ROOT" 2>/dev/null); then
  ARMED=1
fi
REQUIRED=0
if _vdgg_agy_is_required "$ROOT"; then
  REQUIRED=1
fi

if [ "$ARMED" -eq 0 ] && [ "$REQUIRED" -eq 0 ]; then
  _vdgg_agy_json_allow
  exit 0
fi

if ! CODEX_SKILL_DIR=$(_vdgg_agy_resolve_codex_skill_dir); then
  _vdgg_agy_json_deny "VibesDeGoGo! for Antigravity: could not locate .agents/skills/vibesdegogo/scripts/vdgg-state.sh. Keep the VibesDeGoGo repository intact or set VDGG_CODEX_SKILL_DIR."
  exit 0
fi

TOOL_NAME=$(printf '%s' "$INPUT" | jq -r '.toolCall.name // empty')

# Block subagent/workflow fan-out until requirements are fixed (mirrors Claude Code's Agent guard).
if [ "$ARMED" -eq 1 ]; then
  STATE_FILE="$ROOT/.codex/.vdgg-state-${VDGG_ID}"
  PHASE=$(_vdgg_agy_state_get phase "$STATE_FILE")
  case "$TOOL_NAME" in
    invoke_subagent|run_workflow|swarm)
      if [ "$PHASE" = "declare" ] || [ "$PHASE" = "requirements" ]; then
        _vdgg_agy_json_deny "VibesDeGoGo! [${VDGG_ID}]: ${TOOL_NAME} is blocked during ${PHASE}. Finish Step 2 (requirements.md) before delegating."
        exit 0
      fi
      _vdgg_agy_json_allow
      exit 0
      ;;
  esac
fi

# Classify Antigravity tool names into Codex hook tool_name + tool_input.
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
  read_file|view_file|view_file_outline|view_code_item|grep_search|find_by_name|list_dir|\
  update_focus|update_steps|ask_question|search_web|read_url_content|\
  list_plugin_accounts|search_marketplace|manage_task|manage_subagents|send_message|schedule|\
  define_subagent|invoke_subagent|run_workflow|swarm)
    _vdgg_agy_json_allow
    exit 0
    ;;
  *)
    # Fail closed on unknown tools that expose a file path.
    FPATH=$(printf '%s' "$INPUT" | jq -r '.toolCall.args.Path // .toolCall.args.TargetFile // .toolCall.args.file_path // empty')
    if [ -n "$FPATH" ]; then
      MAPPED_TOOL="Write"
      MAPPED_INPUT=$(jq -nc --arg file_path "$FPATH" '{file_path: $file_path}')
    else
      _vdgg_agy_json_allow
      exit 0
    fi
    ;;
esac

PAYLOAD=$(jq -nc \
  --arg cwd "$ROOT" \
  --arg tool_name "$MAPPED_TOOL" \
  --argjson tool_input "$MAPPED_INPUT" \
  '{cwd: $cwd, tool_name: $tool_name, tool_input: $tool_input}')

ERR_FILE=$(mktemp "${TMPDIR:-/tmp}/vdgg-agy-pre.XXXXXX")
trap 'rm -f "$ERR_FILE"' EXIT

set +e
env -u VDGG_CWD -u VDGG_STATE_DIR -u VDGG_TASKS_DIR \
  VDGG_CODEX_SKILL_DIR="$CODEX_SKILL_DIR" \
  bash "$CODEX_SKILL_DIR/scripts/vdgg-hook-pretool.sh" <<< "$PAYLOAD" >/dev/null 2>"$ERR_FILE"
RC=$?
set -e

if [ "$RC" -eq 0 ]; then
  _vdgg_agy_json_allow
  exit 0
fi

REASON=$(cat "$ERR_FILE" 2>/dev/null || true)
[ -n "$REASON" ] || REASON="VibesDeGoGo! for Antigravity: tool call blocked by workflow gate (exit $RC)."
_vdgg_agy_json_deny "$REASON"
exit 0
