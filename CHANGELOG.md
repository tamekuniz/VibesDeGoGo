# Changelog

This project follows the structure of Keep a Changelog:
https://keepachangelog.com/en/1.1.0/

Both editions are developed in this repository. From 0.3.0 through 0.4.0 they
were maintained in separate repositories, so entries for those versions are
grouped by edition. Their histories are merged into this repository.

## [Unreleased]

### Added

- Step 8.5 confession (Claude Code edition): `vdgg_state_advance 9 commit`
  needs `tasks/vdgg/{id}/confession.md` with five sections (acceptance
  ledger, severity downgrades, gate workarounds, scope reductions, false gate
  passes). The gate checks one ledger row per acceptance criterion, an
  existing `evidence/` file for each verified row, no unverified row (no user
  waiver), `findings.md` against the downgrades, the friction log and residue
  against なし, and an audit by `vdgg_audit_run` (Formation seat `AUDIT`, or a
  fresh-context claude run) bound to the confession's hash.
  `vdgg_state_clear` prints the summary line and carries confessed
  workarounds and downgrades into `lessons.md`. Step 0 requires acceptance
  criteria verifiable in the environment; Step 7 records every finding in
  `findings.md`.
- Formation model and effort syntax (both editions; proposal item 6):
  shorthands `opus55` (`claude-opus-5-5`) and `fable51` (`claude-fable-5-1`);
  a shorthand may carry one effort (`opus55 medium`); claude effort accepts
  `xhigh` and `max`; seat `SUB` sets the model for in-process subagents
  (`vdgg_subagent_model`); `vdgg_formation_preflight` warns about mistyped
  claude models and codex models missing from the local Codex catalog
  (silent when there is no catalog).

- Optional plan review seat `4R` in Formations (both editions; proposal item
  5). A Formation that names an external AI on `4R` has it review the Step 4
  plan into `tasks/vdgg/{id}/plan-review.md`, and the Step 4 -> 5 hook
  refuses to leave planning until that file exists. `4R` is outside the `*`
  wildcard, so Formations that do not list it are unchanged.

- Evidence gates (both editions; docs/proposals/2026-09-24-evidence-gates.md
  items 1-4 and 7). Gates now check evidence of the work, not the shape of
  the artifacts:
  - Step 3 -> 4: every file under `## 1. Related files` must exist and have
    been read during `investigating` (Read/Grep/Glob/LS, or Bash readers such
    as `cat`, `sed -n`, `head`, `rg`), as recorded by the PreToolUse hook in
    `.vdgg-read-{id}`.
  - Step 4 -> 5: each `## T<n>` task in `todo.md` carries `### Location`, a
    `### Excerpt` of the current code that must match the file verbatim (or
    `新規` for a new file), and a prose `### Intent`; the plan may not contain
    the new code.
  - Step 6 is patch first: implementation files change through
    `vdgg_patch_apply` (`git apply --check`, allowlist, at most 3 files) or
    `vdgg_codemod_apply` (dry-run count); 6 -> 7 requires the patch chain to be
    intact.
  - Step 7: `vdgg_plan_diff` lays the plan next to the diff, and `verified`
    requires a `Plan reconciliation: <task>` record in `progress.md` for
    planned tasks. Discrepancies are recorded, not blocked.
  - Shared library `scripts/vdgg-evidence.sh`, byte-identical in both editions
    and covered by `tests/test-edition-sync.sh`.
  - SKILL.md (both editions) opens with the design principles: hooks check,
    prose guides; gates look at evidence; only the implementer writes code.
- **Breaking (workflow contract):** in `implementing` and `testing`, direct
  Edit/Write (Codex: `apply_patch`/Edit/Write) on implementation files is
  refused (review fixes go through reflection and a patch); `vdgg_task_begin`
  is required for every task; a task title must start with its `todo.md` id
  (`T1: ...`) when a plan exists; `vdgg_state_write` pairs each step with its
  own phases and each phase with the phase it may follow (no `testing ->
  progress` shortcut); the hooks refuse transitions whose step and phase are
  not literal.
  Allowlist entries can no longer start with `-` or name `.claude/.vdgg-*`,
  `.codex/.vdgg-*`, `.vdgg-target` or `.git/`.

- `VDGG_AUTO_MERGE=on` (environment variable, both editions). Step 9's
  `branch-pr` workflow then waits for the PR's checks and merges it instead of
  stopping for human merge approval. Unset or any other value keeps the previous
  behavior, so nothing changes for existing users who do not set it.

- Session friction log (Claude Code edition). The hooks and `vdgg_state_loop`
  append a `deny`, `stop`, or `loop` line to `.claude/.vdgg-friction-{id}`
  when a gate refuses a tool call or a silent stop, or a retry starts.
  `vdgg_task_begin` marks a task boundary, and entering `reflection` prints this
  task's lines to stderr so Step 6-R sees them without opening the file.
  `vdgg_state_clear` prints the counts for the completion report.

### Fixed

- `vdgg_task_gate` (both editions) no longer records a pass for nothing: a
  call without a verification command is refused, it runs only in Step 7
  (`testing`), it removes the loop's earlier pass before running (so a later
  failing check cannot leave an old pass standing), and the gate file records
  the command that ran (`command=`) so the pass can be checked afterwards.

- `.vdgg-target` values wrapped in single quotes are now unquoted like
  double-quoted ones. `REVIEW_COMMAND='cmd with args'` previously reached
  `bash -c` with the quotes attached and failed as a single unknown command
  name; `VERSION_FILE_*_PATH` in the Codex PreToolUse hook had the same gap.
  Both editions now strip either quote style, matching what the Claude Code
  PreToolUse hook already did and what `target_schema.md` documents.

### Removed

- **Breaking:** `vdgg_state_mark_reviewed` is no longer a public helper in either
  edition. It wrote the Step 7 review sentinel without requiring that any review
  had run, so the gate could be opened with a single command. The review sentinel
  is now written through `vdgg_review_run`, which runs a review command and
  records the gate only when that command exits 0. The hooks in both editions
  block direct calls to the internal sentinel writer, and now also catch a
  sentinel written by relative path after a `cd` into the sidecar directory. Sessions that recorded the
  gate manually must switch to `vdgg_review_run <command>`, or set
  `REVIEW_COMMAND` in `.vdgg-target` and call `vdgg_review_run` with no
  arguments. The MAGI review gate for subjective artifacts now runs through
  `vdgg_review_run` as well, checking the verdict line it wrote.

### Changed

- The two editions are reunited in a single repository. `VibesDeGoGo-for-Claude-Code`
  and `VibesDeGoGo-for-Codex` are superseded by `tmknzz/VibesDeGoGo`, which carries
  both trees at their existing paths (`skills/vibesdegogo/` and
  `.agents/skills/vibesdegogo/`) and both test suites in one `tests/` directory.
  No skill, hook, or script behavior changed in the move.
- The Claude Code plugin marketplace moved to `tmknzz/VibesDeGoGo`. Both the old
  and new marketplaces publish under the name `vibesdegogo`, so remove the old one
  before adding the new one. See the README install section.

### Removed

- `skills/vibesdegogo/references/edition_parity.md`, which existed only in the
  pre-split repository and had gone stale. The obligation it documented — keeping
  six duplicated files byte-identical across the two trees — now lives in
  CONTRIBUTING under "Files Shared Between Editions".

## [0.4.0] - 2026-07-08

### Claude Code edition

#### Added

- Step 0 consultation mode (wall-bounce) with an escalation trigger into MAGI for ambiguous or high-risk requirements.
- Step 0 now integrates GrillMe, a question-driven pre-filter (`GRILLME=on/off/auto`, default off) that runs before MAGI.
- Formation (executor tiers): optional `STEP6_EXECUTOR_TIERS` in `.vdgg-target` declares a cheapest-first executor ladder for Step 6, escalating automatically on repeated failure. Unset means unchanged behavior. Claude Code edition only — the Codex edition has no delegated executor mechanism.
- Step 7 now requires at least one falsifying verification check (boundary/error/regression) and scales the check count to the change surface instead of capping at three.
- REVIEW_COMMAND guidance now recommends a security perspective for publicly shipped code, with an updated example; simplify explicitly does not cover security.
- `VDGG_REQUIRED` entry gate: mechanically rejects edits/commits from unarmed sessions.
- Step 8 followup sweep: a loop that reclaims deferred low-severity findings instead of leaving them stranded.
- Step reporting: `STEP_REPORT=quiet` and a Delegate declaration line make the delegated-executor model and chat output controllable.
- Initial Claude-Code-only split from VibesDeGoGo!.
- Claude Code skill, hook scripts, references, and smoke tests.
- Docs: README repositioned to a plain, fact-based description with a new "Optional: MAGI" section; English README synced to the Japanese version (review-gate wording, PR explainer, jq-fallback note).

#### Changed

- Operational tuning from dogfooding (commit 4f7dcbd): verification-gate pipefail guidance, the simplify full-panel-vs-collapse criterion narrowed to unresolved high/medium findings that still apply to this round's changed code, a lightweight reflection branch for review-triggered retries, allowlist companion-test guidance, and clearer stop messaging.

#### Fixed

- `vdgg_task_begin` now rejects re-arming from outside Step 5, before any side effect can occur.
- `_vdgg_mtime` hardened for correct behavior on GNU/Linux, with a reflection regression test.
- zsh PATH safety when sourcing the helpers (`local path` no longer empties `$PATH`), the task-notes exemption scoped to the active session id, and rollback fixed to use the stored task base ref across reflection retries.

#### Security

- Sidecar guard rewritten with segment splitting and a whitelist, closing forgery/RCE paths.
- Unknown-phase requests no longer wipe all gates; phases are enumerated and the pretool hook defaults to deny.
- `.vdgg-target` sourcing in SKILL.md replaced with safe extraction, closing an RCE path (P0-1).
- `.vdgg-target` is now write-protected, closing a gate-forgery path via a self-authored REVIEW_COMMAND (P0-2).
- NotebookEdit and other unknown tools can no longer bypass the gate (P1-CC-2).

### Codex edition

#### Added

- Step 0 consultation mode (wall-bounce) for ambiguous goals, subjective deliverables, high-risk changes, or multiple valid approaches, with an escalation trigger into MAGI when it is installed; Step 7 notes MAGI can also serve as review for subjective deliverables.
- Step 0 now integrates GrillMe, a question-driven pre-filter (`GRILLME=on/off/auto` in `.vdgg-target`; `auto` matches the consultation trigger conditions, off when GrillMe isn't installed) that runs before MAGI.
- Step 7 now requires at least one falsifying verification check (boundary/error/regression) and scales the check count to the change surface instead of capping at three.
- REVIEW_COMMAND guidance now recommends a security perspective for publicly shipped code, with an updated example; simplify explicitly does not cover security.
- `VDGG_REQUIRED=on` entry gate in `.vdgg-target`: even before a session is armed, the pretool hook denies `apply_patch`/`Edit`/`Write` and write-side Bash (redirects, `tee`, `rm/mv/cp/dd/install/truncate/touch/ln/patch/mkfifo/apply_patch`, `sed`/`perl -i`) and `git commit`, and denies writes to `.vdgg-target` itself; fails closed if `jq` is missing while the gate is on.
- Step 8 followup sweep: Step 7 now classifies findings by severity (high/medium/low), low-only findings are deferred to `followup.md` instead of blocking `verified`, Step 5 can pick up `TF`-prefixed followup tasks, and Step 8 builds a followup-sweep queue from `followup.md` after all tasks complete (Step 9 reports any remainder).
- Step reporting: an Agent Role section requires each Step to declare itself at the start, `STEP_REPORT=quiet` in `.vdgg-target` silences it, and delegated sub-agents/executors emit a `[VibesDeGoGo! Delegate] step=N, executor=..., role=...` line.
- Retry-investigation gate: on `reflection` -> `implementing`, a fresh `investigation-r{loop}.md` and `progress.md` (newer than the state file) are now required, backed by a new `_vdgg_mtime` helper.
- `.gitignore` added, tracking `.codex/.vdgg-*` and `tasks/vdgg/`.

#### Changed

- VDGG state and tool hooks now resolve the git root before reading or writing `.codex/.vdgg-*`, so sessions started from subdirectories apply to the whole repository.
- Operational tuning ported from the Claude Code edition: `set -o pipefail` guidance (with a false-positive warning) for Step 7's `bash -lc` pipe example, a lighter Step 6-R path for review/simplify-triggered retries, a companion-test note for Step 5 allowlists when signatures change, and stop-hook wording that background waits are a legitimate stop reason.
- README.md Core Flow Step 9 wording aligned with README.ja.md ("Commit, and for the default branch-pr workflow, create a PR and stop.").

#### Fixed

- `vdgg_task_begin` now checks the step transition before running side effects (allowlist generation, baseline snapshot), fixing a bug where re-arming outside Step 5 could report success ("began") even though the state write failed afterward.
- The posttool hook now safely handles `tool_response` when Codex 0.139.0 passes it as a string instead of an object, fixing a case where the Bash success/error-ack gate silently stopped working; `codex-setup.md` documents this and the fact that `codex exec` does not fire hooks.
- `_vdgg_mtime` hardened against a GNU/Linux bug where a BSD-style `stat` flag silently succeeded with non-numeric output instead of failing, so the fallback never ran and the reflection gate blocked unconditionally on Linux (the root cause of the Ubuntu CI failures); output is now validated as numeric before falling back to GNU `stat` and then `0`, and the regression test's mtime generation was made POSIX-portable.

#### Security

- `.vdgg-target` sourcing replaced with safe key extraction and an allow-list, closing an RCE path (P0-1).
- `.vdgg-target` is now write-protected, closing a gate-forgery path via a self-authored `REVIEW_COMMAND` (P0-2).
- Sidecar guard rewritten with shell-segment splitting and a read-only whitelist (fail-closed).
- `vdgg_state_write` now validates `phase` against a known list of 11 phases so an unknown phase can no longer wipe all gates; the pretool hook's `verified`/`progress`/`commit` arm is consolidated, closing an edit-permission gap in the `verified` phase, and defaults to deny for unrecognized phases.
- `testing` can no longer skip `reflection` to jump straight to `implementing`, and `reflection` can no longer jump straight to `verified`.
- The pretool hook now blocks direct `commit`/`push` to the base branch during the `commit` phase (reading `WORKFLOW`/`BASE_BRANCH` safely), enforcing the branch-pr workflow.

## [0.3.0]

Both editions were split out of the single repository at this version.

### Claude Code edition - 2026-06-11

#### Added

- Plugin packaging: `.claude-plugin/plugin.json`, `.claude-plugin/marketplace.json`, and `hooks/hooks.json` — installing the plugin registers the skill and activates the hooks automatically.
- Task gate (ported from the Codex edition, with fixes): `vdgg_task_begin` / `vdgg_task_gate` / `vdgg_task_rollback` / `vdgg_task_changed_files` / `vdgg_task_check_allowlist`. The pretool hook enforces the task allowlist during implementing/testing and requires a task-gate pass before `verified`. Task notes under `tasks/vdgg/{id}/` are exempt.
- External review gate: `vdgg_review_run` runs `REVIEW_COMMAND` from `.vdgg-target` (or an explicit command) and writes the review sentinel only on success. The verified gate now accepts the simplify sentinel OR the review sentinel.
- Delegated step executors (documented contract): `STEP3/4/6_EXECUTOR_COMMAND` in `.vdgg-target`; subagent prompts double as executor prompt templates.
- `.gitignore` self-management: `vdgg_state_init` appends a `.claude/.vdgg-*` ignore block (marker-guarded, idempotent).
- Operational guidance ported from v1.7.x: simplify subagent consolidation rules, severity-based findings response (low-only findings go to `followup-r{loop}.md`), lightweight-mode version-bump obligation, goal-based branch naming with stay-on-feature-branch behavior.
- CI: GitHub Actions workflow running syntax checks and the test suite on ubuntu and macos.
- Japanese README (`README.ja.md`).
- Tests: task-gate suite, plugin-manifest suite, review-sentinel/forgery/jq-fallback/8-to-5 cases.

#### Changed

- State file gains `task_allowlist_file` and `task_base_ref` fields; `vdgg_state_write` accepts them as optional args 5/6 (omit = preserve, `-` = clear).
- The 8→5 transition clears the previous task's allowlist/baseline, so `vdgg_task_begin` is mechanically required for every task. **Behavior change:** Edit/Write during implementing/testing is now blocked until `vdgg_task_begin` declares an allowlist.
- Sidecar write-protection generalized: Edit/Write/Bash writes to any `.claude/.vdgg-*` path are blocked (sentinel forgery closed).
- `vdgg_state_mark_reviewed` writes `modified=0`/`modified_files=` (same sentinel schema as the simplify sentinel; Codex-edition parity).
- jq-missing behavior: hooks now stay out of the way when no VDGG session is active in the repository; active sessions keep failing closed with install hints.

#### Removed

- Dead `.vdgg-step-block-*` cleanup remnants and the dead `*/${TASKS_DIR}/*` glob alternatives.
### Codex edition - 2026-06-12

#### Added

- Initial Codex-only split from VibesDeGoGo!.
- Codex skill, hook scripts, project-local hook config, and smoke tests.
- Global `UserPromptSubmit` hook that makes VDGG the default workflow for coding work in any git repository.
- `vdgg_review_run`: runs `REVIEW_COMMAND` from the project-root `.vdgg-target` (or an explicit command) and writes the review sentinel only on success.
- `_vdgg_ensure_gitignore`: appends a `.codex/.vdgg-*` ignore block to `.gitignore` (marker-guarded, idempotent).
- SKILL.md docs: `REVIEW_COMMAND` / `STEP3-4-6_EXECUTOR_COMMAND` delegation contract, the `[Error Acknowledged]` gate, and rollback recovery guidance.
- CI: GitHub Actions workflow running syntax checks and the test suite on ubuntu and macos.
- `README.ja.md`: Japanese README.
- Tests: zsh regression suite, 8→5 reset/clear behavior, loop-survival for allowlist/gate/rollback, `vdgg_review_run`, fakebin jq cases, sentinel forgery, posttool Edit/Write sentinel flip.

#### Changed

- zsh safety: `local path` renamed throughout (`path` is tied to `$PATH` in zsh and silently emptied it; live bug).
- `vdgg_state_write` optional args 5/6: omit = preserve, `-` = clear.
- 8→5 transition resets the loop counter AND clears task scope (allowlist + baseline), so `vdgg_task_begin` is mechanically required per task. **Behavior change:** task notes under `tasks/vdgg/{id}/` no longer need allowlisting.
- `vdgg_task_begin` performs a single atomic state write (perl/sed removed).
- Allowlist, changed-files, and rollback all resolve from stored state so the task gate survives retry loops.
- Changed-files task-notes exemption scoped to the active session id only.
- Sidecar write-protection generalized to `.codex/.vdgg-*` (sentinel forgery closed).
- posttool hook flips the review sentinel on Edit/Write in addition to apply_patch.
- jq-missing hooks fail open when no VDGG session is active; active sessions keep failing closed with install hints.
## Pre-split releases

These versions predate the edition split, when both editions lived in this
repository the first time.

### Unreleased at the time of the split

#### Added

- Codex edition smoke tests (`tests/test-codex-state.sh`) covering init,
  advance, loop, mark_reviewed, clear, and the re-init refusal path.
- README install hints for `jq` on macOS, Debian/Ubuntu/WSL, Alpine, and
  Fedora/RHEL.
- `vdgg_state_mark_reviewed` is now listed in `references/state_helpers.md`
  as an auxiliary review marker for environments without the `simplify` skill.

#### Fixed

- Reflection gate now works on Linux. The pretool hook used the BSD-only
  `stat -f %m` for retry investigation/progress mtime checks, which silently
  returned 0 on Linux and permanently blocked the Step 6 retry transition. A
  small `_vdgg_mtime` helper falls back from `stat -f %m` to `stat -c %Y` so
  the gate is correct on both macOS and Linux/WSL.
- Claude edition `vdgg_state_init` no longer silently overwrites an active
  session. It now prints a clear message with the existing id and returns 1,
  matching the Codex edition behavior.
- Codex `_vdgg_generate_id` now truncates the random component to 4 hex
  characters so ids match the documented `YYYYMMDD-HHMM-xxxx` format and stay
  in parity with the Claude edition.

#### Changed

- Step 1 feature branch name is now derived from the agreed Step 0 Goal in
  `{type}/{slug}` form (e.g., `feat/japanese-readme`) instead of the
  `vibesdegogo/{id}` template. Both Claude and Codex editions of `SKILL.md`,
  and `references/target_schema.md`, were updated. Nesting on top of an
  existing feature branch is allowed; the Step 1 block runs once per session
  because `vdgg_state_init` refuses a second initialization.
- Hook `jq` missing-dependency UX is unified across Claude and Codex hooks.
  All hooks print a per-OS install hint and exit 2 (or 0 in the stop hook).
  The previous behavior that silently kicked off a background `brew install
  jq` has been removed; users now run the install command themselves and the
  pretool/posttool hooks let `brew install jq` / `apt-get install jq` /
  `apk add jq` / `dnf install jq` / `pacman -S jq` commands through while jq
  is still missing.

### [0.2.0] - 2026-05-26

#### Added

- Zero-dependency bash smoke tests for state helpers and hook phase guards.
- Claude/Codex edition parity documentation.
- Contribution guide and GitHub issue/PR templates.

#### Fixed

- Restored meaningful Claude hook/state script comments damaged during rename.
- Replaced the leftover legacy formation regex with `vdgg_state_*` matching.
- `PostToolUseFailure` posttool branch now honors the same `IS_SEARCH`
  exception as the standard `EXIT_CODE` branch, so search no-match (exit 1)
  from `grep`/`find`/etc. no longer raises the error-pending flag and
  blocks follow-up tools.
- Pretool's direct state-file edit guard treats fd-merge redirects
  (`2>&1`, `>&2`) as non-destructive by changing the redirect detector
  from `>` to `>[^&]`. Diagnostic commands that merely mention state-file
  paths now pass through.
- Pretool's direct state-file edit guard exempts `git commit`, so a commit
  message that legitimately mentions a state-file path is no longer
  treated as a destructive edit. Other commit-phase rules still apply.
- Posttool's testing-phase Edit/Write tracking now excludes the simplify
  sentinel itself, preventing a self-referential `modified=1` loop when
  the sentinel is created via Edit/Write (e.g. environments without the
  `simplify` Skill tool).
- Codex pretool received the same redirect and `git commit` exemptions
  for parity.

### [0.1.0] - 2026-05-25

#### Added

- VibesDeGoGo! for Claude Code.
- VibesDeGoGo! for Codex.
- Branch/PR workflow defaults.
- Reflection loop and verification gates.
- Self-maintenance and lightweight mode documentation.
