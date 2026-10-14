---
name: vdgg-watch
description: "VDGGの芯(合意・出典つき調査・機械で回せる検証・外部操作の手前で止まる)だけを使い、登録した1つの目標を聞く→調べる→作る→確かめるの4 Stepで見張る軽量でプロアクティブなエージェント。ユーザーが `/vdgg-watch` と打つか「vdgg-watchで見張って」と明示したときだけ起動する。"
hooks:
  PreToolUse:
    - matcher: ""
      hooks:
        - type: command
          command: 'H="${CLAUDE_PLUGIN_ROOT}/skills/vdgg-watch/scripts/vdgg-watch-hook.sh"; bash -n "$H" && bash "$H" || exit 2'
---

# vdgg-watch

## 前提: プラグインとして導入し、24時間回すなら Mac を起こしておく
- プラグイン経由で導入する。スキルを手動コピーする場合は frontmatter の hook command のパスを絶対パスに書き換える(書き換えないと見張り中は全ツールが止まる)。
- 24時間回すなら Claude Desktop の「Keep computer awake」を有効にする。蓋を閉じたときのスリープは防げない。

ユーザーが `/vdgg-watch` と打つか「vdgg-watchで見張って」と明示したときだけ使う。それ以外では起動しない。

目標ディレクトリ `<G>` の構成: `goal.md`(目標本文、`allow_tools:` 行と `schedule:` 行を任意で含む)、`checks/*.sh`(検証チェック、補助ファイルも checks/ の中)、`checks.lock`、`approvals/`、`artifact/`、`fit.md`、`sources.md`、`evidence/`。実行中マーカーは `<cwd>/.claude/.vdgg-watch-active`。

## 聞く(startより前。hookはまだ動かない)

ユーザーと対話し、目標・`allow_tools`(カンマ区切り、空ならRead/Grep/Glob/WebSearch/WebFetchだけ許可)・頻度(`schedule:`、省略時は1日1回)を合意して `<G>/goal.md` に書く。検証チェックを合意して `<G>/checks/*.sh` に置く。チェックが読む補助ファイルも checks/ の中に置く(checks/ は丸ごとlockの対象)。チェックは `artifact/` を読むだけにし、`artifact/` のコードを実行・sourceしない。実行して確かめたい成果物があるなら、その実行はツール呼び出しとして `allow_tools` か `approvals` の承認対象にする。

合意ができたら次を実行して固定する:

```bash
bash "${CLAUDE_SKILL_DIR}/scripts/vdgg-watch.sh" lock "<G>"
```

lock後にチェックや`allow_tools`を変えるときは、ユーザー自身が `checks/` を直し `<G>/approvals/relock` を作ってから、もう一度上のlockを実行するよう案内する。

固定が済んだら見張りを開始する:

```bash
bash "${CLAUDE_SKILL_DIR}/scripts/vdgg-watch.sh" start "<G>"
```

`<G>` にはいずれも目標ディレクトリの絶対パスそのものを渡す。前後に余計な語やリダイレクトを付けない(hookはこれらの完全一致だけを許す)。

## 調べる(出典はsources.mdへ。artifact/には置かない)

出典URLと取得日を `<G>/sources.md` に残す。出典を `artifact/` に置くと「成果物が無い」の検出が効かなくなる。

## 作る

`<G>/artifact/` に成果物を置く。

## 確かめる(fit.mdを書いてからrun)

`<G>/fit.md` に `## 過剰`(目標にないもの)と `## 不足`(目標にあるのに無いもの)を両方書く。書けたら次を実行する:

```bash
bash "${CLAUDE_SKILL_DIR}/scripts/vdgg-watch.sh" run "<G>"
```

初回の見張りも、最後に必ず `done` で終える(マーカーを残すと次の定期実行の start が止まる)。

## 見張り中に書けるのはartifact/配下とfit.md・proposal.md・sources.mdだけ

hookはWrite/Edit/MultiEdit/NotebookEditについて、`<G>` の `checks/`・`approvals/`・`evidence/` 配下、`checks.lock`、`goal.md`(大小文字を区別しない)を保護対象とし、承認があっても常に拒否する。`<cwd>/.claude` 配下とスキル自身のディレクトリ配下(hookや判断の根拠になる制御ファイル)への書き込みも、承認があっても常に拒否する。保護対象でなければ、許可リスト(artifact/配下・fit.md・proposal.md・sources.md、大小文字区別の完全一致)への書き込みを許す。許可リスト外でも保護対象でなければ、`<G>/approvals/<ツール名>` を置けば1回だけ消費して通す。

Bashは `vdgg-watch.sh` の `lock "<G>"` / `run "<G>"` / `done` を、スクリプトと `<G>` をそれぞれ二重引用符で囲んだ1形式(引用符なし・単一引用符は不可)で呼ぶ完全一致だけを許す。これに合わなくても `<G>/approvals/Bash` があれば1回だけ消費して任意のBashコマンドを通す。`approvals/Bash` はその1コマンドに全権を渡す承認であり、コマンド文字列をどう判定しても、そのコマンドが上の保護対象へ間接的に書き込むことまでは防げない。承認を置くユーザー自身がコマンドの内容を確認すること。それ以外のツールは、lock時点の`allow_tools`に載っているか `<G>/approvals/<ツール名>` があるときだけ通る。

`<G>` とスキルの置き場所は英数字と `._/~ -` だけのパスにすること。`artifact/` の下の成果物名と `<G>` の外の書き込み先は日本語でもよいが、`<G>` の中のそれ以外の書き込み先は同じ文字だけに限られる。これ以外の文字(`$`やバッククォートなど)が混じると、hookはそのBashを安全に判定できないため常に拒否する(approvals/Bashがあっても拒否)。jqが無いと見張り中は全ツールが止まるので、jqを入れておくこと。

## runの終了コード

- `0`: 全チェック合格。何も知らせず黙る。
- `3`: チェックが崩れた。`<G>/proposal.md` の `## 修正案` を埋め、最終メッセージで「何が崩れたか・根拠・修正案・承認の仕方」の4点を伝える。
- `4`: lock後に`checks/`が改ざんされた、またはシンボリックリンクがある。止めてユーザーに報告する。
- `1`: lockが無い、`checks/*.sh`が無い、など。

## doneは修正案が空だと拒否される

`<G>/proposal.md` の `## 修正案` が未記入のままでは `done` が失敗する。修正案を埋めてから次を実行する:

```bash
bash "${CLAUDE_SKILL_DIR}/scripts/vdgg-watch.sh" done
```

## 定期実行はClaude Desktopのlocal scheduled task

local scheduled taskに `/vdgg-watch <G>` を登録する(Desktopアプリが起動中かつMacが起床中のときだけ動く)。cloud routineはローカルファイルを読めないため使わない。頻度は `<G>/goal.md` の `schedule:` 行(無ければ1日1回)に合わせ、この行を変えたらscheduled task側も更新する。

各回の流れ: start → run →(exit 3ならproposal.mdの修正案を埋めて最終メッセージで4点を伝える)→ done。通知はこの最終メッセージ(Claudeアプリの通知)を既定にする。Slackなどに送りたい場合は、そのツール名を `<G>/goal.md` の `allow_tools` に足してrelockする。

承認(approvals)が無い外部操作は行わない。
