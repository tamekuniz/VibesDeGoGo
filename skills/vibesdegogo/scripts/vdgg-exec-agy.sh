#!/bin/sh
# Bundled executor for the builtin "agy" formation value: Antigravity CLI,
# signed in with a Google account (Google AI Pro / Ultra subscription quota).
# Contract: VDGG_EXECUTOR_INPUT is the prompt file; with VDGG_EXECUTOR_OUTPUT
# set this is an artifact seat (artifact written to that file, the
# repository left untouched); without it this is the Step 6 editing seat.
set -eu

input=${VDGG_EXECUTOR_INPUT:-}
output=${VDGG_EXECUTOR_OUTPUT:-}
[ -f "$input" ] || { echo "vdgg-exec-agy: input is missing" >&2; exit 64; }
command -v agy >/dev/null 2>&1 || { echo "vdgg-exec-agy: agy (Antigravity CLI) is required" >&2; exit 69; }

model=${VDGG_EXECUTOR_MODEL:-}
effort=${VDGG_EXECUTOR_EFFORT:-}

# agy reads no prompt from stdin, so the prompt goes in argv. --print=<text>
# keeps a prompt that starts with "-" from being parsed as a flag, and
# --disable-slash-commands keeps one that starts with "/" from expanding a
# skill. ponytail: argv caps the prompt at ARG_MAX (1 MiB on macOS); switch to
# --input-format stream-json if a prompt ever outgrows it.
set -- --disable-slash-commands --mode accept-edits
[ -n "$model" ] && set -- "$@" --model "$model"
[ -n "$effort" ] && set -- "$@" --effort "$effort"

if [ -z "$output" ]; then
  agy "$@" --print="$(cat "$input")" >/dev/null
  exit
fi

# agy has no per-run read-only switch: every mode writes workspace files
# without asking, and plan mode answers with a plan instead of the artifact.
# So the artifact seat runs in a throwaway copy of the work tree (tracked and
# untracked files, ignored ones left out); whatever agy writes is deleted with
# it, and a write outside the copy is refused. ponytail: copies the whole tree
# per call; fine for source repos, slow for huge ones.
root=$(git rev-parse --show-toplevel) || { echo "vdgg-exec-agy: must run inside a git work tree" >&2; exit 69; }
root=$(cd "$root" && pwd -P)
copy=$(mktemp -d "${TMPDIR:-/tmp}/vdgg-agy.XXXXXX")
trap 'rm -rf "$copy"' EXIT
trap 'exit 130' INT TERM HUP
# The physical path: agy treats a workspace reached through a symlink (macOS
# /var -> /private/var) as outside itself and refuses to write there.
copy=$(cd "$copy" && pwd -P)
# Tracked files deleted from the work tree are still listed; tar skips them.
(cd "$root" && git ls-files -z -co --exclude-standard | tar --null -T - -cf - 2>/dev/null) | tar -xf - -C "$copy"
# A symlink would carry reads and writes out of the copy, so none stay. Purge
# before the next extract too: GNU tar writes through a symlinked directory.
find "$copy" -type l -exec rm -f {} +

# Prints a path relative to the work tree root, resolving "..", symlinks and
# the caller's cwd; fails for one outside the work tree.
rel_path() {
  dir=$(cd "$(dirname "$1")" 2>/dev/null && pwd -P) || return 1
  case "$dir/" in "$root"/*) ;; *) return 1 ;; esac
  dir="${dir#"$root"}/${1##*/}"
  printf '%s\n' "${dir#/}"
}
# VDGG keeps a session's inputs and outputs in tasks/vdgg/<id>/, which is
# git-ignored, so the input's directory joins the copy explicitly.
if in_rel=$(rel_path "$input") && [ "$(dirname "$in_rel")" != . ]; then
  (cd "$root" && tar -cf - "$(dirname "$in_rel")") | tar -xf - -C "$copy"
  find "$copy" -type l -exec rm -f {} +
fi

# The prompt names repository paths absolutely (the output path among them),
# and agy ends its turn without an answer when a write outside the workspace
# is refused, so point those paths at the copy and collect the output there.
rel=$(rel_path "$output") || rel=""
if [ -n "$rel" ]; then
  mkdir -p "$copy/$(dirname "$rel")"
  rm -f "$copy/$rel"
fi
prompt=$(ROOT=$root COPY=$copy awk '{
  out = ""
  while ((i = index($0, ENVIRON["ROOT"])) > 0) {
    out = out substr($0, 1, i - 1) ENVIRON["COPY"]
    $0 = substr($0, i + length(ENVIRON["ROOT"]))
  }
  print out $0
}' "$input")
(cd "$copy" && agy "$@" --print="$prompt") > "$output"
# A file agy wrote at the output path is the artifact; otherwise its reply is.
# Only a regular, singly linked file inside the copy counts: a symlink or hard
# link agy left there could pull any file the user can read into the artifact.
if [ -n "$rel" ] && [ -f "$copy/$rel" ] && [ ! -L "$copy/$rel" ] && [ -s "$copy/$rel" ] &&
   [ -n "$(find "$copy/$rel" -links 1)" ]; then
  case "$(cd "$(dirname "$copy/$rel")" && pwd -P)/" in
    "$copy"/*) cp "$copy/$rel" "$output" ;;
  esac
fi
