**English** | [日本語](CONTRIBUTING.ja.md)

# Contributing

Thanks for improving VibesDeGoGo!. This project is intentionally small: shell
scripts, Markdown docs, and no test framework dependency.

## Requirements

- `bash`
- `zsh` (the test suite runs every test under both shells)
- `jq`
- standard Unix tools: `date`, `tr`, `grep`, `sed`, `find`, `awk`

On macOS, install `jq` with:

```bash
brew install jq
```

## Repository Layout

- `skills/vibesdegogo/`: Claude Code skill.
- `skills/vibesdegogo/scripts/`: Claude Code hook and state helpers.
- `skills/vibesdegogo/references/`: workflow references.
- `hooks/hooks.json`, `.claude-plugin/`: Claude Code plugin packaging.
- `.agents/skills/vibesdegogo/`: Codex skill, with its own scripts and references.
  Most of the tree is edition-specific, but six files are shared verbatim — see
  "Files Shared Between Editions" below.
- `.codex/hooks.json`: Codex project-local hook registration.
- `tests/`: zero-dependency smoke tests for both editions.

## Running Tests

Run the full smoke suite:

```bash
bash tests/run-all.sh
```

Run one file:

```bash
bash tests/test-state.sh
bash tests/test-hook-pretool.sh
bash tests/test-hook-posttool.sh
bash tests/test-hook-stop.sh
bash tests/test-codex-state.sh
bash tests/test-codex-hook-pretool.sh
```

Run syntax checks when editing scripts:

```bash
bash -n skills/vibesdegogo/scripts/*.sh
bash -n .agents/skills/vibesdegogo/scripts/*.sh
```

## Editing Hook Scripts

Do not use broad `sed -i` rewrites for hook or state script comments. A previous
rename damaged meaningful comments by replacing them with a generic placeholder.
When changing names or comments:

- inspect the diff by file;
- keep behavior changes separate from comment-only changes;
- keep each edition's hook JSON contract aligned with its setup docs:
  `skills/vibesdegogo/references/setup.md` for Claude Code and
  `.agents/skills/vibesdegogo/references/codex-setup.md` for Codex.

## Files Shared Between Editions

Eight files exist under both `skills/vibesdegogo/` and
`.agents/skills/vibesdegogo/` and must stay byte-identical:

- `scripts/vdgg-llm-start.sh`
- `scripts/vdgg-exec-claude.sh`
- `scripts/vdgg-exec-codex.sh`
- `scripts/vdgg-exec-agy.sh`
- `scripts/vdgg-evidence.sh`
- `references/servers-conf.md`
- `references/servers.conf.example`
- `references/local-inference-setup.md`

If you change one copy, make the other copy identical in the same commit. This
applies to every change, including documentation and comment-only edits — it is
not limited to hook or state scripts.

`tests/test-edition-sync.sh` checks this for every file above except
`references/local-inference-setup.md`, whose install paths differ between the
editions on purpose. To check them all by hand:

```bash
for f in scripts/vdgg-llm-start.sh scripts/vdgg-exec-claude.sh \
         scripts/vdgg-exec-codex.sh scripts/vdgg-exec-agy.sh scripts/vdgg-evidence.sh references/servers-conf.md \
         references/servers.conf.example references/local-inference-setup.md; do
  cmp "skills/vibesdegogo/$f" ".agents/skills/vibesdegogo/$f" || echo "OUT OF SYNC: $f"
done
```

Every other file in the two trees is edition-specific and is expected to differ.

## Commit Style

Use:

```text
{type}: {summary}
```

Common types: `feat`, `fix`, `refactor`, `docs`, `test`, `chore`.

## Pull Requests

Before opening a PR:

- run `bash tests/run-all.sh`;
- run syntax checks for changed script sets;
- note whether the change affects hooks, state helpers, or workflow docs, and
  whether it applies to the Claude Code edition, the Codex edition, or both.

## Versioning

The `version` field inside a skill file tracks the workflow specification for
that edition. Repository releases use separate SemVer tags, starting at `0.1.0`
for the first public OSS release.
