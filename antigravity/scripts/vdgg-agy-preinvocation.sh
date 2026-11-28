#!/bin/bash
# vdgg-agy-preinvocation.sh - Injects active VibesDeGoGo! state before model calls.
#
# When no session is active in the workspace, returns {} and stays out of the way.

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

CODEX_SKILL_DIR=$(_vdgg_agy_resolve_codex_skill_dir 2>/dev/null || printf '%s' "$HOME/.agents/skills/vibesdegogo")
STATE_FILE="$ROOT/.codex/.vdgg-state-${VDGG_ID}"
STEP=$(_vdgg_agy_state_get step "$STATE_FILE")
PHASE=$(_vdgg_agy_state_get phase "$STATE_FILE")
LOOP_COUNT=$(_vdgg_agy_state_get loop_count "$STATE_FILE")
CURRENT_TASK=$(_vdgg_agy_state_get current_task "$STATE_FILE")
FORMATION=$(_vdgg_agy_state_get formation "$STATE_FILE")

MSG="VibesDeGoGo! active session: id=${VDGG_ID}, step=${STEP}, phase=${PHASE}, loop=${LOOP_COUNT:-0}"
[ -n "$CURRENT_TASK" ] && MSG="${MSG}, task=${CURRENT_TASK}"
[ -n "$FORMATION" ] && MSG="${MSG}, formation=${FORMATION}"
MSG="${MSG}. Source \"${CODEX_SKILL_DIR}/scripts/vdgg-state.sh\" in run_command before calling vdgg_* helpers. Use literal step/phase arguments. Output [Intentional Stop] with a concrete reason only when stopping intentionally."

jq -nc --arg msg "$MSG" '{injectSteps: [{systemMessage: {systemMessage: $msg}}]}'
exit 0
