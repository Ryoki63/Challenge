# BACKLOG — タスクキュー

ここに `- [ ] タスク内容` の形式でタスクを追加すると、ループが上から順に1件ずつ処理します。

書き方のコツ:
- 1タスク = 1コミットで終わる粒度に分割する
- 「完了条件:」を併記すると検証の精度が上がる
- 記号の意味: `[ ]` 未着手 / `[>]` 実行中 / `[!]` ブロック / 完了は DONE.md へ移動

---

## Wave 4(2026-06-11 改定計画 #50 — いま実行可能。人間ゲート待ちは積まない)

### レーンA: ios-serial(Strings.swift / project.yml / LienApp.swift 共有 — 上から厳密に直列)
- [ ] [T10][#10] オンボ3画面(AuthServicing/PushAuthorizing プロトコル+モック注入。supabase-swift は Lien ターゲットのみに追加。初期 phase 導出ロジックを新設) 完了条件: lien-ios.yml 緑+OnboardingViewModelTests 緑。実 Supabase 疎通は T08 持ち越しを issue に明記
- [ ] [T08準備②][#8] push トークン取得ハーネス(AppDelegate 新設+DEBUG トークン表示 UI+aps-environment を entitlements に追加) 完了条件: lien-ios.yml 緑(issue #8 は close しない)
- [ ] [T11][#11] 招待 UI+ディープリンク+web/invite 静的ページ(InviteClient モック注入。web 部分は依存ゼロで先行可) 完了条件: web 3状態の手元ブラウザ確認+lien-ios.yml/lien-ci.yml 緑
- [ ] [T12][#12] 約束設定(functions promise-set 新設+PromiseSetupView。LienApp.swift には触れない) 完了条件: deno test 緑+lien-ios.yml 緑+DESIGN §5.3 に promise-set 追記
- [ ] [T13][#13] ホーム画面(PlantSprite.swift と PlantAssets.xcassets 取込の単独オーナー。CheckinPerforming はローカルエコー注入) 完了条件: lien-ios.yml 緑+PlantSpriteTests/HomeViewModelTests 緑
- [ ] [T14][#14] チェックインフロー+オフラインキュー+写真(migration 0002_photo_storage_policies — 着手時に最新連番を再確認) 完了条件: deno test 緑+lien-ios.yml 緑+PendingOpsQueueTests 緑
- [ ] [T15][#15] つつく+リアクション(functions nudge/react 新設。messages.ts の nudge/reply/reaction 文言オーナー) 完了条件: deno test 全緑(+約20件)+lien-ios.yml 緑+罰なし文言の機械検証
- [ ] [T16][#16] 通知一式(messages.ts は streakRisk/milestone 等の残りに限定=nudge 系は T15 委譲。prefs+migration 0003_notif_prefs+ReminderScheduler) 完了条件: deno test 緑+lien-ios.yml 緑+ReminderSchedulerTests 緑
- [ ] [T17][#17] ウィジェット3種(M/円形/インライン)+NSE サムネ(T13 作成の PlantSprite.swift を LienWidget sources へ共有追加。photoThumbUrl 契約を DESIGN §4 に追記) 完了条件: lien-ios.yml 緑+ペイロード/サムネ/日付跨ぎテスト緑
- [ ] [T18][#18] カレンダー履歴(HistoryCalendarBuilder 純粋ロジック+モック repo。streak.ts と同一意味論をテストで突合) 完了条件: lien-ios.yml 緑+月境界・both/ticket 判定テスト緑
- [ ] [T19][#19] お休みチケット(functions rest-declare 新設+snapshot に ticketBalance 追加+Tickets UI) 完了条件: deno test 緑+lien-ios.yml 緑+snapshot 後方互換テスト緑
- [ ] [T21][#21] アルバム画面(AlbumRepository モック+30日制限ポリシー純粋関数) 完了条件: lien-ios.yml 緑+AlbumAccessPolicyTests(29/30/31日境界)緑
- [ ] [T22][#22] シェア画像生成(ImageRenderer 2フォーマット。xcassets は T13 取込済みを確認し未追加時のみ追加) 完了条件: lien-ios.yml 緑+寸法/非ブランク/決定性テスト緑+XCTAttachment 目視
- [ ] [T23][#23] 設定画面+functions pair-dissolve/delete-account(通報 mailto・削除2段階確認。messages.ts は T16 の後に追記) 完了条件: deno test 緑+lien-ios.yml 緑+SettingsViewModelTests 緑
- [ ] [T24][#24] Apple ID 連携(functions apple-link+nonce ロジック+モック注入。entitlements は T08準備②の後) 完了条件: deno test 緑+lien-ios.yml 緑+AppleSignInTests 緑
- [ ] [T28準備][#28] リリース CI 準備(lien-release.yml dry_run+ExportOptions.plist+AppIcon 仮取込=products/lien/assets/icon/icon_drafts/draft_a_bloom_1024.png、G4 で差し替え) 完了条件: dry_run=true で無署名アーカイブ緑(issue #28 は close しない)

### レーンB: infra/scripts(レーンAと並列可)
- [ ] [T08準備①][#8] デプロイ自動化+G1 計測ハーネス(supabase/config.toml verify_jwt=false+scripts/deploy.sh+lien-deploy.yml+scripts/g1/{seed-pair.sh,measure.sh,RUNBOOK.md}) 完了条件: bash -n 構文チェック+lien-ci.yml 緑のまま(issue #8 は close しない)

### レーンC: docs/marketing(レーンA/Bと並列可)
- [ ] [T20準備][#20] 実機 E2E チェックリスト12項目+ランブック(docs/E2E-M1.md)+e2e_reset.sql 完了条件: 12項目が REQUIREMENTS §3.2〜3.9 を網羅(サブエージェント検証)+issue #20 に「実機待ち」コメント
- [ ] [T30準備][#30] App Review 向けレビューノート草案(marketing/review-notes.md)+REQUIREMENTS §8 台帳化(各項目に状態+参照) 完了条件: §8 全5項目に対応節と状態注記が存在
- [ ] [T32準備][#32] ストアメタデータ確定値化(store_metadata/ja/+alternatives.md)+verify_metadata.py+lien-ci.yml に store-metadata ジョブ 完了条件: store-metadata ジョブ緑+#42 に G4 決定依頼コメント投稿

### Wave 5以降(参考 — ゲート解放で着手。詳細は #50)
- Wave 5: [T09v2][#49] G2(#40)回答後、選定スタイルで全コマ制作(assetsレーン・Wave 4と並走可)
- Wave 6: [T08][#8] G0(#38)後、デプロイ+実機G1計測
- Wave 7〜: T20 実機E2E → T27 → T28 本提出(G3)→ M3/M4
