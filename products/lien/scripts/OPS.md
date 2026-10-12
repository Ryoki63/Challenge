# 運用手順(OPS)— 本番 Supabase の定期ジョブ

対象: `products/lien/supabase/migrations/0003_cron.sql` で登録し、`0007_cron_secret.sql` で認証を cron 専用シークレットに替えた cron ジョブ(issue #51・#60 / docs/GROWTH.md §7.1)。
G0〜G1 の人間作業は [g1/RUNBOOK.md](g1/RUNBOOK.md)。本書は「公開後も続く運用」の手順。

## 1. 何がどう動いているか

| ジョブ | スケジュール(pg_cron は UTC) | JST | 呼び先 | 補足 |
|---|---|---|---|---|
| `lien-close-day` | `10 15 * * *` | 毎日 00:10 | `POST /functions/v1/close-day` | 前日(JST)を確定する。再実行してもデータは変わらない。ただし**リセットの通知だけは再送される**(→ §4。手動の再実行は `notify:false`) |
| `lien-grant-tickets` | `5 15 * * *` | 毎月1日 00:05 | `POST /functions/v1/grant-tickets` | 毎日起動するが、**JST の日付が1日の日だけ**呼ぶ。それ以外の日は何も呼ばない。付与はペア×月の実行記録(`ticket_grant_runs`)で冪等 |

- 仕組み: pg_cron が SQL を実行 → `net.http_post`(pg_net)が Edge Function を**非同期**で呼ぶ
- 認証: `Authorization: Bearer <cron 専用シークレット>`。Vault の `lien_cron_secret` と Function secrets の `LIEN_CRON_SECRET` に**同じ値**を置き、Function 側が完全一致(定数時間比較)で認証する。**service role key(万能鍵)では認証しない・できない**(下の「鍵」)
- 秘密はジョブの SQL に書いていない。実行のたびに Vault から引く
- 本文: cron は `{}`(close-day は昨日・通知あり、grant-tickets は今月)。手動の再実行は `dateLocal`(close-day はさらに `notify:false`)を付ける。許すキーはこれだけで、知らないキー・壊れた JSON・型違いは 400(打ち間違いを既定値で動かさない)
- 時刻: 00:05 に grant-tickets(付与)→ 00:10 に close-day(確定)の順。月初は付与が先に入る
- 現行の定義: migration `0007_cron_secret.sql`(0003 のジョブを置き換えたもの)。スケジュール・「JST の1日だけ」の条件・呼び先・鍵は、静的テスト `ops/cron_static_test.ts` が検査する(`lien-cron-watch` の ops-tests ジョブ)
- 設定値(本番で確認): `cron.timezone = GMT` / `pg_net.ttl = 6 hours`(HTTP 応答の保存期間)/ pg_cron 1.6.4 / pg_net 0.20.3

### 鍵(重要)

- **cron 専用シークレット `LIEN_CRON_SECRET`**: 乱数 32 バイト(16 進 64 文字)。close-day / grant-tickets を呼べるだけで、DB の読み書きには使えない。置き場所は2か所で**同じ値**: ① Function secrets の `LIEN_CRON_SECRET` ② Vault の `lien_cron_secret`。未設定・32 文字未満のとき Function は全リクエストを 401 にする(起動ログに理由が出る)。漏れたときの影響は、過去の日の close-day を通知つきで呼ばれる(リセット通知の再送)ことと、過去の月の付与を先に走らされることまで(今日・未来の日と未来の月は Function が断る)
- **Function が DB に接続するための鍵 `SUPABASE_SERVICE_ROLE_KEY`** は、プラットフォームが自動で注入する(Function secrets に自分で入れない)。このプロジェクトでは default の secret key(`sb_secret_...`)で、legacy の `service_role`(`eyJ...`)ではない(2026-10-12 実測: 以前の cron 認証で、legacy キーを Bearer にすると close-day は 401、`sb_secret_...` だと 200 だった)。**cron の認証にはもう使わない**
- 同じ値かの確認: Function secrets API が返す値は SHA-256 のダイジェスト。監視(`ops/cron_check.ts` の `secrets:sync`)が Vault の値の SHA-256 と毎朝照合する(値は表示されない)
- 手動の再実行(`ops/run-cron-fn.sh`)は、Vault の `lien_cron_secret` を Management API 経由で読んで使う(§4)
- 旧: 2026-10-13 より前は Vault の `lien_service_role_key`(万能鍵)を Bearer にしていた。その廃止と、Vault から消した判断は §6

## 2. 見るべきもの

**毎朝 00:40 JST に自動で確認される**(GitHub Actions の `lien-cron-watch`。失敗すると workflow が赤になり、GitHub から通知が届く)。手で見るのは、赤になったときと、/status のとき。

```bash
set -a; source .env; set +a   # SUPABASE_ACCESS_TOKEN を環境変数に読む(値は表示されない)
bash products/lien/scripts/ops/check-cron.sh      # 自動確認と同じ検査を手元で(本番 DB を SELECT するだけ)
```

自動確認が見ているもの(`ops/cron_check.ts`。1検査1行で OK / WARN / FAIL。FAIL が1つでもあれば終了コード 1 = 赤):

| 検査 | 赤になる条件 |
|---|---|
| `project` | プロジェクトが `ACTIVE_HEALTHY` でない(無料枠の自動停止。§5) |
| `job:*` | `lien-close-day` / `lien-grant-tickets` が登録されていない・無効 |
| `close-day:run` | 最後の起動が `succeeded` でない / 26 時間より前(毎日 00:10 に動くはず) |
| `close-day:response` | 起動に対応する HTTP 応答が 200 でない・`errors` が空でない・確定した日が起動日の前日でない・応答が無い(起動から 5.5 時間以内なのに) |
| `grant-tickets:run` | 月初(JST の1日)の起動が `1 row` でない / 月初以外の起動が `0 rows` でない / 月初の応答が 200・`errors` 空でない |
| `grant-tickets:stray` | 保存期間内の応答に、JST の1日でない日の grant-tickets の応答がある(月の途中に呼ばれた) |
| `net:queue` | `net.http_request_queue` に処理待ちが残っている(pg_net のワーカー停止) |
| `vault:*` / `secrets:sync` | Vault に `lien_cron_secret` が無い・万能鍵 `lien_service_role_key` が残っている・Vault と Function secrets の値が違う |
| `exposure` | PostgREST の公開スキーマに `net` / `cron` / `vault` が入っている(§9) |

- 黄(WARN)は「起動から 5.5 時間を過ぎて pg_net の応答が消えていて、中身を確認できない」。朝の自動確認(起動の 30 分後)では出ない。昼に手で実行したときに出る
- **失敗時に赤になることの確認**: Actions の「Run workflow」で `max_age_hours` に `0` を入れる(ローカルは `MAX_AGE_HOURS=0 bash .../check-cron.sh`)。最後の起動が「0 時間より古い」ので必ず赤になる。本番の状態は変えない
- 自動確認は GitHub の `schedule` に頼るので、数分〜数十分遅れることがある。リポジトリの活動が 60 日止まると GitHub が無効化するので、/status で「直近 2 日に schedule の実行があるか」も見る

手で SQL を見るとき(切り分け用。Dashboard の SQL Editor に貼っても同じ):

```bash
bash products/lien/scripts/ops/db-query.sh "<SQL>"
```

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
- **応答は6時間で消える**(`pg_net.ttl`)。00:10 JST の結果は 06:10 JST までしか見えない。そのため自動監視は 00:40 JST に見る。昼以降に手で見るなら (b) と、DB の中身(`streak_days` の最新日)で補う:

```sql
select max(date_local) as latest_closed from streak_days;  -- 両者達成かチケットの日がある場合
```

### 失敗の切り分け

| 症状 | 原因 | 対処 |
|---|---|---|
| (b) に行が増えない | プロジェクトが停止している(無料枠の自動停止)/ ジョブが無効 | Dashboard で復元 → §4 で取りこぼしを再実行。ジョブが無ければ `0007_cron_secret.sql` の `cron.schedule` を再実行 |
| (b) が `failed` | SQL のエラー | `return_message` を読む。Vault や拡張の権限・削除を疑う |
| (c) が `401` `{"error":"unauthorized"}` | Vault の `lien_cron_secret` が Function secrets の `LIEN_CRON_SECRET` と違う / どちらかが無い / 32 文字未満(鍵を作り直した)。監視の `secrets:sync` が先に赤になる | §6 で作り直して2か所を合わせ、§4 で取りこぼしを再実行 |
| (c) が `400` | cron の本文は `{}` なので通常は出ない。手動の再実行の打ち間違い(`invalid_json` / `unknown_field` / `invalid_notify` / `invalid_date_local`)。`date_not_closable` = 今日・未来を確定しようとした / `future_month` = 未来の月を付与しようとした | 本文・日付を直して再実行 |
| (c) が `200` だが `errors` が空でない | 一部のペアの処理失敗(ペア単位で隔離される) | `supabase functions logs close-day --project-ref lniheehfbtpfhglinfjm` で該当ペアを確認(grant-tickets は RPC の失敗なら記録が残らず、次の実行で付与される) |
| (c) が `500` | Function の内部エラー | 同上。直ったら §4 で再実行 |
| (c) が `timed_out = true` / `error_msg` あり | 60秒超過・ネットワーク | §4 で再実行。頻発するならペア数の増加を疑う(timeout は `0007_cron_secret.sql` の `timeout_milliseconds`) |

## 3. 登録内容を変えたいとき

ジョブの追加・変更・停止は migration として書く(`cron.schedule` は同名ジョブがあれば更新する)。
本番に手で流すときは `db-query.sh -f` でよいが、**必ず migration と `supabase_migrations.schema_migrations` を揃える**。
式・呼び先・鍵を変えたら、静的テストを回す: `deno test --allow-read products/lien/scripts/ops/`(スケジュールの JST 換算・「JST の1日だけ」の条件・URL とプロジェクトの一致・鍵の参照先・migration 番号の連番)。

```sql
select cron.unschedule('lien-close-day');                    -- 削除
select cron.alter_job((select jobid from cron.job where jobname = 'lien-close-day'), active := false);  -- 一時停止
```

## 4. 取りこぼしの再実行

cron が動かなかった日(自動停止・障害・鍵の不一致)を埋める。

```bash
set -a; source .env; set +a
# 古い日から新しい日の順に実行される(ストリーク・チケットの判定が前日に依存するため)
bash products/lien/scripts/ops/run-cron-fn.sh close-day 2026-10-09 2026-10-11    # 範囲(両端を含む)
bash products/lien/scripts/ops/run-cron-fn.sh close-day 2026-10-11               # 1日だけ
```

- 範囲は **取りこぼした最初の日 から 昨日(JST)まで**。日付は JST の `date_local`。確定できるのは終わった日だけで、今日・未来はサーバーが 400 `date_not_closable` で断る(確定すると、まだチェックインしていない人を未達として確定して、取り消せない)
- **通知は送らない**: スクリプトは常に `notify:false` で呼ぶ。データ(`streak_days`・チケット・植物)は通常どおり確定するが、ticket_used とリセットの push は出さない
  - 理由: close-day のデータ更新は冪等(確定済みの日は `skipped` で何も書かない)だが、**リセットの日は `streak_days` に行が残らないので、再実行するとその日のリセット通知(「また今日から」)をもう一度送ってしまう**。取りこぼした日の通知は、何時間も何日も遅れて届くと混乱するので、そもそも送らない
  - 以前の「範囲は広めでよい」は、この再送を見落とした誤りだったので訂正した。いまは通知が出ないので、確定済みの日を範囲に含めても害はない(データも通知も変わらない)。それでも範囲は取りこぼした日から始める(無駄に長くなる)
- 認証は Vault の `lien_cron_secret`(Management API 経由で読む。値は表示されない)。401 になったら §6

### 月をまたいで止まっていたとき

月初は 00:05 に grant-tickets(付与)、00:10 に close-day(**前月の末日**を確定)の順で動く。止まっていた期間が月初をまたぐときは、この順を再現する。**close-day の範囲を月初をまたいで1回で通さない**: 前月末日の確定は、本来は月次付与の「後」に起きるので、先に確定すると、付与で救えたはずのチケット切れのリセットが起きる。

順序は「**前月末日の前日まで close-day → grant-tickets → 残りの close-day**」。

例: 10/29〜11/02 に止まっていた(10/28 までは確定済み)。復旧は 11/03 の朝:

```bash
# 1. 前月末日(10/31)の前日までを確定
bash products/lien/scripts/ops/run-cron-fn.sh close-day 2026-10-29 2026-10-30
# 2. 11月分の付与(実行記録があるので、すでに付与済みのペアは自動でスキップされる)
CONFIRM_GRANT=yes bash products/lien/scripts/ops/run-cron-fn.sh grant-tickets 2026-11-01
# 3. 残り(前月末日から昨日まで)
bash products/lien/scripts/ops/run-cron-fn.sh close-day 2026-10-31 2026-11-02
```

月をまたがない停止は、close-day の範囲を1回で通してよい。止まったのが 00:05 の付与だけ(close-day は動いた)なら、手順 2 だけ。

### grant-tickets の取りこぼし(めったに無い)

月の付与は **ペア×月の実行記録(`ticket_grant_runs`)で冪等**。上限に達していて 0 枚の付与だったペアにも記録が残るので、月の途中に再実行しても、その間にチケットを使ったペアへもう一度付与することはない(以前は ledger の行だけが印で、上限のペアには行を残せず、再実行で二重付与しえた)。実行記録・残高・ledger は1トランザクションで書くので、途中で失敗しても半端な状態は残らない(失敗したペアは記録が残らず、次の実行で付与される)。

付与が済んでいるかの確認:

```sql
-- 今月の付与が済んでいない active なペア(0 件なら全ペア済み)
select p.id as pair_id, p.ticket_balance
from pairs p
where p.status = 'active'
  and not exists (
    select 1 from ticket_grant_runs r
    where r.pair_id = p.id and r.month_start = date_trunc('month', (now() at time zone 'Asia/Tokyo'))::date)
  and not exists (   -- 実行記録を入れる前(migration 0006 より前)の付与の印
    select 1 from ticket_ledger l
    where l.pair_id = p.id and l.reason = 'monthly'
      and l.date_local >= date_trunc('month', (now() at time zone 'Asia/Tokyo'))::date);

-- 月ごとの結果(pairs = 処理したペア数 / granted_total = 付与した枚数の合計 / capped = 上限で 0 枚だったペア数)
select month_start, count(*) as pairs, sum(delta) as granted_total, count(*) filter (where delta = 0) as capped
from ticket_grant_runs group by 1 order by 1 desc;
```

- 1つ目に行が出る(その月の付与を取りこぼした)ときは、月の1日の日付で実行する。処理済みのペアは自動でスキップされる:

```bash
CONFIRM_GRANT=yes bash products/lien/scripts/ops/run-cron-fn.sh grant-tickets 2026-11-01
```

- 未来の月はサーバーが 400 `future_month` で断る(実行記録が残って、その月の本当の cron が空振りになるため)。月をまたぐ停止での順序は上の「月をまたいで止まっていたとき」
- 付与は `ticket_ledger` の `reason = 'monthly'` にも残る(上限のペアは行なし)。月初の朝に (c) の応答が残っていれば、`granted / alreadyGranted / unchanged` の内訳が見える

## 5. 自動停止(無料枠)

- 無料枠はしばらくアクセスが無いと自動で停止する。2026-10-12 に実際に 4か月の放置で `INACTIVE` だった
- 停止中は cron も動かない。復元後は §4 で止まっていた期間を埋める
- 恒久対策は D5(リリース前に Pro 化。〜12/1)。それまでも、毎朝の自動監視(`project`)が停止を検知して赤になる

## 6. 鍵の更新(cron 専用シークレット)

`LIEN_CRON_SECRET` は2か所に**同じ値**を置く: ① Function secrets の `LIEN_CRON_SECRET` ② Vault の `lien_cron_secret`。初めて作るときも作り直すときも、手順は同じ(下のスクリプト)。**値は画面に出さない**: 乱数は DB の中で作るので SQL にも履歴にも残らず、読み戻した値は変数に入れて Function secrets へ渡すだけ。

作り直すのは、漏れた疑いがあるとき・Function secrets と Vault の値が違うとき(監視の `secrets:sync` が赤)。**00:00〜00:20 JST は避ける**(cron の起動中に値が食い違う)。

```bash
set -a; source .env; set +a
python3 - << 'PY'
import json, os, urllib.request
H = {"Authorization": "Bearer " + os.environ["SUPABASE_ACCESS_TOKEN"], "Content-Type": "application/json", "User-Agent": "lien-agent/1.0"}
ref = "lniheehfbtpfhglinfjm"
def call(method, path, body=None):
    req = urllib.request.Request("https://api.supabase.com" + path, headers=H, method=method,
                                 data=json.dumps(body).encode() if body is not None else None)
    with urllib.request.urlopen(req) as r:
        raw = r.read().decode()
        return json.loads(raw) if raw else None
q = lambda sql: call("POST", f"/v1/projects/{ref}/database/query", {"query": sql})
# 1. Vault の lien_cron_secret を、DB の中で作った乱数に更新する(無ければ作る)
q("""
do $$
begin
  if exists (select 1 from vault.secrets where name = 'lien_cron_secret') then
    perform vault.update_secret((select id from vault.secrets where name = 'lien_cron_secret'),
                                encode(extensions.gen_random_bytes(32), 'hex'));
  else
    perform vault.create_secret(encode(extensions.gen_random_bytes(32), 'hex'), 'lien_cron_secret',
      'close-day / grant-tickets を呼ぶ pg_cron 用の専用シークレット(Function secrets の LIEN_CRON_SECRET と同じ値)');
  end if;
end $$;
""")
# 2. 読み戻して、同じ値を Function secrets に入れる(値は print しない)
secret = q("select decrypted_secret from vault.decrypted_secrets where name = 'lien_cron_secret'")[0]["decrypted_secret"]
call("POST", f"/v1/projects/{ref}/secrets", [{"name": "LIEN_CRON_SECRET", "value": secret}])
print("OK: Vault の lien_cron_secret と Function secrets の LIEN_CRON_SECRET を更新した(長さ %d)" % len(secret))
PY
```

- 更新後に `bash products/lien/scripts/ops/run-cron-fn.sh close-day <昨日>` で 200 を確認する(確定済みなら `skipped`。通知なし)。Function が新しい値を読むまで少しかかることがある(401 なら数十秒待つ。続くなら close-day / grant-tickets を再デプロイ)
- 確認: `bash products/lien/scripts/ops/check-cron.sh` の `secrets:sync` が OK(SHA-256 の照合。値は出ない)
- Vault の中身を見るときは、値そのものではなく長さだけを見る: `select name, length(decrypted_secret) from vault.decrypted_secrets`(`lien_cron_secret` は `64`)
- 初めて作る順序(migration 0007 を新しい環境に適用するとき): ① このスクリプトで Vault と Function secrets に作る ② close-day / grant-tickets を再デプロイ ③ migration 0007 を適用。migration は Vault に無いと止まる(ガード)

### Vault の万能鍵(`lien_service_role_key`)を消した判断(2026-10-13・issue #60)

- cron は cron 専用シークレットだけを使う。Function も service role key を受け付けない(`_shared/cron_http.ts`)ので、Vault の万能鍵はどこからも参照されない
- 手動の再実行(`ops/run-cron-fn.sh`)も、以前は Management API から service role key(`sb_secret_...`)を引いて Bearer にしていたが、いまは Vault の `lien_cron_secret` を引く。万能鍵を使う経路がなくなった
- 残すと、Vault と pg_net のキューに DB に何でもできる鍵が載り続ける(漏れたときの被害が大きい)。消しても、鍵そのものは Management API(`GET /v1/projects/<ref>/api-keys?reveal=true`)でいつでも取り出せるので、再作成は要らない
- 監視の `vault:master-key` が、万能鍵が Vault に戻っていないかを毎朝確認する(緊急で一時的に戻すなら、この検査が赤になるのを承知の上で)

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

## 9. net スキーマの権限(pg_net)— 絞れなかったこと、代わりの守り

issue #60 では「anon / authenticated から `net.http_post` の EXECUTE と `net.http_request_queue` / `net._http_response` の SELECT を revoke する」としていたが、**postgres ロール(Management API と migration が使うロール)からは絞れなかった**(2026-10-13 実測)。

- pg_net の関数・表は `supabase_admin` 所有で、`PUBLIC`(全ロール)に EXECUTE / SELECT などが付いている(schema `net` の USAGE も PUBLIC)。anon / authenticated への個別の GRANT ではなく PUBLIC 経由なので、`revoke ... from anon, authenticated` を書いても何も変わらない
- `revoke execute on function net.http_post(...) from public` を postgres で実行しても、エラーにならず何も変わらなかった(所有者でも supabase_admin のメンバーでもないため。DO ブロックの中で実行して結果を確認し、全体を巻き戻したので本番は変わっていない)。migration に効かない revoke を書くと、塞いだように見えてしまうので書かない
- 代わりに次で守る:
  1. **公開 API から net に届かない**。PostgREST の公開スキーマは `public, graphql_public` だけ(`Accept-Profile: net` を付けた anon のリクエストは 406 `Invalid schema: net`)、pg_graphql は無効(GraphQL は "pg_graphql extension is not enabled")。anon / authenticated が SQL を直接流す経路はない。監視の `exposure` が、公開スキーマに `net` / `cron` / `vault` が入っていないことを毎朝確認する
  2. **万能鍵を net のキューに載せない**(§1・§6)。キュー(`net.http_request_queue`。処理されるまでの短い間だけヘッダが入る)に載るのは cron 専用シークレットだけ。漏れても DB の読み書きには使えない
- 将来、Supabase が net の所有や権限を変えて postgres から絞れるようになったら、migration に `revoke execute on function net.http_post(...) from public` と `revoke select on net.http_request_queue, net._http_response from public` を足し、cron が使うロール(`postgres`)と `service_role` に EXECUTE / INSERT / シーケンスの USAGE を明示的に GRANT する。**外すと cron が全部止まる**ので、適用前に一時ジョブで確かめること
