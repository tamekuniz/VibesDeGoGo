#!/bin/bash
# test-exec-agy.sh — the bundled agy (Antigravity CLI) executor isolates an
# artifact seat in a throwaway copy of the work tree. A fake `agy` on PATH
# records what it saw and tries to escape; the real repository must not change.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "$ROOT/tests/lib/assert.sh"
W="$ROOT/skills/vibesdegogo/scripts/vdgg-exec-agy.sh"

T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
T=$(cd "$T" && pwd -P)

mkdir -p "$T/bin" "$T/repo/src" "$T/repo/tasks/vdgg/s1"
cat > "$T/bin/agy" <<'EOF'
#!/bin/sh
for a in "$@"; do printf '[%s]\n' "$a"; done
printf 'cwd=%s\n' "$(pwd)"
[ -f src/a.txt ] && echo saw-tracked
[ -f tasks/vdgg/s1/requirements.md ] && echo saw-input-dir
{ [ -e link ] || [ -L link ]; } && echo saw-symlink
echo junk > src/a.txt
out=tasks/vdgg/s1/out.md
case "${FAKE_MODE:-}" in
  file) echo from-file > "$out" ;;
  symlink) ln -s "$FAKE_SECRET" "$out" ;;
  hardlink) ln "$FAKE_SECRET" "$out" ;;
esac
exit 0
EOF
chmod +x "$T/bin/agy"

cd "$T/repo" || exit 1
git init -q .
printf 'tasks/vdgg/\n' > .gitignore
echo original > src/a.txt
ln -s "$T" link
git add -A && git -c user.email=t@t -c user.name=t commit -qm init
echo req > tasks/vdgg/s1/requirements.md
printf -- '-starts with a dash\nwrite to %s/tasks/vdgg/s1/out.md\n' "$T/repo" > tasks/vdgg/s1/input.md
echo secret > "$T/secret"

run() {
    PATH="$T/bin:$PATH" VDGG_EXECUTOR_INPUT=tasks/vdgg/s1/input.md \
        VDGG_EXECUTOR_OUTPUT=tasks/vdgg/s1/out.md "$@" "$W"
}

run env VDGG_EXECUTOR_MODEL=gemini-4-neon-high VDGG_EXECUTOR_EFFORT=low
assert_exit_code 0 "$?" "artifact seat succeeds"
out=$(cat tasks/vdgg/s1/out.md)
assert_contains "$out" "[accept-edits]" "agy runs in accept-edits mode"
assert_contains "$out" "[gemini-4-neon-high]" "the model reaches agy"
assert_contains "$out" "[low]" "the effort reaches agy"
assert_contains "$out" "[--print=-starts with a dash" "the prompt is attached to --print="
assert_contains "$out" "/vdgg-agy." "agy runs in a temporary copy"
case "$out" in *"write to $T/repo/"*) fail "absolute repository paths in the prompt point at the copy" ;; esac
assert_contains "$out" "saw-tracked" "the copy holds tracked files"
assert_contains "$out" "saw-input-dir" "the copy holds the git-ignored input directory"
case "$out" in *saw-symlink*) fail "symlinks are removed from the copy" ;; esac
assert_eq "original" "$(cat src/a.txt)" "the real repository is untouched"
copy=$(printf '%s\n' "$out" | sed -n 's/^cwd=//p')
assert_file_not_exists "$copy" "the copy is deleted afterwards"

run env FAKE_MODE=file
assert_eq "from-file" "$(cat tasks/vdgg/s1/out.md)" "a file agy writes at the output path is the artifact"

run env FAKE_MODE=symlink FAKE_SECRET="$T/secret"
case "$(cat tasks/vdgg/s1/out.md)" in secret) fail "a symlink at the output path is not followed" ;; esac

run env FAKE_MODE=hardlink FAKE_SECRET="$T/secret"
case "$(cat tasks/vdgg/s1/out.md)" in secret) fail "a hard link at the output path is not collected" ;; esac

rm -f tasks/vdgg/s1/out.md
(cd src && PATH="$T/bin:$PATH" VDGG_EXECUTOR_INPUT=../tasks/vdgg/s1/input.md \
    VDGG_EXECUTOR_OUTPUT=../tasks/vdgg/s1/out.md "$W") 2>"$T/err"
assert_eq "" "$(cat "$T/err")" "relative paths with .. are normalized before tar sees them"
assert_contains "$(cat tasks/vdgg/s1/out.md)" "saw-input-dir" "a subdirectory caller still gets the input directory"
assert_contains "$(cat tasks/vdgg/s1/out.md)" "saw-tracked" "a subdirectory caller still runs agy at the copy root"

PATH="$T/bin:$PATH" VDGG_EXECUTOR_INPUT=/nonexistent VDGG_EXECUTOR_OUTPUT=x "$W" 2>/dev/null
assert_exit_code 64 "$?" "a missing input fails with 64"

echo "exec agy: all checks passed"
