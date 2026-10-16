# VibesDeGoGo! Reference: State Helpers

The state helper script is:

```bash
VDGG_SKILL_DIR="${VDGG_SKILL_DIR:-$HOME/.claude/skills/vibesdegogo}"
source "$VDGG_SKILL_DIR/scripts/vdgg-state.sh"
```

For plugin installs, set `VDGG_SKILL_DIR` to the skill's base directory announced when the skill loads.

## Files

```text
.claude/.vdgg-active
tasks/vdgg/{id}/
.claude/.vdgg-state-{id}
.claude/.vdgg-friction-{id}
.claude/.vdgg-read-{id}              files read during Step 3 (written by the hook)
.claude/.vdgg-task-patchchain-{id}   Step 6 patch chain (written by the helpers)
```

State file format:

```text
step=<number>
phase=<phase>
loop_count=<number>
current_task=<task title>
task_allowlist_file=<path to active allowlist, empty before vdgg_task_begin>
task_base_ref=<path to baseline git-status snapshot>
vdgg_id=<YYYYMMDD-HHMM-xxxx>
last_updated=<UTC timestamp>
```

## Public Functions

```bash
vdgg_state_init
vdgg_state_read
vdgg_state_write <step> <phase> <loop_count> [current_task] [task_allowlist_file] [task_base_ref]
vdgg_state_advance <step> <phase>
vdgg_state_loop <step> <phase>
vdgg_review_run [review command...]
vdgg_task_begin <task title> <allowed path>...
vdgg_task_changed_files
vdgg_task_check_allowlist
vdgg_task_gate <verification command> [args...]
vdgg_task_rollback
vdgg_patch_apply <patch under tasks/vdgg/{id}/patch/>
vdgg_codemod_apply <expected-files> <command> [args...]
vdgg_plan_diff [task-id]
vdgg_check_investigation
vdgg_check_plan
vdgg_audit_run
vdgg_state_clear
vdgg_friction_report
vdgg_get_tasks_dir
vdgg_get_id
```

## Task Gate

`vdgg_task_begin` writes the allowlist to
`.claude/.vdgg-task-allowlist-{id}-{loop}`, snapshots the allowlisted files
into `.claude/.vdgg-task-baseline-{id}-{loop}/`, and records a
`git status --porcelain` baseline. During `implementing` and `testing`, the
pretool hook blocks Edit/Write outside the allowlist (task notes under
`tasks/vdgg/{id}/` are exempt). `vdgg_task_gate` re-checks the allowlist
against actual changed files (catching Bash-mediated edits too), runs the
verification command, and writes `.claude/.vdgg-task-gate-{id}-{loop}` on
success — required before `verified` whenever an allowlist is active. It
refuses a call without a command and any phase but `testing`, removes this
loop's earlier pass before running, and records the command it ran
(`command=`, shell-quoted) with `passed_at` and `exit=0`.
`vdgg_task_rollback` reverts allowlisted changes to the baseline; if files
outside the allowlist changed, it refuses — resolve those manually (e.g.
`git status` + `git checkout -- <file>`) before retrying. Rollback also
restarts the patch chain.

## Evidence Helpers

These live in `scripts/vdgg-evidence.sh`, which `vdgg-state.sh` sources.

- `vdgg_patch_apply <file>` (implementing only): the file must be a `.patch`
  or `.diff` under `tasks/vdgg/{id}/patch/`. It is copied to a private file,
  checked (allowlisted exact paths, no protected paths, no symlinks, renames
  or copies, at most 3 files, `git apply --check`) and applied; the patch
  chain then records the new content.
- `vdgg_codemod_apply <expected-files> <command> [args...]` (implementing
  only): runs the command, then refuses unless exactly `<expected-files>`
  (at least 1) allowlisted files changed and nothing off the allowlist did.
- `vdgg_plan_diff [task-id]` writes
  `tasks/vdgg/{id}/review/<task>-plan-vs-diff.md` (the task's plan, planned vs
  changed files, and the diff since `vdgg_task_begin`) and prints its path.
- `vdgg_check_investigation` / `vdgg_check_plan` print what the Step 3 -> 4 and
  Step 4 -> 5 gates would refuse.

`vdgg_task_begin` starts the chain with nothing applied and
`vdgg_task_rollback` restarts it; `vdgg_state_loop` leaves it alone, so a
change made outside a patch is still reported in the next loop.

`vdgg_state_write` pairs each step with its phases (1 declare, 2
requirements, 3 investigating, 4 planning, 5 task-selected, 6
implementing/reflection, 7 testing/verified, 8 progress, 9 commit) and
accepts each phase only after its predecessor in the workflow (`testing` from
`implementing`, `reflection` from `testing`, `verified` from `testing`,
`progress` from `verified`, `task-selected` from `planning` or `progress`).

`vdgg_review_run` is the review gate for passes done without the Claude Code
`simplify` skill. It runs the review command — an explicit one, or
`REVIEW_COMMAND` from `.vdgg-target` — and writes a per-loop review sentinel
under `.claude/.vdgg-review-sentinel-{id}-{loop}` with `modified=0` only when
that command exits 0; it is the documented way to write that sentinel. The
verified gate accepts either the
simplify sentinel or this review sentinel; both flip to `modified=1` when
implementation files are edited afterward in the same loop. See `SKILL.md`
Step 7 for the full gate description.

`vdgg_audit_run` is the Step 8.5 audit. It writes `tasks/vdgg/{id}/audit-input.md`
(auditor instructions, then `requirements.md`, `confession.md`, `findings.md`,
`progress.md`, the followup files, the friction log, the evidence files and the
diff), runs the Formation's `AUDIT` seat through `vdgg_executor_run` or, when that
seat is unlisted, `vdgg-exec-claude.sh` (a fresh-context `claude -p` run), and
saves the report to `tasks/vdgg/{id}/audit.md`. Only when the report's last line
is `監査判定: 一致` does it write `.claude/.vdgg-audit-{id}` with the confession's
hash; the 8 -> 9 gate accepts the audit only while that hash still matches.
`vdgg_state_clear` prints `confession=<summary>` and appends the confessed
workarounds and downgrades to the session's `lessons.md`.

## Transition Rules

Allowed transitions:

- same step,
- next step,
- `8 -> 5` to continue with unfinished tasks,
- `7 -> 6` for testing/reflection retry.

`vdgg_state_loop` increments `loop_count`, removes that loop's simplify and review sentinels, and appends a `loop` event to the friction log.

`8 -> 5` resets `loop_count` to 0 and clears `task_allowlist_file`/`task_base_ref` because a new task starts; `vdgg_task_begin` must run again before the next task's edits. Omitted optional args of `vdgg_state_write` preserve the stored values; a literal `-` clears a task field explicitly.

## Cleanup

`vdgg_state_init` and `vdgg_state_clear` remove stale transient files:

```text
.claude/.vdgg-error-pending
.claude/.vdgg-simplify-sentinel-*
.claude/.vdgg-review-sentinel-*
.claude/.vdgg-task-*  (allowlists, baselines, gate files, patch chains)
.claude/.vdgg-friction-*
.claude/.vdgg-read-*
```

`vdgg_state_clear` prints `vdgg_friction_report` to stdout before it removes anything.

## Friction Log

Path:

```text
$CWD/.claude/.vdgg-friction-{vdgg_id}
```

Append-only, one line per event. The leading word is the whole contract with the reader; the fields after it are for Step 6-R and humans:

```text
deny phase=<phase> loop=<loop_count> tool=<tool name> gate=<line of the refusing exit>
stop phase=<phase>
loop phase=<phase>
task <task title>
```

- `deny`: written by the PreToolUse hook's EXIT trap when the hook exits 2 after the session is armed. Refusals that happen before that point (missing `jq`, the `VDGG_REQUIRED` entry gate) are not logged.
- `stop`: written by the Stop hook when it refuses a silent stop.
- `loop`: written by `vdgg_state_loop` when a retry starts. `8 -> 5` resets `loop_count`, so this event, not `loop_count`, is the session-wide retry count.
- `task`: written by `vdgg_task_begin`. It marks a boundary rather than an event, and is not counted.

Entering `reflection` prints the lines after the last `task` marker (at most 20) to stderr, so Step 6-R sees the gates this task hit without opening the file.

`vdgg_friction_report` prints `denies=N`, `stops=M`, and `loops=L`, one per line, and prints zeros when no session is armed or nothing has been logged. `task` markers are not counted.

Known limits:

- Exit status 2 stands in for "a gate refused". `grep` and `jq` also exit 2 on their own errors, so a hook defect can be logged as a `deny`, and a gate that answered with a JSON permission decision would not be counted.
- `gate` is a line number in the hook as it was when the line was written, and means nothing outside that session. It comes from a DEBUG trap, not `BASH_LINENO`: bash 5 resets that to 1 once the EXIT trap starts, while bash 3.2 does not.
- DEBUG traps are not inherited by functions, so an `exit` inside one — or a `set -e` death inside one — records the line before the call rather than the line that ended the hook. `tests/test-friction-log.sh` asserts statically that no function reachable under the armed trap contains `exit`; the `set -e` case is documented but not yet asserted.
- Only the Claude Code edition writes this log. The Codex edition's hooks do not.

## Simplify Sentinel

Path:

```text
$CWD/.claude/.vdgg-simplify-sentinel-{vdgg_id}-{loop_count}
```

Fields:

```text
started=1
started_at=<UTC timestamp>
modified=0|1
modified_files=<comma-separated paths>
```

Lifecycle:

1. Created by PostToolUse when the `simplify` skill runs during `testing`.
2. Updated to `modified=1` when Edit/Write runs after simplify in the same loop.
3. Deleted when verified transition succeeds, loop advances, or state clears.
