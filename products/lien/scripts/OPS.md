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
