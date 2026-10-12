# contracts — iOS ⇔ サーバーの契約フィクスチャ

サーバー(`supabase/functions`)の**実ハンドラ**を固定入力で走らせて得た応答 JSON を置く場所。
iOS は同じ JSON を `LienTests` のリソースとして読み、アプリが本番で使うデコーダ・モデル・エラーマップで
そのまま復元できることをテストする(`ios/LienTests/ContractFixtureTests.swift`)。

> 目的: 「CI は緑なのに実機で通らない」を防ぐ(docs/REVIEW-2026-10-12.md §2・§4.1)。
> サーバーとアプリが別々に正しくても、応答の形やエラー文字列がずれると本番では動かない。

## ファイル

| ファイル | 元になるサーバー処理 | iOS 側の受け口 |
|---|---|---|
| `snapshot.paired.json` / `snapshot.solo.json` / `snapshot.empty.json` | `GET /snapshot`(`snapshot/core.ts`)。ペア成立 / ソロ / 約束もペアもない新規ユーザー | `SnapshotResponse` |
| `checkin.paired.json` / `checkin.solo.json` | `POST /checkin`(`checkin/core.ts`)。ふたり達成 / ソロ(写真なし) | `CheckinResponse` |
| `checkin.photo-upload.json` | 同上(`requestPhotoUpload: true`)。署名付きアップロード URL(原寸+サムネ) | `CheckinResponse.photoUpload` |
| `checkin-cancel.ok.json` | `POST /checkin-cancel` | `CheckinCancelResponse` |
| `promise-set.ok.json` | `POST /promise-set` | `PromiseSetResponse` |
| `invite-create.ok.json` / `invite-accept.ok.json` | `POST /invite-create` / `/invite-accept` | `InviteCreateResponse` / `InviteAcceptResponse` |
| `nudge.ok.json` / `react.ok.json` | `POST /nudge` / `/react` | `NudgeResponse` / `ReactResponse` |
| `plant-name.ok.json` / `plant-name.already-named.json` | `POST /plant-name`(`plant-name/core.ts`)。最初に名前を付ける `{ name, snapshot }` / すでに名前がある鉢への first の 409 `{ error: "already_named", name }` | (iOS 側は未実装 — 植物 v2-b の PlantNaming の Live 結線で追加。#57) |
| `push.visible.json` / `push.silent.json` | 相手へ送る APNs ペイロード(可視 / サイレント)。`lien.snapshot` を NSE・アプリが読む | `AppGroupStore.saveSnapshotData` |
| `stamps.json` | `_shared/messages.ts` のスタンプ語彙(順序つき) | `NudgeStamp` / `ReactionStamp` |
| `errors.json` | 各 function の `core.ts` / `index.ts` が返しうる `{ "error": "<code>" }` と HTTP ステータス | `InviteClientError` ほか各エラーマップ |

エラーの本文はすべて `{ "error": "<code>" }`。`errors.json` はソースの文字列から機械的に拾った台帳で、
クライアントが専用 case にマップしたコードがサーバーに実在すること、サーバーに増えたコードをクライアントが
取りこぼしていないことを `ContractFixtureTests` が検査する。

## 再生成と検査

JSON は手で編集しない。サーバーの応答形(`_shared/snapshot.ts` など)を変えたら再生成する:

```sh
# 再生成(リポジトリルートから)
deno run --allow-read --allow-write products/lien/contracts/tools/generate.ts

# 生成結果とコミット済み JSON が一致するか(差分があれば exit 1)
deno run --allow-read products/lien/contracts/tools/generate.ts --check
deno test --allow-read products/lien/contracts/tools/
```

入力(時刻 2026-06-11T08:30:00Z・UUID・招待 token)はすべて固定なので、同じサーバーコードからは常に同じバイト列になる。
差分が出たら**レビューしてから**コミットし、`ContractFixtureTests` が通る(= iOS のデコードが追従している)ことを確認する。

## 運用上の注意

- `lien-ios` ワークフローは `products/lien/contracts/**` の変更でも起動する(フィクスチャは `LienTests` のリソース)。
- 成長ルール v2(#54)で snapshot に `plantGrownDays` / `plantStageFloor` / `plantNextStageAt` の3キーが足された
  (ソロは 0 / 0 / null。最後の段階も `plantNextStageAt` は null。DESIGN §3.4)。iOS の `PairSnapshot` が
  これらを省略可で受けるようになったら(#56・#57)、`ContractFixtureTests` で値まで検査する。
- 前方互換: サーバーが snapshot に未知のキーを足しても、古いアプリは無視して動く
  (`ContractFixtureTests.testSnapshotDecodingToleratesNewServerKeys`)。キーの**削除・型変更・改名**は
  互換性を壊すので、DESIGN §9-7 に従い JOURNAL に互換性影響を明記する。
- `deno test`(`lien-ci` の `products/lien/supabase/functions` 配下)は、この `tools/` を含まない。
  サーバーを変更するときは上の `--check` を手元で走らせる(CI への組み込みは backend レーンの判断)。
