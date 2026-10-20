# Lien Android — 運用ドキュメント

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
