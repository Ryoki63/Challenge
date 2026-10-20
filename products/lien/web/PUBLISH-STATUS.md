# MK3 #76 — 公開指示後の受入確認

確認日: 2026-10-20 (Asia/Tokyo)。担当: ux-exec。**公開未了 / 法務の公開用4項目待ち**。

## 承認・入力の根拠

- 配備先: `Ryoki63/Challenge` の GitHub Pages、`https://ryoki63.github.io/Challenge`。
  `site.json` と `SupportLinks.webBaseURL` は一致。公開先の再承認は求めない。
- 公開先承認: [#76 オーナー返信](https://github.com/Ryoki63/Challenge/issues/76#issuecomment-6287900053)
  「推奨案の通りに進めてください」。さらに
  [公開指示](https://github.com/Ryoki63/Challenge/issues/76#issuecomment-6289938523)
  「公開しちゃおう」を受領した。
- X: [#79 オーナー指定](https://github.com/Ryoki63/Challenge/issues/79#issuecomment-6290455043)
  `@lien_promise` を `site.json.xUrl` に反映済み。ハンドルの再指定は不要。
- 公開指示から制定日・事業者名・メール・裁判所は推測しない。
  #42 の「それでOK!」はストア文言の候補に対する返信で、法務4項目の値はない。
- PR #100 / #111 はマージ済み。今回作業中の #111 マージを受け、指定ブランチへ
  最新mainを履歴書換えなしで取り込み、追加PRで提出する。実行担当はマージしない。

## Issue 本文の完了条件との照合

| 完了条件 | 確認結果 | 未達・境界 |
|---|---|---|
| `privacy-policy.md` と `terms.md` から HTML を生成し Pages に載せる | 生成11件・原本一致 PASS。法務HTMLは配信用とmarketing用の両方を生成 | **Pages公開未達**。法務4項目が未記入。Pages GETはHTTP 404、有効化・配備成功は未確認 |
| トップにアプリの1行説明 | 正本サブタイトルを表示。紹介文は各自1つの約束に合わせて修正 | 正式なmkt-review文言承認は別途必要 |
| スクリーンショット3枚 | MK7の実View描画PNG(達成ホーム・相手だけ完了・履歴)3枚を無加工複製。件数・寸法・バイト一致・ブラウザ表示PASS | シミュレータ上のImageRenderer描画。実機キャプチャとは呼ばない。開発中・デモデータを明記 |
| Xへのリンク | `https://x.com/lien_promise` を表示。ブラウザDOM確認PASS | Xへの投稿は本タスクでは実施しない |
| 「近日公開」またはApp Storeリンク | 「近日公開」を表示。テストPASS | App Store URLは未公開のためnullのまま |
| 個人情報を集めるフォームは置かない(メール収集は行わない) | フォーム・入力欄・外部スクリプトなし。テスト/ブラウザ確認PASS | 計測SDK・外部フォントも追加していない |
| 文言はmkt-reviewのレビュー済み | 前回の未解決箇所と今回の生成器変更を独立レビュワー1人で確認、高優先指摘なし | **正式役職の承認未達**。独立レビューをConsilium mkt-reviewの代理承認には数えない |

## 指摘への対応と独立レビュー

| 前回の未解決指摘 | 今回の対応 |
|---|---|
| 約束がペア共通1つと読める | 「ひとりひとつ」「それぞれが…1つ決めます」と明示 |
| チケット保護・記録伸長の条件不足 | 毎月2枚・在庫有時の自動消費・在庫無時の再スタート・最高記録保持を明記。無条件成長の紹介文を削除。履歴PNGにも「ふたりがそろった日だけ」と表示 |
| 実在しない画面のSVG | SVG生成と配信物を削除しMK7のPNG3枚に置換。Mウィジェットを含む03_widgetはv1.0のティザーに載せない |
| 公開入力未確定 | 公開Xのみオーナー指定で解消。法務4項目は未提供のまま保護 |

修正箇所の独立レビューは1回、高優先の修正指摘なし。詳細は
[レビュー記録](evidence/review-2026-10-20.md)。法的適合性は判定していない。
元画像の来歴は `marketing/screenshots/manifest.json`、commit `c308e5c`、
`lien-ios` run `39389661638` attempt 2。今回選んだ3枚はそのPNGとバイト一致。

## 検証

| コマンド・確認 | 結果 |
|---|---|
| webで `python3 -m unittest discover -s tools -p 'test_*.py' -v` | 50件PASS(既存47件維持、回帰3件追加) |
| webで `python3 tools/build_site.py` | 11件生成PASS |
| webで `python3 tools/build_site.py --check` | 11件一致PASS |
| webで `python3 tools/build_site.py --check-publishable` | **exit 1 / 公開不可**。法務4出力に未記入。X未設定は解消 |
| repo rootで `deno test --allow-read products/lien/scripts/ops/marketing_docs_static_test.ts` | 型検査と8件PASS |
| ローカルChrome、393px / 1440px | 横はみ出しなし、フォーム0、PNG3枚のdecode成功、Xリンク一致。法務2ページはローカルHTTP 200 |
| `gh api repos/Ryoki63/Challenge/pages` | HTTP 404。公開状態は取得不能、公開済みとしない |
| `git diff --check` | PASS |

表示証跡: [モバイル](evidence/teaser-393.png) / [デスクトップ](evidence/teaser-1440.png)、
[検査JSON](evidence/browser-check.json)。本番・iPhone Safariでの確認ではない。
Python専用の型チェック/lint設定はなく、関連テストと差分検査で検証。
iOS/バックエンドに今回独自の変更なし、アプリbuildは対象外。静的サイトbuildは成功。
Pages設定変更・workflow dispatch・配備・ストア申請・SNS投稿は実行していない。

## 残入力と再開順序

1. オーナーが **制定日・公開する事業者名・公開サポートメール・管轄裁判所**を
   #76へ1回の返信で指定する。公開許可・公開先・Xは再質問しない。認証情報は不要。
2. Markdown正本と `site.json.contactEmail` を反映し、再生成・テスト・公開前チェック。
3. Consiliumのmkt-reviewが今回の文言と素材を正式評価、レビュー役職が追加PRを判断。
4. 公開前チェック成功後、承認済み公開先のPages有効化と `lien-pages` 配備。
5. 本番トップ・法務2ページ・サポート連絡先・XリンクのHTTP応答と表示確認。
   human-gateのIssueを実行担当はcloseしない。
