# JOURNAL — 実行履歴（追記専用）

ループの各イテレーションが「やったこと・判断・検証・結果」をここに追記します。
人間（あなた）が後からレビューするための監査ログです。エージェントは過去の記録を削除・編集しません。

---

## 2026-06-10 21:07 — demo: hello/hello.py の作成
- やったこと: `hello/hello.py` を新規作成し、"Hello from the loop!" を出力する1行の print 文を実装。
  BACKLOG から該当タスクを削除し、DONE.md に移動した。
- 判断したこと: 特になし（タスク内容が明確で迷う点はなかった）。
- 検証: リポジトリルートで `python hello/hello.py` を実行し、出力が "Hello from the loop!" と完全一致することを確認。
  さらにサブエージェントによる第三者視点の検証でも PASS 判定。
- 結果: 完了

## 2026-06-10 23:34 — T01: products/lien/ 雛形作成 (issue #1)
- やったこと: DESIGN §2 準拠の products/lien/ ディレクトリ構成(ios/ supabase/ assets/ web/invite/ marketing/)、README、.gitignore、Secrets.example.xcconfig、CI骨格 .github/workflows/lien-ci.yml(deno test ジョブ)を作成。マルチエージェント並列実行(Wave 1)の1タスクとして実施。
- 判断したこと: ios/project.yml は TASKPLAN で T06 スコープのため T01 では作らない(README に注記)。iOSビルドCIも T06 が別ファイルで追加する。
- 検証: ローカル deno test 緑(1 passed)。独立検証エージェントが DESIGN §2 との構成一致・gitignore 動作・YAML構文を確認。CI緑は push 後に gh run で確認。
- 結果: 完了(issue #1 はCI緑確認後にclose)

## 2026-06-10 23:34 — demo: docs/STRUCTURE.md 作成 (issue #45)
- やったこと: ルート直下の全ファイル・フォルダの役割を日本語でまとめた docs/STRUCTURE.md を新規作成。BACKLOG から該当行を削除し DONE.md に追記。
- 判断したこと: GitHub Issues が正・BACKLOG はローカル補助、という関係を明記。products/lien/ の予定構成(DESIGN §2)にも言及。
- 検証: ルート直下13項目すべての言及を grep で機械的に突合し OK。独立検証エージェントも PASS。
- 結果: 完了
- フォローアップ: .claude/settings.local.json が .gitignore に未登録(慣例では除外推奨)→ 別途検討
