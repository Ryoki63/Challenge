# #158 ウィジェットのホーム直行 — 実装・検証記録

対象: Issue #158 / `consilium/158-bug-ios` / 基点 `7991bc55088b9ccff9b335410a88f726910f8b04`。
2026-10-21、eng-exec。仕様は REQUIREMENTS §3.10 と Issue 本文。

## 変更と受入条件

| 条件 | 実装・検査 | 状態 |
|---|---|---|
| S/M/円形/インラインからホーム直行 | 共通の `WidgetHomeLink.url` (`lien://home`) を全分岐の外側の `Group.widgetURL` に1回だけ適用 | ソース配線・Widget型検査PASS。OSタップ未確認 |
| 設定を開いたまま復帰 | solo/pairedでURLを受け、設定/招待を閉じる。通常のscene復帰と区別する | モデル試験PASS |
| 招待を開いたまま復帰 | 手動表示/招待URL表示の両方で閉じる。保留tokenも消し、同期後に再表示しない | モデル試験PASS |
| 招待リンクと衝突しない | home完全一致以外は従来の招待パーサーへ。新しい招待の再受信も検査 | モデル試験PASS |
| コールド起動のsolo/paired | `start()` 前のhome受信でもphaseを保持 | モデル試験PASS。OS配送未確認 |
| セッションなし/約束なしの安全側動作 | home処理でphaseを強制変更しない。onboarding/promiseSetupを維持 | モデル試験PASS |
| 通常のアプリ復帰 | home URLを受けないscene復帰は設定/招待を保持 | モデル試験PASS |

URL・シートだけの局所修正。データモデル、サーバー、認証、招待パーサー、同期処理、署名、公開日、workflowは変更しない。

## ローカル検証

macOS / Command Line Tools / Swift 6.1.2。Xcode未導入のため、iOS SDK・OS操作は下記と区別する。
作業出力と一時ディレクトリを指定worktree内へ限定した。

```sh
export TMPDIR="$PWD/products/lien/ios/build/issue-158/tmp"
export CLANG_MODULE_CACHE_PATH="$PWD/products/lien/ios/build/issue-158/module-cache"
export MACOS_CHECK_OUT="$PWD/products/lien/ios/build/issue-158/focused"
bash products/lien/ios/scripts/macos-check/check.sh test \
  AppModelTests SnapshotSynchronizerTests DeepLinkHandlerTests WidgetSourceTests SourceTree

export MACOS_CHECK_OUT="$PWD/products/lien/ios/build/issue-158/full"
bash products/lien/ios/scripts/macos-check/check.sh all
git diff --check
```

- 絞込: 77 tests / 373 assertions / 0 failures。
- 全macOS: 1,146 tests / 26,700 assertions / 0 failures。
- Foundationモジュール: 90ファイルbuild成功。
- SwiftUI Views: 123ファイル型検査PASS。
- Widget extension: 19ファイル型検査PASS。macOSにないロック画面familyは既存スクリプトのコピー上で置換する。
- `git diff --check`: PASS。
- 既存警告: `PairSnapshot.swift:280,286` の `ISO8601DateFormatter` staticに対するSwift 6 strict concurrency警告。今回の差分ではないため変更しない。
- 専用Swift lint設定なし。文言・privacy・release等の既存静的検査は全macOS試験に含まれる。

最初の絞込は存在しない `SnapshotFactory.swift` を指定して停止し、テスト実行には未到達。
その時点の修正前モジュール（90ファイルになる前の89ファイルbuild）を保持し、追加AppModel回帰8件をリンクして実行した。
`ONLY='AppModelTests.test(HomeDeepLink|OrdinaryForeground|UnrelatedURLs)'` の結果は **3 PASS / 5 FAIL**。
設定残存、手動招待残存、保留tokenによる再表示を検出し、修正後の同じ回帰はすべてPASSした。

詳細ログは無視対象の `products/lien/ios/build/issue-158/` にある（`focused.log` / `full.log` / `red/regression.out`）。
PRには提出SHAのCI結果を別途記録し、ローカルのmacOS互換試験をiOS XCTestと呼ばない。

## 独立レビュー

2026-10-21、実装者とは別のeng-review担当（Hume）による読取専用レビューを1回実施。
URL配線、全familyへの適用、暖/冷起動、pending招待と同期、通常復帰、招待回帰、安全なphase維持、テスト実効性を確認。
**具体的な指摘なし**。コード上の受入条件適合を確認し、OS実タップの合格とは区別した。
同期途中を止めて再開する専用競合試験は追加していない。配線検査はソース文字列検査であり、WidgetKitのOSイベント配送自体は検査しない。

## 残検証と引渡し

- iOS無署名build/XCTest: コードSHA `1ef04c0184f5727637497e330a19e20f37ec2c44` の `lien-ios` run `39532151011` attempt 2がsuccess。iPhone 17 / iOS 26.5、1,231 tests / 0 failures / `TEST SUCCEEDED`。release scriptのPython試験も130件PASS。初回は同じ1,231件が成功したが20分上限でジョブcancelledとなり、再実行1回だけでジョブ全体successを確認した。
- `lien-ci` run `39532151022`: コードSHAの全6ジョブsuccess。
- 既存の別件: 変更していない `lien-play.yml` はrun `39532149899` がjobs=0でfailure。直前2runもfailure。PRのiOS/共通7チェックはPASSだが、リポジトリ全workflowが緑とは報告しない。
- CI通過後の追記はこの記録・JOURNAL・DONEだけとし、実装ファイルは検証済みコードSHAから変更しない。PRは #159、マージしない。
- 実機4familyのタップ、OSのscene restoration、実際のsheet dismissal: 未確認。`products/lien/ios/README.md` §13に手順を追加した。
- 画面の描画は変更せず、実タップのスクリーンショットは未取得。CI画像もOSタップの証拠とは扱わない。
- mainへの直接push、PRマージ、ストア提出、課金、本番データ操作は実施しない。レビュー役職へPRで引き渡す。
