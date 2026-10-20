# Android 版ドキュメント（Lien / APP-001）

Android 版の計画・依存関係・判断カードの入口。**iOS v1.0（2026-10-31 公開）と v1.1（11/12〜13 公開）が最優先**で、Android はそれを遅らせない範囲で進める。

## 読む順

1. [`PLAN-ANDROID.md`](PLAN-ANDROID.md) — 全体計画。逆算日程（A: 個人 + テスター募集 / B: 組織 + D-U-N-S）、テスター比較、コスト、リスク、出典
2. [`DEPENDENCIES-ANDROID.md`](DEPENDENCIES-ANDROID.md) — Issue #119〜#127 の依存関係・担当・期限・外部（人間）タスクを 1 枚にしたもの
3. 判断カード
   - [`decisions/DECISION-AND-001.yaml`](decisions/DECISION-AND-001.yaml) — **Play アカウント種別とテスター確保策**（A/B/C。推奨 B）
   - [`decisions/DECISION-AND-002.yaml`](decisions/DECISION-AND-002.yaml) — **Play 25 USD・D-U-N-S・検証端末の予算計上**（総損失上限 3 万円との整合）

## 現在の状態（2026-10-21 01:52 JST）

| 項目 | 状態 |
|---|---|
| 計画 | Issue #119 / PR #131 に提出済み。10/21 レビュー指摘（予算算術、iOS保護期間との日程衝突、G12日本指定リンク）を修正中 |
| アカウント種別 | **未決定（DECISION-AND-001 / 期限 2026-10-23 18:00）。PMO の推奨は B（組織 + 無料 D-U-N-S）** |
| 予算の計上 | **未決定（DECISION-AND-002 / 期限 2026-10-27 18:00）** |
| Play 登録・支払い・D-U-N-S 申請 | **未実施**（人間の承認後） |
| Android のコード | **未着手**（`products/lien/android/` はまだ無い） |
| 部署の起票 | #120 は `status:review`、#121/#123/#124 は `status:in-progress`、#122 は `status:waiting`（human-gate）、#125/#126 は `status:ready`、#127 はトラッカー |
| iOS への影響 | なし。Android のコードは 11/13 まで `main` に入れない |

## 決定の返し方

Issue #119 に、次のいずれかを返信する（秘密・認証情報・個人の連絡先は書かない）。

- `B` — 組織アカウント（D-U-N-S）。**PMO の推奨**。個人事業主は開業届で組織として本人確認できる。屋号・事業用住所/電話/ウェブサイトが必要。D-U-N-S は無料 30 営業日（10/23 申請で 12/8 頃）または 15,000 円で 7 営業日。公開は有料 D-U-N-S なら 2026-12-23 頃、無料の標準は 2027-01-07 頃、D&B 反映が最長なら 2027-03 頃
- `A` — 個人アカウント + テスター 15〜20 人。登録・支払い・本人確認は iOS 保護期間後の 11/1〜11/5、知人への個別依頼は 11/1 から始める。公開募集はしない。11/13 に 12 人の見込みがなければ B へ。公開目標 2027-01-06
- `C` — 保留（iOS v1.1 の後に再判断）
- 予算は `A` なら「広告 0・端末借用・無料 D-U-N-S」、`B` なら「上限増額（有料 D-U-N-S を含む）」、`C` なら「延期」を添える

判断カードの `status` は、決定後に `accepted` / `rejected` へ更新し、`decided_at` / `decided_by` / `decision` を記入する。このリポジトリのエージェントは、外部送信・支払い・ストア申請・D-U-N-S の申請を行わない。

## このフォルダで扱わないこと

- 要件の確定（#120）、技術選定の確定（#121）、画面の確定（#122）、テスト項目の確定（#123）
- ストア文言・スクショの確定（#125）
- 金額の最終確定（#126）。ここでは計画上の試算と矛盾の指摘まで
- 認証情報・署名鍵・サービスアカウントの値（一切書かない）

---

## 運用ドキュメント（Ops / #124）

Issue #124（ops-lead）で作成した、Google Play の登録・署名・CI・申告の文書。

| 文書 | 内容 | 主に使う人 |
|---|---|---|
| [PLAY-CONSOLE-SETUP.md](PLAY-CONSOLE-SETUP.md) | Play Console の登録手順。個人 / 組織の違い、本人確認、25 USD、12人×14日。オーナー用の30分1枚つき | オーナー / ops |
| [PLAY-SIGNING-AND-SECRETS.md](PLAY-SIGNING-AND-SECRETS.md) | Play App Signing、アップロード鍵、サービスアカウント、GitHub Secrets の名前、ローテーション、障害対応 | ops / eng |
| [PLAY-DATA-SAFETY.md](PLAY-DATA-SAFETY.md) | データセーフティ、コンテンツレーティング、対象年齢、広告 ID の回答表 | ops / product |

## 現在の状態（2026-10-21）

- Play Console の登録・支払い・本人確認は**人間が行う**。このリポジトリには認証情報・本人確認書類・カード番号を置かない。
- Android の実装（`products/lien/android/`）は #121 / draft PR #145 で追加予定。**未マージの間は `.github/workflows/lien-play.yml` の build / publish はスキップされる**（`detect` job）。
- `lien-play.yml` のアップロードは `workflow_dispatch` + `publish=true` + Environment `play-internal` の承認が必要。本番トラックにはアップロードしない。
- 申告表の未確定項目は [PLAY-DATA-SAFETY.md §6](PLAY-DATA-SAFETY.md#6-提出前の確認項目未確定は-null-のまま残す) に集約。**推測で埋めない。**

## 関連 Issue

- #119: 全体計画・12人×14日の突破策・組織アカウント可否
- #120: Android v1.0 の要件（課金・通報・権限の有無）
- #121: Android の技術選定・雛形・CI
- #123: QA 計画・端末マトリクス
- #124: 本書（登録・署名・CI・申告）
- #125: ストア掲載文・スクリーンショット
- #126: コスト・総損失上限
- #127: Android 全体トラッカー
