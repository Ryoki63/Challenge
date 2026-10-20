# Issue #50 — 文書整合の受入・証跡・レビュー

確認日: 2026-10-21 JST。対象は `docs/TASKPLAN.md`、補助キュー `tasks/BACKLOG.md` の Xcode・テスター募集2行、本記録と `progress/JOURNAL.md` の末尾追記のみ。コード・workflow・確定仕様・日程・既存担当を変更しない。

## 契約と担当

- 正本: [Issue #50 本文](https://github.com/Ryoki63/Challenge/issues/50)冒頭の今回の受入条件。eng-lead 確認担当が、[オーナーの A 承認](https://github.com/Ryoki63/Challenge/issues/50#issuecomment-6297755228)を新仕様なしで具体化した。旧 Wave 本文は変更せず、過去計画の見出しで分離した。
- eng-exec の認証 login は `Ryoki63`。#50 の assignee を同アカウント1件に設定・再取得してから計画文書の編集を開始。他 Issue の割当・ラベルは変更しない。
- 独立レビュー担当: eng-lead 確認担当 `01a15a8c-7dd5-7c81-a42f-3271e93cc91b`。受入条件確認と変更文書のレビューを1人に集約する。独立レビューの結果は受領後に末尾へ追記する。

| 本文の受入条件 | 対応箇所・確認内容 |
|---|---|
| ローカル Xcode を着手条件にしない、#28 に一本化、重複新設しない | TASKPLAN 冒頭・§9.6・§9.7、BACKLOG の人間作業2行。既存 `lien-ios.yml` / `lien-release.yml` / RELEASE-RUNBOOK を参照するだけ |
| 10/24 凍結・10/27 提出・10/31 公開、外部テスト省略、既存責務維持 | §9.2 の日程は無変更、§9.7 に絶対日付で再掲。#28/#20/#41/#105/#106 の割当・役割を読み取りのみ確認 |
| QA と実機・継続利用評価を分離、証跡と未検証を明記 | §9.7 の対象・既存担当・証跡・未検証範囲の表。G3 省略は達成ではない |
| 提案承認済と残件を区別、承認を配布や実機完了としない | §9.6 の未決2点を承認済へ置換、§9.7 で手順書マージ／無署名成功／署名・配布未検証を分離 |

## 直接照合した出典

- #50 の [10/12 提案](https://github.com/Ryoki63/Challenge/issues/50#issuecomment-6121738212)と [10/20 承認](https://github.com/Ryoki63/Challenge/issues/50#issuecomment-6288022165)。今回の範囲確定は UTC 2026-10-20T18:07:42Z = JST 2026-10-21 03:07:42。日付の違いは時差であり、10/20 の別コメントと混同しない。
- #28 の [T28準備完了](https://github.com/Ryoki63/Challenge/issues/28#issuecomment-6129880340)。`gh run view` で lien-ios run `38287644360` と lien-release run `38287659337` がともに SHA `d3b6499ce53f2dc1620338740b6c8e2e05e842c6` / success であることを再取得。後者はコメント上の無署名 archive であり、署名・配布成功の証拠には用いない。
- #129 / #128 は `gh pr view` で MERGED を確認。同期した main `7991bc5` 上の RELEASE-RUNBOOK.md / E2E-M1.md を照合。#105 / #106 の Issue は open のため、文書の存在とタスク全体の完了を分離する。#106 の過去レビュー末尾の「PR未マージ」は当時の記録で、現在のPR状態を上書きしない。
- #28 / #20 / #41 は assignee 未設定、#105 は role:qa-lead / Ryoki63、#106 は role:eng-lead / Ryoki63。#41 は human-gate・open。参照時点の状態として記録し、担当を推測して補充しない。

## 検証の適用範囲

- 文書のみの変更。ローカルリンク、Markdown の表・フェンス、JOURNAL の追記限定、変更ファイル範囲、差分検査、表示と出典照合を行う。実行結果は確認後に末尾へ追記する。
- アプリの単体テスト・型チェック・lint・ローカル iOS build・release build・実機 QA は対象外。push 起動の通常 CI は今回の提出 SHA に対する別の検証として記録する。
- Secrets・`.env` の読み書き、署名・配布・招待・本番操作、main への直接 push、マージ、Issue close は行わない。

## 直接・機械検査結果

- `PYTHONDONTWRITEBYTECODE=1 python3 build/plan-50/verify_docs.py` → PASS。変更4ファイル限定、JOURNAL が同期後 HEAD の全バイトを保つ追記のみ、§9.2 無変更、ローカルリンク実在、表の列数・フェンス、秘密値形式不在、#50 open・単独担当、関連5 Issue の assignee 不変を検査。スクリプトと一時プレビューは無視対象 `build/plan-50/` にだけ保存する。
- `gh run view 38287659337 --repo Ryoki63/Challenge --json jobs` → unsigned archive success / signed archive skipped / export and upload skipped。配布成功ではないことをステップ単位でも確認した。
- Chrome headless と Playwright(Python)でローカル HTML に描画し、外部リクエストを遮断して目視確認。TASKPLAN §9.7 の表は7行、レビュー対応表は5行、いずれも横 overflow・空リンク0。`build/plan-50/plan.png` / `review.png` を確認。初回の表示検査コマンドは転記時の余分な `+` で SyntaxError、修正後の1回で成功。生成物はコミットしない。
- `git diff HEAD --check` → PASS。アプリテスト・型チェック・lint・ローカル／配布 build は文書限定なので対象外。実機・配布成功を確認したとは報告しない。

## 独立レビュー結果

eng-lead 確認担当による独立レビュー1回は **PASS（受入条件4点すべてPASS、must-fix 0件、未解決指摘なし）**。Issue 本文との照合、未追跡の本記録全文、既存 workflow とローカルリンク、JOURNAL の upstream 本文完全保持まで確認した。BACKLOG の2行整合も既承認 A の範囲内と判定。追加の全体レビューは行わない。

提出前ゲート: 全要件の文書反映・出典照合・表示・差分・独立レビュー PASS。今回範囲の残 TODO は0。通常 CI と PR の提出状態は push 後の提出 SHA で確認し、PR／Issue に記録する。過去のビルド成功やこの文書レビューを、提出 SHA の CI 全緑とは扱わない。
