# Issue #106 — 本番実行シートの検証・eng-review

確認日: 2026-10-20 JST。対象は `products/lien/ios/RELEASE-RUNBOOK.md` と `README.md` §8の導線、JOURNAL追記のみ。workflow・アプリ・署名設定は変更しない。成果物は単一Markdownの実行シート（A4印刷1ページの指定ではない）。

## 独立レビュー

実装者と別のサブエージェントを **eng-review** として起動。レビュワーID: `01a159a5-86a5-7e72-95d1-4a53e86e9aee`。読み取りのみで、受入条件・workflow・`release.sh`・`verify_archive.py`・`ci_status.py`・`ExportOptions.plist`と照合した。

**初回判定: PASS（文書レビュー）。重大な阻害指摘なし。**

| Issue本文の完了条件 | eng-reviewの判定・根拠 |
|---|---|
| Secrets 6件の名前・取得元・設定先・取得担当、値を書かない | PASS。6件が揃い実値なし |
| dry_run → 本番、切り戻し、Bundle ID/APNs/署名の対処 | PASS。実装と整合 |
| 実行後チェック（ビルド表示・招待受信） | PASS。処理完了・内部グループ・インストールまで確認手順を明記 |
| eng-reviewを通す | PASS。実装者とは別のレビュワーによる照合を実施 |

非阻害の改善指摘: mainの事前比較とdispatch間の更新raceについて、不一致・取得不能時の取消とASC到達確認・配布禁止を明記する。実行シートに追記し、変更した段落だけ限定再確認する（全体の重複レビューはしない）。

**限定再レビュー: PASS。** 本番Run ID段落だけを同じeng-reviewが再確認。SHA確認コマンド・取消試行・再開手順・ASC到達確認・配布禁止と、自動upload防止gateではない旨が揃い、改善指摘は解消。全体再レビューは実施していない。

## 機械検査・表示確認

- `PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s products/lien/ios/scripts -p 'test_*.py'` → **130件 OK**。キー形式・CI gate・archive検査等の既存テスト。secret実値は使わない。
- ローカルPythonの検査 → Secrets表の集合がworkflowの`secrets.*`参照6件と一致、全行に担当・設定先、全ローカルリンク実在、コードフェンス整合、秘密値形式不在、JOURNALがHEADの内容を保つ追記のみ、をPASS。
- コード例3ブロックを実行せず`bash -n`で構文検査 → PASS。`bash -n products/lien/ios/scripts/release.sh`もPASS。本番workflowの起動は行わない。
- Chrome headless＋ローカルの一時プレビューで表示確認。外部リクエストは遮断。表2個（各ヘッダー＋6行）、コード例3個、横overflowなしを確認。Secrets表・切り戻し表を画像で目視確認。QA生成物はgitignore済み`build/issue-106-qa/`内でコミットしない。最初のfull-page撮影はブラウザで失敗したが、viewport撮影へ切替えて確認済み。
- `git diff --check` → PASS。

## 実行済みと未実行の境界

- `xcodebuild -version`はCommand Line Toolsのみのため失敗。**今回のiOSビルド・署名のローカル実測はしていない**。文書変更なのでローカルの型チェック・lint・アプリビルドは対象外。pushで起動する通常CIは別途PRで確認する。
- 着手SHA `cb951bea6b7d61997d8d68b0e0c6849db453e3fe`は`lien-ci` run `39427686022` success、同SHAの`lien-ios`実行なし。これは提出コミットのCI成功を意味しない。
- 既存`lien-release` run `38333546970`（別SHA）は無署名archive成功、signed archiveとuploadはskipped。**初回クラウド署名成功の証跡ではない**。
- 本番dispatch・Secrets取得/登録・Apple設定/アップロード・招待/配布は行っていない。Appleの処理時間、1時間での到達、実機通知、招待受信の実測は、オーナー承認後にこの実行シートを使って確認する。
- ロールバック: 文書はPR経由のrevert。DB migrationなし、本番データ変更なし。10/24機能凍結・10/27審査提出・10/31公開の期限や仕様は変更しない。署名の初回検証とApple処理待ちはスケジュールリスクとして残る。

## 提出後CIの最終結果（2026-10-21 00:03 JST）

- 実装SHA `f3311d933323951db57a048e45fc41d582b948fa` の`lien-ci` run `39438487582`は6ジョブsuccess。JOURNALのみ追記したSHA `110582a2259c23ca3e2445daee2a2de4b2725c6e` のrun `39438842365`も6ジョブsuccess。
- 同実装SHAの`lien-ios` run `39438492922`初回はSwiftPM依存取得でGitHub:443接続不能・RevenueCat clone timeout/early EOF（exit 74）。1回だけ失敗ジョブを再実行した。
- attempt 2は依存解決・シミュレータ起動・無署名build/testがsuccess。ログは **1221 tests / 0 failures / TEST SUCCEEDED**。ただしジョブ全体は20分制限を超過し、APIの最終conclusionは **cancelled**（20分15秒）。全ステップのsuccess表示をジョブ全体のsuccessへ読み替えない。
- **文書受入とeng-reviewはPASS、CI全体の緑ゲートは未達のためタスク最終判定はfailed。PR #129は未マージ、Issue #106はOPENを維持する。** 同操作の3回目は行わず、CI実行時間の調査・復旧後の再検証を別の作業として引き継ぐ。今回workflow・アプリ・依存定義は変更していない。
