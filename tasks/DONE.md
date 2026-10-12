# DONE — 完了タスクのアーカイブ

ループが完了したタスクをここに移動します（新しいものが下）。

---

- [x] demo: `hello/hello.py` を作成する。実行すると "Hello from the loop!" と出力される。完了条件: `python hello/hello.py` の出力が一致すること。 — 2026-06-10 21:07
- [x] demo: このリポジトリの構成（各ファイル・フォルダの役割）を `docs/STRUCTURE.md` に日本語でまとめる。完了条件: ルート直下の全ファイル・フォルダが言及されていること。 — 2026-06-10 (issue #45)
- [x] T01: products/lien/ 雛形作成(DESIGN §2準拠+deno test CI骨格)。CI緑。 — 2026-06-10 (issue #1)
- [x] T02: migration 0001 全テーブル+RLS+is_pair_member。PGlite実DB検証50/50。 — 2026-06-11 (issue #2)
- [x] T03: _shared/streak.ts+tickets.ts 純粋ロジック+テスト31件。 — 2026-06-11 (issue #3)
- [x] T04: checkin/snapshot functions+apns.ts(モック注入)+snapshot.ts。 — 2026-06-11 (issue #4)
- [x] T05: invite-create/invite-accept/close-day/grant-tickets+テスト43件(計132緑)。 — 2026-06-11 (issue #5)
- [x] T06: ios project.yml+3ターゲット骨格+iOSビルドCI(lien-ios緑)。 — 2026-06-11 (issue #6)
- [x] T07: PairSnapshot+AppGroupStore+静的ウィジェットS+NSE+LienTests(CI緑)。 — 2026-06-11 (issue #7)
- [x] T09: 植物スプライトv0 13枚+AssetCatalog取込+プレビュー。G2(#40)へ提出済み。 — 2026-06-11 (issue #9)
- [x] T25: privacy-policy+terms+Web公開HTML+CHECKLIST-G4。 — 2026-06-11 (issue #25)
- [x] T30準備: App Reviewレビューノート草案(marketing/review-notes.md新規)+REQUIREMENTS §8台帳化(全5項目に状態+参照)。issue #30はクローズせず継続(T23/T08実データ投入/T28完了後に本編完了)。 — 2026-10-12 (issue #30)
- [x] T32準備: ストアメタデータ確定値化(store_metadata/ja/6ファイル+alternatives.md)+verify_metadata.py+lien-ci.ymlにstore-metadataジョブ追加。Pairy終了済み・次の需要=1月新年需要という状況変化を反映しPairy依存語を排除。lien-ci run 38206570833でstore-metadataジョブ緑確認。issue #32はクローズせず継続(G4 #42の人間判断待ち)。 — 2026-10-12 (issue #32)
- [x] T20準備: 実機E2Eチェックリスト(docs/E2E-M1.md、12項目+ランブック+REQUIREMENTS §3.2〜3.9セルフ検証)+e2e_reset.sql(作成のみ・未実行)。セルフ検証で12項目はM1コアパスとしては十分だが§3.2〜3.9の全要件網羅ではないと判明(5件の既知ギャップを付録Aに明記)。lien-ci run 38207131557で緑確認。issue #20はクローズせず継続(実機2台でのE2E実施はG0/T08/#11-19 close後)。 — 2026-10-12 (issue #20)
- [x] T15: つつく+リアクション。バックエンド(functions nudge/react新設+messages.ts語彙拡張、deno test 188緑+lint/fmt clean、commit 8b49d50)+iOS(NudgeReactService.swift の NudgeSending/Reacting capability protocol+LocalEchoCheckinServiceへモック適合、HomeViewModelのcanNudge/canReact gating、HomeViewへNudgeArea/ReactionArea結線、NudgeSheet.swift のスタンプ選択UI、NudgeReactTests.swift 14件、commit 5552670)。lien-ci/lien-ios CI両緑(iOS 139テスト全緑)。関数は要件どおり未デプロイ(verify_jwt=falseのみconfig.tomlに追加)。実Supabase結線・checkinIdベースの実リアクション対象解決・返信記録(nudges.replied)はT16/後続統合タスクへ明示的に持ち越し。 — 2026-10-12 (issue #15)
- [x] (追記漏れの補完 — JOURNAL 2026-06-11 の記録に基づく)T08準備①: デプロイ自動化+G1 計測ハーネス(config.toml / deploy.sh / lien-deploy.yml / scripts/g1)。commit 20eacd5。 — 2026-06-11 (issue #8, close せず継続)
- [x] (補完)T10: オンボ3画面(supabase-swift・匿名認証・テスト13件)。commit 50eb461・lien-ios 緑。 — 2026-06-11 (issue #10)
- [x] (補完)T08準備②: AppDelegate+push トークン DEBUG 表示+aps-environment。commit 633125e・lien-ios 緑。 — 2026-06-11 (issue #8, close せず継続)
- [x] (補完)T11: 招待3導線+DeepLink+web/invite 静的ページ。commit 6eafd27・lien-ios 緑。 — 2026-06-11 (issue #11)
- [x] (補完)T12: 約束設定 UI+functions promise-set(本番デプロイ済み)。commit 8427dec・deno 153 緑・lien-ios 緑。 — 2026-06-11 (issue #12)
- [x] (補完)T13: ホーム画面+PlantSprite(AppIcon 修正 f01c1a4 込み)。commit 24bc37b・lien-ios 緑。 — 2026-06-11 (issue #13)
- [x] (補完)T14: チェックインフロー+オフラインキュー+写真+当日取消(migration 0002 は 2026-10-12 に本番適用 823ce18)。commit 4d90953・deno 157 緑・lien-ios 緑。 — 2026-06-12 (issue #14)
- [x] 残タスク洗い出し(Haiku×2・47件)+方針レビュー(Opus×2)+成長ルール v2 設計(docs/GROWTH.md)+植物 v4「タネの子」SVG レイヤー34点+アイコン案。ユーザー決定「全部推奨で」(D1〜D6)。commit 41b3668。 — 2026-10-12 (issue #40 / #50)
