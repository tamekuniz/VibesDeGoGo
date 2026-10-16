#!/bin/bash
# vdgg-evidence.sh - evidence gates shared by both VibesDeGoGo! editions.
#
# Kept byte-identical between skills/vibesdegogo/scripts/ and
# .agents/skills/vibesdegogo/scripts/ (tests/test-edition-sync.sh).
#
# Two kinds of callers source this file:
#   - the PreToolUse hooks, which always run under bash, and
#   - vdgg-state.sh, which the user's shell sources (bash or zsh, and in the
#     Codex edition under `set -euo pipefail`).
# So the code here uses no arrays (subscripts differ between the shells), no
# `status` (read-only in zsh) or `path` (tied to $PATH in zsh) variables, no
# unquoted word splitting or globs, printf rather than echo, and `>|` so a
# user's noclobber cannot fail a write. Every command that may fail on purpose
# sits in a condition or ends in `|| true`: under zsh, errexit reaches into
# command substitutions. Parsing is done in awk; values that may hold a
# backslash (paths, ids) reach awk through ENVIRON, never `-v`.
#
# `_vdgg_ev_*` functions are pure: they take explicit arguments and touch no
# session state, so the hooks call them directly. The public `vdgg_*` helpers
# at the bottom use the state helpers of the vdgg-state.sh that sourced this
# file (`_vdgg_get_active_id`, `_vdgg_state_field`, VDGG_STATE_DIR, ...).

# --- Paths -------------------------------------------------------------------

# Normalize a path to repository-relative form: strip the root prefix, any
# leading ./ and any trailing /.
_vdgg_ev_norm() {
    local root="$1" p="$2"
    case "$p" in
        "$root"/*) p="${p#"$root"/}" ;;
    esac
    while :; do
        case "$p" in
            ./*) p="${p#./}" ;;
            *) break ;;
        esac
    done
    while :; do
        case "$p" in
            */) p="${p%/}" ;;
            *) break ;;
        esac
    done
    printf '%s\n' "$p"
}

# True for a non-empty repository-relative path that does not climb out and
# cannot be mistaken for a command option.
_vdgg_ev_is_relative() {
    case "$1" in
        ''|.|..|-*|/*|../*|*/../*|*/..) return 1 ;;
    esac
    return 0
}

# --- Step/phase pairing ------------------------------------------------------

# True when <phase> belongs to <step> and may follow <current_phase>. The
# step graph alone let a phase jump (3 investigating -> 3 planning -> 4
# task-selected, or 6 implementing -> 6 reflection -> 7 testing) walk past
# every gate keyed on a transition; pairing each step with its phases and
# each phase with the phases it may follow leaves the gated transitions as
# the only way through. An empty current phase (no state yet) is not checked.
_vdgg_ev_step_phase_ok() {
    local step="$1" phase="$2" current_phase="${3:-}" from=""
    case "$step:$phase" in
        1:declare) from="declare" ;;
        2:requirements) from="declare requirements" ;;
        3:investigating) from="requirements investigating" ;;
        4:planning) from="investigating planning" ;;
        5:task-selected) from="planning task-selected progress" ;;
        6:implementing) from="task-selected implementing reflection" ;;
        6:reflection) from="testing reflection" ;;
        7:testing) from="implementing testing" ;;
        7:verified) from="testing verified" ;;
        8:progress) from="verified progress" ;;
        9:commit) from="progress commit" ;;
        *) return 1 ;;
    esac
    [ -n "$current_phase" ] || return 0
    case " $from " in
        *" $current_phase "*) return 0 ;;
    esac
    return 1
}

# Transition commands the hooks can judge: every `vdgg_state_(advance|loop|
# write)` used as a command must be followed by a literal `<digits> <phase>`.
# A variable, escape or quote trick there cannot be matched against the
# gates, so the hooks refuse it instead. Returns 1 when the command holds an
# unjudgeable transition.
_vdgg_ev_transitions_literal() {
    printf '%s\n' "$1" | awk '
        {
            line = $0
            while (match(line, /(^|[;&|(!{][ \t]*|^[ \t]*)vdgg_state_(advance|loop|write)/)) {
                rest = substr(line, RSTART + RLENGTH)
                line = rest
                if (rest ~ /^[^A-Za-z0-9_]/ || rest == "") {
                    if (rest !~ /^[ \t]+[0-9]+[ \t]+[a-z][a-z-]*([^A-Za-z0-9_$\\-]|$)/) { bad = 1; exit }
                }
            }
        }
        END { exit bad ? 1 : 0 }
    '
}

# --- Step 3: read evidence ---------------------------------------------------

# Print the paths a Bash command line reads, one per line, as written in the
# command (not normalized). The line is tokenized with shell quoting in mind
# (quotes, backslashes, `#` comments) and split into segments on unquoted
# ; | & ( ) and newlines. A segment counts when its verb is a known reader:
#   file readers:   cat less more head tail nl bat tac view strings od
#                   hexdump xxd diff
#   pattern first:  grep egrep fgrep rg ag ack sed awk (the first positional
#                   argument is the pattern/script unless -e/-f supplied it)
#   git:            show diff log blame (a REV:path argument yields path),
#                   git grep (pattern first)
# Every non-option argument of such a segment is printed, plus `< file`
# inputs. Over-reporting (numbers, patterns) is harmless: the gate only asks
# whether a listed file appears here. Reads it cannot see (variables,
# command substitution, xargs, loops) make the gate stop, never pass. After a
# `cd`/`pushd` segment (or `git -C`), relative paths are no longer reported,
# since they no longer name what the gate would compare them with.
_vdgg_ev_bash_read_paths() {
    printf '%s\n' "$1" | awk -v sq="'" '
        { buf = buf $0 "\n" }
        function flush_tok() {
            if (have_tok) {
                nt++
                tok[nt] = cur
                tqu[nt] = quoted
                tkind[nt] = redir
                tassign[nt] = assign_shape
                redir = ""
                if (hd_pending) { hd_delim = cur; hd_pending = 0 }
            }
            cur = ""; have_tok = 0; quoted = 0; assign_shape = 0
        }
        # Skip a here-document body: the lines after this newline up to the
        # delimiter line. Its text is data, not commands.
        function skip_heredoc(    j, e, line) {
            while (i < n) {
                j = i + 1
                e = index(substr(buf, j), "\n")
                if (e == 0) { line = substr(buf, j); i = n }
                else { line = substr(buf, j, e - 1); i = j + e - 1 }
                if (hd_strip) sub(/^\t+/, "", line)
                if (line == hd_delim) break
            }
            hd_delim = ""; hd_strip = 0
        }
        function end_seg(    i) {
            flush_tok()
            if (nt > 0) segment()
            for (i = 1; i <= nt; i++) { delete tok[i]; delete tqu[i]; delete tkind[i]; delete tassign[i] }
            nt = 0
            redir = ""
        }
        function emit(p) {
            if (p == "") return
            if (cd_seen && substr(p, 1, 1) != "/") return
            print p
        }
        function segment(    k, verb, kind, sub_cmd, t, pattern_given, skipped_first, after_dd, skip_next, git_cd) {
            k = 1
            # Leading assignments, shell keywords and transparent prefixes.
            while (k <= nt && tkind[k] == "" && (tassign[k] || (!tqu[k] && tok[k] ~ /^(sudo|command|builtin|exec|time|nice|env|!|\{|if|then|else|elif|do|while|until)$/))) k++
            if (k > nt) return
            # A --help/--version run reads no file.
            for (t = k + 1; t <= nt; t++) if (!tqu[t] && tkind[t] == "" && tok[t] ~ /^--(help|version)$/) return
            verb = tok[k]
            sub(/.*\//, "", verb)
            if (verb ~ /^(cd|pushd|popd)$/) { cd_seen = 1; return }
            kind = ""
            git_cd = 0
            if (verb ~ /^(cat|less|more|head|tail|nl|bat|tac|view|strings|od|hexdump|xxd|diff)$/) kind = "file"
            else if (verb ~ /^(grep|egrep|fgrep|rg|ag|ack|sed|awk)$/) kind = "pattern"
            else if (verb == "git") {
                k++
                # Options before the subcommand; -C and -c take an argument.
                while (k <= nt && tok[k] ~ /^-/) {
                    if (tok[k] == "-C") git_cd = 1
                    if (tok[k] == "-C" || tok[k] == "-c") k++
                    k++
                }
                if (k > nt) return
                sub_cmd = tok[k]
                if (sub_cmd ~ /^(show|diff|log|blame)$/) kind = "git"
                else if (sub_cmd == "grep") kind = "pattern"
                else return
                if (git_cd) return
            }
            else return
            pattern_given = 0; skipped_first = 0; after_dd = 0; skip_next = 0
            for (k = k + 1; k <= nt; k++) {
                t = tok[k]
                if (tkind[k] == "<") { emit(t); continue }
                if (tkind[k] != "") continue
                if (skip_next) { skip_next = 0; continue }
                if (t == "") continue
                if (!after_dd && !tqu[k] && t == "--") { after_dd = 1; continue }
                if (!after_dd && !tqu[k] && t ~ /^-/) {
                    if (kind == "pattern" && t ~ /^(-e|-f|--regexp|--file|--expression)$/) {
                        pattern_given = 1
                        skip_next = 1
                    } else if (kind == "pattern" && t ~ /^(--regexp=|--file=|--expression=)/) {
                        pattern_given = 1
                    }
                    continue
                }
                # The pattern/script uses up its slot even when it holds a
                # variable or backtick, so the file after it still counts.
                if (kind == "pattern" && !pattern_given && !skipped_first) {
                    skipped_first = 1
                    continue
                }
                if (t ~ /^\$/ || index(t, "$(") > 0 || index(t, "`") > 0) continue
                if (kind == "git" && t ~ /:./) sub(/^[^:]*:/, "", t)
                emit(t)
            }
        }
        END {
            dq = "\""
            n = length(buf)
            q = ""
            for (i = 1; i <= n; i++) {
                c = substr(buf, i, 1)
                nx = (i < n) ? substr(buf, i + 1, 1) : ""
                if (q != "") {
                    if (c == q) q = ""
                    else if (q == dq && c == "\\" && nx != "" && index("$`\"\\\n", nx) > 0) { cur = cur nx; i++ }
                    else cur = cur c
                    continue
                }
                if (c == sq || c == dq) {
                    # NAME="x y" is still an assignment: the NAME= came unquoted.
                    if (!quoted && cur ~ /^[A-Za-z_][A-Za-z0-9_]*=/) assign_shape = 1
                    q = c; have_tok = 1; quoted = 1; continue
                }
                if (c == "\\" && nx != "") {
                    if (nx != "\n") { cur = cur nx; have_tok = 1 }
                    i++
                    continue
                }
                if (c == " " || c == "\t") { flush_tok(); continue }
                if (c == "#" && !have_tok) {
                    while (i < n && substr(buf, i + 1, 1) != "\n") i++
                    continue
                }
                if (c == "<" || c == ">" || (c == "&" && nx == ">")) {
                    # A bare fd number right before the operator belongs to it.
                    if (have_tok && !quoted && cur ~ /^[0-9]+$/) { cur = ""; have_tok = 0 }
                    else flush_tok()
                    op = c
                    while (i < n && index("<>&|", substr(buf, i + 1, 1)) > 0) { i++; op = op substr(buf, i, 1) }
                    # Only a plain `<` names a file that is read; here-docs,
                    # here-strings, fd duplications and outputs name no read.
                    redir = (op == "<") ? "<" : ">"
                    if (op == "<<") {
                        hd_pending = 1
                        if (substr(buf, i + 1, 1) == "-") { hd_strip = 1; i++ }
                    }
                    continue
                }
                if (c == "\n" || c == ";" || c == "|" || c == "&" || c == "(" || c == ")") {
                    end_seg()
                    if (c == "\n" && hd_delim != "") skip_heredoc()
                    continue
                }
                cur = cur c
                have_tok = 1
                if (!quoted && cur ~ /^[A-Za-z_][A-Za-z0-9_]*=/) assign_shape = 1
            }
            end_seg()
        }
    '
}

# Append the paths read on stdin to the read log, normalized against root.
# Best effort: the hook must never refuse a tool call because logging failed.
_vdgg_ev_record_reads() {
    local log="$1" root="$2" p rel
    # `>>` cannot create a file under zsh NO_CLOBBER; create it first.
    [ -e "$log" ] || : >| "$log" 2>/dev/null || return 0
    while IFS= read -r p; do
        [ -n "$p" ] || continue
        rel=$(_vdgg_ev_norm "$root" "$p")
        [ -n "$rel" ] || continue
        printf '%s\n' "$rel" >> "$log" 2>/dev/null || return 0
    done
    return 0
}

# Print the paths listed under `## 1. Related files`: one per top-level list
# item (no indentation), taken from the item's first `backticked` span, or its
# first word when it has none. A trailing :LINE or :START-END is dropped.
_vdgg_ev_related_paths() {
    [ -f "$1" ] || return 0
    awk '
        /^## 1\. Related files[[:space:]]*$/ { in_s = 1; next }
        in_s && /^## / { in_s = 0 }
        in_s && /^([-*+]|[0-9]+[.)])[ \t]+/ {
            line = $0
            sub(/\r$/, "", line)
            sub(/^([-*+]|[0-9]+[.)])[ \t]+/, "", line)
            p = ""
            b = index(line, "`")
            if (b > 0) {
                rest = substr(line, b + 1)
                e = index(rest, "`")
                if (e > 0) p = substr(rest, 1, e - 1)
            } else {
                split(line, w, " ")
                p = w[1]
            }
            sub(/[,;:]+$/, "", p)
            sub(/:[0-9]+(-[0-9]+)?$/, "", p)
            if (p != "") print p
        }
    ' "$1" 2>/dev/null || true
}

# True when the read log shows dir itself (via Glob/LS/Grep) or anything
# under it.
_vdgg_ev_log_has_under() {
    [ -f "$1" ] || return 1
    VDGG_EV_DIR="$2" awk '
        BEGIN { d = ENVIRON["VDGG_EV_DIR"] }
        $0 == d || index($0, d "/") == 1 { found = 1; exit }
        END { exit found ? 0 : 1 }
    ' "$1" 2>/dev/null
}

# Step 3 -> 4 evidence: every path listed under `## 1. Related files` exists
# and was read during investigating. Prints one line per problem to stdout
# and returns 1 when any is found (including "nothing listed").
_vdgg_ev_check_related() {
    local inv="$1" log="$2" root="$3" entry rel count=0 bad=0
    while IFS= read -r entry; do
        [ -n "$entry" ] || continue
        count=$((count + 1))
        rel=$(_vdgg_ev_norm "$root" "$entry")
        if ! _vdgg_ev_is_relative "$rel"; then
            printf 'not a repository-relative path: %s\n' "$entry"
            bad=1
            continue
        fi
        if [ ! -e "$root/$rel" ]; then
            printf 'listed but does not exist: %s\n' "$rel"
            bad=1
            continue
        fi
        if [ -d "$root/$rel" ]; then
            if ! _vdgg_ev_log_has_under "$log" "$rel"; then
                printf 'listed but nothing in it was read during Step 3: %s/\n' "$rel"
                bad=1
            fi
        elif ! grep -qxF -- "$rel" "$log" 2>/dev/null; then
            printf 'listed but not read during Step 3: %s\n' "$rel"
            bad=1
        fi
    done <<EOF
$(_vdgg_ev_related_paths "$inv")
EOF
    if [ "$count" -eq 0 ]; then
        printf 'no files listed under ## 1. Related files (one list item per file, path first)\n'
        return 1
    fi
    [ "$bad" -eq 0 ]
}

# --- Step 4: plan excerpts ---------------------------------------------------

# Step 4 -> 5 evidence. Every task in todo.md (a `## T<n>` or `## TF<n>`
# heading) carries, as level-3 sections:
#   ### Location   `path:line` or `path` plus a function name
#   ### Excerpt    one fenced block with the current code at that location,
#                  copied verbatim (at least 2 lines holding a letter or
#                  digit), or the word 新規 / new for a file that does not
#                  exist yet
#   ### Intent     prose: what changes and why
# Location/Excerpt pairs may repeat. A fenced block anywhere else inside a
# task (Intent, notes, a second block in an Excerpt) is refused: the plan
# states intent, the implementer writes the code. Prints one line per
# problem and returns 1 when any is found.
_vdgg_ev_check_plan() {
    local todo="$1" root="$2"
    if [ ! -f "$todo" ]; then
        printf 'todo.md not found: %s\n' "$todo"
        return 1
    fi
    VDGG_EV_ROOT="$root" awk -v q="'" '
        function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }
        function problem(msg) { print task ": " msg; err = 1 }
        function shq(s,    parts, n, i, r) {
            # Single-quote s for system(); split/join rather than gsub, whose
            # handling of a backslash in the replacement differs between awks.
            n = split(s, parts, q)
            r = parts[1]
            for (i = 2; i <= n; i++) r = r q "\\" q q parts[i]
            return q r q
        }
        function section_name(h,    l) {
            l = tolower(trim(substr(h, 5)))
            if (l ~ /^location/ || l ~ /^修正箇所/) return "location"
            if (l ~ /^excerpt/ || l ~ /^抜粋/) return "excerpt"
            if (l ~ /^intent/ || l ~ /^意図/) return "intent"
            return "other"
        }
        function start_task(h) {
            task = h
            sub(/^## /, "", task)
            match(task, /^TF?[0-9]+/)
            task = substr(task, 1, RLENGTH)
            ntask++
            sect = ""
            have_loc = 0; have_intent = 0
            reset_pair()
        }
        function reset_pair() { loc = ""; loc_hdr = 0; ex_seen = 0; ex_new = 0; ex_n = 0; ex_fences = 0 }
        function end_pair() {
            if (loc_hdr && loc == "") problem("a ### Location section is empty")
            if (loc != "") {
                if (!ex_seen) problem("Location " loc " has no Excerpt")
                else verify()
            }
            reset_pair()
        }
        function end_task() {
            if (task == "") return
            end_pair()
            if (!have_loc) problem("no ### Location")
            if (!have_intent) problem("no ### Intent (or it is empty)")
            task = ""
        }
        function under_root(p,    dir) {
            # The directory holding p must resolve (symlinks followed) inside
            # the root, so an excerpt is never matched against an outside file.
            dir = root
            if (index(p, "/") > 0) { dir = p; sub(/\/[^\/]*$/, "", dir); dir = root "/" dir }
            return system("r=$(cd -P " shq(root) " >/dev/null 2>&1 && pwd -P) && d=$(cd -P " shq(dir) " >/dev/null 2>&1 && pwd -P) && case \"$d/\" in \"$r\"/*) exit 0 ;; esac; exit 1") == 0
        }
        function verify(    p, file, first, last, i, j, nf, ok, meaningful, line) {
            p = loc
            while (substr(p, 1, 2) == "./") p = substr(p, 3)
            if (index(p, root "/") == 1) p = substr(p, length(root) + 2)
            if (p == "" || p ~ /^[\/-]/ || p ~ /(^|\/)\.\.(\/|$)/) { problem("Location is not a repository-relative path: " loc); return }
            if (tolower(p) ~ /^(tasks\/vdgg|\.claude|\.codex)(\/|$)/) { problem("Location " p " is a workflow file, not source code"); return }
            file = root "/" p
            if (ex_new) {
                if (ex_fences > 0) problem("a 新規/new Excerpt takes no code block; describe the new file in the Intent")
                if (system("test -e " shq(file) " || test -L " shq(file)) == 0) problem(p " is marked 新規/new but already exists; excerpt its current code instead")
                return
            }
            if (!under_root(p)) { problem(p " does not resolve inside the repository"); return }
            if (system("test -L " shq(file)) == 0) { problem(p " is a symlink; name the file it points to"); return }
            if (system("test -f " shq(file)) != 0) { problem(p " does not exist (write 新規 in its Excerpt if the task creates it)"); return }
            if (ex_fences == 0) { problem("Excerpt for " p " has no fenced code block"); return }
            first = 1; last = ex_n
            while (first <= last && trim(ex[first]) == "") first++
            while (last >= first && trim(ex[last]) == "") last--
            meaningful = 0
            for (i = first; i <= last; i++) if (ex[i] ~ /[A-Za-z0-9]/) meaningful++
            if (meaningful < 2) { problem("Excerpt for " p " needs at least 2 lines of the current code that hold a letter or digit"); return }
            nf = 0
            while ((getline line < file) > 0) { sub(/\r$/, "", line); fl[++nf] = line }
            close(file)
            for (i = 1; i + (last - first) <= nf; i++) {
                ok = 1
                # Concatenate with "" so numeric-looking lines compare as text.
                for (j = first; j <= last; j++) if ((fl[i + j - first] "") != (ex[j] "")) { ok = 0; break }
                if (ok) return
            }
            problem("Excerpt for " p " does not match the file verbatim (copy the current lines exactly, indentation included)")
        }
        function fence_closes(s,    i) {
            s = trim(s)
            if (length(s) < flen) return 0
            for (i = 1; i <= length(s); i++) if (substr(s, i, 1) != fch) return 0
            return 1
        }
        BEGIN { root = ENVIRON["VDGG_EV_ROOT"]; task = ""; ntask = 0; err = 0; in_fence = 0 }
        { sub(/\r$/, "") }
        in_fence {
            if (fence_closes($0)) { in_fence = 0; next }
            if (task != "" && sect == "excerpt" && ex_fences == 1) ex[++ex_n] = $0
            next
        }
        /^## / {
            end_task()
            if ($0 ~ /^## TF?[0-9]+([^0-9]|$)/) start_task($0)
            next
        }
        /^[ \t]*(```|~~~)/ {
            in_fence = 1
            opening = trim($0)
            fch = substr(opening, 1, 1)
            flen = 0
            while (substr(opening, flen + 1, 1) == fch) flen++
            if (task == "") next
            if (sect == "excerpt" && loc != "") {
                ex_fences++
                if (ex_fences > 1) problem("Excerpt for " loc " has more than one fenced block")
            } else {
                problem("fenced code block outside an Excerpt (the plan states intent; the implementer writes the code)")
            }
            next
        }
        task == "" { next }
        /^### / {
            sect = section_name($0)
            if (sect == "location") { end_pair(); loc_hdr = 1 }
            if (sect == "excerpt") {
                if (loc == "") problem("Excerpt without a preceding Location")
                else if (ex_seen) problem("second Excerpt for " loc)
                ex_seen = 1
            }
            next
        }
        /^#/ { sect = "other"; next }
        sect == "location" && loc == "" && trim($0) != "" {
            line = trim($0)
            sub(/^([-*+]|[0-9]+[.)])[ \t]+/, "", line)
            b = index(line, "`")
            if (b > 0) {
                rest = substr(line, b + 1)
                e = index(rest, "`")
                loc = (e > 0) ? substr(rest, 1, e - 1) : substr(rest, 1)
            } else {
                split(line, w, " ")
                loc = w[1]
            }
            sub(/:[0-9]+(-[0-9]+)?$/, "", loc)
            if (loc == "") loc = "?"
            have_loc = 1
            next
        }
        sect == "excerpt" && loc != "" && ex_fences == 0 && trim($0) != "" {
            if (trim($0) ~ /^(新規|[Nn][Ee][Ww])$/) ex_new = 1
            next
        }
        sect == "intent" && trim($0) != "" { have_intent = 1; next }
        END {
            end_task()
            if (ntask == 0) { print "no tasks: todo.md needs at least one ## T<n> heading"; err = 1 }
            exit err
        }
    ' "$todo"
}

# Step 4 -> 5, optional plan review (seat 4R). When the session's Formation
# assigns seat 4R to an external AI, its review of the plan
# (tasks/vdgg/<id>/plan-review.md) must exist before a task is selected.
# Formations without 4R, or with 4R inline, are not affected. Needs the
# Formation helpers of vdgg-state.sh. Prints the problem and returns 1.
_vdgg_ev_check_plan_review() {
    local tasks_dir="$1" formation="$2" ai
    [ -n "$formation" ] || return 0
    if ! ai=$(vdgg_formation_resolve STEP_4R_AI "$formation" 2>&1); then
        printf 'Formation %s cannot be resolved: %s\n' "$formation" "$ai"
        return 1
    fi
    [ "$ai" = "inline" ] && return 0
    [ -s "$tasks_dir/plan-review.md" ] && return 0
    printf 'Formation %s assigns the plan review seat 4R to %s: run vdgg_executor_run STEP_4R_AI <input> %s/plan-review.md and address its findings before Step 5\n' "$formation" "$ai" "$tasks_dir"
    return 1
}

# --- Step 6: patch chain -----------------------------------------------------

# Hash one snapshot entry: a symlink records its target, a file its blob id.
_vdgg_ev_hash() {
    local h
    if [ -L "$1" ]; then
        h=$(readlink "$1" 2>/dev/null) || h=""
        printf 'L:%s\n' "$h"
    elif h=$(git hash-object --no-filters -- "$1" 2>/dev/null); then
        printf '%s\n' "$h"
    else
        # Unique per call, so an unhashable file always reads as drift.
        printf '?unreadable:%s:%s\n' "$$" "$(date +%s)$RANDOM"
    fi
}

# Content snapshot of the allowlisted files: one `<hash><TAB><path>` line
# per file; a directory entry expands to the files and symlinks under it, a
# missing entry is recorded as `-`. Regular files are hashed by one
# `git hash-object --stdin-paths` call (a process per file would overrun the
# 5 s hook timeout on a large directory entry); symlinks record their target.
# find operands are anchored with ./ so an entry can never be read as a find
# option.
_vdgg_ev_snapshot() {
    local root="$1" allowlist="$2" entry f list hashes
    [ -f "$allowlist" ] || return 0
    list=$(mktemp "${TMPDIR:-/tmp}/vdgg-snap.XXXXXX") || return 1
    hashes=$(mktemp "${TMPDIR:-/tmp}/vdgg-snap.XXXXXX") || { rm -f "$list"; return 1; }
    while IFS= read -r entry; do
        while :; do
            case "$entry" in
                */) entry="${entry%/}" ;;
                *) break ;;
            esac
        done
        [ -n "$entry" ] || continue
        if [ -d "$root/$entry" ] && [ ! -L "$root/$entry" ]; then
            (cd "$root" >/dev/null 2>&1 && { find "./$entry" \( -type f -o -type l \) 2>/dev/null || true; } | sed 's#^\./##')
        elif [ -e "$root/$entry" ] || [ -L "$root/$entry" ]; then
            printf '%s\n' "$entry"
        else
            printf '%s\t%s\n' "-" "$entry"
        fi
    done < "$allowlist" | LC_ALL=C sort -u | while IFS= read -r f; do
        case "$f" in
            "-	"*) printf '%s\n' "$f" ;;
            *)
                if [ -L "$root/$f" ]; then
                    printf '%s\t%s\n' "$(_vdgg_ev_hash "$root/$f")" "$f"
                else
                    printf 'F\t%s\n' "$f"
                fi
                ;;
        esac
    done >| "$list"
    # Hash every regular file at once, in list order.
    if awk -F '\t' '$1 == "F" { print substr($0, 3) }' "$list" \
        | (cd "$root" >/dev/null 2>&1 && git hash-object --no-filters --stdin-paths) >| "$hashes" 2>/dev/null; then
        VDGG_EV_HF="$hashes" awk -F '\t' '
            BEGIN { hf = ENVIRON["VDGG_EV_HF"] }
            $1 == "F" {
                if ((getline h < hf) <= 0) h = "?unreadable:" NR
                print h "\t" substr($0, 3)
                next
            }
            { print }
        ' "$list"
    else
        # The batch failed (an unreadable file): hash one by one, so the
        # failing file gets its own unique marker.
        while IFS= read -r f; do
            case "$f" in
                "F	"*) f="${f#F	}"; printf '%s\t%s\n' "$(_vdgg_ev_hash "$root/$f")" "$f" ;;
                *) printf '%s\n' "$f" ;;
            esac
        done < "$list"
    fi
    rm -f "$list" "$hashes"
    return 0
}

# Rewrite the chain file: `applied=<n>` then the current snapshot.
_vdgg_ev_chain_write() {
    local chain="$1" applied="$2" root="$3" allowlist="$4" tmp
    tmp="${chain}.tmp.$$"
    if {
        printf 'applied=%s\n' "$applied"
        _vdgg_ev_snapshot "$root" "$allowlist" | LC_ALL=C sort -t "$(printf '\t')" -k2
    } >| "$tmp" && mv -f "$tmp" "$chain"; then
        return 0
    fi
    rm -f "$tmp"
    printf 'vdgg: could not write the patch chain %s\n' "$chain" >&2
    return 1
}

_vdgg_ev_chain_applied() {
    local n
    n=$(awk -F= '/^applied=/ { print $2; exit }' "$1" 2>/dev/null) || n=0
    case "$n" in ''|*[!0-9]*) n=0 ;; esac
    printf '%s\n' "$n"
}

# Print the allowlisted paths whose content differs from the chain file.
_vdgg_ev_chain_diff() {
    local chain="$1" root="$2" allowlist="$3"
    _vdgg_ev_snapshot "$root" "$allowlist" | VDGG_EV_CHAIN="$chain" awk -F '\t' '
        BEGIN {
            chain = ENVIRON["VDGG_EV_CHAIN"]
            while ((getline line < chain) > 0) {
                if (line ~ /^applied=/) continue
                t = index(line, "\t")
                if (t == 0) continue
                want[substr(line, t + 1)] = substr(line, 1, t - 1)
            }
        }
        {
            seen[$2] = 1
            if (!($2 in want) || want[$2] != $1) print $2
        }
        END { for (p in want) if (!(p in seen) && want[p] != "-") print p }
    ' | LC_ALL=C sort -u
    return 0
}

# Step 6 -> 7 evidence: at least one patch/codemod went through the chain and
# the allowlisted files still hold exactly what the last one left.
_vdgg_ev_chain_check() {
    local chain="$1" allowlist="$2" root="$3" drift
    if [ -z "$allowlist" ] || [ ! -f "$allowlist" ]; then
        printf 'no active task allowlist; run vdgg_task_begin at Step 5\n'
        return 1
    fi
    if [ ! -f "$chain" ]; then
        printf 'no patch chain for this task; run vdgg_task_begin at Step 5\n'
        return 1
    fi
    if [ "$(_vdgg_ev_chain_applied "$chain")" -lt 1 ]; then
        printf 'no patch applied yet; write tasks/vdgg/<id>/patch/<task>.patch and run vdgg_patch_apply\n'
        return 1
    fi
    drift=$(_vdgg_ev_chain_diff "$chain" "$root" "$allowlist")
    if [ -n "$drift" ]; then
        printf 'changed outside vdgg_patch_apply/vdgg_codemod_apply since the last apply: %s\n' "$drift"
        return 1
    fi
    return 0
}

# --- Step 7: plan reconciliation ---------------------------------------------

# awk helper shared by the todo.md readers below, the same fence rule as
# _vdgg_ev_check_plan: a fence opens on ``` or ~~~ and closes only on a line
# of that character at least as long. fence_step() returns 1 for a fence line
# or a line inside a fence.
_VDGG_EV_FENCE_AWK='
function fence_step(line,    t, n) {
    t = line
    sub(/^[ \t]+/, "", t)
    sub(/[ \t\r]+$/, "", t)
    if (!fenced) {
        if (t !~ /^(```|~~~)/) return 0
        fc = substr(t, 1, 1)
        fl = 0
        while (substr(t, fl + 1, 1) == fc) fl++
        fenced = 1
        return 1
    }
    if (length(t) >= fl) {
        for (n = 1; n <= length(t); n++) if (substr(t, n, 1) != fc) return 1
        fenced = 0
    }
    return 1
}
'

# Task id from a task title: the T<n> or TF<n> at its start, after any
# leading punctuation such as `[` (a title like `[bug] T1` has none), or
# nothing.
_vdgg_ev_task_id() {
    printf '%s\n' "$1" | awk '
        NR == 1 {
            s = $0
            sub(/^[^A-Za-z0-9]+/, "", s)
            if (match(s, /^TF?[0-9]+/)) print substr(s, 1, RLENGTH)
        }
    ' 2>/dev/null || true
}

# True when todo.md has a `## <tid>` task heading (exact first word).
_vdgg_ev_todo_has_task() {
    [ -n "$2" ] && [ -f "$1" ] || return 1
    VDGG_EV_TID="$2" awk "$_VDGG_EV_FENCE_AWK"'
        BEGIN { tid = ENVIRON["VDGG_EV_TID"] }
        fence_step($0) { next }
        /^## TF?[0-9]/ { h = substr($0, 4); match(h, /^TF?[0-9]+/); if (substr(h, 1, RLENGTH) == tid) { found = 1; exit } }
        END { exit found ? 0 : 1 }
    ' "$1" 2>/dev/null
}

# Verified evidence for a planned task: progress.md has a heading
# `Plan reconciliation: <task>` (any level) with a non-empty body. Whether
# plan and diff agree is not judged here, only that someone compared them.
# With no todo.md there is no plan to reconcile. A followup task (TF<n>)
# that is not in todo.md needs no record; any other task must be one of
# todo.md's tasks, so a title cannot opt out of the record.
_vdgg_ev_check_reconciliation() {
    local todo="$1" progress="$2" title="$3" tid
    [ -f "$todo" ] || return 0
    tid=$(_vdgg_ev_task_id "$title")
    if [ -z "$tid" ]; then
        printf 'the current task title "%s" does not start with its todo.md id (T<n>)\n' "$title"
        return 1
    fi
    if ! _vdgg_ev_todo_has_task "$todo" "$tid"; then
        case "$tid" in
            TF*) return 0 ;;
        esac
        printf 'task %s is not in todo.md; select tasks from the plan\n' "$tid"
        return 1
    fi
    if [ -f "$progress" ] && VDGG_EV_TID="$tid" awk "$_VDGG_EV_FENCE_AWK"'
        BEGIN { want = "Plan reconciliation: " ENVIRON["VDGG_EV_TID"] }
        # A heading quoted in a code block (e.g. pasted from the plan-diff
        # report) is not the record; the block still counts as its body.
        fence_step($0) { if (in_s) found = 1; next }
        /^#+[ \t]/ {
            match($0, /^#+/)
            level = RLENGTH
            # A sub-heading belongs to the section; a same or higher level
            # heading ends it.
            if (in_s && level > s_level) next
            in_s = 0
            h = $0
            sub(/^#+[ \t]+/, "", h)
            sub(/[ \t]+$/, "", h)
            if (index(h, want) == 1) {
                rest = substr(h, length(want) + 1)
                if (rest == "" || rest ~ /^[^0-9A-Za-z_.-]/ || rest ~ /^\.([^0-9]|$)/) { in_s = 1; s_level = level }
            }
            next
        }
        in_s && /[^[:space:]]/ { found = 1 }
        END { exit found ? 0 : 1 }
    ' "$progress" 2>/dev/null; then
        return 0
    fi
    printf 'progress.md has no non-empty "Plan reconciliation: %s" section; compare the plan with the diff (vdgg_plan_diff) and record matches and discrepancies with reasons\n' "$tid"
    return 1
}

# --- Step 8.5 confession ------------------------------------------------------
#
# confession.md is the agent's own account of where the run fell short: which
# acceptance criteria were verified (each with an evidence file) and which were
# not, every high/medium review finding it did not fix, every gate it satisfied
# in form rather than in intent, every piece of scope it dropped, and every gate
# that passed when it should have failed. The 8 -> 9 gate checks what can be
# checked mechanically -- the headings, one ledger row per acceptance criterion,
# evidence files that exist, and findings.md, the friction log and progress.md
# against what the confession admits. Whether the text is true is the job of the
# auditor (vdgg_audit_run), whose verdict is bound to this exact confession.

# Body of one `## <heading>` section, blank lines dropped.
_vdgg_ev_section() {
    [ -f "$1" ] || return 0
    VDGG_EV_HEAD="$2" awk '
        /^## / {
            h = substr($0, 4)
            sub(/[ \t]+$/, "", h)
            on = (h == ENVIRON["VDGG_EV_HEAD"])
            next
        }
        on && NF { print }
    ' "$1"
}

# True when a section body declares there is nothing to confess.
_vdgg_ev_says_none() {
    case "$1" in
        なし*) return 0 ;;
    esac
    return 1
}

# Number of `- [<tag>]` rows in a section body.
_vdgg_ev_count_rows() {
    printf '%s\n' "$1" | grep -cE "^- \\[$2\\]" || true
}

# Number of list items in a section body; a "なし" body counts 0.
_vdgg_ev_count_items() {
    if _vdgg_ev_says_none "$1"; then
        printf '0\n'
        return 0
    fi
    printf '%s\n' "$1" | grep -cE '^([-*]|[0-9]+[.)])[[:space:]]+' || true
}

# Problems with the confession, one per line; returns 1 when there are any.
# <dir> is tasks/vdgg/{id} (requirements.md, confession.md, findings.md,
# progress.md, evidence/); <friction> is the session's friction log.
_vdgg_ev_check_confession() {
    local dir="$1" friction="$2" conf="$1/confession.md" out="" sec body n_req n_row n_unv n_deny rows ref id ids down
    if [ ! -f "$conf" ]; then
        printf 'confession.md is missing: write tasks/vdgg/<id>/confession.md (SKILL.md Step 8.5)\n'
        return 1
    fi
    for sec in "受け入れ条件の照合表" "severity 格下げ" "ゲートの形式回避" "範囲縮小" "ゲート誤合格"; do
        body=$(_vdgg_ev_section "$conf" "$sec")
        if [ -z "$body" ]; then
            out="${out}## ${sec}: the heading is missing or its body is empty
"
        elif _vdgg_ev_says_none "$body" && ! printf '%s\n' "$body" | grep -q '確認方法'; then
            out="${out}## ${sec}: なし must say how it was checked (なし（確認方法: ...）)
"
        fi
    done

    # Ledger: one tagged row per acceptance criterion.
    body=$(_vdgg_ev_section "$conf" "受け入れ条件の照合表")
    n_req=$(_vdgg_ev_count_items "$(_vdgg_ev_section "$dir/requirements.md" "Acceptance criteria")")
    n_row=$(printf '%s\n' "$body" | grep -cE '^- \[(検証済み|未検証)\]' || true)
    if [ "${n_req:-0}" -eq 0 ]; then
        out="${out}requirements.md lists no acceptance criteria (list items under ## Acceptance criteria)
"
    elif [ "${n_row:-0}" -ne "$n_req" ]; then
        out="${out}the ledger has ${n_row:-0} rows but requirements.md lists ${n_req} acceptance criteria: one row per criterion
"
    fi
    if printf '%s\n' "$body" | grep -E '^- ' | grep -qvE '^- \[(検証済み|未検証)\]'; then
        out="${out}every ledger row starts with - [検証済み] or - [未検証]
"
    fi
    n_unv=$(_vdgg_ev_count_rows "$body" "未検証")
    if [ "${n_unv:-0}" -gt 0 ]; then
        out="${out}${n_unv} acceptance criteria are 未検証: verify each here and save the evidence under evidence/ (return to Step 5 when a fix is needed). When one cannot be verified in this environment -- only for a missing physical device or a missing external account -- stop with [Intentional Stop] and do not commit. The user cannot waive this.
"
    fi
    rows=$(printf '%s\n' "$body" | grep -E '^- \[検証済み\]' || true)
    while IFS= read -r row; do
        [ -n "$row" ] || continue
        ref=$(printf '%s\n' "$row" | grep -oE 'evidence/[^][ ()`"'\'',、）]+' || true)
        if [ -z "$ref" ]; then
            out="${out}検証済み row without an evidence/ file: ${row}
"
            continue
        fi
        while IFS= read -r id; do
            [ -n "$id" ] || continue
            if [ ! -f "$dir/$id" ]; then
                out="${out}evidence file not found: ${id}
"
            fi
        done <<EOF
$ref
EOF
    done <<EOF
$rows
EOF

    # Every high/medium finding that was not fixed is a downgrade.
    down=$(_vdgg_ev_section "$conf" "severity 格下げ")
    if [ ! -f "$dir/findings.md" ]; then
        out="${out}findings.md is missing: record every review finding with its original severity and what was done (SKILL.md Step 7)
"
    else
        ids=$(awk '
            /^- F[0-9]+ \[(high|medium)\]/ {
                n = index($0, "→")
                d = (n > 0) ? substr($0, n + length("→")) : ""
                sub(/^[ \t]+/, "", d)
                if (index(d, "修正") != 1) print $2
            }
        ' "$dir/findings.md")
        while IFS= read -r id; do
            [ -n "$id" ] || continue
            if ! printf '%s\n' "$down" | grep -qE "(^|[^0-9A-Za-z])${id}([^0-9]|\$)"; then
                out="${out}finding ${id} was high/medium and not fixed, but ## severity 格下げ does not list it
"
            fi
        done <<EOF
$ids
EOF
    fi

    # What the session's own records show cannot be confessed away as なし.
    # Refusals in progress are this gate's own and the edits it blocks; the
    # ones before Step 8 are what the confession must account for.
    n_deny=$(grep '^deny ' "$friction" 2>/dev/null | grep -cv '^deny phase=progress ' || true)
    if [ "${n_deny:-0}" -gt 0 ] \
        && _vdgg_ev_says_none "$(_vdgg_ev_section "$conf" "ゲートの形式回避")"; then
        out="${out}the friction log records ${n_deny} refused tool calls before Step 8, but ## ゲートの形式回避 says なし: account for each one
"
    fi
    if [ -f "$dir/progress.md" ] && grep -qi 'residue' "$dir/progress.md" \
        && _vdgg_ev_says_none "$(_vdgg_ev_section "$conf" "範囲縮小")"; then
        out="${out}progress.md records residue, but ## 範囲縮小 says なし: list what was left and why
"
    fi

    if [ -n "$out" ]; then
        printf '%s' "$out"
        return 1
    fi
    return 0
}

# The auditor's verdict counts only for the confession it read: the sentinel
# vdgg_audit_run writes carries the confession's hash.
_vdgg_ev_check_audit() {
    local sentinel="$1" conf="$2" want got
    if [ ! -f "$sentinel" ]; then
        printf 'no audit: run vdgg_audit_run after the confession is final\n'
        return 1
    fi
    want=$(_vdgg_ev_hash "$conf")
    got=$(sed -n 's/^confession=//p' "$sentinel" | head -n 1)
    if [ "$got" != "$want" ]; then
        printf 'the confession changed after the audit: run vdgg_audit_run again\n'
        return 1
    fi
    return 0
}

# First line of the completion report.
_vdgg_ev_confession_summary() {
    local conf="$1"
    printf '未検証 %s 件 ／ 格下げ %s 件 ／ 回避 %s 件\n' \
        "$(_vdgg_ev_count_rows "$(_vdgg_ev_section "$conf" "受け入れ条件の照合表")" "未検証")" \
        "$(_vdgg_ev_count_items "$(_vdgg_ev_section "$conf" "severity 格下げ")")" \
        "$(_vdgg_ev_count_items "$(_vdgg_ev_section "$conf" "ゲートの形式回避")")"
}

# Workarounds and downgrades the confession admits, as lessons.md lines.
_vdgg_ev_confession_lessons() {
    local conf="$1" sec body
    for sec in "ゲートの形式回避" "severity 格下げ"; do
        body=$(_vdgg_ev_section "$conf" "$sec")
        _vdgg_ev_says_none "$body" && continue
        printf '%s\n' "$body" | grep -E '^([-*]|[0-9]+[.)])[[:space:]]+' \
            | sed -E "s/^([-*]|[0-9]+[.)])[[:space:]]+/- [告白: ${sec}] /" || true
    done
}

# Print the Location paths of one task in todo.md.
_vdgg_ev_plan_locations() {
    [ -f "$1" ] || return 0
    { VDGG_EV_TID="$2" awk "$_VDGG_EV_FENCE_AWK"'
        function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }
        BEGIN { tid = ENVIRON["VDGG_EV_TID"] }
        fence_step($0) { next }
        /^## / {
            h = substr($0, 4); match(h, /^TF?[0-9]+/)
            in_t = (RLENGTH > 0 && substr(h, 1, RLENGTH) == tid); sect = ""; next
        }
        !in_t { next }
        /^### / { l = tolower(trim(substr($0, 5))); sect = (l ~ /^location/ || l ~ /^修正箇所/) ? "loc" : ""; taken = 0; next }
        sect == "loc" && !taken && trim($0) != "" {
            line = trim($0); sub(/^([-*+]|[0-9]+[.)])[ \t]+/, "", line); b = index(line, "`")
            if (b > 0) { rest = substr(line, b + 1); e = index(rest, "`"); p = (e > 0) ? substr(rest, 1, e - 1) : rest }
            else { split(line, w, " "); p = w[1] }
            sub(/:[0-9]+(-[0-9]+)?$/, "", p); sub(/^\.\//, "", p)
            if (p != "") print p
            taken = 1
        }
    ' "$1" 2>/dev/null || true; } | LC_ALL=C sort -u
    return 0
}

# Print one task's section of todo.md verbatim.
_vdgg_ev_plan_section() {
    [ -f "$1" ] || return 0
    VDGG_EV_TID="$2" awk "$_VDGG_EV_FENCE_AWK"'
        BEGIN { tid = ENVIRON["VDGG_EV_TID"] }
        { inside = fence_step($0) }
        !inside && /^## / { h = substr($0, 4); match(h, /^TF?[0-9]+/); in_t = (RLENGTH > 0 && substr(h, 1, RLENGTH) == tid) }
        in_t { print }
    ' "$1" 2>/dev/null || true
}

# Print the allowlisted files whose content differs between the task baseline
# copy and the working tree (new and deleted files included).
_vdgg_ev_changed_vs_baseline() {
    local base="$1" root="$2" allowlist="$3" entry f
    [ -f "$allowlist" ] || return 0
    while IFS= read -r entry; do
        while :; do
            case "$entry" in
                */) entry="${entry%/}" ;;
                *) break ;;
            esac
        done
        [ -n "$entry" ] || continue
        {
            if [ -d "$base/$entry" ]; then
                (cd "$base" >/dev/null 2>&1 && { find "./$entry" -type f 2>/dev/null || true; } | sed 's#^\./##')
            fi
            if [ -d "$root/$entry" ]; then
                (cd "$root" >/dev/null 2>&1 && { find "./$entry" -type f 2>/dev/null || true; } | sed 's#^\./##')
            fi
            if [ ! -d "$base/$entry" ] && [ ! -d "$root/$entry" ]; then
                printf '%s\n' "$entry"
            fi
        } | LC_ALL=C sort -u | while IFS= read -r f; do
            [ -n "$f" ] || continue
            if [ -f "$base/$f" ] && [ -f "$root/$f" ]; then
                cmp -s "$base/$f" "$root/$f" || printf '%s\n' "$f"
            elif [ -f "$base/$f" ] || [ -f "$root/$f" ]; then
                printf '%s\n' "$f"
            fi
        done
    done < "$allowlist"
    return 0
}

# --- Public helpers (need vdgg-state.sh) -------------------------------------

_vdgg_ev_chain_file() {
    printf '%s/.vdgg-task-patchchain-%s\n' "$VDGG_STATE_DIR" "$1"
}

_vdgg_ev_read_log() {
    printf '%s/.vdgg-read-%s\n' "$VDGG_STATE_DIR" "$1"
}

# Called by vdgg_task_begin / vdgg_task_rollback / vdgg_state_loop: (re)start
# the chain from the current content of the allowlisted files.
_vdgg_ev_chain_reset() {
    local id="$1" applied="${2:-0}" allowlist="$3"
    [ -n "$id" ] && [ -n "$allowlist" ] && [ -f "$allowlist" ] || return 0
    _vdgg_ev_chain_write "$(_vdgg_ev_chain_file "$id")" "$applied" "$VDGG_CWD" "$allowlist"
}

# Shared preamble of vdgg_patch_apply / vdgg_codemod_apply. Sets
# _VDGG_EV_ID, _VDGG_EV_ALLOWLIST and _VDGG_EV_CHAIN, or prints why not.
_vdgg_ev_apply_preflight() {
    local caller="$1" state_file phase drift
    _VDGG_EV_ID=$(_vdgg_get_active_id)
    if [ -z "$_VDGG_EV_ID" ]; then
        printf '%s: no active VibesDeGoGo! session\n' "$caller" >&2
        return 1
    fi
    state_file=$(_vdgg_state_file_for_id "$_VDGG_EV_ID")
    phase=$(_vdgg_state_field phase "$state_file")
    if [ "$phase" != "implementing" ]; then
        printf '%s: only allowed in implementing (phase=%s)\n' "$caller" "$phase" >&2
        return 1
    fi
    _VDGG_EV_ALLOWLIST=$(_vdgg_state_field task_allowlist_file "$state_file")
    if [ -z "$_VDGG_EV_ALLOWLIST" ] || [ ! -f "$_VDGG_EV_ALLOWLIST" ]; then
        printf '%s: no active task allowlist; run vdgg_task_begin at Step 5\n' "$caller" >&2
        return 1
    fi
    _VDGG_EV_CHAIN=$(_vdgg_ev_chain_file "$_VDGG_EV_ID")
    if [ ! -f "$_VDGG_EV_CHAIN" ]; then
        printf '%s: no patch chain for this task; run vdgg_task_begin at Step 5\n' "$caller" >&2
        return 1
    fi
    drift=$(_vdgg_ev_chain_diff "$_VDGG_EV_CHAIN" "$VDGG_CWD" "$_VDGG_EV_ALLOWLIST")
    if [ -n "$drift" ]; then
        printf '%s: allowlisted files changed outside a patch since the last apply: %s\n' "$caller" "$drift" >&2
        printf '%s: fold that change into a patch after vdgg_task_rollback, or revert it by hand\n' "$caller" >&2
        return 1
    fi
    return 0
}

# Paths no patch or codemod may write, whatever the allowlist says: the
# workflow's own sidecars, the trusted target config, and git internals.
_vdgg_ev_protected_path() {
    # Folded to lower case: on a case-insensitive filesystem (macOS default)
    # `.CLAUDE/.vdgg-state-x` is the sidecar.
    case "$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')" in
        .claude/.vdgg-*|.codex/.vdgg-*|.vdgg-target|*/.vdgg-target|.git|.git/*|*/.git|*/.git/*) return 0 ;;
    esac
    return 1
}

# Step 6 (patch first): check a unified diff under tasks/vdgg/<id>/patch/ with
# `git apply --check`, then apply it. Every file it touches must be on the
# task allowlist (exact paths, like vdgg_task_check_allowlist), must not be a
# protected path or an existing symlink, and the patch may touch at most 3
# files: a bigger patch means the task should have been split (Step 4
# sizing). Symlink modes, renames and copies are refused, judged from git's
# own normalized summary rather than the raw patch text. Every check and the
# apply run on one private copy, so the patch cannot change in between.
vdgg_patch_apply() {
    local patch="${1:-}" rel copy rc
    if [ -z "$patch" ] || [ "$#" -ne 1 ]; then
        printf 'usage: vdgg_patch_apply tasks/vdgg/<id>/patch/<task>.patch\n' >&2
        return 1
    fi
    _vdgg_ev_apply_preflight vdgg_patch_apply || return 1
    rel=$(_vdgg_ev_norm "$VDGG_CWD" "$patch")
    case "$rel" in
        */../*|../*) rel="" ;;
        "tasks/vdgg/${_VDGG_EV_ID}/patch/"*.patch|"tasks/vdgg/${_VDGG_EV_ID}/patch/"*.diff) ;;
        *) rel="" ;;
    esac
    if [ -z "$rel" ] || [ ! -f "$VDGG_CWD/$rel" ] || [ -L "$VDGG_CWD/$rel" ]; then
        printf 'vdgg_patch_apply: the patch must be an existing .patch/.diff file under tasks/vdgg/%s/patch/: %s\n' "$_VDGG_EV_ID" "$patch" >&2
        return 1
    fi
    if ! copy=$(mktemp "${VDGG_STATE_DIR}/.vdgg-patch.XXXXXX" 2>/dev/null); then
        printf 'vdgg_patch_apply: cannot create a private copy of the patch\n' >&2
        return 1
    fi
    if cp "$VDGG_CWD/$rel" "$copy" && _vdgg_ev_patch_apply_copy "$copy" "$rel"; then
        rc=0
    else
        rc=1
    fi
    rm -f "$copy"
    return "$rc"
}

_vdgg_ev_patch_apply_copy() {
    local copy="$1" rel="$2" numstat summary verbose f nfiles=0 applied
    if ! numstat=$(git -c core.quotepath=false -C "$VDGG_CWD" apply --recount --numstat -- "$copy" 2>&1); then
        printf 'vdgg_patch_apply: not a valid patch: %s\n' "$numstat" >&2
        return 1
    fi
    # Captured first: with pipefail, `git ... | grep -q` can lose a match to
    # SIGPIPE and read as "no match".
    summary=$(git -c core.quotepath=false -C "$VDGG_CWD" apply --recount --summary -- "$copy" 2>/dev/null) || summary=""
    # Which files the patch touches is taken from git itself: `apply --check
    # -v` prints one `Checking patch <path>...` line per file section, and
    # `Checking patch OLD => NEW...` whenever the section would remove one
    # path and write another, whatever the diff --git, ---/+++ or rename
    # lines say. numstat and summary show only NEW, so they cannot be the
    # list of touched files.
    if ! verbose=$(git -c core.quotepath=false -C "$VDGG_CWD" apply --recount --check -v -- "$copy" 2>&1); then
        printf 'vdgg_patch_apply: git apply --check failed; regenerate the patch against the current files:\n%s\n' "$verbose" >&2
        return 1
    fi
    # Independent textual check: in every file section the --- and +++ names
    # agree (one side may be /dev/null for a new or deleted file). git
    # C-quotes names with non-ASCII bytes ("a/caf\303\251.txt"), so the quotes
    # are dropped before the a/ b/ prefix; both sides are quoted alike. The
    # diff --git line is not parsed: the -v list above already covers it.
    if ! awk '
        function name(s) {
            sub(/^(---|\+\+\+) /, "", s)
            sub(/\t.*$/, "", s)
            if (substr(s, 1, 1) == "\"") { s = substr(s, 2); sub(/"$/, "", s) }
            sub(/^[ab]\//, "", s)
            return s
        }
        /^--- / { old = name($0); next }
        /^\+\+\+ / {
            new = name($0)
            if (old != new && old != "/dev/null" && new != "/dev/null") { bad = 1; exit }
        }
        END { exit bad ? 1 : 0 }
    ' "$copy"; then
        printf 'vdgg_patch_apply: a file section names two different files (a rename in disguise); use vdgg_codemod_apply\n' >&2
        return 1
    fi
    if printf '%s\n' "$summary" | grep -E '(mode|=>) 120000|^ (rename|copy) ' >/dev/null; then
        printf 'vdgg_patch_apply: symlinks, renames and copies are not applied from a patch; use vdgg_codemod_apply\n' >&2
        return 1
    fi
    while IFS= read -r f; do
        case "$f" in
            "Checking patch "*...) ;;
            *) continue ;;
        esac
        f="${f#Checking patch }"
        f="${f%...}"
        case "$f" in
            *" => "*)
                printf 'vdgg_patch_apply: the patch moves %s; renames are not applied from a patch, use vdgg_codemod_apply\n' "$f" >&2
                return 1
                ;;
        esac
        if _vdgg_ev_protected_path "$f"; then
            printf 'vdgg_patch_apply: %s is a protected path and is never patched\n' "$f" >&2
            return 1
        fi
        if ! grep -qxF -- "$f" "$_VDGG_EV_ALLOWLIST"; then
            printf 'vdgg_patch_apply: %s is not on the task allowlist\n' "$f" >&2
            return 1
        fi
        if [ -L "$VDGG_CWD/$f" ]; then
            printf 'vdgg_patch_apply: %s is a symlink; patch the file it points to\n' "$f" >&2
            return 1
        fi
        nfiles=$((nfiles + 1))
    done <<EOF
$verbose
EOF
    if [ "$nfiles" -eq 0 ]; then
        printf 'vdgg_patch_apply: the patch changes no file\n' >&2
        return 1
    fi
    if [ "$nfiles" -gt 3 ]; then
        printf 'vdgg_patch_apply: the patch touches %s files; more than 3 means the task is too big, split it (Step 4 sizing)\n' "$nfiles" >&2
        return 1
    fi
    if ! git -C "$VDGG_CWD" apply --recount -- "$copy"; then
        printf 'vdgg_patch_apply: git apply failed after a passing --check\n' >&2
        return 1
    fi
    applied=$(_vdgg_ev_chain_applied "$_VDGG_EV_CHAIN")
    applied=$((applied + 1))
    _vdgg_ev_chain_write "$_VDGG_EV_CHAIN" "$applied" "$VDGG_CWD" "$_VDGG_EV_ALLOWLIST" || return 1
    printf 'vdgg-patch: applied %s (%s file(s), chain=%s)\n' "$rel" "$nfiles" "$applied" >&2
}

# Step 6, mechanical bulk edits (renames, many-file substitutions): run a
# codemod command instead of a patch. <expected-files> is the dry-run count
# of changed allowlisted paths (e.g. `rg -l old src | wc -l`), at least 1; a
# rename changes two paths, the old one and the new one; the helper refuses when the
# command changed a different number of allowlisted files, or files off the
# allowlist (as vdgg_task_check_allowlist sees them). The command itself is
# trusted like any other shell command: the count check catches a runaway
# substitution, not a deliberate hand edit, and writes the allowlist check
# cannot see (ignored files, the sidecars) are not inspected. Allowlist
# entries can never be protected paths (vdgg_task_begin refuses them), so a
# protected path in the chain diff is a defense in depth, not the boundary.
vdgg_codemod_apply() {
    local expected="${1:-}" rc changed count applied f
    # Digits only, at most 6 of them, leading zeros dropped: a value `[`
    # cannot compare must never reach it (an error there reads as false).
    case "$expected" in
        ''|*[!0-9]*|???????*) expected=0 ;;
    esac
    while :; do
        case "$expected" in
            0?*) expected="${expected#0}" ;;
            *) break ;;
        esac
    done
    if [ "$expected" = "0" ]; then
        printf 'usage: vdgg_codemod_apply <expected-changed-files (>= 1)> <command> [args...]\n' >&2
        return 1
    fi
    shift
    if [ "$#" -eq 0 ]; then
        printf 'usage: vdgg_codemod_apply <expected-changed-files (>= 1)> <command> [args...]\n' >&2
        return 1
    fi
    _vdgg_ev_apply_preflight vdgg_codemod_apply || return 1
    if "$@"; then
        rc=0
    else
        rc=$?
    fi
    if [ "$rc" -ne 0 ]; then
        printf 'vdgg_codemod_apply: command failed (exit %s); inspect the tree, vdgg_task_rollback if needed\n' "$rc" >&2
        return "$rc"
    fi
    if ! vdgg_task_check_allowlist; then
        printf 'vdgg_codemod_apply: the command changed files off the allowlist; vdgg_task_rollback and narrow it\n' >&2
        return 1
    fi
    changed=$(_vdgg_ev_chain_diff "$_VDGG_EV_CHAIN" "$VDGG_CWD" "$_VDGG_EV_ALLOWLIST")
    while IFS= read -r f; do
        [ -n "$f" ] || continue
        if _vdgg_ev_protected_path "$f"; then
            printf 'vdgg_codemod_apply: %s is a protected path; vdgg_task_rollback\n' "$f" >&2
            return 1
        fi
    done <<EOF
$changed
EOF
    count=0
    if [ -n "$changed" ]; then
        count=$(printf '%s\n' "$changed" | awk 'END { print NR }')
    fi
    if [ "$count" != "$expected" ]; then
        printf 'vdgg_codemod_apply: changed %s file(s), the dry run predicted %s; vdgg_task_rollback and re-check the command\n' "$count" "$expected" >&2
        return 1
    fi
    applied=$(_vdgg_ev_chain_applied "$_VDGG_EV_CHAIN")
    applied=$((applied + 1))
    _vdgg_ev_chain_write "$_VDGG_EV_CHAIN" "$applied" "$VDGG_CWD" "$_VDGG_EV_ALLOWLIST" || return 1
    printf 'vdgg-codemod: %s file(s) changed as predicted (chain=%s)\n' "$count" "$applied" >&2
}

# Step 7: write tasks/vdgg/<id>/review/<task>-plan-vs-diff.md, the plan (intent
# and excerpts) next to the actual diff, and print its path. Hand it to the
# reviewer; record the outcome in progress.md under
# `### Plan reconciliation: <task>`.
vdgg_plan_diff() {
    local id state_file title tid todo out tmp review base_ref base relbase allowlist planned changed f
    id=$(_vdgg_get_active_id)
    if [ -z "$id" ]; then
        printf 'vdgg_plan_diff: no active VibesDeGoGo! session\n' >&2
        return 1
    fi
    state_file=$(_vdgg_state_file_for_id "$id")
    title=$(_vdgg_state_field current_task "$state_file")
    tid="${1:-}"
    [ -n "$tid" ] || tid=$(_vdgg_ev_task_id "$title")
    case "$tid" in
        ''|*[!A-Za-z0-9_.-]*)
            printf 'vdgg_plan_diff: cannot derive a task id from "%s"; pass it explicitly\n' "$title" >&2
            return 1
            ;;
    esac
    todo="${VDGG_TASKS_DIR}/${id}/todo.md"
    allowlist=$(_vdgg_state_field task_allowlist_file "$state_file")
    base_ref=$(_vdgg_state_field task_base_ref "$state_file")
    base="${base_ref/baseline-status-/baseline-}"
    if [ -z "$allowlist" ] || [ ! -f "$allowlist" ] || [ -z "$base_ref" ] || [ ! -d "$base" ]; then
        printf 'vdgg_plan_diff: no active task baseline; run vdgg_task_begin at Step 5\n' >&2
        return 1
    fi
    relbase=$(_vdgg_ev_norm "$VDGG_CWD" "$base")
    review="${VDGG_TASKS_DIR}/${id}/review"
    if [ -L "$review" ] || [ -L "${VDGG_TASKS_DIR}/${id}" ]; then
        printf 'vdgg_plan_diff: %s is a symlink; refusing to write through it\n' "$review" >&2
        return 1
    fi
    mkdir -p "$review" || return 1
    out="${review}/${tid}-plan-vs-diff.md"
    # Write a fresh private file, then rename it into place (below), so the
    # report is never written through a planted symlink.
    tmp=$(mktemp "${review}/.plan-diff.XXXXXX") || return 1
    planned=$(_vdgg_ev_plan_locations "$todo" "$tid")
    changed=$(_vdgg_ev_changed_vs_baseline "$base" "$VDGG_CWD" "$allowlist" | LC_ALL=C sort -u)
    {
        printf '# Plan vs diff: %s\n\n' "$tid"
        printf 'Reviewer: list (1) changes in the diff that the plan does not mention and (2) planned changes the diff does not make. The implementer records every discrepancy and its reason in progress.md under `### Plan reconciliation: %s`. Discrepancies do not block; an unexplained one does.\n\n' "$tid"
        printf '## Plan (todo.md)\n\n'
        _vdgg_ev_plan_section "$todo" "$tid"
        printf '\n## Files\n\n'
        while IFS= read -r f; do
            [ -n "$f" ] || continue
            if printf '%s\n' "$changed" | grep -qxF -- "$f"; then
                printf '%s `%s`\n' '- planned, changed:' "$f"
            else
                printf '%s `%s`\n' '- planned, NOT changed:' "$f"
            fi
        done <<EOF
$planned
EOF
        while IFS= read -r f; do
            [ -n "$f" ] || continue
            if ! printf '%s\n' "$planned" | grep -qxF -- "$f"; then
                printf '%s `%s`\n' '- changed, NOT planned:' "$f"
            fi
        done <<EOF
$changed
EOF
        printf '\n## Diff (task baseline -> working tree)\n\n```diff\n'
        while IFS= read -r f; do
            [ -n "$f" ] || continue
            if [ -f "$base/$f" ] && [ -f "$VDGG_CWD/$f" ]; then
                _vdgg_ev_diff_or_mark "$relbase/$f" "$f"
            elif [ -f "$VDGG_CWD/$f" ]; then
                _vdgg_ev_diff_or_mark /dev/null "$f"
            else
                _vdgg_ev_diff_or_mark "$relbase/$f" /dev/null
            fi
        done <<EOF
$changed
EOF
        printf '```\n'
    } >| "$tmp" || { rm -f "$tmp"; return 1; }
    # mv follows a symlink to a directory, so clear a planted link first and
    # refuse a directory in the report's place.
    if [ -L "$out" ]; then
        rm -f "$out"
    fi
    if [ -d "$out" ]; then
        rm -f "$tmp"
        printf 'vdgg_plan_diff: %s is a directory\n' "$out" >&2
        return 1
    fi
    mv -f "$tmp" "$out" || { rm -f "$tmp"; return 1; }
    printf '%s\n' "$out"
}

# One `git diff --no-index` for the plan-diff report. Its exit status cannot
# tell "differs" from "could not read" (both are 1), so a non-empty stderr
# leaves a visible marker instead: a failed diff never reads as "no change".
_vdgg_ev_diff_or_mark() {
    local errf
    errf=$(mktemp "${TMPDIR:-/tmp}/vdgg-diff.XXXXXX" 2>/dev/null) || errf=/dev/null
    git -C "$VDGG_CWD" diff --no-index --no-color -- "$1" "$2" 2>"$errf" || true
    if [ "$errf" != /dev/null ]; then
        if [ -s "$errf" ]; then
            printf '# vdgg_plan_diff: could not diff %s -> %s: %s\n' "$1" "$2" "$(head -1 "$errf")"
        fi
        rm -f "$errf"
    fi
    return 0
}

# Pre-checks the agent can run before asking the hook to open a gate.
vdgg_check_investigation() {
    local id
    id=$(_vdgg_get_active_id)
    [ -n "$id" ] || { printf 'vdgg_check_investigation: no active session\n' >&2; return 1; }
    _vdgg_ev_check_related "${VDGG_TASKS_DIR}/${id}/investigation.md" "$(_vdgg_ev_read_log "$id")" "$VDGG_CWD"
}

vdgg_check_plan() {
    local id
    id=$(_vdgg_get_active_id)
    [ -n "$id" ] || { printf 'vdgg_check_plan: no active session\n' >&2; return 1; }
    _vdgg_ev_check_plan "${VDGG_TASKS_DIR}/${id}/todo.md" "$VDGG_CWD"
}
