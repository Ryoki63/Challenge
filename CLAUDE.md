# CLAUDE.md

このリポジトリの最上位指示は AGENTS.md にある。**必ず先に読んで従うこと**:

@AGENTS.md

## Claude Code 固有の補足

- 「LOOP.mdに従って」と言われたら、作業前に LOOP.md 全文を読むこと
- タスクの分解・追加は `/plan`、進捗確認は `/status`、GitHub同期は `/sync` のプロジェクトskillを使う
- コミットメッセージは `loop: <要約>`(ループ実行時)/ `chore|feat|fix: <要約>`(手動作業時)
- **commit したら必ず push する**(GitHub常時連携ポリシー)
- **`progress/JOURNAL.md` はユーザーが常時ウォッチしている。こまめに追記する**(着手時に書き始め、節目ごとに追記、完了で締める)。対話セッションでも実質的な作業をしたら追記する。古い記録は AGENTS.md のローテーション手順で要約・整理する(@AGENTS.md「JOURNAL こまめ更新ポリシー」)
