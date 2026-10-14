**English** | [日本語](README.ja.md)

# VibesDeGoGo!

A state-and-hook workflow for AI coding agents. It keeps the agent moving through requirements, investigation, implementation, verification, and commit, but stops it before unchecked assumptions, skipped verification, or scope drift.

One asymmetry runs the whole thing:

- Don't stop to ask permission — no "can I continue?", it keeps moving.
- Do stop before a constraint violation — a new dependency, touching auth / persistence / billing / security, a destructive op, or drifting out of the agreed scope: it halts and asks first.

The rules are enforced by hooks (`PreToolUse` / `PostToolUse` / `Stop`) plus a state file, not by prompt text, and a task gate cross-checks the actual file changes against the allowlist you declared. The hooks are a guardrail, not a sandbox — strong rails plus an audit trail, not proof of correctness.

bash + jq. No account, keys, or telemetry. MIT.

## Editions

This repository holds three editions that share the workflow but target different agents:

- **for Claude Code** — `skills/vibesdegogo/`, `hooks/hooks.json`, `.claude-plugin/`
- **for Codex** — `.agents/skills/vibesdegogo/`, `.codex/hooks.json`
- **for pi / Qwen** — `pi/`. See the [pi edition setup](pi/README.md) for launcher and requirements.
- **vdgg-watch** — `skills/vdgg-watch/`. A sister skill, not an edition: it watches one goal while you sleep and speaks up only when a premise breaks, with evidence and a proposed fix.

They are installed independently. Install only the edition you use, or both.

## Core Flow

1. Agree on Goal / Constraints / Acceptance criteria.
2. Write `tasks/vdgg/{id}/requirements.md`.
3. Investigate the codebase and write `investigation.md`.
4. Create `todo.md` and `progress.md`.
5. Implement one bounded task at a time.
6. Verify with concrete checks.
7. Pass the review gate (simplify or an external review).
8. Update progress and ask for validation when needed.
9. Commit, and for the default `branch-pr` workflow, create a PR and stop.
   (A PR — pull request — is GitHub's "review this change" page. Nothing
   reaches the main code until you approve the merge.)

## Per-Step AI Formations

A named Formation can assign any AI to each Step. Trusted configuration lives outside the repository under `~/.config/vdgg`:

```text
~/.config/vdgg/
  formations/local-balanced.conf
  executors/qwen.conf
  executors/gemma.conf
```

One line per delegated seat; unlisted seats stay inline (the current agent). `*` assigns the non-interactive seats (3, 4, 6, 6R, 7) at once, and the builtins `claude` / `codex` take optional model and effort tokens:

```text
# formations/local-balanced.conf
6: qwen
7: gemma
grill: qwen
```

Delegating every delegable seat to Codex is one line:

```text
*: codex
```

Builtins with model/effort:

```text
6: claude sonnet low
7: codex high
```

Each executor file contains only an absolute path to a no-argument wrapper. VDGG executes that file directly rather than evaluating a shell command string.

```ini
# ~/.config/vdgg/executors/qwen.conf
COMMAND=/Users/you/.local/bin/vdgg-qwen
```

When you select a Formation, Step 1 pins it in state:

```bash
vdgg_state_init --formation local-balanced
```

The wrapper receives `VDGG_EXECUTOR_FORMATION`, `VDGG_EXECUTOR_AI`, `VDGG_EXECUTOR_STEP`, `VDGG_EXECUTOR_INPUT`, and `VDGG_EXECUTOR_OUTPUT`. Executor failure preserves state and stops; it never silently falls back to `inline`. With no Formation, the historical inline behavior and `.vdgg-target` executor settings remain unchanged.

## Layout

```text
.claude-plugin/
  plugin.json
  marketplace.json
hooks/
  hooks.json
skills/vibesdegogo/
  SKILL.md
  scripts/
    vdgg-state.sh
    vdgg-hook-pretool.sh
    vdgg-hook-posttool.sh
    vdgg-hook-stop.sh
  references/
    setup.md
    output_formats.md
    target_schema.md
    hook_rules.md
    state_helpers.md
    subagent_prompts.md

.agents/skills/vibesdegogo/
  SKILL.md
  scripts/
    vdgg-state.sh
    vdgg-hook-pretool.sh
    vdgg-hook-posttool.sh
    vdgg-hook-stop.sh
    vdgg-hook-userprompt.sh
  references/
    codex-setup.md
.codex/hooks.json

tests/
```

Seven files are duplicated between the two trees on purpose and must stay byte-identical: the three executor wrappers (`vdgg-llm-start.sh`, `vdgg-exec-claude.sh`, `vdgg-exec-codex.sh`), the evidence-gate library (`vdgg-evidence.sh`) and the three shared references (`servers-conf.md`, `servers.conf.example`, `local-inference-setup.md`). See [CONTRIBUTING.md](CONTRIBUTING.md).

## Install: Claude Code edition

### As a plugin (recommended)

Inside Claude Code, run:

```text
/plugin marketplace add tmknzz/VibesDeGoGo
/plugin install vibesdegogo@vibesdegogo
```

This registers the skill and activates the hooks automatically.

**Migrating from `tmknzz/VibesDeGoGo-for-Claude-Code`:** that marketplace and this one both publish under the name `vibesdegogo`. Remove the old one before adding this one, so the two never coexist:

```text
/plugin uninstall vibesdegogo@vibesdegogo
/plugin marketplace remove vibesdegogo
/plugin marketplace add tmknzz/VibesDeGoGo
/plugin install vibesdegogo@vibesdegogo
```

### Manual install

Copy the skill folder into Claude Code's skills directory:

```bash
mkdir -p "$HOME/.claude/skills"
cp -R skills/vibesdegogo "$HOME/.claude/skills/vibesdegogo"
```

Then register the hooks shown in:

```text
skills/vibesdegogo/references/setup.md
```

## Install: Codex edition

For local authoring, Codex reads repo skills from `.agents/skills` in this repository.

For cross-repository use, install the skill in a user-level skill directory:

```bash
mkdir -p "$HOME/.agents/skills"
cp -R .agents/skills/vibesdegogo "$HOME/.agents/skills/vibesdegogo"
```

Then register global hooks in `~/.codex/hooks.json` or `~/.codex/config.toml`. The global `UserPromptSubmit` hook makes VDGG the default for coding work in any git repository. The tool hooks enforce the workflow after VDGG state is initialized in that repository root. See:

```text
.agents/skills/vibesdegogo/references/codex-setup.md
```

Project-local hooks are included in `.codex/hooks.json`. In Codex, use `/hooks` to review and trust them.

## Requirements

`jq` is required because the hook scripts parse hook JSON:

```bash
brew install jq               # macOS
sudo apt-get install jq       # Debian / Ubuntu / WSL
apk add jq                    # Alpine
sudo dnf install jq           # Fedora / RHEL
```

Without `jq`, the hooks do nothing and stay out of the way in repositories where no VibesDeGoGo! session is running.

## Project Configuration

For each project, optionally create `.vdgg-target` in the project root. See:

```text
skills/vibesdegogo/references/target_schema.md
```

The most important optional workflow fields are:

```bash
WORKFLOW=branch-pr
AUTO_PUSH=false
```

With the default `WORKFLOW=branch-pr`, Step 9 pushes the feature branch so it can open a PR. `AUTO_PUSH=true` only affects `WORKFLOW=trunk`.

## Uninstall

The complete footprint, so you (or your agent) can remove everything.

**Claude Code edition:**

- Plugin install: run `/plugin uninstall vibesdegogo@vibesdegogo` inside Claude Code (or `claude plugin uninstall vibesdegogo@vibesdegogo` from a terminal).
- Manual install: delete `~/.claude/skills/vibesdegogo/` and remove the four hook entries (`PreToolUse`, `PostToolUse`, `PostToolUseFailure`, `Stop`) that reference `vdgg-hook-*.sh` from `~/.claude/settings.json`.
- Per-repository session artifacts: `.claude/.vdgg-*` and `tasks/vdgg/` are safe to delete. `.gitignore` gains an auto-appended block for `.claude/.vdgg-*`; drop it if you like.

**Codex edition:**

- Delete `~/.agents/skills/vibesdegogo/`.
- Remove the four hook entries (`PreToolUse`, `PostToolUse`, `Stop`, `UserPromptSubmit`) that reference `vdgg-hook-*.sh` from `~/.codex/hooks.json`.
- Per-repository session artifacts: `.codex/.vdgg-*` and `tasks/vdgg/` are safe to delete. `.gitignore` gains an auto-appended block for `.codex/.vdgg-*`; drop it if you like.

Both editions: keep `.vdgg-target` — it is your configuration file, not something VDGG installed.

## Test

```bash
bash tests/run-all.sh
```

Both editions' suites run from this one directory.

## Optional: MAGI

If you also install **MAGI** (a small open-source 3-persona deliberation skill), VibesDeGoGo! uses it at two points — and silently skips it if you don't: **Step 0** to deliberate a genuinely split, high-stakes decision (it hands back material; you still decide), and **Step 7** as the review gate for subjective artifacts (docs, copy, design). MAGI judges desirability, not code correctness. → https://github.com/tmknzz/MAGI

## Status

This repository holds both editions. They were previously maintained in separate repositories (`VibesDeGoGo-for-Claude-Code` and `VibesDeGoGo-for-Codex`), whose histories are merged into this one.
