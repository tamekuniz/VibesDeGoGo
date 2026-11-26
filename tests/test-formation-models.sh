#!/bin/bash
# test-formation-models.sh — Formation model/effort/subagent syntax and the
# preflight model-name warnings (proposal item 6), for both editions.
#   - opus55 / fable51 shorthands, a shorthand with an effort
#   - claude effort xhigh / max
#   - the SUB seat and vdgg_subagent_model
#   - preflight warns on an unknown claude model, and on a codex model missing
#     from the local Codex catalog — and stays silent when there is no catalog
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "$ROOT/tests/lib/assert.sh"
. "$ROOT/tests/lib/exec-fixtures.sh"

T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

run_edition() {
    local edition="$1" state="$2"
    (
        export HOME="$T/home-$edition"
        export VDGG_CONFIG_DIR="$T/cfg-$edition"
        export CODEX_HOME="$T/codex-$edition"
        mkdir -p "$HOME" "$VDGG_CONFIG_DIR/formations" "$T/repo-$edition"
        cd "$T/repo-$edition" || exit 1
        git init -q .
        export VDGG_CWD="$T/repo-$edition"
        . "$state"
        set +e
        vdgg_install_exec_fixtures "$T/bin-$edition" "$VDGG_CONFIG_DIR"
        F="$VDGG_CONFIG_DIR/formations"

        # Shorthands and effort.
        _vdgg_parse_seat_value "opus55" "x"
        assert_eq "claude-opus-5-5" "$_VDGG_SEAT_MODEL" "$edition: opus55 expands to claude-opus-5-5"
        _vdgg_parse_seat_value "fable51" "x"
        assert_eq "claude-fable-5-1" "$_VDGG_SEAT_MODEL" "$edition: fable51 expands to claude-fable-5-1"
        _vdgg_parse_seat_value "opus55 medium" "x"
        assert_exit_code 0 "$?" "$edition: a shorthand takes an effort"
        assert_eq "medium" "$_VDGG_SEAT_EFFORT" "$edition: the shorthand's effort is kept"
        assert_eq "claude" "$_VDGG_SEAT_NAME" "$edition: a shorthand still runs the claude wrapper"
        _vdgg_parse_seat_value "opus55 claude-sonnet-5" "x" 2>/dev/null
        assert_exit_code 1 "$?" "$edition: a shorthand refuses a second model"
        _vdgg_parse_seat_value "opus55 high low" "x" 2>/dev/null
        assert_exit_code 1 "$?" "$edition: a shorthand refuses two tokens"
        _vdgg_parse_seat_value "claude claude-opus-5-5 xhigh" "x"
        assert_eq "xhigh" "$_VDGG_SEAT_EFFORT" "$edition: claude accepts effort xhigh"
        _vdgg_parse_seat_value "claude max" "x"
        assert_eq "max" "$_VDGG_SEAT_EFFORT" "$edition: claude accepts effort max"
        assert_eq "" "$_VDGG_SEAT_MODEL" "$edition: max is an effort, not a model"
        _vdgg_parse_seat_value "codex max" "x"
        assert_eq "max" "$_VDGG_SEAT_MODEL" "$edition: max stays a model name for codex (its effort vocabulary is unchanged)"

        # Builtin agy (Antigravity CLI): model and effort tokens like claude/codex.
        _vdgg_parse_seat_value "agy gemini-4-neon-high max" "x"
        assert_exit_code 0 "$?" "$edition: agy takes a model and an effort"
        assert_eq "agy" "$_VDGG_SEAT_NAME" "$edition: agy stays the agy builtin"
        assert_eq "gemini-4-neon-high" "$_VDGG_SEAT_MODEL" "$edition: agy keeps its model"
        assert_eq "max" "$_VDGG_SEAT_EFFORT" "$edition: agy accepts effort max"
        _vdgg_parse_seat_value "agy minimal" "x"
        assert_eq "minimal" "$_VDGG_SEAT_MODEL" "$edition: minimal is not an agy effort, so it is the model"
        _vdgg_parse_seat_value "agy m1 high extra" "x" 2>/dev/null
        assert_exit_code 1 "$?" "$edition: agy refuses a third token"
        printf '7: agy gemini-4-neon-high | codex high\nMAGI-M: agy\n' > "$F/agy.conf"
        vdgg_formation_preflight agy >/dev/null 2>"$T/err-$edition"
        assert_exit_code 0 "$?" "$edition: a Formation naming agy passes preflight"
        assert_eq "" "$(cat "$T/err-$edition")" "$edition: agy models produce no warning"
        assert_contains "$(_vdgg_seat_command "agy gemini-4-neon-high" x)" "vdgg-exec-agy.sh" "$edition: agy runs the bundled agy wrapper"

        # SUB seat.
        printf '3: opus55 medium\nSUB: fable51 max\n' > "$F/sub.conf"
        vdgg_formation_preflight sub >/dev/null 2>&1
        assert_exit_code 0 "$?" "$edition: SUB is a valid seat"
        assert_eq "agent fable max" "$(vdgg_subagent_model sub)" "$edition: SUB maps to an Agent model family and effort"
        printf '*: okexec\n' > "$F/wild.conf"
        assert_eq "inline" "$(vdgg_subagent_model wild)" "$edition: the * wildcard does not assign SUB"
        printf 'SUB: codex high\n' > "$F/subx.conf"
        assert_eq "executor" "$(vdgg_subagent_model subx)" "$edition: a non-claude SUB runs as an executor"
        printf 'sub: claude claude-opus-5-5\n' > "$F/subc.conf"
        assert_eq "agent opus" "$(vdgg_subagent_model subc)" "$edition: SUB is case-insensitive and maps claude-opus-* to opus"

        # Preflight model-name warnings: warn, never fail.
        printf '3: claude claude-opsu-5 high\n6: opus55\n' > "$F/typo.conf"
        vdgg_formation_preflight typo >/dev/null 2>"$T/err-$edition"
        assert_exit_code 0 "$?" "$edition: a mistyped claude model does not fail preflight"
        assert_contains "$(cat "$T/err-$edition")" "claude-opsu-5" "$edition: a mistyped claude model is warned about"
        printf '3: claude claude-opus-5-5 high\n6: claude sonnet\n' > "$F/good.conf"
        vdgg_formation_preflight good >/dev/null 2>"$T/err-$edition"
        assert_eq "" "$(cat "$T/err-$edition")" "$edition: known claude models produce no warning"
        vdgg_formation_resolve STEP_3_AI typo >/dev/null 2>"$T/err-$edition"
        assert_eq "" "$(cat "$T/err-$edition")" "$edition: resolving a seat does not repeat the warnings"

        printf '7: codex atlus medium\n' > "$F/cx.conf"
        rm -rf "$CODEX_HOME"
        vdgg_formation_preflight cx >/dev/null 2>"$T/err-$edition"
        assert_exit_code 0 "$?" "$edition: preflight passes without a Codex catalog"
        assert_eq "" "$(cat "$T/err-$edition")" "$edition: no Codex catalog means no warning (CI and cloud stay quiet)"
        mkdir -p "$CODEX_HOME"
        printf 'model_catalog_json = "catalog.json"\n' > "$CODEX_HOME/config.toml"
        printf '{"models":[{"slug":"gpt-5-codex"},{"slug":"atlas"}]}\n' > "$CODEX_HOME/catalog.json"
        vdgg_formation_preflight cx >/dev/null 2>"$T/err-$edition"
        assert_exit_code 0 "$?" "$edition: an unknown codex model does not fail preflight"
        assert_contains "$(cat "$T/err-$edition")" "atlus" "$edition: a codex model missing from the catalog is warned about"
        printf '7: codex atlas medium\n' > "$F/cx.conf"
        vdgg_formation_preflight cx >/dev/null 2>"$T/err-$edition"
        assert_eq "" "$(cat "$T/err-$edition")" "$edition: a codex model in the catalog produces no warning"
        rm -f "$CODEX_HOME/config.toml"
        printf '{"models":[{"slug":"atlas"}]}\n' > "$CODEX_HOME/models_cache.json"
        printf '7: codex atlus\n' > "$F/cx.conf"
        vdgg_formation_preflight cx >/dev/null 2>"$T/err-$edition"
        assert_contains "$(cat "$T/err-$edition")" "atlus" "$edition: models_cache.json is used when config.toml names no catalog"
    ) || fail "$1: formation model checks aborted"
}

run_edition claude "$ROOT/skills/vibesdegogo/scripts/vdgg-state.sh"
run_edition codex "$ROOT/.agents/skills/vibesdegogo/scripts/vdgg-state.sh"
echo "formation models: all checks passed"
