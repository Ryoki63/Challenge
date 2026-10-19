# BACKLOG — タスクキュー

ここに `- [ ] タスク内容` の形式でタスクを追加すると、ループが上から順に1件ずつ処理します。

書き方のコツ:
- 1タスク = 1コミットで終わる粒度に分割する
- 「完了条件:」を併記すると検証の精度が上がる
- 記号の意味: `[ ]` 未着手 / `[>]` 実行中 / `[!]` ブロック / 完了は DONE.md へ移動

---

## 第1波(2026-10-12 決定 — docs/REVIEW-2026-10-12.md §3。正は GitHub Issues)

v1.0 の目標(オーナー決定 2026-10-20 で前倒し。旧: 内部 TestFlight 10/23 → 機能凍結 11/8 → 外部テスト 11/13 → 審査提出 11/23〜27 → 公開 12/11):
10/20–21 Apple 承認解消(G0 #38)と ASC 設定 → 10/22–23 APNs 本番キー・`lien-release` 本番・**内部 TestFlight 10/23** → **10/24 機能凍結** → 10/24–25 実機 E2E・スクショ撮り直し → **10/26 G4 承認** → **10/27 審査提出**(手動リリース)→ 10/28–30 審査待ち(差戻し最大 1 回)→ **10/30–31 公開**。外部テスト(T28b)は省略。
- 成立条件: Apple 承認が 10/21 まで。10/23 の内部 TestFlight に間に合わなければ公開を 11/3〜11/7 に再設定する。
- **10/24 の線**: それまでに終わらない作業は v1.0.1 へ送る(T18・T22・T19a。T17a のウィジェットは動く状態なら残す)。v1.0 の必須は T23・T27・T30・G4・T16(縮小版通知)。
- マーケ(Issue #74〜#80)は公開前から並行。v1.1 課金は別ブランチで実装 10/26–11/6、G6/T37 は 〜11/1、11/9 審査提出、11/12〜13 公開(T34・T35・T36 は v1.2 以降)。
v1.1 課金(#33〜#36)・T21 アルバム・T24 SIWA は `on-hold` ラベルでループから外している。

### backend(直列: supabase/ と DESIGN §3.4・§4・§5.2〜§5.4 のオーナー)
- [x] [X1][#51] 本番 cron 登録(pg_cron+pg_net+Vault。close-day 00:10 JST / grant-tickets 毎月1日) 完了条件: 本番 cron.job に2ジョブ+手動実行 200
- [x] [X2][#52] 写真パスを本人単位に(migration 0004+checkin) 完了条件: deno test 緑+本番で他人パスへの書込 403
- [x] [X3][#53] push_env 保存+APNs 環境のトークン単位選択(migration 0005+apns.ts) 完了条件: deno test 緑+本番適用
- [x] [GS][#54] 成長ルール v2(サーバー): 10段階・streak_days から数える・昨日の仮判定・plant-name・一括デプロイ 完了条件: deno test 緑+本番スモーク

### docs(並列可: REQUIREMENTS / TASKPLAN / CONCEPT / E2E-M1 / store_metadata / DESIGN §3.5)
- [x] [DOC][#58] 仕様改定(成長ルール v2・D3 スコープ削減・D6 計測) 完了条件: lien-ci 緑(store-metadata)

### 第2波(2026-10-13 起動)
- [x] [B3][#60] backend 堅牢化: OPS 再実行手順の修正(リセット通知を再送しない notify:false)・監視の自動化(毎朝 00:40 JST の Actions)・cron 専用シークレット・net 権限の revoke・cron 式の静的テスト・push_env を getUser で読む・DESIGN §5.6/§7/§10
- [x] [DOC2][#61] DESIGN §3.3(AppPhase 4状態・AppServices 等)・§3.6(ディープリンクはプリフィル+明示タップに合わせる)/ review-notes §1.1・§1.2 を実装に合わせる(T30)/ TASKPLAN の ios-serial 順の更新(PA を PV・T23 の前へ)

### ios-serial(Strings.swift / project.yml / LienApp.swift — 上から厳密に直列。2026-10-13 順序更新: 新イラストを最初の内部 TestFlight に載せるため PA を前倒し)
- [x] [W1][#55] アプリ結線: Live 基盤+AppRouter+ソロモード+push_token/push_env 保存+契約フィクスチャ 完了条件: lien-ios 緑+AppRouterTests・契約テスト緑
- [x] [W1fu+T27lint][#62] W1 の手直し(push_token 再送・AppModel の復帰・Live 構成テスト・招待シートの間隔)+罰なし文言 lint+「パートナー」→「相手」
- [x] [T28準備][#28] Xcode 26 固定・ExportOptions・PrivacyInfo・1.0.0・v4 アイコン・Release で Config 欠落を致命に・supabase-swift 固定・push_env を署名から判定 完了条件: dry_run の無署名 archive 緑
- [x] [PA][#56] 植物 v2-a(描画): v4 SVG レイヤー取込+PlantCharacterView+plant-assets CI の SVG 化 完了条件: CI 緑+実描画一覧の artifact
- [>] [PV][#59] 相手の写真を当日のホームで見せる(PostgREST+署名付き URL)
- [>] [T23][#23] 審査対応一式(通報・ブロック=解消・規約同意・完全削除) 完了条件: deno+lien-ios 緑+レビューノート §1.4/§1.5 を再現
- [>] [PB][#57] 植物 v2-b(体験): ゲージ・段階アップ演出・名前付け +VoiceOver 文・葉の下の約束の絵文字・PA レビューの手直し 完了条件: lien-ios 緑+各テスト緑
- [x] [T16][#16] 通知(縮小版: 端末ローカル通知+ON/OFF。`messages.ts` は触らない) — 2026-10-13 済み
- [ ] [T27][#27] 文言総点検(**v1.0 必須**) — 10/24 機能凍結まで
- [ ] [T17a][#17] S+ロック画面(ウィジェットは動く状態なら残す。10/24 までに動かなければ v1.0.1)
- [ ] [T18][#18] 履歴 / [T22][#22] シェア画像 / [T19a][#19] チケット残数バッジ — **10/24 までに終わらなければ v1.0.1 へ**(v1.0 の必須ではない)

### 人間(D5 ほか)
- 10/20–21: G0(#38 Apple 承認の解消)と ASC 設定 / Xcode 26 導入(ディスク 40GB)
- 10/22–23: APNs 本番キー・`lien-release` 本番 → 内部 TestFlight 10/23
- 10/26: G4 承認 / 10/27: 審査提出(手動リリース)
- Supabase Pro 化(D5)は 10/30 まで
- テスター募集(旧: 11/6 まで)は、外部テスト(T28b)の省略に伴い再確認が必要
