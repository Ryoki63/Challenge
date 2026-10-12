---
name: status
description: プロジェクトの進捗レポートを出す。BACKLOG残数・完了タスク・直近のJOURNAL・git履歴・ブロック事項をまとめる。「進捗どう?」「状況教えて」と言われたら使う。
---

# /status — 進捗レポート

このリポジトリの現在地を、ユーザーが30秒で把握できる形でレポートします。

## 手順

1. 以下を並行して読む・実行する:
   - `tasks/BACKLOG.md`(残タスク数、`[>]` 実行中、`[!]` ブロックの有無)
   - `tasks/DONE.md`(直近の完了タスク)
   - `progress/JOURNAL.md`(直近2〜3エントリ)
   - `git log --oneline -10` と `git status --short`
   - `git fetch && git status -sb`(リモートとの差分: ahead/behind)
   - **本番 cron の確認**(下の「本番 cron の確認」。読み取りだけ)
2. 以下の構成でレポートする:
   - **一行サマリ** — 今どのフェーズで、順調か止まっているか
   - **ブロック事項**(`[!]` 行があれば最優先で表示し、ユーザーへの質問を明記)
   - **本番 cron**(緑 / 黄 / 赤 / 手元では未確認。赤なら原因と `products/lien/scripts/OPS.md` §2 の切り分けを添える)
   - **直近の完了**(2〜3件)
   - **次にループが処理するタスク**(BACKLOG先頭)
   - **GitHub同期状態**(push漏れ・未コミット変更があれば警告)
3. push漏れや未コミット変更を見つけたら、`/sync` の実行を提案する(勝手には実行しない)。

## 本番 cron の確認

本番の close-day(毎日 00:10 JST)と grant-tickets(毎月1日 00:05 JST)が動いているかを見る。
自動監視は毎朝 00:40 JST の GitHub Actions `lien-cron-watch`(失敗すると赤)。

1. 直近の自動監視(秘密は要らない):
   `GH_TOKEN=$(gh auth token --user Ryoki63) gh run list --repo Ryoki63/Challenge --workflow lien-cron-watch.yml --limit 3`
   - `success` = 緑、`failure` = 赤。赤なら `gh run view <id> --log-failed` で FAIL の行を読む
   - schedule の実行が直近 2 日に無ければ、それ自体を報告する(workflow が無効化された可能性)
2. 手元でも確認する(`.env` と deno があるとき。本番 DB を SELECT するだけ・秘密は表示されない):
   `set -a; source .env; set +a; bash products/lien/scripts/ops/check-cron.sh`
   - 出力は 1 検査 1 行(OK / WARN / FAIL)。FAIL があれば最優先で報告する。WARN は「保存期間(6 時間)を過ぎて応答が確認できない」など確認不能の注意
   - `.env` や deno が無ければこの手順は飛ばして「手元では未確認」と書く

## してはいけないこと

- タスクの実行や修正(レポートのみ)。cron の確認も読み取りだけで、`run-cron-fn.sh` などの書き込みを伴う手順は実行しない
- JOURNAL/DONE の編集
