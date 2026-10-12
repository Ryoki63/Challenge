# BACKLOG — タスクキュー

ここに `- [ ] タスク内容` の形式でタスクを追加すると、ループが上から順に1件ずつ処理します。

書き方のコツ:
- 1タスク = 1コミットで終わる粒度に分割する
- 「完了条件:」を併記すると検証の精度が上がる
- 記号の意味: `[ ]` 未着手 / `[>]` 実行中 / `[!]` ブロック / 完了は DONE.md へ移動

---

## 第1波(2026-10-12 決定 — docs/REVIEW-2026-10-12.md §3。正は GitHub Issues)

v1.0 の目標: 内部 TestFlight 10/23 → 機能凍結 11/8 → 外部テスト 11/13 → 審査提出 11/23〜27 → 公開 12/11。
v1.1 課金(#33〜#36)・T21 アルバム・T24 SIWA は `on-hold` ラベルでループから外している。

### backend(直列: supabase/ と DESIGN §3.4・§4・§5.2〜§5.4 のオーナー)
- [>] [X1][#51] 本番 cron 登録(pg_cron+pg_net+Vault。close-day 00:10 JST / grant-tickets 毎月1日) 完了条件: 本番 cron.job に2ジョブ+手動実行 200
- [ ] [X2][#52] 写真パスを本人単位に(migration 0004+checkin) 完了条件: deno test 緑+本番で他人パスへの書込 403
- [ ] [X3][#53] push_env 保存+APNs 環境のトークン単位選択(migration 0005+apns.ts) 完了条件: deno test 緑+本番適用
- [ ] [GS][#54] 成長ルール v2(サーバー): 10段階・streak_days から数える・昨日の仮判定・plant-name・一括デプロイ 完了条件: deno test 緑+本番スモーク

### docs(並列可: REQUIREMENTS / TASKPLAN / CONCEPT / E2E-M1 / store_metadata / DESIGN §3.5)
- [>] [DOC][#58] 仕様改定(成長ルール v2・D3 スコープ削減・D6 計測) 完了条件: lien-ci 緑(store-metadata)

### ios-serial(Strings.swift / project.yml / LienApp.swift — 上から厳密に直列)
- [>] [W1][#55] アプリ結線: Live 基盤+AppRouter+ソロモード+push_token/push_env 保存+契約フィクスチャ 完了条件: lien-ios 緑+AppRouterTests・契約テスト緑
- [ ] [PA][#56] 植物 v2-a(描画): v4 SVG レイヤー取込+PlantCharacterView+plant-assets CI の SVG 化 完了条件: CI 緑+実描画一覧の artifact
- [ ] [PB][#57] 植物 v2-b(体験): ゲージ・段階アップ演出・名前付け 完了条件: lien-ios 緑+各テスト緑
- [ ] [T28準備][#28] Xcode 26 固定・ExportOptions・PrivacyInfo・MARKETING_VERSION 1.0.0・v4 アイコン 完了条件: dry_run の無署名 archive 緑
- [ ] [T23][#23] 審査対応一式(通報・ブロック=解消・規約同意・完全削除) 完了条件: deno+lien-ios 緑+レビューノート §1.4/§1.5 を再現
- [ ] [T16][#16] 通知(縮小版: ローカル通知+streakRisk/milestone+ON/OFF) / [T17a][#17] S+ロック画面 / [T18][#18] 履歴 / [T19a][#19] チケット残数バッジ / [T22][#22] シェア画像 / [T27][#27] 文言総点検 — 11/8 機能凍結まで

### 人間(D5 ほか)
- G0(#38)を 10/16 までに / Xcode 26 導入(ディスク 40GB)/ テスター募集(11/6 まで)/ Supabase Pro 化(12/1 まで)/ G4a(11/6 まで)
