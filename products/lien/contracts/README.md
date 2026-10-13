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
| `plant-name.ok.json` / `plant-name.already-named.json` | `POST /plant-name`(`plant-name/core.ts`)。最初に名前を付ける `{ name, snapshot }` / すでに名前がある鉢への first の 409 `{ error: "already_named", name }` | `PlantNameResponse` / `PlantNameConflictResponse`(→ `EdgeFunctionPlantNaming.interpret` と `PlantNameConflict`。`ContractFixtureTests`・`PlantNamingTests` が本番と同じデコーダで読む) |
| `pair-dissolve.ok.json` / `pair-dissolve.already.json` | `POST /pair-dissolve`(`pair-dissolve/core.ts`)。ペアを解消した `{ dissolved: true, snapshot }`(snapshot は解消後のソロの形)/ すでにペアが無かった冪等の応答 `{ dissolved: false, snapshot }` | `PairDissolveResponse` |
| `delete-account.ok.json` | `POST /delete-account`(`delete-account/core.ts`)。`{ deleted: true }` | `AccountDeleteResponse` |
| `push.visible.json` / `push.silent.json` / `push.pair-dissolved.json` | 相手へ送る APNs ペイロード(可視 / サイレント / ペアを解消されたときのサイレント。解消後のソロの snapshot 同梱)。`lien.snapshot` を NSE・アプリが読む | `AppGroupStore.saveSnapshotData` |
| `stamps.json` | `_shared/messages.ts` のスタンプ語彙(順序つき) | `NudgeStamp` / `ReactionStamp` |
| `errors.json` | 各 function の `core.ts` / `index.ts` が返しうる `{ "error": "<code>" }` と HTTP ステータス | `InviteClientError` ほか各エラーマップ |

エラーの本文はすべて `{ "error": "<code>" }`。`errors.json` はソースの文字列から機械的に拾った台帳で、
クライアントが専用 case にマップしたコードがサーバーに実在すること、サーバーに増えたコードをクライアントが
取りこぼしていないことを `ContractFixtureTests` が検査する。

## 手書きのフィクスチャ(PostgREST / Storage の応答)

上の表のフィクスチャは Edge Function の実ハンドラから作る。次の5つは、Edge Function ではなく **PostgREST と Storage の応答**
(相手の今日の写真をホームに出す経路 — PV #59)なので、`generate.ts` では作れず、**手書き**している。
中身は応答の本文そのもの(補足のキーは足さない。iOS は本番と同じデコーダで読む)。

| ファイル | 要求 | 応答 | iOS 側の受け口 |
|---|---|---|---|
| `partner-checkin.photo.json` | `GET {base}/rest/v1/checkins?select=id,photo_path&date_local=eq.<今日>&user_id=neq.<自分の user_id>&limit=1`(`apikey: <anon キー>` + `Authorization: Bearer <利用者の JWT>`) | 200 / 相手が今日、写真を添えた行(`photo_path` = 原寸のパス `pairs/<pair_id>/<date>/<user_id>/photo.jpg`) | `PartnerCheckinRow`(→ `PartnerCheckin`。`PostgRESTPartnerCheckinResolver`) |
| `partner-checkin.no-photo.json` | 同上 | 200 / 相手の行はあるが `photo_path` が `null`(写真なし) | 同上 |
| `partner-checkin.none.json` | 同上 | 200 / `[]`(相手がまだチェックインしていない・取消した・RLS で読めない = ペア解消後など) | 同上 |
| `storage-sign.ok.json` | `POST {base}/storage/v1/object/sign/photos/<photo_path または photo_thumb.jpg のパス>`(本文 `{"expiresIn": 3600}`。`apikey` + `Authorization: Bearer <利用者の JWT>`) | 200 / `{ "signedURL": "/object/sign/photos/<path>?token=<署名>" }`(ルート相対。`{base}/storage/v1` を前に付けて取りに行く)。token は目印の文字列(実物の署名ではない) | `StorageSignResponse`(→ `StoragePhotoURLSigner`) |
| `storage-sign.not-found.json` | 同上(ペア外のユーザー・存在しないオブジェクト・未ログイン) | **HTTP 400**(404 ではない)/ 本文 `{ "statusCode": "404", "error": "not_found", "message": "Object not found" }` | `StoragePhotoURLSigner.isNotFoundBody`(→ `PartnerPhotoError.notFound`) |

- 署名付き URL の取得は `GET {base}/storage/v1/object/sign/photos/<path>?token=<署名>`(認証ヘッダなし)。200 は `image/jpeg` の本文。
  署名の寿命切れ・改ざんは **HTTP 400** `{"statusCode":"400","error":"InvalidJWT","message":"\"exp\" claim timestamp check failed"}`
  (アプリは 400 / 401 / 403 を「失効」として署名からやり直し、404 は「無い」として扱う)
- **本番の実応答との突き合わせは済み**(2026-10-13、backend レーンの API E2E #67。`scripts/OPS.md` §12): 上の4つの形(キー・型)は本番と一致した。
  ペアの相手は `photo_path` を読んで署名付き URL を作れ、ペア外・未ログインは作れない(RLS の実挙動)。
  署名の**発行**の失敗は HTTP 404 でなく **400**と分かったので、アプリは「400 で本文が not_found」を `notFound` に写す(`StoragePhotoURLSigner`)。
  どちらでも結果は同じ(写真を出さない・サムネが無いときは原寸で代わりを作る)。`storage-sign.not-found.json` は #67 の観測記録から
  `statusCode` / `error` / `message` を写したもので、本文にほかのキーがあっても、アプリは `statusCode` と `error` だけを読む。
  ずれが見つかったら、この表とフィクスチャ、`PartnerPhotoContractTests` を実応答に合わせる
- `contracts_test.ts` の `HAND_WRITTEN` が、この5つを「生成物ではない JSON」として認める一覧。足したら表と両方を直す
- 署名付き URL の寿命は `StoragePhotoURLSigner.expiresInSeconds`(3600 秒)。Storage の応答に寿命は含まれないので、アプリは要求した値から期限を数える

## 再生成と検査

上の表のフィクスチャ(生成物)は手で編集しない。サーバーの応答形(`_shared/snapshot.ts` など)を変えたら再生成する:

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
- お休みチケットの残数(#19、2026-10-13)で snapshot に `ticketBalance` が足された(ペア共有の残数 = `pairs.ticket_balance`。
  0 以上の整数・0 枚は `0`。**ソロは `null`**(キーは省略せず `null` で出す)。DESIGN §3.4)。フィクスチャの値: ペアのもの
  (`snapshot.paired.json` ほか)は `2`(無料プランの月次付与のまま。`invite-accept.ok.json` は初期付与の 2 枚)、
  ソロのもの(`snapshot.solo.json` / `snapshot.empty.json` / `pair-dissolve.*.json` / `push.pair-dissolved.json`)は `null`。
  iOS の `PairSnapshot` が省略可(`Int?`。キーが無い古いサーバーも `null` も nil)で受けるようになったら、
  `ContractFixtureTests` で値まで検査する(今は未知のキーとして無視される)。
- 写真の実体の削除(#68、2026-10-13): `checkin-cancel` は応答の形を変えずに、取消のとき Storage の写真(原寸 + サムネ)も消す。
  取消のあと、その写真の署名付き URL は作れない(HTTP 400 `{"statusCode":"404","error":"not_found"}` = `storage-sign.not-found.json`)。
  署名付きアップロードは、上限 6 MiB・`image/jpeg` だけ(超えると **HTTP 400** + 本文の `statusCode` 413 / 415)。DESIGN §5.2
- 認証サーバー(Supabase Auth)の不調(通信の失敗・5xx)は、`snapshot` / `pair-dissolve` / `delete-account` が **503 `auth_unavailable`** で返す
  (確定した拒否 = 期限切れ・ユーザーが居ない、は 401 `unauthorized` のまま。`_shared/auth_errors.ts`)。iOS はこのコードを専用の case にせず、
  一般のサーバー失敗(`.server`)として扱う — セッションの見張り(`SessionHealthMonitor`)が数えないため、「ログイン状態を確認できません」の誤検知にならない
- 前方互換: サーバーが snapshot に未知のキーを足しても、古いアプリは無視して動く
  (`ContractFixtureTests.testSnapshotDecodingToleratesNewServerKeys`)。キーの**削除・型変更・改名**は
  互換性を壊すので、DESIGN §9-7 に従い JOURNAL に互換性影響を明記する。
- `deno test`(`lien-ci` の `products/lien/supabase/functions` 配下)は、この `tools/` を含まない。
  そのため `lien-ci` の `deno-test` ジョブに、上の `--check` と `deno test --allow-read products/lien/contracts/tools/`
  を別の step として組み込んである(2026-10-12・#54 のレビュー指摘)。サーバーの応答形を変えて再生成を忘れると
  CI が落ちる。手元でも、サーバーを変更したら先に走らせておく。
