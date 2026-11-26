#!/bin/bash
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "$ROOT/tests/lib/assert.sh"

CC="$ROOT/skills/vibesdegogo"
CX="$ROOT/.agents/skills/vibesdegogo"

# Files shared verbatim between the two editions. Editing one side without the
# other is the drift this test exists to catch; sync the pair and re-run.
# local-inference-setup.md is NOT in this list: each edition names its own
# install path as the copy source, so the two diverge deliberately.
# An array, not a newline-separated string: zsh does not word-split an
# unquoted parameter expansion, so `for rel in $PAIRS` would iterate once
# over the whole blob there.
PAIRS=(
    scripts/vdgg-llm-start.sh
    scripts/vdgg-exec-claude.sh
    scripts/vdgg-exec-codex.sh
    scripts/vdgg-exec-agy.sh
    scripts/vdgg-evidence.sh
    references/servers-conf.md
    references/servers.conf.example
)

for rel in "${PAIRS[@]}"; do
    assert_file_exists "$CC/$rel" "Claude Code edition has $rel"
    assert_file_exists "$CX/$rel" "Codex edition has $rel"
    cmp -s "$CC/$rel" "$CX/$rel"
    assert_exit_code 0 "$?" "editions are byte-identical: $rel"
done

# The Formation block in vdgg-state.sh (from _vdgg_formation_keys up to
# vdgg_state_init) is kept byte-identical so the two editions stay diffable.
extract_formation() {
    awk '/^_vdgg_formation_keys\(\) \{/,/^vdgg_state_init\(\) \{/' "$1" | sed '$d'
}
extract_formation "$CC/scripts/vdgg-state.sh" > "${TMPDIR:-/tmp}/vdgg-sync-cc.$$"
extract_formation "$CX/scripts/vdgg-state.sh" > "${TMPDIR:-/tmp}/vdgg-sync-cx.$$"
cmp -s "${TMPDIR:-/tmp}/vdgg-sync-cc.$$" "${TMPDIR:-/tmp}/vdgg-sync-cx.$$"
STATUS=$?
rm -f "${TMPDIR:-/tmp}/vdgg-sync-cc.$$" "${TMPDIR:-/tmp}/vdgg-sync-cx.$$"
assert_exit_code 0 "$STATUS" "vdgg-state.sh Formation block is byte-identical across editions"
