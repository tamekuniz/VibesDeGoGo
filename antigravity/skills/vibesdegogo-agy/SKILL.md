---
name: vibesdegogo-agy
description: "Antigravity (App / IDE / CLI) で VibesDeGoGo! の Step 0–9 状態機械・証拠ゲート・Formations を実行する。実装・修正・リファクタリング・検証タスク用。"
---

# VibesDeGoGo! for Antigravity

Antigravity ネイティブプラグイン（`hooks.json`）とセットで動作し、Codex 版の状態機械・証拠ゲート（`.agents/skills/vibesdegogo/`）を再利用して Step 0–9 の規律を機械的に強制するエディションです。

## 設計原則

- **フックが守るべきことを検証し、文章は判断をガイドする**：状態遷移・読み込み証拠・計画抜粋・パッチ適用・テスト・レビューのゲートはすべて `PreToolUse` / `PostToolUse` / `Stop` フックが強制します。
- **証拠（Evidence）でゲートを開く**：見出しの有無ではなく、実際に読んだファイル・実コードと完全一致する抜粋・`git apply --check` を通ったパッチ・実行成功した検証コマンドで進みます。
- **実装役だけがコードを書く**：Step 4 の計画には現行コードの抜粋（`### Excerpt`）と意図（`### Intent`）だけを書き、新しいコードは Step 6 でパッチとして生成します。

## 基本ルール

- `run_command` で `vdgg_*` ヘルパーを呼ぶときは毎回 `vdgg-state.sh` を `source` する（シェル状態は呼び出し間で引き継がれない）。
  - `PreInvocation` フックがアクティブなセッションの `VDGG_CODEX_SKILL_DIR` パスをシステムメッセージで通知するため、そのパスの `scripts/vdgg-state.sh` を使用する。
- 状態遷移（`vdgg_state_advance` / `vdgg_state_loop` / `vdgg_state_write`）の Step 番号と phase 名は必ずリテラルで書く（変数展開不可）。
- 失敗した `run_command` の次の `run_command` には `[Error Acknowledged]` と原因・修正方針をコメント等で含める。
- 制約違反（新規依存追加、認証・永続化・課金・セキュリティ変更、破壊的操作、スコープ外変更）の手前、または待機が必要なときは **`[Intentional Stop]`** と具体的な理由を明記して止まる。
- サイドカー（`.codex/.vdgg-*`）や `.vdgg-target` を直接編集しない。

## フロー（Step 0–9）

1. **Step 0（合意 / 壁打ち）**：Goal / Constraints / Acceptance criteria をユーザーと合意する。曖昧・主観的・高リスクなら壁打ちしてから確定する。
2. **Step 1（開始宣言）**：`vdgg_state_init`（Formation 指定時は `--formation <name>`）でセッションを開始し、`branch-pr` 既定なら `{type}/{slug}` ブランチを切る。
3. **Step 2（要件記録）**：`tasks/vdgg/{id}/requirements.md`（`## Goal`, `## Constraints`, `## Acceptance criteria`, `## Lessons Applied`）を書き、`vdgg_state_advance 2 requirements`。
4. **Step 3（調査）**：関連ファイルを `read_file` や `run_command` で実際に読み、`tasks/vdgg/{id}/investigation.md`（必須 7 見出し＋`## 8. Lessons applied`）を書いて `vdgg_state_advance 3 investigating` → 完了後に `4 planning`。
   - `read_file` / `grep_search` 等の成功結果は `PostToolUse` が自動で `.codex/.vdgg-read-{id}` に記録する。
5. **Step 4（計画）**：`tasks/vdgg/{id}/todo.md`（各 `## T<n>` に `### Location` / `### Excerpt` / `### Intent`）と `progress.md` を作成する。
6. **Step 5（タスク選択）**：`vdgg_state_advance 5 task-selected` → `vdgg_task_begin "T1: ..." <allowlist files...>`。
7. **Step 6（実装：パッチファースト）**：`vdgg_state_advance 6 implementing`。実装ファイルへの直接 `edit_file` / `write_file` はブロックされる。`tasks/vdgg/{id}/patch/<task>.patch` を書いて `vdgg_patch_apply`（または `vdgg_codemod_apply`）で適用する。
8. **Step 7（検証・レビュー）**：`vdgg_state_advance 7 testing` → `vdgg_task_gate <test-cmd>` → `vdgg_plan_diff` で計画との差分を `progress.md` に記録（`Plan reconciliation: T1`）→ `vdgg_review_run`（外部レビューや Formation Step 7）を実行 → `vdgg_state_advance 7 verified`。
   - テスト失敗やレビュー指摘でコードを直す場合は `vdgg_state_loop 6 reflection` で原因調査と `investigation-r{loop}.md`・`progress.md` 更新を経て次のパッチへ進む。
9. **Step 8（進捗更新）**：`vdgg_state_advance 8 progress`。全タスクが終わるまで Step 5 へ戻る。
10. **Step 9（コミット・PR）**：`vdgg_state_advance 9 commit`。feature ブランチへコミット・PR 作成後に `vdgg_state_clear` で終了する。

## Formations（マルチAI編成）＆ MAGI 連携

`~/.config/vdgg/formations/<name>.conf` を使うことで、司令塔を Antigravity（Gemini）にしつつ、実装やレビューに `claude` / `codex` / ローカルLLM を割り当てられます。外部実行役が失敗しても自動で `inline` にフォールバックせず停止します。

**MAGI 連携（`magi` プラグイン導入時）：**
- **Step 0（要件審議）**：方針が割れる・主観的・高リスクな分岐では `magi` スキルの軽量議にかけて判断材料をユーザーへ返す（最終決定はユーザー）。
- **Step 7（主観的成果物のレビューゲート）**：ドキュメント・文言・デザイン・ネーミングなどテストで白黒つかない成果物は `magi` で審議し、判定行を `tasks/vdgg/{id}/magi-verdict.md` に書いた上で `vdgg_review_run grep -q '^MAGI判定: 可決' "tasks/vdgg/${ID}/magi-verdict.md"` でゲートを通す。コードの正しさはテストと外部コードレビューで検証する。

> [!IMPORTANT]
> 同一リポジトリルートで Claude Code / Codex / pi / Antigravity の VibesDeGoGo! セッションを同時並行で動かさないでください（`.codex/.vdgg-*` を共有します）。並行作業する場合は `git worktree` で別ディレクトリに分けてください。
