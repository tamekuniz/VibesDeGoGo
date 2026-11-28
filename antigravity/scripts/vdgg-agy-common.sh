#!/bin/bash
# vdgg-agy-common.sh - Shared helpers for the VibesDeGoGo! Antigravity plugin hooks.
#
# Reuses the Codex edition's state machine, evidence gates, and hook scripts
# (.agents/skills/vibesdegogo/) so workflow rules stay in one place.

_vdgg_agy_plugin_dir() {
  if [ -n "${PLUGIN_ROOT:-}" ] && [ -d "$PLUGIN_ROOT" ]; then
    (cd "$PLUGIN_ROOT" 2>/dev/null && pwd -P)
    return 0
  fi
  (cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." 2>/dev/null && pwd -P)
}

_vdgg_agy_resolve_codex_skill_dir() {
  if [ -n "${VDGG_CODEX_SKILL_DIR:-}" ] && [ -f "$VDGG_CODEX_SKILL_DIR/scripts/vdgg-state.sh" ]; then
    printf '%s\n' "$VDGG_CODEX_SKILL_DIR"
    return 0
  fi
  local pdir repo_skill
  pdir=$(_vdgg_agy_plugin_dir)
  repo_skill="$(cd "$pdir/.." 2>/dev/null && pwd -P)/.agents/skills/vibesdegogo"
  if [ -f "$repo_skill/scripts/vdgg-state.sh" ]; then
    printf '%s\n' "$repo_skill"
    return 0
  fi
  if [ -f "$HOME/.agents/skills/vibesdegogo/scripts/vdgg-state.sh" ]; then
    printf '%s\n' "$HOME/.agents/skills/vibesdegogo"
    return 0
  fi
  return 1
}

_vdgg_agy_resolve_root() {
  local raw_cwd="$1" root
  [ -n "$raw_cwd" ] || raw_cwd="$PWD"
  if root=$(git -C "$raw_cwd" rev-parse --show-toplevel 2>/dev/null); then
    printf '%s\n' "$root"
    return 0
  fi
  printf '%s\n' "$raw_cwd"
}

_vdgg_agy_is_required() {
  local root="$1" target v
  target="$root/.vdgg-target"
  [ -f "$target" ] || return 1
  v=$(grep -m1 '^VDGG_REQUIRED=' "$target" 2>/dev/null | sed -E 's/^[^=]*=//; s/^"(.*)"$/\1/; s/^'\''(.*)'\''$/\1/' || true)
  [ "$v" = "on" ]
}

_vdgg_agy_active_id() {
  local root="$1" active_file id
  active_file="$root/.codex/.vdgg-active"
  [ -f "$active_file" ] || return 1
  id=$(cat "$active_file" 2>/dev/null || true)
  [ -n "$id" ] || return 1
  case "$id" in
    *[!A-Za-z0-9_-]*) return 1 ;;
  esac
  [ -f "$root/.codex/.vdgg-state-${id}" ] || return 1
  printf '%s\n' "$id"
}

_vdgg_agy_state_get() {
  grep "^$1=" "$2" 2>/dev/null | head -1 | cut -d= -f2- || true
}

_vdgg_agy_json_allow() {
  printf '{"decision":"allow"}\n'
}

_vdgg_agy_json_deny() {
  jq -nc --arg reason "$1" '{"decision":"deny","reason":$reason}'
}

_vdgg_agy_json_continue() {
  jq -nc --arg reason "$1" '{"decision":"continue","reason":$reason}'
}
