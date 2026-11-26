[English](CONTRIBUTING.md) | **日本語**

# コントリビューションガイド

VibesDeGoGo! の改善にご協力ありがとうございます。本プロジェクトは意図的に小規模に保たれており、shell スクリプトと Markdown ドキュメントのみで構成され、テストフレームワークへの依存はありません。

## 必要環境

- `bash`
- `zsh`（テストスイートは全テストを bash と zsh の両方で実行します）
- `jq`
- 標準 Unix ツール: `date`, `tr`, `grep`, `sed`, `find`, `awk`

macOS の場合、`jq` は次でインストールできます:

```bash
brew install jq
```

## リポジトリ構成

- `skills/vibesdegogo/`: Claude Code skill
- `skills/vibesdegogo/scripts/`: Claude Code 用の hook と state ヘルパー
- `skills/vibesdegogo/references/`: ワークフロー参照資料
- `hooks/hooks.json`, `.claude-plugin/`: Claude Code プラグインとしての梱包
- `.agents/skills/vibesdegogo/`: 独自の scripts と references を持つ Codex skill。
  大半はエディション固有だが、7 ファイルだけは両ツリーで共通 ──
  後述の「両エディションで共通のファイル」を参照
- `.codex/hooks.json`: Codex のプロジェクトローカル hook 登録
- `tests/`: 両エディション用の依存ゼロの smoke テスト

## テストの実行

全 smoke テスト:

```bash
bash tests/run-all.sh
```

個別ファイル:

```bash
bash tests/test-state.sh
bash tests/test-hook-pretool.sh
bash tests/test-hook-posttool.sh
bash tests/test-hook-stop.sh
bash tests/test-codex-state.sh
bash tests/test-codex-hook-pretool.sh
```

スクリプト編集時の構文チェック:

```bash
bash -n skills/vibesdegogo/scripts/*.sh
bash -n .agents/skills/vibesdegogo/scripts/*.sh
```

## hook スクリプトの編集について

hook / state スクリプト内のコメントに対して、広域 `sed -i` での書き換えは行わないでください。過去にリネーム作業で意味のあるコメントが汎用 placeholder に置き換えられてしまった経緯があります。名前やコメントを変更する際は:

- diff をファイル単位で確認する
- 振る舞いの変更とコメントだけの変更は別コミットに分ける
- 各エディションの hook JSON 契約と、それぞれの setup ドキュメント
  （Claude Code は `skills/vibesdegogo/references/setup.md`、Codex は
  `.agents/skills/vibesdegogo/references/codex-setup.md`）の整合性を保つ

## 両エディションで共通のファイル

次の 8 ファイルは `skills/vibesdegogo/` と `.agents/skills/vibesdegogo/` の
両方に存在し、byte 一致を保つ必要があります。

- `scripts/vdgg-llm-start.sh`
- `scripts/vdgg-exec-claude.sh`
- `scripts/vdgg-exec-codex.sh`
- `scripts/vdgg-exec-agy.sh`
- `scripts/vdgg-evidence.sh`
- `references/servers-conf.md`
- `references/servers.conf.example`
- `references/local-inference-setup.md`

片方を変更したら、同じコミットでもう片方も同じ内容にしてください。これは
hook / state スクリプトに限らず、ドキュメントやコメントだけの変更を含む
すべての変更に適用されます。

`tests/test-edition-sync.sh` が上記のうち `references/local-inference-setup.md`
以外を検査します（このファイルはエディションごとにインストール先の記述が意図的に
異なります）。すべてを手で確認するには:

```bash
for f in scripts/vdgg-llm-start.sh scripts/vdgg-exec-claude.sh \
         scripts/vdgg-exec-codex.sh scripts/vdgg-exec-agy.sh scripts/vdgg-evidence.sh references/servers-conf.md \
         references/servers.conf.example references/local-inference-setup.md; do
  cmp "skills/vibesdegogo/$f" ".agents/skills/vibesdegogo/$f" || echo "OUT OF SYNC: $f"
done
```

これ以外のファイルはすべてエディション固有であり、内容が異なるのが正常です。

## commit スタイル

以下の形式を使ってください:

```text
{type}: {summary}
```

よく使う type: `feat`, `fix`, `refactor`, `docs`, `test`, `chore`

## Pull Request

PR を開く前に:

- `bash tests/run-all.sh` を走らせる
- 変更したスクリプトの構文チェックを走らせる
- 変更が hook、state helper、workflow docs のどれに影響するかに加え、
  Claude Code 版、Codex 版、または両方のどれに入るかを明記する

## バージョニング

skill ファイル内の `version` フィールドは、当該エディションのワークフロー仕様を追跡します。リポジトリのリリースは別途 SemVer タグで管理しており、最初のパブリック OSS リリースは `0.1.0` から始まります。
