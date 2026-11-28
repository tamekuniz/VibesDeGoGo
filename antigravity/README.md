# VibesDeGoGo! for Antigravity

Antigravity（App 2.0 / IDE / CLI）のネイティブプラグイン（`plugin.json` + `hooks.json`）として動作し、Codex 版の state / evidence / hooks（`.agents/skills/vibesdegogo/`）を再利用する第 4 エディションです。

## 特徴

- **フックで強制**：Antigravity の `PreToolUse` / `PostToolUse` / `PreInvocation` / `Stop` フックを Codex 版のゲート群へ接続し、読み込み証拠・計画抜粋一致・パッチファースト・テストゲート・無言停止防止をそのまま有効化します。
- **ゼロ依存（追加パッケージなし）**：`bash`、`git`、`jq` のみで動作します。
- **マルチAI編成（Formations）**：司令塔を Antigravity（Gemini）にしつつ、レビューや実装に `claude` / `codex` / ローカルLLM を割り当てられます。

## 必要環境

- `bash`、`git`、`jq`（macOS: `brew install jq`）
- VibesDeGoGo リポジトリ一式（`.agents/skills/vibesdegogo/` を参照するため、リポジトリ全体を手元に保持してください）

## インストール（推奨：シンボリックリンク）

グローバルプラグインディレクトリ（`~/.gemini/config/plugins/`）へ `antigravity/` をリンクすると、すべてのプロジェクトで有効になります。

```bash
mkdir -p "$HOME/.gemini/config/plugins"
ln -s /path/to/VibesDeGoGo/antigravity "$HOME/.gemini/config/plugins/vibesdegogo"
```

プロジェクト単位で有効にしたい場合は、対象リポジトリの `.agents/plugins/vibesdegogo` にリンクします。

```bash
mkdir -p .agents/plugins
ln -s /path/to/VibesDeGoGo/antigravity .agents/plugins/vibesdegogo
```

※リンクではなくコピーして配置する場合は、`VDGG_CODEX_SKILL_DIR` に `.agents/skills/vibesdegogo` の絶対パスを指定するか、`$HOME/.agents/skills/vibesdegogo` に Codex 版スキルを配置してください。

## 使い方

Antigravity のチャットで **`vibesdegogo-agy` スキルを使って実装して**（または「VibesDeGoGo で進めて」）と依頼します。

- セッション開始（`vdgg_state_init`）までは通常のチャットと変わらず邪魔をしません（`.vdgg-target` に `VDGG_REQUIRED=on` を書いたリポジトリでは開始前の編集もブロックします）。
- 状態ファイルは Codex / pi 版と同じ `.codex/.vdgg-*` と `tasks/vdgg/{id}/` を使います。
- **同一リポジトリルートで Codex / pi / Antigravity の VDGG を並行実行しないでください**（並行時は別 worktree を使用）。

## アンインストール

```bash
rm "$HOME/.gemini/config/plugins/vibesdegogo"
```

## テスト

```bash
bash tests/test-antigravity-adapter.sh
bash tests/run-all.sh
```
