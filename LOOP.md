# LOOP.md — 自律ループ実行指示書

あなたはこのリポジトリの自律タスク実行エージェントです。
この指示書は「ループ1回分」の手順です。**1回の実行で処理するタスクは必ず1件のみ**です。

## 実行手順

0. `git pull --rebase` でリモートと同期する。
   - リモートが未設定・到達不能なら、スキップして続行する(後の JOURNAL 記録にその旨を書く)。
   - コンフリクトが起きたら `git rebase --abort` で戻し、手順7(ブロック処理)へ。

1. **次のタスクを GitHub Issues から選ぶ**
   ```
   gh issue list --repo Ryoki63/Challenge --state open \
     --label "agent:W" --assignee "" \
     --json number,title,labels \
     --jq 'sort_by(.number) | first'
   ```
   - `agent:W` ラベルがついた未アサインのissueのうち、**番号が最小の1件**を選ぶ。
   - `human-gate` ラベルも持つissueはスキップする(人間が処理するもの)。
   - 対象issueが0件なら、最終出力の末尾に `<LOOP_COMPLETE>` とだけ書いて終了する。
   - BACKLOG.md にも同じタスクが残っている場合は `- [>]` に書き換える(同期維持)。

2. **着手宣言**: issueにコメントを投稿し、自分にアサインする
   ```
   gh issue comment <番号> --repo Ryoki63/Challenge \
     --body "着手: <YYYY-MM-DD HH:mm>。<やること一言>"
   gh issue edit <番号> --repo Ryoki63/Challenge --add-assignee "@me"
   ```

3. タスクを実行する。
   - スコープは**そのタスクに書かれた内容のみ**。関連する改善・リファクタを勝手に広げない。
   - issueの「完了条件」が完了の定義。

4. 検証する。
   - コードを書いた場合：実際に実行・ビルドして動作を確認する。
   - 可能であれば Agent ツール（サブエージェント）に「この変更がタスクの完了条件を満たすか批判的に確認して」と依頼する。
   - 検証に失敗したら修正して再検証（最大3回まで。それでも失敗なら手順7へ）。

5. **完了処理（すべて必須）**：
   a. `tasks/BACKLOG.md` から該当タスク行を削除する(存在する場合)。
   b. `tasks/DONE.md` の末尾に `- [x] <タスク内容> — <YYYY-MM-DD HH:mm>` を追記する。
   c. `progress/JOURNAL.md` の末尾に下記フォーマットで実行記録を追記する。
   d. `git add -A && git commit -m "loop: <タスクの要約（50字以内）>"` でコミットする。
   e. `git push` する（GitHub常時連携）。push に失敗してもタスク自体は完了扱いとし、
      JOURNAL に「push失敗: <理由>」を注記する。**`--force` は禁止**。
   f. **GitHub issue にクローズコメントを投稿してcloseする**:
      ```
      gh issue comment <番号> --repo Ryoki63/Challenge \
        --body "完了: <YYYY-MM-DD HH:mm>。<やったこと要約。commit: <ハッシュ7桁>>"
      gh issue close <番号> --repo Ryoki63/Challenge
      ```

6. 正常完了時は、最終出力の末尾に `<LOOP_CONTINUE>` と書いて終了する。

7. **失敗・ブロック時の処理**：
   - BACKLOG.md のタスク行を `- [!] <元の内容> — BLOCKED: <理由>` に書き換える(存在する場合)。
   - `progress/JOURNAL.md` に何を試して何が起きたかを記録する。
   - **GitHub issue にブロックコメントを投稿する**:
     ```
     gh issue comment <番号> --repo Ryoki63/Challenge \
       --body "BLOCKED: <理由>。\n\nユーザーへの質問: <何を確認してほしいか>"
     ```
   - ここまでの変更をコミットし、push する（メッセージ: `loop: blocked - <要約>`）。
   - 最終出力の末尾に `<LOOP_BLOCKED>` と書いて終了する。**次のタスクには進まない。**

## JOURNAL.md 追記フォーマット

```
## <YYYY-MM-DD HH:mm> — <タスク要約>
- やったこと: <実施内容を2〜4行で>
- 判断したこと: <迷った点と選択理由。なければ「特になし」>
- 検証: <どう確認したか・結果>
- 結果: 完了 / ブロック(<理由>)
```

## ガードレール（厳守）

- 1実行 = 1タスク。前倒しで複数処理しない。
- `git push --force` と公開済み履歴の書き換えは禁止（通常の push は手順6eで必須）。
- GitHub への push 以外の外部送信・投稿、ファイルの大量削除は、タスク本文に明記されている場合のみ実行可。
- このリポジトリの外（親フォルダや他のプロジェクト）のファイルは変更しない。
- 不明点・曖昧さがあって進められない場合は、推測で進めず手順7（ブロック処理）を使い、
  JOURNAL.md にユーザーへの質問を書き残す。
- シークレット（APIキー等）をファイルにハードコードしない。
