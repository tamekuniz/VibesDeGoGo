[English](README.md) | **日本語**

# VibesDeGoGo!

AI コーディングエージェント向けの state ＋ hook ワークフロー。要件定義・調査・実装・検証・コミットを通してエージェントを走らせ続けつつ、前提の未確認・検証の省略・スコープ逸脱の手前で止めます。

すべてを貫くのは1つの非対称：

- 進捗確認では止まらない ──「続けていいですか？」を言わず走り続ける。
- 制約違反の手前では止まる ── 依存の追加、auth / 永続化 / 課金 / セキュリティに触る、破壊的操作、合意したスコープからの逸脱 ── これらの直前で止まって尋ねる。

ルールはプロンプト本文ではなく、hook（`PreToolUse` / `PostToolUse` / `Stop`）＋ state file で強制し、タスクゲートが実際のファイル変更を宣言済み許可リストと突き合わせます。hook はサンドボックスではなくガードレールです ── 「強固なレール＋監査記録」であって、正しさの証明ではありません。

bash と jq のみ。アカウント・鍵・テレメトリなし。MIT。

## エディション

このリポジトリには、ワークフローを共有しつつ対象エージェントが異なる3つのエディションが入っています。

- **for Claude Code** ── `skills/vibesdegogo/`、`hooks/hooks.json`、`.claude-plugin/`
- **for Codex** ── `.agents/skills/vibesdegogo/`、`.codex/hooks.json`
- **for pi / Qwen** ── `pi/`。起動と必要条件は [pi版README](pi/README.md) を参照。
- **vdgg-watch** ── `skills/vdgg-watch/`。エディションではなく姉妹スキル。寝ている間も1つの目標を見張り、前提が崩れたときだけ根拠つきの修正案を出す。

導入は独立しています。使う方だけ入れても、両方入れてもかまいません。

## 基本の流れ

1. ゴール / 制約 / 受け入れ基準に合意する。
2. `tasks/vdgg/{id}/requirements.md` を書く。
3. コードベースを調査して `investigation.md` を書く。
4. `todo.md` と `progress.md` を作る。
5. 区切りのよいタスクを1つずつ実装する。
6. 具体的なチェックで検証する。
7. レビューゲート（simplify または外部レビュー）を通す。
8. 進捗を更新し、必要なら動作確認を依頼する。
9. コミットし、既定の `branch-pr` ワークフローでは PR を作って止まる。
   （PR＝プルリクエストは GitHub の「変更確認ページ」です。あなたが merge を
   承認するまで、本体のコードには何も反映されません。）

## StepごとのAI指定（Formation）

名前付きFormationで、各Stepの担当AIを自由に割り当てられます。設定はリポジトリではなく、信頼済みのユーザー設定 `~/.config/vdgg` に置きます。

```text
~/.config/vdgg/
  formations/local-balanced.conf
  executors/qwen.conf
  executors/gemma.conf
```

委譲する席だけを1行ずつ書きます。書かなかった席は inline（現在のエージェント）のまま。`*` は非対話席（3, 4, 6, 6R, 7）への一括指定で、組み込みの `claude` / `codex` には model と effort を任意で付けられます。

```text
# formations/local-balanced.conf
6: qwen
7: gemma
grill: qwen
```

「委譲できる席は全部 Codex」は1行で書けます。

```text
*: codex
```

組み込み語 + model/effort の例:

```text
6: claude sonnet low
7: codex high
```

各executor設定には、引数なしで起動できる絶対パスのwrapperだけを書きます。shell文字列として評価しません。

```ini
# ~/.config/vdgg/executors/qwen.conf
COMMAND=/Users/you/.local/bin/vdgg-qwen
```

Formation名を指定すると、Step 1で次の形で固定されます。

```bash
vdgg_state_init --formation local-balanced
```

wrapperは`VDGG_EXECUTOR_FORMATION`、`VDGG_EXECUTOR_AI`、`VDGG_EXECUTOR_STEP`、`VDGG_EXECUTOR_INPUT`、`VDGG_EXECUTOR_OUTPUT`を受け取ります。外部AIが失敗した場合はstateを保持して停止し、`inline`へ黙って切り替えません。Formationを指定しなければ、従来の実行と`.vdgg-target` executor設定がそのまま動きます。

## 構成

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

2つのツリー間で意図的に重複していて、byte 一致を保つ必要があるファイルが7本あります。executor wrapper 3本（`vdgg-llm-start.sh`、`vdgg-exec-claude.sh`、`vdgg-exec-codex.sh`）、証拠ゲートのライブラリ（`vdgg-evidence.sh`）、共有 reference 3本（`servers-conf.md`、`servers.conf.example`、`local-inference-setup.md`）です。[CONTRIBUTING.ja.md](CONTRIBUTING.ja.md) を参照してください。

## インストール：Claude Code 版

### プラグインとして（推奨）

Claude Code の中で次を実行します:

```text
/plugin marketplace add tmknzz/VibesDeGoGo
/plugin install vibesdegogo@vibesdegogo
```

スキルの登録とフックの有効化が自動で行われます。JSONの手編集は不要です。

**`tmknzz/VibesDeGoGo-for-Claude-Code` から移行する場合:** 旧マーケットプレイスとこのマーケットプレイスは、どちらも `vibesdegogo` という同じ名前で公開しています。共存させないよう、旧を削除してから追加してください:

```text
/plugin uninstall vibesdegogo@vibesdegogo
/plugin marketplace remove vibesdegogo
/plugin marketplace add tmknzz/VibesDeGoGo
/plugin install vibesdegogo@vibesdegogo
```

### 手動インストール

スキルフォルダを Claude Code のスキルディレクトリにコピーします:

```bash
mkdir -p "$HOME/.claude/skills"
cp -R skills/vibesdegogo "$HOME/.claude/skills/vibesdegogo"
```

その後、次のファイルに記載されたフックを登録してください:

```text
skills/vibesdegogo/references/setup.md
```

## インストール：Codex 版

ローカルでの開発時は、Codex がこのリポジトリの `.agents/skills` からリポジトリスキルを読み込みます。

複数リポジトリで使う場合は、ユーザーレベルのスキルディレクトリにスキルをインストールします:

```bash
mkdir -p "$HOME/.agents/skills"
cp -R .agents/skills/vibesdegogo "$HOME/.agents/skills/vibesdegogo"
```

その後、`~/.codex/hooks.json` または `~/.codex/config.toml` にグローバルフックを登録してください。グローバルの `UserPromptSubmit` フックにより、任意の git リポジトリでのコーディング作業で VDGG が既定になります。ツールフックは、そのリポジトリルートで VDGG の状態が初期化されたあとにワークフローを強制します。次を参照してください:

```text
.agents/skills/vibesdegogo/references/codex-setup.md
```

プロジェクトローカルのフックは `.codex/hooks.json` に含まれています。Codex では `/hooks` でそれらを確認し、信頼（trust）してください。

## 必要なもの

フックスクリプトはフックJSONを `jq` で解析するため、`jq` が必要です:

```bash
brew install jq               # macOS
sudo apt-get install jq       # Debian / Ubuntu / WSL
apk add jq                    # Alpine
sudo dnf install jq           # Fedora / RHEL
```

`jq` がない場合でも、VDGGセッションが動いていないリポジトリではフックは何もせず邪魔をしません。

## プロジェクト設定

プロジェクトごとに、必要ならリポジトリルートに `.vdgg-target` を置きます。次を参照してください:

```text
skills/vibesdegogo/references/target_schema.md
```

ワークフロー関連で重要な任意項目は次の2つです:

```bash
WORKFLOW=branch-pr
AUTO_PUSH=false
```

既定の `WORKFLOW=branch-pr` では、Step 9 が PR を作るために feature ブランチを push します。`AUTO_PUSH=true` は `WORKFLOW=trunk` のときにだけ効きます。

## アンインストール

すべての足跡の一覧です（あなた自身でも、エージェントに頼む場合でもこのリストで完遂できます）。

**Claude Code 版:**

- プラグイン導入の場合: Claude Code 内で `/plugin uninstall vibesdegogo@vibesdegogo` を実行（ターミナルからなら `claude plugin uninstall vibesdegogo@vibesdegogo`）。
- 手動導入の場合: `~/.claude/skills/vibesdegogo/` を削除し、`~/.claude/settings.json` から `vdgg-hook-*.sh` を参照するフック4件（`PreToolUse` / `PostToolUse` / `PostToolUseFailure` / `Stop`）を除去。
- 各リポジトリ内のセッション生成物: `.claude/.vdgg-*` と `tasks/vdgg/` は削除して安全です。`.gitignore` に自動追記される `.claude/.vdgg-*` のブロックも不要なら消してかまいません。

**Codex 版:**

- `~/.agents/skills/vibesdegogo/` を削除する。
- `~/.codex/hooks.json` から `vdgg-hook-*.sh` を参照するフック4件（`PreToolUse` / `PostToolUse` / `Stop` / `UserPromptSubmit`）を除去する。
- 各リポジトリ内のセッション生成物: `.codex/.vdgg-*` と `tasks/vdgg/` は削除して安全です。`.gitignore` に自動追記される `.codex/.vdgg-*` のブロックも不要なら消してかまいません。

両エディション共通: `.vdgg-target` は残してください — これはあなたの設定ファイルで、VDGG が入れたものではありません。

## テスト

```bash
bash tests/run-all.sh
```

両エディションのテストがこの1つのディレクトリから走ります。

## オプション：MAGI 連携

**MAGI**（小さなオープンソースの3人格合議スキル）も入れていれば、VibesDeGoGo! は2箇所でそれを使います ── 無ければ黙ってスキップ：**Step 0** で本当に割れた高リスクの判断を合議し（材料を返すだけ／決めるのはあなた）、**Step 7** で主観的成果物（ドキュメント・コピー・デザイン）のレビューゲートにします。MAGIが見るのは「望ましさ」で、コードの正しさではありません。→ https://github.com/tmknzz/MAGI

## ステータス

このリポジトリは両エディションを収めています。以前は `VibesDeGoGo-for-Claude-Code` と `VibesDeGoGo-for-Codex` の2リポジトリで別々に開発しており、その履歴はこのリポジトリに統合されています。
