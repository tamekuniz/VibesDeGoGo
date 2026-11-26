---
name: vibesdegogo
description: "Use VibesDeGoGo! for Codex when the user asks Codex to carry coding work through requirements, investigation, planning, implementation, verification, progress reporting, and commit/PR with safety stops."
version: 0.4.0
---

# VibesDeGoGo! for Codex

VibesDeGoGo! for Codex is a serial, state-file-driven workflow for autonomous coding in Codex. It follows the VibesDeGoGo! for Claude Code step model first; do not simplify the workflow unless the user explicitly asks for a lighter mode.

## Design Principles

These three rules decide how every gate below is built.

- **Hooks check what must hold; prose only guides judgment.** Anything the workflow depends on is verified by a hook or a state helper. Text in this file or AGENTS.md is written on the assumption that it will sometimes be skipped: it explains how to decide, and is never the only thing keeping the workflow safe.
- **Gates look at evidence, not form.** A gate opens on something that exists only if the work was done: files actually read in Step 3, excerpts that match the current code verbatim in Step 4, a patch that `git apply --check` accepts in Step 6, a recorded comparison of plan and diff in Step 7. Headings and file existence alone open nothing.
- **Only the implementer writes code.** Planning names the location, quotes the current code and states the intent, but does not write the new code. The implementing seat (this session, or the Formation's Step 6 executor) produces it as a patch, so the code a different-vendor reviewer reads was not authored by the planner.

## When To Use

Use this skill for coding work where the user wants Codex to continue through implementation, verification, and commit/PR.

Trigger phrases include `VibesDeGoGo! for Codex`, `VibesDeGoGo!`, `/VibesDeGoGo!`, and Japanese equivalents such as `VibesDeGoGoで進めて`.

Do not use it for wording-only requests, open-ended discussion, or brainstorming where no repository workflow should execute.

## Agent Role

- Declare before acting: output a Step declaration at the beginning of each Step.

### Step reporting

Whenever work is delegated to a subagent or an external executor, output one line in the user-facing text before the delegation:

```text
[VibesDeGoGo! Delegate] step=N, executor=<model or command>, role=<short role>
```

### Step AI Formations

A Formation is a named Step-to-AI assignment written as a small hand-editable text file. Select it before Step 0 with `VDGG_FORMATION=<name>` or an explicit user instruction. Before consultation begins, source `vdgg-state.sh`, run `vdgg_formation_preflight <name>`, and resolve `STEP_0_AI` and `STEP_0_GRILL_AI` with that explicit name. Then pass the same name to `vdgg_state_init --formation <name>` in Step 1. Formation files and executor definitions are trusted user configuration outside the repository:

```text
${VDGG_CONFIG_DIR:-$HOME/.config/vdgg}/
  formations/<name>.conf
  executors/<ai>.conf
```

Write one line per step, in order, so the whole lineup is visible at a glance:

```text
0: primary
0G: primary
1: primary
2: primary
3: sonnet5
4: sonnet5
5: primary
6: sonnet5
6R: fable5
7: fable5
8: primary
9: primary
--
Everything below the separator is a free-form memo and is never read.
```

Syntax, one line per seat: `<seat>: <ai> [model] [effort]` or `<seat>: <ai1> [model] [effort] | <ai2> [model] [effort] | ...` for a fallback list.

- Seats: `0`, `0G`, `1`, `2`, `3`, `4`, `4R`, `5`, `6`, `6R`, `7`, `8`, `9`, `SUB` (case-insensitive; `grill` is still accepted as a synonym of `0G`; `4R` is the optional plan review, see Step 4), plus `MAGI-M`, `MAGI-B`, `MAGI-C` for the three MAGI council seats (MELCHIOR / BALTHASAR / CASPER; case-insensitive), plus `*` which assigns `3, 4, 6, 6R, 7` at once — an explicit seat line wins over `*`. Every step can name the AI that runs it. Unlisted seats fall back to `primary`. The MAGI seats are outside the `*` wildcard set; they must be listed explicitly to delegate, otherwise MAGI runs those seats inline.
- Values: `primary` — the model this session is already running on, i.e. no delegation (`inline` is accepted as a synonym). The model shorthands `opus5`, `opus55`, `sonnet5`, `fable5`, `fable51`, `haiku45`, which expand to the bundled `claude` wrapper plus the full model id (`opus55` = `claude-opus-5-5`, `fable51` = `claude-fable-5-1`) and take one optional claude effort (`opus55 medium`). The builtins `claude` / `codex` / `agy`, which run the bundled `scripts/vdgg-exec-claude.sh` / `vdgg-exec-codex.sh` / `vdgg-exec-agy.sh` wrappers with optional model and effort tokens — effort is recognized by a closed vocabulary (claude: `low|medium|high|xhigh|max`, codex: `minimal|low|medium|high|xhigh`, agy: `low|medium|high|xhigh|max`), any other token is the model. `agy` is Antigravity CLI signed in with a Google account, so it runs on a Google AI Pro / Ultra subscription quota (`agy models` lists the model ids, e.g. `7: agy gemini-4-neon-high`). agy has no read-only mode, so on an artifact seat the wrapper runs it in a throwaway copy of the work tree (symlinks removed, absolute repository paths in the prompt pointed at the copy) and collects the output file from there; nothing it writes reaches the repository. Or a bare executor name resolved through `executors/<name>.conf` containing one `COMMAND=/absolute/path/to/executable` line; bare names take no extra tokens — bake fixed settings into that command.
- `vdgg_formation_preflight` warns (it never fails) about model names that look mistyped: a claude model must be an alias (`opus`, `sonnet`, `haiku`, `fable`) or `claude-<family>-<version>`, and a codex model must appear in the local Codex catalog (`model_catalog_json` in `${CODEX_HOME:-~/.codex}/config.toml`, else `models_cache.json` there). Without a Codex catalog there is nothing to compare with, and no codex warning is printed.
- Seat `SUB` names the model for the in-process subagents a step launches (the Step 6-R researcher, simplify's angle finders). It is outside the `*` wildcard. `vdgg_subagent_model` prints `inline` (no SUB seat: inherit this session's model), `agent <family> [effort]` (pass `<family>` — `opus`, `sonnet`, `haiku` or `fable` — as the subagent's model; the effort applies only where the launcher accepts one), or `executor` (SUB names another vendor or executor: run that work with `vdgg_executor_run STEP_SUB_AI` instead).
- A lone `--` line ends the configuration. Everything below it is a memo: no comment marker is needed and nothing there is parsed, so it cannot break the file.
- Naming an AI on a seat assigns the *work product* of that step, never the mechanics. State transitions, task allowlists, review gates, and commit permissions stay with the controlling VDGG session at every step. Seats `0` and `0G` are conversational, so a bundled one-shot wrapper there answers in a single pass instead of holding a dialogue — use a bare executor that can own the conversation when that matters.
- The `MAGI-M` / `MAGI-B` / `MAGI-C` seats are not VDGG steps — they name executors for the three MAGI council members (MELCHIOR / BALTHASAR / CASPER) when the MAGI skill (`zmagi`, formerly `magi`) runs as a Step 0 consultation escalation or a Step 7 subjective-artifact review gate. The MAGI skill resolves each seat via `vdgg_formation_resolve MAGI_MELCHIOR_AI` (and the B / C variants). Seats left unlisted (or set to `primary`/`inline`) run inline in the host — MAGI's own default — so existing formation files that predate MAGI seats keep working unchanged. Committee independence increases when at least MELCHIOR runs on a different vendor than the host; see the MAGI skill's Formation section for the honesty covenant that governs external-executor failures.
- The parser never sources these files and the command is executed directly, not through a shell string. Tokens must start with an alphanumeric so they can never reach an executor's argv as a flag.
- Fallback list (`|`-separated, up to 5 specs, whitespace around `|` is optional): `vdgg_executor_run` tries the first spec, and on a non-zero exit or missing/empty output falls through to the next spec, stopping at the first success. Each spec follows the same `<ai> [model] [effort]` grammar and is validated independently. `primary`/`inline` may only appear as the sole spec, never in the tail — a fallback list has to name external executors that can actually be tried. Grill Me (`STEP_0_GRILL_AI`) does not fall through on a validator failure (a semantic mismatch, not a transient transport failure). Also record: a failing executor's stderr string is not authoritative evidence of persistent rate-limit or auth loss — use the fallback list to reroute, and do not rebuild the Formation on the basis of a single error message alone.

When a Formation is selected, resolve the assigned AI before acting in every Step with `vdgg_formation_resolve <STEP_KEY>`. Use `STEP_6R_AI` for reflection and `STEP_0_GRILL_AI` for Grill Me. Then:

1. `inline`: work normally in the current agent.
2. External AI: write the smallest sufficient input artifact, output the Delegate line, and call `vdgg_executor_run <STEP_KEY> <input-file> [output-file]`.
3. Validate the expected artifact before advancing. A non-zero executor result, missing output, unknown AI, or invalid Formation stops the workflow with state unchanged. Never silently fall back to `inline`.

The executor receives `VDGG_EXECUTOR_FORMATION`, `VDGG_EXECUTOR_AI`, `VDGG_EXECUTOR_MODEL`, `VDGG_EXECUTOR_EFFORT`, `VDGG_EXECUTOR_STEP`, `VDGG_EXECUTOR_INPUT`, and `VDGG_EXECUTOR_OUTPUT`. State transitions, task allowlists, review gates, and commit permissions remain owned by the controlling VDGG session.

With no Formation selected, every step runs inline; `.vdgg-target` `REVIEW_COMMAND` still configures the Step 7 review.

### ChatGPT Chat + local Qwen Formation

For `chatgpt-qwen` or `chatgpt-web`, follow [ChatGPT/Qwen integration](references/chatgpt-qwen.md). The ChatGPT executor waits for this host agent to service its request using the in-app browser and `codex-with-chatgpt`; it does not drive a browser by itself. Never wait on the executor without servicing the request. Check the visible `6 Pro` model and actual workspace before relaying a response. Existing state, allowlist and review gates remain mandatory.

### Local llama-server executors

When a Formation assigns a Step to an executor backed by a locally-hosted `llama-server` (llama.cpp), VDGG ships two helpers so the server configuration lives in one declarative file instead of being scattered across `~/.zshrc`, launchd plists, and executor wrapper scripts:

- [`references/servers-conf.md`](references/servers-conf.md) — schema and CLI contract for `${VDGG_CONFIG_DIR:-$HOME/.config/vdgg}/servers.conf` (source of truth).
- [`references/servers.conf.example`](references/servers.conf.example) — a copy-and-edit fixture.
- [`scripts/vdgg-llm-start.sh`](scripts/vdgg-llm-start.sh) — a thin wrapper: `--check`, `--dry-run <id>`, `<id>` (exec).
- [`references/local-inference-setup.md`](references/local-inference-setup.md) — first-run walkthrough for macOS launchd (tested) and Linux systemd (schema-compatible, awaiting community verification).

Executor `COMMAND=` lines can then call `vdgg-llm-start <id>` through a wrapper that sends the actual request to `http://127.0.0.1:<port>`. Only the port/api key move; the executor script itself no longer hard-codes them.

## Important Codex Differences

- State lives in `.codex/.vdgg-active` and `.codex/.vdgg-state-{id}`. Each step accepts only its own phases (1 declare, 2 requirements, 3 investigating, 4 planning, 5 task-selected, 6 implementing/reflection, 7 testing/verified, 8 progress, 9 commit), and each phase only after the phase before it in the workflow (`testing` only from `implementing`, `reflection` only from `testing`, `verified` only from `testing`, `progress` only from `verified`). The pretool hook refuses a `vdgg_state_advance/loop/write` whose step and phase are not written literally. The Step 3 read log is `.codex/.vdgg-read-{id}` and the Step 6 patch chain `.codex/.vdgg-task-patchchain-{id}`.
- Task files still live in `tasks/vdgg/{id}/`.
- Prefer global hooks in `~/.codex/hooks.json` or `~/.codex/config.toml` so VDGG rules apply across repositories. Repo-local `.codex/hooks.json` is optional and only covers that repository after trust.
- Hook commands should call the installed skill path, normally `$HOME/.agents/skills/vibesdegogo`, or set `VDGG_CODEX_SKILL_DIR` to an absolute skill directory. Do not assume the target project contains `.agents/skills/vibesdegogo`.
- Codex hook coverage is a guardrail, not a complete enforcement boundary. When unsure, stop before risky work.
- Codex does not have the exact Claude Code `simplify` gate. Use the Codex review gate in this skill instead: after verification, run the review through `vdgg_review_run` so the gate is recorded only when the review command succeeds, then advance to `verified`.
- After a failed Bash command, the next command you issue must contain `[Error Acknowledged]` in its text before anything else runs (the pretool error gate). If the hook blocks you, include that marker in your next command text to clear the gate before continuing.
- Each implementation loop must use a task allowlist and task gate: `vdgg_task_begin` records the allowed files and baseline, `vdgg_task_gate` must pass before `verified`, and `vdgg_task_rollback` reverts the current task when the gate fails.

Use this resolver inside every shell command that calls state helpers:

```bash
VDGG_REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
VDGG_CODEX_SKILL_DIR="${VDGG_CODEX_SKILL_DIR:-$HOME/.agents/skills/vibesdegogo}"
if [ ! -f "$VDGG_CODEX_SKILL_DIR/scripts/vdgg-state.sh" ]; then
  VDGG_CODEX_SKILL_DIR="$VDGG_REPO_ROOT/.agents/skills/vibesdegogo"
fi
source "$VDGG_CODEX_SKILL_DIR/scripts/vdgg-state.sh"
```

## Step 0: Agree On Requirements

Before starting the state machine, draft and get agreement on:

1. Goal: what state or user value should be achieved.
2. Constraints: what must not change and what boundaries apply.
3. Acceptance criteria: concrete checks that determine completion.

Default constraints must include:

- Prefer the target environment's standard features, components, APIs, and patterns.
- Do not add custom UI, custom components, custom state management, custom design systems, custom utilities, or external dependencies unless the need is clear.
- Stop before changing constraints, adding dependencies, changing API/persistence/auth/permissions/security/billing/analytics/user-data behavior, destructive operations, or broad renames.
- Do not mark work complete without verification.

Start Step 1 only after the user clearly accepts the draft.

Do not create or advance `.codex/.vdgg-*` state files, create task files, switch branches, or edit implementation files before Step 0 is accepted. Step 0 happens before state exists, so hooks cannot fully enforce it; the agent must stop itself here.

## Step 0 Mode: Consultation (壁打ち)

When the requirements cannot yet be safely fixed, run Step 0 as a consultation (壁打ち) before drafting Goal / Constraints / Acceptance. Enter this mode when any of these hold: the goal is ambiguous; the work is subjective or creative — docs, naming, copy, design, a handbook, anything an AI can produce where "good" lives in the user's head, not only in code; the change is high-stakes or hard to reverse (public artifacts, contracts); or more than one defensible direction exists. For a clear, mechanical task with one obvious shape, skip this mode and draft the three items directly.

Consultation is a sounding board. It is none of its three failure modes:

- **Not guess-and-go:** do not silently pick one reading and start building.
- **Not option-dumping:** do not hand over a bare list ("A, B, or C?") and make the user do the thinking.
- **Not autonomous-finalize:** do not settle a subjective or scope question for the user behind a closed door.

Loop until the WHAT is agreed:

1. Name the decisions the result actually hinges on — real forks, not pseudo-choices. Raise a few at a time; do not flood.
2. For each, lay out the trade-offs (what each option wins and loses) and give a recommendation with its reasoning. Recommend; do not merely survey.
3. The user decides or redirects. On every subjective or scope question the user is the decider; the agent supplies the thinking, not the verdict.
4. For a genuinely split, high-stakes fork, escalate that one point to a deeper, multi-perspective deliberation: run the MAGI skill (`zmagi`, formerly `magi`) if it is installed; if not, get a second opinion another way (a different model, or a structured review). Bring the output back as material — still for the user to decide.

Do not relitigate a settled point, and do not stall: drive toward convergence. When the WHAT is agreed, leave consultation mode and write `requirements.md`. For subjective artifacts, record in Acceptance what "good" was agreed to mean, so completion stays checkable. Then proceed to Step 1.

## Step 0 Helper: Grill Me (optional)

The Consultation loop above is the baseline for resolving ambiguity. Grill Me is an optional third part — a question-driven interrogator that walks the decision tree one branch at a time — that can be slotted in **before** drafting Goal / Constraints / Acceptance, to pre-filter ambiguity through structured waves of questions, each with a recommended answer.

When Grill Me is engaged, Step 0 runs in three layers before drafting:

1. **Shallow consultation** — the baseline loop above raises real forks and gives recommendations.
2. **Grill Me pass** — sequential question waves drive the user through unresolved branches, each question carrying a recommended answer; the user accepts, redirects, or rejects per question.
3. **MAGI escalation** — for any remaining genuinely split, high-stakes fork, step 4 of the Consultation loop still applies (run MAGI if installed, else get a second opinion another way).

Then drafting `requirements.md` proceeds as usual.

If a selected Formation assigns `STEP_0_GRILL_AI` to an external AI, that executor owns the complete Grill Me conversation. Its command must keep the transcript out of stdout/stderr and write only the final handoff file. `vdgg_executor_run` accepts that handoff only when its level-2 headings are exactly, in order: `Goal`, `Constraints`, `Acceptance criteria`, `Decisions`, and `Unresolved questions`. The HQ consumes that file, not the conversation transcript. If the executor cannot own the interaction on the current surface, stop and report the limitation; do not relay every turn through HQ and call it equivalent.

Grill Me is a pre-filter, not a replacement for MAGI. Skipping Grill Me is safe because MAGI remains the deeper-deliberation backstop for high-stakes forks.

Control via `.vdgg-target`:

```bash
# Step 0 Grill Me toggle. Grill Me is an optional question-driven
# interrogator that walks the decision tree one branch at a time and
# runs before drafting Goal / Constraints / Acceptance.
#   off  (default) — do not run Grill Me.
#   on             — always run Grill Me at Step 0.
#   auto           — run when the Consultation entry conditions hold
#                    (ambiguous goal, subjective work, high stakes,
#                    multiple defensible directions).
# Treated as off if the Grill Me skill is not installed.
GRILLME=auto
```

When no Formation assigns an external Grill Me executor, a missing Grill Me skill makes the setting behave as `off` and Step 0 continues with Consultation. In that legacy path, the orchestrating agent invokes the installed Grill Me skill directly; there is no shell helper for it (the same convention as MAGI escalation).

## Entry Gate: VDGG_REQUIRED

Normally the hooks are fail-open while no VibesDeGoGo! session is armed (no `.codex/.vdgg-active`), so unrelated repositories are never blocked. A repository can opt out of that leniency in `.vdgg-target`:

```bash
# Entry gate. While no session is armed, the pretool hook denies
# apply_patch/Edit/Write, Bash segments that write files (redirects to real
# paths, tee, rm/mv/cp/dd/install/truncate/touch/ln/patch/mkfifo/apply_patch,
# sed/perl -i) and `git commit` — including writes to .vdgg-target itself, so
# the gate cannot be self-disabled. Read-only commands, builds, and the
# arming command (vdgg_state_init) stay allowed. Without jq the hook fails
# closed while this key is on. Only the literal value `on` activates the
# gate; absent/off/other values keep the historical fail-open behavior.
VDGG_REQUIRED=off
```

Set `VDGG_REQUIRED=on` in repositories where every code change must go through the VibesDeGoGo! workflow: arming the gates is then no longer a voluntary act, so an agent that skips Step 1 cannot edit or commit at all. The deny message points to `vdgg_state_init`. Known limits match the sidecar guard: interpreter one-liners and writes hidden behind shell variables evade the literal segment match — the gate stops contract-ignoring drift, not a deliberately evasive agent.

## Step 1: Formation

```bash
VDGG_REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
VDGG_CODEX_SKILL_DIR="${VDGG_CODEX_SKILL_DIR:-$HOME/.agents/skills/vibesdegogo}"
if [ ! -f "$VDGG_CODEX_SKILL_DIR/scripts/vdgg-state.sh" ]; then
  VDGG_CODEX_SKILL_DIR="$VDGG_REPO_ROOT/.agents/skills/vibesdegogo"
fi
source "$VDGG_CODEX_SKILL_DIR/scripts/vdgg-state.sh"
if [ -n "${VDGG_FORMATION:-}" ]; then
  vdgg_state_init --formation "$VDGG_FORMATION"
else
  vdgg_state_init
fi
```

For the default `branch-pr` workflow, create a feature branch after initialization and before code edits.

Branch name is derived from the Step 0 Goal, not from the VibesDeGoGo! id. Pick a name in the form `{type}/{slug}` where:

- `{type}` is one of `feat`, `fix`, `refactor`, `docs`, `test`, `chore` (same vocabulary as the Step 9 commit type).
- `{slug}` is a short kebab-case summary of the change (3-5 words, lowercase, ASCII, hyphen-separated). Drop articles and filler.
- Examples: `feat/japanese-readme`, `fix/init-portability`, `refactor/state-helpers`.

```bash
WORKFLOW=branch-pr
BASE_BRANCH=""
# Never `source` .vdgg-target: it is a repository-controlled file, and sourcing
# it would execute any code an untrusted repo places there. Read only the needed
# keys and validate them.
if [ -f .vdgg-target ]; then
  WORKFLOW=$(grep -m1 '^WORKFLOW=' .vdgg-target | sed -E 's/^[^=]*=//; s/^"(.*)"$/\1/')
  BASE_BRANCH=$(grep -m1 '^BASE_BRANCH=' .vdgg-target | sed -E 's/^[^=]*=//; s/^"(.*)"$/\1/')
  case "$WORKFLOW" in trunk|branch-pr) ;; *) WORKFLOW=branch-pr ;; esac
  case "$BASE_BRANCH" in ''|*[!A-Za-z0-9._/-]*) BASE_BRANCH="" ;; esac
fi
WORKFLOW=${WORKFLOW:-branch-pr}
if [ "${WORKFLOW:-branch-pr}" != "trunk" ]; then
  if [ -z "${BASE_BRANCH:-}" ]; then
    BASE_BRANCH=$(git symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null | sed 's#^origin/##')
    BASE_BRANCH=${BASE_BRANCH:-main}
  fi
  # VDGG_BRANCH: agent fills in based on the agreed Step 0 Goal.
  VDGG_BRANCH="<type>/<kebab-case-slug>"
  git checkout -b "$VDGG_BRANCH"
fi
```

Nesting is allowed: if the current branch is already a feature branch, a new `{type}/{slug}` branch is still created on top of it. The Step 1 block runs once per session because `vdgg_state_init` refuses a second initialization.

Then output:

```text
[VibesDeGoGo! Declaration] id=<vdgg_get_id output>
```

## Step 2: Requirements

Write `tasks/vdgg/{id}/requirements.md`:

```markdown
## Goal
...

## Constraints
...

## Acceptance criteria
...

## Lessons Applied
...
```

The `## Lessons Applied` heading is the earliest structural point where user-memory / user `AGENTS.md` / AIB lessons still shape the requirements themselves. List each applicable item with a one-line "why relevant"; write `None applicable` when nothing fits — the heading and a non-empty body are enforced by the hook, so the consultation is never silently skipped. This section is distinct from Step 3's `## Lessons applied` heading in `investigation.md`, which records per-repo `tasks/vdgg/*/lessons.md` findings that shape the *implementation* rather than the requirements; both layers complement each other.

Advance:

```bash
# [VibesDeGoGo! Step 2 Start] step=2, phase=requirements, loop=0
VDGG_REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
VDGG_CODEX_SKILL_DIR="${VDGG_CODEX_SKILL_DIR:-$HOME/.agents/skills/vibesdegogo}"
[ -f "$VDGG_CODEX_SKILL_DIR/scripts/vdgg-state.sh" ] || VDGG_CODEX_SKILL_DIR="$VDGG_REPO_ROOT/.agents/skills/vibesdegogo"
source "$VDGG_CODEX_SKILL_DIR/scripts/vdgg-state.sh"
vdgg_state_advance 2 requirements
```

## Step 3: Investigation

`investigation.md` MUST use exactly these seven level-2 headings, each with a non-empty body — the hook that opens Step 4 checks every heading and every body:

1. `## 1. Related files`
2. `## 2. Existing implementation patterns`
3. `## 3. Impact surface`
4. `## 4. Prior similar implementations`
5. `## 5. Side effects and risks`
6. `## 6. Constraints`
7. `## 7. Verification strategy`

An additional `## Lessons applied` section follows (see below) — that heading is not enforced by the hook but is still required by the workflow.

- Read actual project files. Do not guess.
- Trace direct callers and impact.
- Read lessons from recent sessions and record the applicable ones in `investigation.md` under a `## Lessons applied` heading (write `none applicable` when nothing fits):

  ```bash
  for f in $(find tasks/vdgg -name lessons.md -exec ls -t {} + 2>/dev/null | head -20); do echo "--- $f ---"; cat "$f"; done
  ```
- Record unknowns explicitly in `tasks/vdgg/{id}/investigation.md`.
- List every related file under `## 1. Related files`, one top-level list item per file with the path first (optionally in backticks; a `:line` suffix is fine). List files that exist now; files the change will create belong in the Step 4 plan.
- Read each listed file during this phase with a Bash reader (`cat`, `sed -n`, `head`, `tail`, `rg`, `grep`, `git show REV:path`, ...). While the phase is `investigating`, the pretool hook records the files those commands name in `.codex/.vdgg-read-{id}` (Codex hands the hook no separate read tool). The Step 3 -> 4 gate refuses when a listed file does not exist or was not read in this phase, or when nothing is listed. `vdgg_check_investigation` prints what is still missing.

Advance:

```bash
# [VibesDeGoGo! Step 3 Start] step=3, phase=investigating, loop=0
VDGG_REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
VDGG_CODEX_SKILL_DIR="${VDGG_CODEX_SKILL_DIR:-$HOME/.agents/skills/vibesdegogo}"
[ -f "$VDGG_CODEX_SKILL_DIR/scripts/vdgg-state.sh" ] || VDGG_CODEX_SKILL_DIR="$VDGG_REPO_ROOT/.agents/skills/vibesdegogo"
source "$VDGG_CODEX_SKILL_DIR/scripts/vdgg-state.sh"
vdgg_state_advance 3 investigating
```

The hook blocks Step 4 until `investigation.md` exists, contains all seven required headings each with a non-empty body, and every file under `## 1. Related files` exists and was read during this phase.

## Step 4: Planning

Create `tasks/vdgg/{id}/todo.md` and `tasks/vdgg/{id}/progress.md`.

`todo.md` carries the plan evidence the Step 4 -> 5 gate checks. Each task is a level-2 heading `## T<n>: <title>` with these level-3 sections:

````markdown
## T1: <title>

### Location
`path/to/file.sh:120` (or the path plus a function name)

### Excerpt
```sh
<the current code at that location, copied verbatim, at least 2 lines>
```

### Intent
<what changes there and why, in prose>
````

- Repeat `### Location` + `### Excerpt` for each place the task touches. For a file the task creates, write `新規` (or `new`) as the Excerpt instead of a code block.
- The gate compares every excerpt with the file line by line, indentation included, so copy it from the file you read in Step 3; code written from memory rarely matches.
- Do not write the new code in the plan: a fenced block anywhere in a task other than the Excerpt is refused. The Intent says what changes; the implementer writes the code in Step 6.
- The gate runs on `vdgg_state_advance 5 task-selected` and on `vdgg_task_begin` issued from planning. `vdgg_check_plan` prints the problems first.

**Optional plan review (seat `4R`).** A Formation may name a second model for the plan, ideally from another vendor than the planner (e.g. `4R: codex high`). The seat is outside the `*` wildcard, so it is active only in Formations that list it. When `vdgg_formation_resolve STEP_4R_AI` returns a non-`inline` AI, output the Delegate line, give it `requirements.md`, `investigation.md` and `todo.md` as the input artifact, and call `vdgg_executor_run STEP_4R_AI <input-file> tasks/vdgg/{id}/plan-review.md`. Ask for missing tasks, wrong locations, tasks too big for one cycle, and intents that do not meet the requirements; revise `todo.md` for the findings you accept. The Step 4 -> 5 hook refuses to leave planning while `plan-review.md` is missing in such a Formation. MAGI is not used here: its default seats are three personas of one model, and its scoring axes are built for subjective artifacts.

Advance:

```bash
# [VibesDeGoGo! Step 4 Start] step=4, phase=planning, loop=0
VDGG_REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
VDGG_CODEX_SKILL_DIR="${VDGG_CODEX_SKILL_DIR:-$HOME/.agents/skills/vibesdegogo}"
[ -f "$VDGG_CODEX_SKILL_DIR/scripts/vdgg-state.sh" ] || VDGG_CODEX_SKILL_DIR="$VDGG_REPO_ROOT/.agents/skills/vibesdegogo"
source "$VDGG_CODEX_SKILL_DIR/scripts/vdgg-state.sh"
vdgg_state_advance 4 planning
```

## Step 5: Select One Task

Choose exactly one task sized for a full implementation cycle — or, during a followup sweep, the next pending `TF` task from the queue in `progress.md`. Start the task title with its id (`T1: ...`, `TF1: ...`); the Step 7 plan reconciliation looks the task up by it. `vdgg_task_begin` is required for every task, `TF` followups included:

- one task must be small enough to complete implementation, tests, build, and real/manual check in one Step 6 to Step 8 loop;
- split separate provider/API/auth/key-storage/UI/persistence/versioning risks into separate tasks;
- do not select umbrella tasks such as `T1-T3` or "all model providers";
- if the selected task cannot be verified with the current acceptance criteria in one Step 7, split it before Step 6.
- declare an allowlist of every implementation/test/documentation file this task is allowed to change; keep it narrow and task-specific.
- if the task changes an interface, enum, type, or signature, include the test file(s) that assert it in the allowlist; Step 6 cannot return to Step 5 to re-arm a wider allowlist.

Choose one task and record it:

```bash
# [VibesDeGoGo! Step 5 Start] step=5, phase=task-selected, loop=0
VDGG_REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
VDGG_CODEX_SKILL_DIR="${VDGG_CODEX_SKILL_DIR:-$HOME/.agents/skills/vibesdegogo}"
[ -f "$VDGG_CODEX_SKILL_DIR/scripts/vdgg-state.sh" ] || VDGG_CODEX_SKILL_DIR="$VDGG_REPO_ROOT/.agents/skills/vibesdegogo"
source "$VDGG_CODEX_SKILL_DIR/scripts/vdgg-state.sh"
vdgg_state_advance 5 task-selected
vdgg_task_begin "T1: title" path/to/file1 path/to/file2
```

The pretool hook blocks implementation edits until `vdgg_task_begin` has created an active allowlist. During Step 6 and Step 7, hook-mediated `apply_patch`, `Edit`, and `Write` edits outside that allowlist are blocked.

## Step 6: Implement

Advance before editing implementation files:

```bash
# [VibesDeGoGo! Step 6 Start] step=6, phase=implementing, loop=0
VDGG_REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
VDGG_CODEX_SKILL_DIR="${VDGG_CODEX_SKILL_DIR:-$HOME/.agents/skills/vibesdegogo}"
[ -f "$VDGG_CODEX_SKILL_DIR/scripts/vdgg-state.sh" ] || VDGG_CODEX_SKILL_DIR="$VDGG_REPO_ROOT/.agents/skills/vibesdegogo"
source "$VDGG_CODEX_SKILL_DIR/scripts/vdgg-state.sh"
vdgg_state_advance 6 implementing
# write the change as a unified diff (paths relative to the repository root):
#   tasks/vdgg/{id}/patch/T1.patch
vdgg_patch_apply tasks/vdgg/{id}/patch/T1.patch
```

Do not run verification commands in this phase. Step 6 is patch first: implementation files change only through a checked patch.

- In `implementing`, `apply_patch`/Edit/Write on implementation files is refused; write the patch file (a task note under `tasks/vdgg/{id}/patch/`) instead. `vdgg_patch_apply` runs `git apply --check` and applies the patch only if it passes. Every file it touches must be on the task allowlist, symlinks, renames and copies are refused, and a patch that touches more than 3 files is refused: that size means the task should have been split. Write a follow-up patch against the new state of the files for the next change in the same task.
- Mechanical bulk edits use a codemod instead: run the dry run first, then `vdgg_codemod_apply <expected-files> <command> [args...]`. The helper refuses when the number of changed allowlisted files differs from the dry run, or when files off the allowlist changed.
- `vdgg_state_advance 7 testing` is refused until at least one patch or codemod has been applied for the task and the allowlisted files still hold exactly what the last one left. `vdgg_task_rollback` restores the baseline and restarts the patch chain.
- When a Formation assigns Step 6 to an external AI, call `vdgg_executor_run STEP_6_AI <input-file> tasks/vdgg/{id}/patch/<task>.patch` so the executor writes the patch, then apply it with `vdgg_patch_apply`.

## Step 7: Verify And Review

State the verification checks you will run, scaled to the change's surface — roughly 1 to 3 for a small, localized change, more when it spans multiple files or touches a contract; do not stop at three if the surface is larger. At least one must be a check that would FAIL if the change were wrong — a boundary, error, or regression case, not only a happy-path confirmation. Then run them through `vdgg_task_gate`. Pass the verification command as separate shell words, for example `vdgg_task_gate npm test`, or use `vdgg_task_gate bash -lc 'set -o pipefail; command with pipes'`. Without `set -o pipefail`, a failing command earlier in the pipe can be masked by a later stage's exit code, and the gate records a false pass. The gate takes a command (a bare `vdgg_task_gate` is refused), runs only in `testing`, and records the command it ran as `command=` in the gate file, so a pass can be checked afterwards; any run first removes this loop's earlier pass, so a later failing check cannot leave an old pass standing.

```bash
# [VibesDeGoGo! Step 7 Start] step=7, phase=testing, loop=0
VDGG_REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
VDGG_CODEX_SKILL_DIR="${VDGG_CODEX_SKILL_DIR:-$HOME/.agents/skills/vibesdegogo}"
[ -f "$VDGG_CODEX_SKILL_DIR/scripts/vdgg-state.sh" ] || VDGG_CODEX_SKILL_DIR="$VDGG_REPO_ROOT/.agents/skills/vibesdegogo"
source "$VDGG_CODEX_SKILL_DIR/scripts/vdgg-state.sh"
vdgg_state_advance 7 testing
vdgg_task_gate <verification-command> [args...]
```

After checks pass, do a focused simplification/review pass:

- remove unnecessary complexity,
- confirm standard-first choices,
- confirm no constraints were violated,
- record the review in `progress.md`.

Then mark the Codex review gate. The gate is recorded by running the review through `vdgg_review_run`, which writes the sentinel only when the review command exits 0. There is no separate marker to call.

```bash
VDGG_REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
VDGG_CODEX_SKILL_DIR="${VDGG_CODEX_SKILL_DIR:-$HOME/.agents/skills/vibesdegogo}"
[ -f "$VDGG_CODEX_SKILL_DIR/scripts/vdgg-state.sh" ] || VDGG_CODEX_SKILL_DIR="$VDGG_REPO_ROOT/.agents/skills/vibesdegogo"
source "$VDGG_CODEX_SKILL_DIR/scripts/vdgg-state.sh"
vdgg_review_run codex exec --sandbox read-only 'review the diff; exit 1 on blocking findings'
```

`vdgg_review_run` runs `REVIEW_COMMAND` from `.vdgg-target` (or an explicit command) and writes the review sentinel only when the command exits 0; a non-zero exit propagates without writing the sentinel. Prefer a different vendor than the implementing model for the reviewer. The reviewer must be read-only: findings only, no edits. For code that ships to other machines or handles user data, the review prompt must include a security perspective (injection, secrets exposure, unsafe file/network/exec operations) — the simplify gate does not cover security.

```bash
# With an explicit command:
vdgg_review_run codex exec --sandbox read-only 'review the diff; exit 1 on blocking findings'

# Using REVIEW_COMMAND from .vdgg-target (no args):
vdgg_review_run
```

For a **subjective artifact** (docs, copy, naming, design — where quality is a judgment, not something a test can decide), this review pass can be the `MAGI` skill (installed as `zmagi`, formerly `magi`) when it is present: run MAGI as the review, write its verdict line to `tasks/vdgg/{id}/magi-verdict.md`, and record the gate with `vdgg_review_run grep -q '^MAGI判定: 可決' tasks/vdgg/{id}/magi-verdict.md`. If MAGI is not installed, do the focused review yourself as above. MAGI judges desirability, not code correctness — correctness still rides on tests and your review.

Relevant `.vdgg-target` key for Step 7:

```bash
# External review command. Must exit 0 to pass. Use a different vendor.
REVIEW_COMMAND="claude -p 'review the working tree diff for correctness and security (injection, secrets exposure, unsafe file/network/exec operations, data loss); exit non-zero on blocking findings'"
```

### Plan reconciliation

Before the review, compare the task's plan with what was actually changed:

```bash
vdgg_plan_diff            # writes tasks/vdgg/{id}/review/<task>-plan-vs-diff.md and prints its path
```

The report places the task's plan (Locations, Excerpts, Intent) next to the diff since `vdgg_task_begin`, and lists planned files that changed, planned files that did not, and changed files the plan does not mention. Give it to the reviewer with the diff and ask for (1) changes the plan does not mention and (2) planned changes that were not made. Then record the outcome in `progress.md`:

```markdown
### Plan reconciliation: T1
- path/a.sh: as planned
- path/b.sh: not planned; needed because ...
```

Discrepancies do not block: forcing the diff to match the plan would push a wrong plan into the code. An unrecorded comparison does block. For a task from `todo.md`, `vdgg_state_advance 7 verified` is refused until that heading exists with a non-empty body. Followup `TF` tasks that are not in `todo.md` need no record. Any other task must be one of `todo.md`'s tasks, and its title starts with its id (`T1: ...`).

### Multi-perspective review is mandatory (Layer 2)

Single-pass Step 7 review is prohibited. The reviewer must inspect the diff through **N ≥ 3 independent perspectives** ("lenses"), and the merged review output must carry `lens_count` at the top level so `vdgg_review_run` can verify the requirement was met (a lens_count below 3 is rejected by the Layer 2 validator that `vdgg_review_run` invokes after Layer 1). This is the default; there is no per-task opt-in.

- Default lens set is `correctness`, `security`, `contract`, `simplification`, `altitude`. Small diffs (< 200 LOC, 1–2 files) may drop to any 3 of those. Large or contract-touching diffs (> 500 LOC, or auth/persistence/concurrency) must use 5.
- For Formation Step 7 executor delegation, the HQ is responsible for invoking the executor `N` times with per-lens prompts and merging the results into one schema-conformant JSON. Set the merged output's top-level `lens_count` to `N`. A single 1-shot call to an external reviewer is NOT enough.
- When merging N single-lens outputs, dedup findings by `(file, line, summary)` if the same defect surfaces across lenses; keep the highest severity when they disagree.

### Adversarial countersign for clean reviews (Layer 3)

Multi-perspective review (Layer 2) protects against a single reviewer taking a shortcut, but N lenses of *the same reviewer* still share a blind spot: the reviewer's model, its training cutoff, its habit of trusting patterns it has seen before. When the primary review comes back with no `high` or `medium` finding, that "clean" verdict is the moment to worry — real problems can survive same-reviewer redundancy and only surface under a genuinely different eye.

Layer 3 runs an **adversarial countersign** on any clean primary review: a second reviewer, ideally from a different vendor or model family, re-reviews the same diff with the mandate "find what the primary missed." Only when the countersign also comes back clean is the sentinel flipped from `countersign=none` to `countersign=clean`. If the countersign surfaces any `high` or `medium` finding the primary missed, `vdgg_review_countersign` returns a failure that the caller must treat as a failed review — go to reflection (Step 6-R) rather than advancing.

Pipeline enforcement — `vdgg_review_run` marks the sentinel with `countersign_required=1` whenever the primary review returns no `high`/`medium` finding, AND when `--review-output` is omitted (legacy backward-compat path). The PreToolUse hook calls `_vdgg_review_gate_ready` before opening verified and refuses to advance while `countersign_required=1 && countersign != clean`. Skipping `vdgg_review_countersign` on a clean primary — or trying to open the gate via legacy `vdgg_review_run true` — is a hard block. `_vdgg_write_review_sentinel` also refuses direct calls that lack the one-shot `_VDGG_WRITE_REVIEW_SENTINEL_AUTHORIZED=1` breadcrumb.

- Trigger condition: primary findings empty OR all `low`. A primary with any `high`/`medium` already flagged problems; the helper no-ops there and the sentinel records `countersign_required=0`. (Codex edition intentionally omits the CC-only simplify path exemption — no simplify skill in this runtime.)
- Reviewer selection: the countersign should come from a different vendor or model family than the primary whenever the Formation makes that possible. A same-family countersign satisfies the mechanism but weakens the guarantee — record when this happens in `progress.md` so future rounds know to escalate.
- The countersign output must satisfy Layer 1 (schema) and Layer 2 (`lens_count ≥ 3`) on its own — a countersign that returns prose or a single-lens JSON is a failed countersign, not a passed one.

### Review prompts must request concrete fixes, not only findings

Every Step 7 review prompt — self-review, Formation Step 7 executor calls, external `vdgg_review_run` reviewers, and MAGI verdicts on subjective artifacts — MUST require the reviewer to include the concrete fix for each finding alongside the problem statement. Findings without a proposed fix push the implementer back into guessing what the reviewer meant, which is the shape past regressions have taken. This is the default; there is no per-task opt-in.

When writing the prompt, require each finding to carry:

- `file`, `line` — where the problem is.
- `severity` — `high` / `medium` / `low` (mandatory; see the severity-based response section below).
- `summary` — one sentence stating the problem.
- `fix` — a concrete code snippet, unified diff, or step-by-step instruction that resolves it. "Consider X" / "may want to Y" is not acceptable — the reviewer must commit to a specific change. If the reviewer genuinely cannot propose a fix, write `fix: unknown, needs investigation` so the implementer treats it as a research task instead of a guess.
- `cost` — reviewer's estimate of implementation effort (low / medium / high), used by the implementer to plan the fix batch.

The implementer still owns the final decision (accept, skip, or defer to `followup.md`); the reviewer's job is to make that decision cheap by handing over a fix the implementer can adopt, adapt, or reject on concrete grounds.

### Review findings: severity-based response

After the Step 7 review — self-review, `vdgg_review_run`, or MAGI — surfaces findings, classify each one and decide before editing:

- **high**: correctness bug, data loss, race condition, security, contract regression.
- **medium**: real bug with a narrow trigger, or a design that will break under reasonable use.
- **low**: cosmetic, stale doc, log message wording, naming, dead branch, style.

Response:

- Any **high or medium** finding → go to reflection (`vdgg_state_advance 6 reflection`) and make the fix in the next loop as a patch (`vdgg_patch_apply`). `apply_patch`/Edit/Write on implementation files are refused in `testing` as in `implementing`; an edit that gets through anyway flips the review sentinel (`.codex/.vdgg-review-sentinel-{id}-{loop}`) to `modified=1`, and the patch chain reports it.
- **All findings are low (or `[]`)** → DO NOT edit implementation files. Append the findings to `tasks/vdgg/{id}/followup.md` — or, inside a `TF` followup task, to `followup-final.md` — and advance directly to `verified`. Low items are collected by the Step 8 followup sweep.

This stops convergence-loops on cosmetic findings while keeping the hook discipline intact: a high/medium fix always costs a reflection and a patch, so there is no escape hatch for it.

When listing findings, always assign an explicit `severity` field per finding so the classification is auditable. If the review output omits severity, classify each finding yourself before deciding the response.

Finally advance:

```bash
# [VibesDeGoGo! Step 7 Start] step=7, phase=verified, loop=0
VDGG_REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
VDGG_CODEX_SKILL_DIR="${VDGG_CODEX_SKILL_DIR:-$HOME/.agents/skills/vibesdegogo}"
[ -f "$VDGG_CODEX_SKILL_DIR/scripts/vdgg-state.sh" ] || VDGG_CODEX_SKILL_DIR="$VDGG_REPO_ROOT/.agents/skills/vibesdegogo"
source "$VDGG_CODEX_SKILL_DIR/scripts/vdgg-state.sh"
vdgg_state_advance 7 verified
```

The pretool hook blocks `verified` until both `vdgg_task_gate` and `vdgg_review_run` have succeeded.

If verification fails, run `vdgg_task_rollback`, go to reflection, select exactly one revised hypothesis, and retry. If review changes implementation files, go to reflection and retest. If `vdgg_task_rollback` refuses because files outside the allowlist changed, resolve those manually (`git status` + `git checkout -- <file>`) and rerun it.

## Step 6-R: Reflection

Advance:

```bash
# [VibesDeGoGo! Step 6 Start] step=6, phase=reflection, loop=<same loop>
VDGG_REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
VDGG_CODEX_SKILL_DIR="${VDGG_CODEX_SKILL_DIR:-$HOME/.agents/skills/vibesdegogo}"
[ -f "$VDGG_CODEX_SKILL_DIR/scripts/vdgg-state.sh" ] || VDGG_CODEX_SKILL_DIR="$VDGG_REPO_ROOT/.agents/skills/vibesdegogo"
source "$VDGG_CODEX_SKILL_DIR/scripts/vdgg-state.sh"
vdgg_state_advance 6 reflection
```

Write `tasks/vdgg/{id}/investigation-r{loop}.md` and update `progress.md` with:

1. Root Cause Investigation.
2. Pattern Analysis.
3. Hypothesis: exactly one hypothesis.
4. Implementation plan: exactly one fix.

When the loop was triggered by review or simplify findings rather than a test failure, this can be lightweight: write `investigation-r{loop}.md` directly from the review findings (classification plus the one fix) instead of opening a new deep root-cause investigation.

Return to implementation:

```bash
# [VibesDeGoGo! Step 6 Start] step=6, phase=implementing, loop=<next loop>
VDGG_REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
VDGG_CODEX_SKILL_DIR="${VDGG_CODEX_SKILL_DIR:-$HOME/.agents/skills/vibesdegogo}"
[ -f "$VDGG_CODEX_SKILL_DIR/scripts/vdgg-state.sh" ] || VDGG_CODEX_SKILL_DIR="$VDGG_REPO_ROOT/.agents/skills/vibesdegogo"
source "$VDGG_CODEX_SKILL_DIR/scripts/vdgg-state.sh"
vdgg_state_loop 6 implementing
```

Right after returning to `implementing`, distill any reusable lesson from this reflection into `tasks/vdgg/{id}/lessons.md` — one entry per lesson: symptom → wrong assumption → correct move. Before writing, re-run the Step 3 lessons command and skip duplicates; write nothing when the failure was one-off (lessons are deliberately failure-derived — clean-pass insights are out of scope). After writing an entry, output one line in the user-facing text so the user can veto it on the spot, while the phase still allows deleting the entry:

```text
[VibesDeGoGo! Lesson] <one-line summary>
```

(The reflection phase itself cannot write this file: the pretool hook allows only `progress.md` and `investigation-r*.md` there.)

If the revised hypothesis needs files outside the current allowlist, do not try to widen the allowlist in place — `vdgg_task_begin` cannot re-arm outside Step 5 (6 -> 5 is not a legal transition) and will fail loudly. Adapt the fix to the current allowlist (e.g. downgrade an optional cleanup to a followup note), or complete/close this task and take the wider scope as a new task via Step 8 -> Step 5.

## Step 8: Progress And Validation Request

Advance:

```bash
# [VibesDeGoGo! Step 8 Start] step=8, phase=progress, loop=0
VDGG_REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
VDGG_CODEX_SKILL_DIR="${VDGG_CODEX_SKILL_DIR:-$HOME/.agents/skills/vibesdegogo}"
[ -f "$VDGG_CODEX_SKILL_DIR/scripts/vdgg-state.sh" ] || VDGG_CODEX_SKILL_DIR="$VDGG_REPO_ROOT/.agents/skills/vibesdegogo"
source "$VDGG_CODEX_SKILL_DIR/scripts/vdgg-state.sh"
vdgg_state_advance 8 progress
```

Update `progress.md`, update configured version files if `.vdgg-target` requires it, and ask the user for validation when needed.

Check whether all tasks are complete:

- unfinished tasks: go back to Step 5,
- all planned tasks complete: run the followup sweep below, then continue to Step 9.

### Followup sweep (low findings)

On the FIRST Step 8 entry after all planned tasks are complete, build the sweep queue exactly once: read `tasks/vdgg/{id}/followup.md`; if it is empty or absent, continue to Step 9. Otherwise group its items into followup tasks using the task-sizing rules in Step 5, name them with a `TF` prefix (`TF1: ...`, `TF2: ...`), and record the queue in `progress.md` with a status per task (pending / fixed / residue).

Then return to Step 5 (8 -> 5) for the next pending `TF` task, so every fix runs through the normal allowlist, task gate, and review gate, and lands in the same branch and PR as the planned work. Later Step 8 entries during the sweep do NOT re-read `followup.md`; they update the queue statuses in `progress.md` and pick 8 -> 5 while pending `TF` tasks remain, Step 9 when none do. During the sweep, skip the per-task validation ask above — request validation once, before Step 9.

Sweep rules:

- A `TF` task's re-review may be a single lightweight review pass: its scope was already screened and classified by a planned task's review.
- New low findings discovered inside a `TF` task go to `followup-final.md` (append, never overwrite) and are NOT queued — list them as residue in the Step 9 report.
- An item judged unsafe or out of scope to fix is marked `residue` in the queue with the reason and listed in the Step 9 report.

## Step 9: Commit

Advance:

```bash
# [VibesDeGoGo! Step 9 Start] step=9, phase=commit, loop=0
VDGG_REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
VDGG_CODEX_SKILL_DIR="${VDGG_CODEX_SKILL_DIR:-$HOME/.agents/skills/vibesdegogo}"
[ -f "$VDGG_CODEX_SKILL_DIR/scripts/vdgg-state.sh" ] || VDGG_CODEX_SKILL_DIR="$VDGG_REPO_ROOT/.agents/skills/vibesdegogo"
source "$VDGG_CODEX_SKILL_DIR/scripts/vdgg-state.sh"
vdgg_state_advance 9 commit
```

Commit format:

```text
{type}: {summary}
```

Default `branch-pr` behavior:

1. commit on the feature branch,
2. push the feature branch,
3. create a PR,
4. report the PR URL,
5. stop for human merge approval.

`VDGG_AUTO_MERGE=on` (environment variable; only the literal value `on`) removes
step 4: after the PR is created, wait for its checks and merge it. Set it in the
shell profile to make every repository behave this way.

```bash
if [ "${VDGG_AUTO_MERGE:-}" = "on" ]; then
    # "no checks configured" and "checks failed" are both exit 1 from
    # `gh pr checks`, so count them first instead of ignoring the status.
    if [ "$(gh pr view --json statusCheckRollup -q '.statusCheckRollup | length')" -gt 0 ]; then
        gh pr checks --watch --interval 15 || {
            echo "vdgg: PR checks failed; not merging." >&2
            exit 1
        }
    fi
    gh pr merge --squash
fi
```

`trunk` workflow is allowed only when `.vdgg-target` explicitly sets `WORKFLOW=trunk`.

## Clear State And Finish

After PR creation or trunk commit/push decision:

```bash
VDGG_REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
VDGG_CODEX_SKILL_DIR="${VDGG_CODEX_SKILL_DIR:-$HOME/.agents/skills/vibesdegogo}"
[ -f "$VDGG_CODEX_SKILL_DIR/scripts/vdgg-state.sh" ] || VDGG_CODEX_SKILL_DIR="$VDGG_REPO_ROOT/.agents/skills/vibesdegogo"
source "$VDGG_CODEX_SKILL_DIR/scripts/vdgg-state.sh"
vdgg_state_clear
```

Regardless of workflow, before reporting completion: report any residue from the followup sweep — each unfixed low finding with the reason it was left — and report a lessons line (`lessons applied: N / new: M`).

## Stop Conditions

Do not stop for progress confirmation. Stop intentionally with `[Intentional Stop]` before:

- violating Step 0 constraints,
- adding or changing dependencies,
- changing API, persistence, auth, permissions, security, billing, analytics, or user-data contracts,
- destructive operations,
- broad renames,
- inability to satisfy or verify acceptance criteria.
- inability to rollback a failed task gate cleanly.
