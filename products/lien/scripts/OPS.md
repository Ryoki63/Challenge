# 運用手順(OPS)— 本番 Supabase の定期ジョブ

対象: `products/lien/supabase/migrations/0003_cron.sql` で登録した cron ジョブ(issue #51 / docs/GROWTH.md §7.1)。
G0〜G1 の人間作業は [g1/RUNBOOK.md](g1/RUNBOOK.md)。本書は「公開後も続く運用」の手順。

## 1. 何がどう動いているか

| ジョブ | スケジュール(pg_cron は UTC) | JST | 呼び先 | 補足 |
|---|---|---|---|---|
| `lien-close-day` | `10 15 * * *` | 毎日 00:10 | `POST /functions/v1/close-day` | 前日(JST)を確定する。再実行しても結果は同じ |
| `lien-grant-tickets` | `5 15 * * *` | 毎月1日 00:05 | `POST /functions/v1/grant-tickets` | 毎日起動するが、**JST の日付が1日の日だけ**呼ぶ。それ以外の日は何も呼ばない |

- 仕組み: pg_cron が SQL を実行 → `net.http_post`(pg_net)が Edge Function を**非同期**で呼ぶ
- 認証: `Authorization: Bearer <Vault の lien_service_role_key>`。Function 側は `SUPABASE_SERVICE_ROLE_KEY` との**完全一致**で認証する(close-day / grant-tickets の `index.ts`)
- 鍵はジョブの SQL に書いていない。実行のたびに Vault から引く
- 時刻: 00:05 に grant-tickets(付与)→ 00:10 に close-day(確定)の順。月初は付与が先に入る
- 設定値(本番で確認): `cron.timezone = GMT` / `pg_net.ttl = 6 hours`(HTTP 応答の保存期間)/ pg_cron 1.6.4 / pg_net 0.20.3

### 鍵(重要)

**Function が見る `SUPABASE_SERVICE_ROLE_KEY` は、このプロジェクトでは default の secret key(`sb_secret_...`)で、legacy の `service_role`(`eyJ...`)ではない。**
2026-10-12 に実測した: legacy キーで close-day を呼ぶと 401、`sb_secret_...` だと 200。

- Vault の `lien_service_role_key` には `sb_secret_...` を入れてある
- `.env.keys` の `SUPABASE_SERVICE_ROLE_KEY`(legacy)は PostgREST などでは使えるが、**cron の Bearer には使えない**
- 取得方法: Management API `GET /v1/projects/<ref>/api-keys?reveal=true` の `type = secret`。値は画面に出さず変数で使う(§6 と [ops/run-cron-fn.sh](ops/run-cron-fn.sh) が実装済み)

## 2. 見るべきもの(週1回の /status で十分。公開後は毎朝)

運用用のスクリプト:

```bash
set -a; source .env; set +a   # SUPABASE_ACCESS_TOKEN を環境変数に読む(値は表示されない)
bash products/lien/scripts/ops/db-query.sh "<SQL>"
```

(Dashboard の SQL Editor に貼っても同じ。)

**(a) ジョブが登録され、有効か**

```sql
select jobid, jobname, schedule, active from cron.job order by jobname;
-- 期待: lien-close-day / lien-grant-tickets の2行、active = true
```

**(b) 直近の起動(pg_cron が SQL を実行できたか)**

```sql
select j.jobname, d.status, d.return_message,
       (d.start_time at time zone 'Asia/Tokyo')::timestamp(0) as start_jst
from cron.job_run_details d join cron.job j using (jobid)
order by d.start_time desc limit 10;
```

| ジョブ | 正常 | 読み方 |
|---|---|---|
| lien-close-day | `succeeded` / `1 row` | 毎日 00:10 JST に1行 |
| lien-grant-tickets | `succeeded` / `0 rows`(毎月1日だけ `1 row`) | 1日以外は呼ばないので `0 rows` が正常 |

- `succeeded` は「リクエストを積めた」だけ。**Function が成功したかは (c) で見る**
- `failed` のときは `return_message` に SQL のエラーが出る(Vault の権限・拡張など)

**(c) HTTP の結果(Function が成功したか)**

```sql
select id, status_code, timed_out, error_msg,
       (created at time zone 'Asia/Tokyo')::timestamp(0) as created_jst,
       left(content, 300) as content
from net._http_response order by id desc limit 10;
```

- 正常: `status_code = 200` かつ `content` の `"errors":[]`。close-day は `{"dateLocal":"2026-10-11","pairs":2,"recordedBoth":0,"recordedTicket":0,"reset":0,"skipped":2,"errors":[]}` の形
- **応答は6時間で消える**(`pg_net.ttl`)。00:10 JST の結果は 06:10 JST までしか見えない。朝に見るなら (b) と、DB の中身(`streak_days` の最新日)で補う:

```sql
select max(date_local) as latest_closed from streak_days;  -- 両者達成かチケットの日がある場合
```

### 失敗の切り分け

| 症状 | 原因 | 対処 |
|---|---|---|
| (b) に行が増えない | プロジェクトが停止している(無料枠の自動停止)/ ジョブが無効 | Dashboard で復元 → §4 で取りこぼしを再実行。ジョブが無ければ `0003_cron.sql` の `cron.schedule` を再実行 |
| (b) が `failed` | SQL のエラー | `return_message` を読む。Vault や拡張の権限・削除を疑う |
| (c) が `401` `{"error":"unauthorized"}` | Vault の鍵が Function の `SUPABASE_SERVICE_ROLE_KEY` と違う(鍵を作り直した / Vault に無い) | §6 で Vault を更新し、§4 で取りこぼしを再実行 |
| (c) が `200` だが `errors` が空でない | 一部のペアの処理失敗(ペア単位で隔離される) | `supabase functions logs close-day --project-ref lniheehfbtpfhglinfjm` で該当ペアを確認 |
| (c) が `500` | Function の内部エラー | 同上。直ったら §4 で再実行 |
| (c) が `timed_out = true` / `error_msg` あり | 60秒超過・ネットワーク | §4 で再実行。頻発するならペア数の増加を疑う(timeout は `0003_cron.sql` の `timeout_milliseconds`) |

## 3. 登録内容を変えたいとき

ジョブの追加・変更・停止は migration として書く(`cron.schedule` は同名ジョブがあれば更新する)。
本番に手で流すときは `db-query.sh -f` でよいが、**必ず migration と `supabase_migrations.schema_migrations` を揃える**。

```sql
select cron.unschedule('lien-close-day');                    -- 削除
select cron.alter_job((select jobid from cron.job where jobname = 'lien-close-day'), active := false);  -- 一時停止
```

## 4. 取りこぼしの再実行

cron が動かなかった日(自動停止・障害・鍵の不一致)を埋める。**close-day は冪等**(確定済みの日は `skipped`)なので、範囲は広めでよい。

```bash
set -a; source .env; set +a
# 古い日から新しい日の順に実行される(ストリーク・チケットの判定が前日に依存するため)
bash products/lien/scripts/ops/run-cron-fn.sh close-day 2026-10-01 2026-10-11    # 範囲(両端を含む)
bash products/lien/scripts/ops/run-cron-fn.sh close-day 2026-10-11               # 1日だけ
```

- 日付は JST の `date_local`。取りこぼした最初の日から「昨日」まで
- 実行すると、その日に確定すべき通知(チケット消費・リセットの責めない文言)が**遅れて**送られる
- スクリプトは鍵を Management API から引き、画面に出さない。401 になる鍵は自動で飛ばす

**grant-tickets の取りこぼし**(めったに無い)

- 月の途中に動かすと、上限に達していたペアはチケットを使った後に再付与される(冪等キーの ledger 行が残らないため)
- **その月の付与を丸ごと取りこぼした**と確認できたときだけ、月の1日の日付で実行する:

```bash
CONFIRM_GRANT=yes bash products/lien/scripts/ops/run-cron-fn.sh grant-tickets 2026-11-01
```

- 付与済みかは `ticket_ledger` の `reason = 'monthly'` で見る(上限のペアは行が残らない)。1日の朝に (c) の応答が残っていればそれが確実

## 5. 自動停止(無料枠)

- 無料枠はしばらくアクセスが無いと自動で停止する。2026-10-12 に実際に 4か月の放置で `INACTIVE` だった
- 停止中は cron も動かない。復元後は §4 で止まっていた期間を埋める
- 恒久対策は D5(リリース前に Pro 化。〜12/1)。それまでは週1回 §2 を見る

## 6. 鍵の更新(Vault)

Function の `SUPABASE_SERVICE_ROLE_KEY` が変わったとき(secret key の作り直し・legacy キーの無効化など)は、Vault を同じ値に合わせる。**値は画面に出さない。**

```bash
set -a; source .env; set +a
python3 - << 'PY'
import json, os, urllib.request
H = {"Authorization": "Bearer " + os.environ["SUPABASE_ACCESS_TOKEN"], "Content-Type": "application/json", "User-Agent": "lien-agent/1.0"}
ref = "lniheehfbtpfhglinfjm"
def call(path, body=None):
    req = urllib.request.Request("https://api.supabase.com" + path, headers=H, method="POST" if body else "GET",
                                 data=json.dumps(body).encode() if body else None)
    return json.load(urllib.request.urlopen(req))
keys = call(f"/v1/projects/{ref}/api-keys?reveal=true")
secret = next(k["api_key"] for k in keys if k.get("type") == "secret" and k.get("name") == "default")
sql = ("select vault.update_secret(id, '%s') from vault.secrets where name = 'lien_service_role_key'"
       % secret.replace("'", "''"))
print(call(f"/v1/projects/{ref}/database/query", {"query": sql}))
PY
```

- 更新後に `bash products/lien/scripts/ops/run-cron-fn.sh close-day <昨日>` で 200 を確認する(冪等)
- Vault の中身を確認するときは、値そのものではなく長さと先頭だけを見る:
  `select length(decrypted_secret), left(decrypted_secret, 10) from vault.decrypted_secrets where name = 'lien_service_role_key'`(`41` / `sb_secret_`)

## 7. 適用記録

| 日時(JST) | 内容 |
|---|---|
| 2026-10-12 18:28 | migration 0003 を本番に適用。pg_cron 1.6.4 / pg_net 0.20.3 を導入、2ジョブを登録。Vault に `lien_service_role_key`(`sb_secret_...`)を登録 |
| 2026-10-12 18:29 | 検証: ジョブの SQL を手で実行 → 200。一時ジョブ(毎分)で pg_cron の実行 → `succeeded` / 200 を確認し、一時ジョブは削除。初回の close-day(2026-10-11)で test ペア2組が確定(チケット消費) |
| 2026-10-12 22:04 | issue #54 のレビュー修正を本番へ: snapshot を使う Edge Functions 9 本を再デプロイ(checkin v6 / checkin-cancel v3 / close-day v3 / invite-accept v3 / nudge v2 / plant-name v2 / promise-set v3 / react v2 / snapshot v3。verify_jwt はすべて false のまま)。migration の追加なし。内容は react の push を最初の1回だけに・昨日の仮判定を close-day の確定前の窓(0:00〜1:00)だけに・リクエスト本文 `null` を 400 に・plant-name の書式文字の拒否 |
| 2026-10-13 00:10 | **初回の定期実行**(pg_cron → close-day v3)。2026-10-12 を確定: `pairs 6 / recordedBoth 2 / recordedTicket 4 / reset 0 / skipped 0 / errors []`(HTTP 200)。P1(`d38fda60-…`)は both が記録され `plants.grown_days = 1`・`stage = 0` のまま(stage は書かない設計どおり)。grant-tickets(00:05)は 1日ではないので `0 rows` |

## 8. 本番のテストデータ(台帳)

本番 DB に残っている**テストデータ**の一覧(2026-10-13 時点で users 19 人・pairs 8 組。**実ユーザーはまだ 1 人もいない**)。公開前(審査提出の前)に削除する候補で、**KPI の SQL からは必ず除く**(D6: 計測は SDK でなく DB から SQL で出す)。審査用デモのペア(T30。開発者が操作する相手役)は、これとは別に作って区別する。新しくテストデータを作ったら、この表と下の SQL のリストに足す。

| ペア | 作成(JST) | users | 出所・状態 |
|---|---|---|---|
| `20aeea77-e43a-47d1-8d6f-1ab2369bcdd4` | 06-11 22:19 | `5f5eff69-d8df-4b27-8a01-d7ef07f9a40e` / `759bf2ed-bc2f-44fb-a05f-a45dae4f6bb5`(テストA/B) | 6/11 の T08・T14 のスモーク(seed-pair.sh)。close-day で `ticket` の日が入った |
| `2b31bfe7-5909-4b50-b907-d9c4a5391255` | 06-11 22:19 | `2145bf47-6603-47fb-8993-cfbbde21b09e` / `02545907-b191-43ea-aed4-7a59480772c9`(テストA/B) | 同上 |
| `b75034ba-ba42-4d28-b5b7-29052433a245` | 10-12 13:51 | `dd913492-263b-4e5e-8a0e-0c72e2c46897` / `922ff8a7-72e2-41c8-8bf7-493693b2c4c6`(テストA/B) | 10/12 の migration 0002 の本番適用後の写真経路スモーク |
| `4c58a2a5-a440-4919-8f16-5ee1cdb848ee` | 10-12 18:38 | `934df380-cc5c-440e-8e75-ab9f711866a3` / `6b579485-8dee-4662-b3b3-9826ed5128cc`(テストA/B) | #52 写真パスのスモーク。**Storage に `pairs/4c58a2a5-…/` 以下の写真オブジェクトあり**(削除のとき一緒に消す) |
| P1 `d38fda60-4dda-442a-91a8-dd102e48c7ff` | 10-12 19:27 | `86687f8b-df69-4a2d-8610-00d52259af9f` / `3e68ed74-0190-4a70-84f5-cb254c6a9070`(テスト54A/B)+ ペアなしの `2b4667a8-b2bd-4650-b531-d5fb3589912b`(ニックネーム空) | #54 の本番スモーク(通常フロー)。植物の名前は「さくら」 |
| P2 `09bb294c-d3a0-4962-aab7-d1c5c9d60af4` | 10-12 19:28 | `ce6f1f22-1218-4e6a-9a16-a7007052e1f6` / `8d56ea14-5cf0-449c-90f0-5c1116a3fe90`(テスト54C/D) | #54 の本番スモーク(整形用)。`started_on` を 2026-04-01 にずらし、4月に both を 30 行(〜5/1)SQL で入れた |
| P3 `c33b5d9c-9788-4529-b608-a607036fdf30` | 10-13 00:36 | `be4c372d-0f32-4c8f-9183-2ee7b6abe342` / `e8adc43d-61c3-4ae1-b238-ab505158d483`(テスト54E/F) | #54 のレビュー修正スモーク(昨日の仮判定の窓)。`started_on` を 10-12 にずらし、10-12 付けの checkin を SQL で入れた |
| P4 `7ef8edd2-7890-4726-ba39-b781ddcfce6e` | 10-13 00:37 | `46797561-77a7-4bfe-b588-e9b5a3bae11b` / `4d2131ea-644f-4850-b1ac-a510b8fcaa0f`(テスト54G/H) | 同上(react の最初の1回だけ push・遅れた checkin) |
| (ペアなし) | 10-13 00:06 | `662e804a-6988-4d2b-9295-e55d53a44f6d`(テスト54E・約束あり)/ `079bfe55-70fd-4f16-b790-359cdb6aa037`(テスト54F) | 同じスモークの1回目が通信のタイムアウトで途中終了した残り |

### KPI の SQL から除く

```sql
-- KPI の SQL の先頭に付ける。テストデータの users.id を除く(上の表のとおり。増やしたらここにも足す)
with test_users(id) as (values
  ('5f5eff69-d8df-4b27-8a01-d7ef07f9a40e'::uuid), ('759bf2ed-bc2f-44fb-a05f-a45dae4f6bb5'),
  ('2145bf47-6603-47fb-8993-cfbbde21b09e'), ('02545907-b191-43ea-aed4-7a59480772c9'),
  ('dd913492-263b-4e5e-8a0e-0c72e2c46897'), ('922ff8a7-72e2-41c8-8bf7-493693b2c4c6'),
  ('934df380-cc5c-440e-8e75-ab9f711866a3'), ('6b579485-8dee-4662-b3b3-9826ed5128cc'),
  ('86687f8b-df69-4a2d-8610-00d52259af9f'), ('3e68ed74-0190-4a70-84f5-cb254c6a9070'), ('2b4667a8-b2bd-4650-b531-d5fb3589912b'),
  ('ce6f1f22-1218-4e6a-9a16-a7007052e1f6'), ('8d56ea14-5cf0-449c-90f0-5c1116a3fe90'),
  ('be4c372d-0f32-4c8f-9183-2ee7b6abe342'), ('e8adc43d-61c3-4ae1-b238-ab505158d483'),
  ('46797561-77a7-4bfe-b588-e9b5a3bae11b'), ('4d2131ea-644f-4850-b1ac-a510b8fcaa0f'),
  ('662e804a-6988-4d2b-9295-e55d53a44f6d'), ('079bfe55-70fd-4f16-b790-359cdb6aa037')
)
select count(*) from users u where u.id not in (select id from test_users);   -- 実ユーザー数(いまは 0)
-- ペア・チェックインなどは user_id / pair_members 経由で同じリストを使って除く
```

- ニックネームでは除かない(P1 のペアなしユーザーのように空のものがある)。実ユーザーの受け入れ開始日(G3)が決まったら、`created_at >= その日` に置き換えてもよい
- **削除は人間が決めてから**(公開前の一括)。`auth.users` を消すと `public.users` 以下は CASCADE で消える範囲を確認してから行い、Storage の `pairs/<pair_id>/` も消す。実行前に対象の ID を表と突き合わせる

### 10/13 朝の確認(初回の本番 close-day)で驚かない値

- **見るのは P1**(`d38fda60-…`): 10/12 に両者チェックイン → 10/13 00:10 に `both` が記録され、`plants.grown_days = 1`・`stage = 0` のまま(stage は書かない)。**確認済み**(§7 の記録)
- **P2 の値は気にしなくてよい**(`09bb294c-…`): 4月の both 30 行は SQL で入れた整形用。10/11 の両者チェックインに `streak_days` の行が無い(10/11 の close-day は P2 を作る前の 18:29 に動いたため)。昨日の仮判定は窓(0:00〜1:00)の外では行だけを信じるので、P2 の表示は 30 回・ストリーク 0 のまま(窓が無かった以前の実装は 10/12 の間ずっと 31 回と出し、10/13 に 30 へ下がる動きだった)。10/13 の close-day は 10/12 を確定しただけで、10/11 は埋まっていない
- 10/13 00:10 の対象は `started_on <= 10/12` の active なペア全部(6 組)。チケットの消費が走ったが、push_token を持つユーザーはいないので通知は出ていない
- 10/11 を手動で確定すると(`run-cron-fn.sh close-day 2026-10-11`)、`started_on <= 10/11` のテストペア(6/11 の 2 組と P2)にもチケット消費やリセットが走る。P2 の 10/11 だけを埋めたいときは、先に対象のペアを確認してから行う
