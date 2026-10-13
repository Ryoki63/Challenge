# 運用手順(OPS)— 本番 Supabase の定期ジョブ

対象: `products/lien/supabase/migrations/0003_cron.sql` で登録し、`0007_cron_secret.sql` で認証を cron 専用シークレットに替えた cron ジョブ(issue #51・#60 / docs/GROWTH.md §7.1)。
G0〜G1 の人間作業は [g1/RUNBOOK.md](g1/RUNBOOK.md)。本書は「公開後も続く運用」の手順。
cron とは別に、本番の API を 2 ユーザーで通して確かめる手順(通しテスト。issue #67)は §12。

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
- 現行の定義: migration `0007_cron_secret.sql`(0003 のジョブを置き換えたもの)。スケジュール・「JST の1日だけ」の条件・呼び先・鍵・本文 `{}` は、静的テスト `ops/cron_static_test.ts` が migration の文面を検査する(`lien-cron-watch` の ops-tests ジョブ)。**本番の `cron.job` が migration のとおりか**は、毎朝の監視(`job:*`)が検査する
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
| `job:*` | `lien-close-day` / `lien-grant-tickets` が登録されていない・無効・**定義が migration 0007 とずれている**(スケジュール・呼び先・Vault の `lien_cron_secret`・本文 `{}`・「JST の1日だけ」の条件。誰かが手で書き換えて、通知が止まる・毎晩同じ日を確定するのに起動は `succeeded` のまま、を防ぐ) |
| `job:unexpected` | 想定外のジョブが登録されている(スモークの一時ジョブの消し忘れなど。毎分本番の Function を呼び続ける。§10) |
| `close-day:run` | **直近の予定の回(JST 00:10。猶予 5 分)の起動の記録が無い**(前夜の起動が抜けた)/ 起動が `succeeded` でない |
| `close-day:response` | 起動に対応する HTTP 応答が 200 でない・`errors` が空でない・確定した日が起動日の前日でない・応答が無い(起動から 5.5 時間以内なのに) |
| `grant-tickets:run` | **直近の予定の回(JST 00:05)の起動の記録が無い**(その日が月初なら、月次付与が抜けた)/ 起動が `succeeded` でない / 月初(JST の1日)の起動が `1 row` でない / 月初以外の起動が `0 rows` でない |
| `grant-tickets:response` | 月初の起動の応答が 200 でない・`errors` が空でない・応答が無い(起動から 5.5 時間以内なのに) |
| `grant-tickets:stray` | 保存期間内の応答に、JST の1日でない日の grant-tickets の応答がある(月の途中に呼ばれた) |
| `net:queue` | `net.http_request_queue` に処理待ちが残っている(pg_net のワーカー停止) |
| `vault:*` / `secrets:sync` | Vault に `lien_cron_secret` が無い・万能鍵 `lien_service_role_key` が残っている・Vault と Function secrets の値が違う |
| `exposure` | PostgREST の公開スキーマに `net` / `cron` / `vault` が入っている、または `pg_graphql` 拡張が有効(§9) |

- **「起動したか」は経過時間でなく予定の回で見る**: 「最後の起動が N 時間以内」では、前夜の回が丸ごと抜けても(最後の起動 = 前々夜 = 24.5 時間前)通ってしまい、月初 00:05 の付与が抜けても最後の起動は前日の `0 rows`(1日でない日の正常な起動)に見える。そこで now から「もう起動しているはずの直近の予定時刻」(close-day は JST 00:10、grant-tickets は JST 00:05。予定から 5 分は猶予)を求め、その時刻以降の起動の記録を必須にしている。日中に手で実行しても赤にならない(予定の回は次の 00:05 / 00:10 まで変わらない)。起動していない回の応答は探さない
- `MAX_AGE_HOURS`(workflow の `max_age_hours`)は最後の起動の許容経過時間の上限(既定 26)。通常は上の予定の回の検査が先に働くので、**0 を入れて必ず赤にする動作確認**のためのもの
- 黄(WARN)は「起動から 5.5 時間を過ぎて pg_net の応答が消えていて、中身を確認できない」。朝の自動確認(起動の 30 分後)では出ない。昼に手で実行したときに出る
- **このリポジトリは公開なので、Actions のログとジョブサマリは誰でも読める**。Actions 上では件数(ペア数・達成数など)・ペア ID・応答の本文を出さない(`redact`。判定は同じ)。件数や `errors` の中身を見たいときは、手元の `check-cron.sh`(redact なし)か、Function のログ(`supabase functions logs close-day`)で見る
- **失敗時に赤になることの確認**: Actions の「Run workflow」で `max_age_hours` に `0` を入れる(ローカルは `MAX_AGE_HOURS=0 bash .../check-cron.sh`)。最後の起動が「0 時間より古い」ので必ず赤になる。本番の状態は変えない
- 自動確認は GitHub の `schedule` に頼るので、数分〜数十分遅れることがある。リポジトリの活動が 60 日止まると GitHub が無効化するので、/status で「直近 2 日に schedule の実行があるか」も見る
- **監視が見るのは直近の予定の回だけ**。GitHub の `schedule` が欠けた日の欠落は、翌日の監視では見えない(翌日は翌日の回を見る)。とくに**初回の本物の月次付与(2026-11-01 00:05 JST)の朝**は、`lien-cron-watch` の 11/01 の schedule 実行が緑かを見て、欠けていたら手元の `check-cron.sh` を走らせる(付与が済んでいるかは §4 の SQL でいつでも確認できる)

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

cron が動かなかった日(自動停止・障害・鍵の不一致)を埋める。動作確認のために本番の close-day / grant-tickets を呼ぶときは §10 の作法に従う(空の本文で呼ぶと、昨日が通知つきで実際に確定する)。

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
  and not exists (   -- 旧来の印: 同月の ledger monthly 行(0006 より前の付与。invite-accept の初期付与もこれで、今も増える)
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
- **同月の ledger の monthly 行は、実行記録とは別の「処理済み」の印として今も必要**: ペアを作ると invite-accept が初期付与を `reason = 'monthly'`・`date_local = started_on` で ledger に書く(実行記録は作らない)。ペアを作った月は、この初期付与がその月の付与にあたるので、grant-tickets は印を見て上乗せしない(月初 00:05 の直前にできた premium ペアに +5 が重ならない。月の途中の再実行でも同じ)。0006 より前の付与のための互換だけではないので、「旧来の印だから」と消さない(`ops/cron_static_test.ts` が検査する)

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

- 更新後に認証が通ることを確かめる: `bash products/lien/scripts/ops/run-cron-fn.sh close-day 2026-03-31` が 200 になれば OK(どのペアの `started_on` よりも前の日付なので、対象 0 ペアで**何も変わらない**。通知なし)。**「昨日」で確かめると、まだ確定していないペアがあれば実際に確定する**(冪等で通知は出ないが、データは動く)ので、認証だけを見たいときは前の日付を使う。新しい値は更新直後の最初の呼び出しから使われる(2026-10-13 実測。再デプロイは要らない)。401 が続くなら Vault と Function secrets の値が違う(監視の `secrets:sync` が赤になる)
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
| 2026-10-13 01:43〜01:50 | **issue #60(堅牢化)を本番へ**。① migration 0006(`ticket_grant_runs` と RPC `apply_monthly_ticket_grant`。service_role 専用)と 0007(cron の認証を `lien_cron_secret` に)を適用し、`supabase_migrations.schema_migrations` にも記録。0006 は先に本番で強制ロールバックのドライランをして、RPC の各分岐(granted / unchanged / already / 負の残数 / 不正な月・日付)と権限を確認 ② cron 専用シークレットを作成: Vault の `lien_cron_secret` を DB の中の乱数(64 文字)で作り、同じ値を Function secrets の `LIEN_CRON_SECRET` に入れた(§6 のスクリプトそのまま。SHA-256 が一致)③ Edge Functions 11 本を再デプロイ(checkin v9 / checkin-cancel v6 / close-day v6 / grant-tickets v5 / invite-accept v6 / invite-create v5 / nudge v5 / plant-name v5 / promise-set v6 / react v5 / snapshot v6。更新は 01:43〜01:44。verify_jwt はすべて false のまま。※ 当初この行は各 1 小さい版数を書いていた。2026-10-13 に Management API の実測で訂正)④ Vault の `lien_service_role_key`(万能鍵)を削除(判断は §6)。内容は close-day の `notify`・今日以降を確定しない、grant-tickets の月単位の実行記録・未来の月を断る、cron 専用シークレットでの認証、`push_env` を getUser と一緒に読む(送信のたびの逆引きをやめた) |
| 2026-10-13 01:46〜01:50 | **#60 のスモーク(本番)**: 関数 29 項目 PASS(405 / 認証なし・別の秘密・**万能鍵が 401** / 壊れた JSON・知らないキー・型違い・今日と明日の確定・未来の月が 400 / `{"dateLocal":"2026-03-31","notify":false}` が 200 で `notify:false`・対象 0 ペア / RPC を service role で呼ぶと FK 違反 23503 = 結線 OK、anon では 401 / 表は anon から読めない)。cron の経路は一時ジョブ(毎分。本番ジョブの command をそのまま使用。確認後に削除)で確認: close-day は `succeeded` / `1 row` → pg_net の応答 200(`notify:false`・errors 空)、**grant-tickets の command は 1日でない日なので `succeeded` / `0 rows` で、pg_net の応答は増えない**(= 呼ばれない)。`ops/run-cron-fn.sh close-day 2026-03-30 2026-03-31` が Vault の秘密で 200・`notify:false`(引数の検査も確認: 今日・確認なしの grant-tickets・未来の月・1日でない日付は断る)。Function が流す問い合わせの形(`USER_COLUMNS` / `PARTNER_SELECT` の select・`ticket_grant_runs`・`db.rpc`)を supabase-js で本番に対して確認(読み取りと、必ず失敗する RPC だけ)。**意図しない変更が1つ**: スモークの「空の本文」(cron の素朴な POST)の確認で、既定の「昨日 = 2026-10-12」が実際に確定された。00:10 の cron が閉じなかったテストペア P3(`c33b5d9c-…`)・P4(`7ef8edd2-…`)の 10/12 に `both` が1行ずつ入り、`plants.grown_days` が数え直された(通知は出ていない: push_token を持つユーザーがいない・APNs 未設定)。テストペアなので影響はないが、台帳(§8)の値は 10/12 の分だけ進んでいる |
| 2026-10-13 01:48〜01:49 | 監視の確認: `ops/check-cron.sh`(手元)と、GitHub Actions の `lien-cron-watch` の手動実行(workflow_dispatch。run 38279962642)が全項目 OK(`secrets:sync` で Vault と Function secrets が一致、`vault:master-key` で万能鍵なし、`exposure` で公開スキーマに net なし)。失敗時の動作確認: `max_age_hours=0` で手動実行(run 38280031567)すると `watch` ジョブが `failure`(FAIL: close-day:run / grant-tickets:run)になり、赤になることを確認。本番の状態は変えていない。続けて §6 の鍵の更新スクリプトを実行して**更新の経路**も確認: Vault の値が変わり、直後の最初の呼び出しから新しい値で 200(Function の再デプロイ不要)、`secrets:sync` も OK。なお上の2つの run(38279962642・38280031567)は、公開ログへの件数の出力をやめる前なので、ログにテストペアの件数が出ている。以降の run(redact 版。例 38280878109 = 緑)は件数・ペア ID・応答の本文を出さない |
| 2026-10-13 02:33〜02:36 | **#60 の Opus レビュー修正を反映**。① 監視(`ops/cron_check.ts`)を直した: 直近の予定の回(close-day は JST 00:10・grant-tickets は 00:05。猶予 5 分)の起動を必須にし、前夜の回が抜けたら赤・月初の付与の回が抜けたら赤にした(以前は最後の起動が 26 時間以内なら OK で、どちらも見逃していた)。ジョブ定義(スケジュール・呼び先・鍵・本文)のずれと想定外のジョブも赤。手動実行 38285007571 が緑(redact 版)、`max_age_hours=0` の 38285073541 が赤になることを確認。本番の状態は変えていない ② grant-tickets を再デプロイ(v5 → v6。旧来の印のコメントの修正だけで動作は同じ。デプロイ物 = main の HEAD を保つため。他の 10 関数は変更なし)。デプロイ後に副作用のないスモーク 6 項目が PASS(GET 405 / 認証なし・別の秘密 401 / cron 秘密 + 未来の月・知らないキー・壊れた JSON が 400)。`ticket_grant_runs` は 0 行のまま・データは変わっていない ③ lien-cron-watch・lien-deploy の action を commit SHA で固定(lien-deploy の dry_run 手動実行 38285254685 が緑)。lien-cron-watch の ops-tests を functions/ 配下の変更でも回すようにした ④ 上の 01:43〜01:50 の行の関数の版数を実測に訂正 |
| 2026-10-13 05:07〜05:21 | **issue #67: 本番に対する 2 ユーザーの API 通しテストを初めて実行**(`scripts/e2e/run.sh`。§12)。開発中の 3 回(05:07・05:11・05:14)と最終の 1 回(05:20)で、各回 匿名ユーザー 3 人・ペア 1 組・写真 2 枚を作り、すべて削除した(後片付けのあと、users・pairs・Storage のオブジェクトが実行前と同じ件数に戻ったことを SELECT で確認。作った ID は §8 の末尾)。最終回は **244 項目 PASS・FAIL 0**・契約フィクスチャ(`contracts/`)とのずれ 1(署名付き URL の発行の失敗は HTTP 404 でなく 400。手書きフィクスチャの説明が 404 を想定)・NOTE 3(取消後も写真の実体が Storage に残る = issue #68 / 署名の失敗が 400 / APNs の secrets が未設定 = G0 待ち)。#59 PV の経路(相手が `checkins.photo_path` を読み、署名付き URL で画像を取れる。ペア外・未ログインは取れない)と、PushTokenSync の経路(自分の `users.push_token` / `push_env` の書き込みと読み戻し)も本番で通った。close-day / grant-tickets は呼んでいない(§10)。本番のスキーマ・関数・設定は変えていない |
| 2026-10-13 05:55〜06:00 | **issue #67 の Opus レビュー修正の確認として、通しテストを本番で 3 回流し直した**(`scripts/e2e/run.sh`。§12)。① `run --cleanup`(匿名ユーザー 3 人・ペア 1 組・写真 2 枚): **263 項目 PASS・FAIL 0**・契約フィクスチャとのずれ 0 ② `run`(データを残す)→ `list` → `cleanup --user …`(厳格な確認の経路)→ 削除。同じ状態で、`--user` に A だけ・本番にもともとあるテストユーザー(§8 の台帳のもの)を指定すると止まる(dry-run)ことも確認 ③ 契約フィクスチャ(`storage-sign.not-found.json`)を隠した複製で `run --cleanup --no-outsider`(ずれ 1 件で終了コード 1 になり、後片付けは済む)。3 回とも作ったデータをすべて削除し、users・pairs・invites・Storage のオブジェクトの件数が実行前と同じに戻ったことを SELECT で確認。本番のスキーマ・関数・設定は変えていない。close-day / grant-tickets は呼んでいない(§10) |

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

### 通しテスト(§12)が作って、その場で削除したもの(2026-10-13・issue #67)

`scripts/e2e/run.sh run` は実行のたびに、匿名ユーザー 3 人(ニックネーム `E2E-A` / `E2E-B` / `E2E-C`)・ペア 1 組・Storage の写真 2 枚を作る。`--cleanup`(または `cleanup` コマンド)で削除するので、**通常は本番に残らない**。残したままにしたとき(`--cleanup` なしの実行、途中の失敗)だけ、上の表と下の SQL のリストに足す(残っているかは `run.sh list` で分かる)。次の 4 回は削除済みなので、表にも SQL のリストにも入れていない(監査のための記録。この 4 回までは ID を残した。以降の確認の実行は、公開リポジトリのため ID を残さない。最後の行):

| 実行(JST) | users(A / B / C) | pair | 後片付け |
|---|---|---|---|
| 10-13 05:07 | `2c8944f3-57f2-4baf-a27f-781dd80e8ae7` / `fde5f2f2-bbbe-4c1f-bc48-40b10c36be48` / `9b12c9ba-e587-402a-8c5a-7cb140e67496` | `3b65a71c-5e9c-4615-9be0-25d35ee7cf94` | 05:09 `cleanup` で削除(Storage 2 件を含む)。この回は契約の比べ方に不備があり(名前なし・ソロの null を FAIL にした)、直してから再実行した |
| 10-13 05:11 | `ed2149ff-20a2-4aec-b240-e1aed1e339aa` / `7f29f59e-675d-4546-bc04-f960dfcf8d42` / `5c2a49e2-e450-4fa4-a6a4-133c8ddb4545` | `223e25d3-7b38-444e-aecd-690c5755d649` | 05:12 `--cleanup` で削除 |
| 10-13 05:14 | `6890099d-7d31-40fc-b726-d5b4d68908c5` / `240a6207-c66e-4d28-b352-58ccc32def5b` / `b8c42f60-8752-4587-b9ee-12cd20f3d15b` | `9c0140de-eb0c-497e-bcac-75f9dd39a3a1` | 05:15 `--cleanup` で削除。コードの分割後の確認(235 項目 PASS) |
| 10-13 05:20(最終) | `aba422f1-5223-4dba-819a-f843da70e9b6` / `ceefbf04-d193-4b9b-b411-a66d814fac1b` / `c95cd4cf-cb03-49de-9530-f031249053ce` | `16d10099-841f-43aa-b52c-6779ed67d344` | 05:21 `--cleanup` で削除。244 項目 PASS(PV の手書きフィクスチャとの突き合わせを足した版) |
| 10-13 05:55〜05:59(Opus レビュー修正後の確認 3 回) | (記録しない) | (記録しない) | 3 回とも削除済み(§7 の同じ日の行)。ユーザー・ペアの ID は残さない |

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

**この代わりの守りで受け入れるかはユーザーの判断**(issue #63。急ぎではなく、v1.0 の公開はブロックしない。決まるまでは下の代わりの守りのまま)。

- pg_net の関数・表は `supabase_admin` 所有で、`PUBLIC`(全ロール)に EXECUTE / SELECT などが付いている(schema `net` の USAGE も PUBLIC)。anon / authenticated への個別の GRANT ではなく PUBLIC 経由なので、`revoke ... from anon, authenticated` を書いても何も変わらない
- `revoke execute on function net.http_post(...) from public` を postgres で実行しても、エラーにならず何も変わらなかった(所有者でも supabase_admin のメンバーでもないため。DO ブロックの中で実行して結果を確認し、全体を巻き戻したので本番は変わっていない)。migration に効かない revoke を書くと、塞いだように見えてしまうので書かない
- 代わりに次で守る:
  1. **公開 API から net に届かない**。PostgREST の公開スキーマは `public, graphql_public` だけ(`Accept-Profile: net` を付けた anon のリクエストは 406 `Invalid schema: net`)、pg_graphql は無効(GraphQL は "pg_graphql extension is not enabled")。anon / authenticated が SQL を直接流す経路はない。監視の `exposure` が、公開スキーマに `net` / `cron` / `vault` が入っていないこと、`pg_graphql` が無効なことを毎朝確認する(`pg_graphql` を有効にすると、PUBLIC に SELECT が付いた net の表が GraphQL の API に出る恐れがあるので、有効にするなら net が出ないことを確かめてから)
  2. **万能鍵を net のキューに載せない**(§1・§6)。キュー(`net.http_request_queue`。処理されるまでの短い間だけヘッダが入る)に載るのは cron 専用シークレットだけ。漏れても DB の読み書きには使えない
- 将来、Supabase が net の所有や権限を変えて postgres から絞れるようになったら、migration に `revoke execute on function net.http_post(...) from public` と `revoke select on net.http_request_queue, net._http_response from public` を足し、cron が使うロール(`postgres`)と `service_role` に EXECUTE / INSERT / シーケンスの USAGE を明示的に GRANT する。**外すと cron が全部止まる**ので、適用前に一時ジョブで確かめること

## 10. 本番でのスモークの作法(やってはいけない呼び方)

本番に対して動作確認で close-day / grant-tickets を呼ぶときの決まり。#60 のスモークで一度これを破り、本番のデータが動いた(§7 の 2026-10-13 01:46〜01:50 の「意図しない変更」)。

- **close-day を「空の本文」や日付なしで呼ばない**。本文を省く・`{}` にすると、cron と同じ既定 = **昨日(JST)を確定する・通知あり(`notify:true`)**。実ユーザーがいる状態で呼ぶと、本物のチケット消費・リセット・通知が起き、取り消せない(まだチェックインしていない人を未達として確定する)。#60 のスモークでは、これでテストペア P3・P4 の 10/12 が実際に確定した
- 確認は **過去の日付 + `notify:false`** に限る。`bash products/lien/scripts/ops/run-cron-fn.sh close-day 2026-03-31` は、どのペアの `started_on` よりも前の日付なので対象 0 ペアで何も変わらず、常に `notify:false`(§6)。認証の疎通を見るだけなら、これで 200 が返れば足りる。スモークのスクリプトを書くときも、close-day の正常系は同じ形(過去の日付・`notify:false`)だけにする
- 副作用なしで確かめられるもの(認証・本文の検査で止まり、DB に触らない): メソッド違い(405)、認証なし・別の秘密・万能鍵(401)、壊れた JSON・知らないキー・型違い・今日以降の日付(`date_not_closable`)・未来の月(`future_month`)(400)。「正常系の 200」を本番で確かめたいときだけ、上の過去の日付を使う
- **grant-tickets は、本番で 200 になる呼び方をしない**(月次付与は実行記録が残って取り消せない)。確認は上の 400 系までにする。付与そのものの確認は、本番での強制ロールバックのドライラン(0006 でやったように、DO ブロックの中で RPC を呼び、最後に例外を投げて全体を巻き戻す)か、月初の本物の cron(翌 00:40 の監視の `grant-tickets:response`)で行う
- cron のジョブを一時的に作って確かめるときは、確認後に必ず `select cron.unschedule('<名前>')` で消す(消し忘れは監視の `job:unexpected` が赤にする)。一時ジョブの本文も、`notify:false` と過去の日付を入れたものにする(本番ジョブの command をそのまま毎分で動かすと、昨日の確定が通知つきで走る)

## 11. 規模が増えたときの注意(今の規模では問題ない。公開後の増え方を見て直す)

Opus レビュー(2026-10-13)の指摘。いまはペアが数組で起きないが、ペアが増えると効いてくるもの。**v1.0 の公開前には要らない**。公開後に Function のログで実行時間を見て、必要になったら直す(issue #64。on-hold)。

- **close-day の残数の更新は「絶対値で書く」**: 最初に読んだ残数から計算した値(`balance - 1` など)をそのまま書くので、読んでから書くまでの間に別の処理が残数を変えると、その変更を上書きする(lost update)。たとえば grant-tickets の付与が 00:10 までに終わらない規模になると、付与を上書きしてしまう。いまは 00:05 の付与が数秒で終わり、00:10 の確定の前に必ず済む。直し方: 残数の増減を DB 側の原子的な更新(RPC。`apply_monthly_ticket_grant` のように1トランザクション)にする
- **grant-tickets はペアごとに約 5 往復の問い合わせを順に行う**(実行記録の確認・ledger の確認・メンバー2人の `premium_until`・RPC)。pg_net の timeout は 60 秒(`0007_cron_secret.sql` の `timeout_milliseconds`)で、見積もりではペアが数百組になると超える。超えると応答は `timed_out` になり(監視の `grant-tickets:response` が赤になる)、Function 自体は最後まで動くが、結果は pg_net 経由では見えない。直し方: ペア・`premium_until`・実行記録を `in (...)` でまとめて読み、書き込みだけを RPC にする

## 12. 本番に対する 2 ユーザーの API 通しテスト(e2e。issue #67)

実機の E2E(T20)の前に、エージェントが本番のバックエンドに 2 ユーザーのシナリオを流し、「CI は緑なのに本番で通らない」を先に潰す(docs/REVIEW-2026-10-12.md §4.2 T20)。`products/lien/scripts/e2e/`(deno)。**手動実行専用**: 本番にテスト用の匿名ユーザーを作る。CI では動かさない(`CI=true` のときは `E2E_ALLOW_CI=1` が無いと止まる。lien-ci・lien-cron-watch のどのジョブからも呼ばれない)。通しテスト本体の部品(後片付けの安全装置・招待 token の形・契約フィクスチャとの突き合わせ・引数の解釈)の単体テストと型検査は、ネットワークも本番も使わないので、lien-ci の `e2e-tests` ジョブで回る。

### 使い方

```bash
set -a; source .env; set +a      # SUPABASE_ACCESS_TOKEN を環境変数に読む(値は表示されない)
bash products/lien/scripts/e2e/run.sh check             # 環境の確認だけ(キー・プロジェクトの状態・フィクスチャ。データは作らない)
bash products/lien/scripts/e2e/run.sh run --cleanup     # 通しテスト → 最後に作ったデータを削除(ふだんはこれ)
bash products/lien/scripts/e2e/run.sh run               # データを残して中身を調べたいとき(あとで cleanup)
bash products/lien/scripts/e2e/run.sh cleanup --dry-run # 直近の run が作ったデータの削除予定だけ見る(SELECT のみ)
bash products/lien/scripts/e2e/run.sh cleanup           # 直近の run が作ったデータを削除
bash products/lien/scripts/e2e/run.sh cleanup --user <uuid> [--user <uuid> ...]   # ID を指定して削除(通しテストの目印がそろったものだけ。下の安全装置)
bash products/lien/scripts/e2e/run.sh list              # 残っている通しテストのものらしいユーザーを一覧(SELECT のみ。--user で消せるか否かも出す)
```

- 終了コード: 0 = すべて PASS / 1 = FAIL、または契約フィクスチャとのずれが 1 件でもある(または後片付けの失敗)/ 2 = 使い方・環境の誤り
- 環境変数: `SUPABASE_ACCESS_TOKEN`(アプリが使う公開キーの取得・DB の確認・後片付けに使う)/ `SUPABASE_ANON_KEY`(任意。指定すれば Management API なしで `run` できる)/ `PROJECT_REF` / `E2E_STATE_DIR`(作ったデータの ID を書く状態ファイルの置き場所。既定 `${TMPDIR:-/tmp}/lien-e2e`。リポジトリの外)
- オプション(`run`): `--cleanup`(後片付けに `SUPABASE_ACCESS_TOKEN` が要る。無いまま流すと、本番に何も作らずに終了コード 2 で止まる)/ `--no-outsider`(ペア外の C を作らない)/ `--no-db-checks`(最後の DB の SELECT を省く)/ `--force-time`(下の実行制限を無視。勧めない)
- `run.sh` は `deno run --no-prompt` で動かす。足りない権限は対話の許可プロンプトで聞かず、その場でエラーにする(TTY で「許可」されて、`--state` が `E2E_STATE_DIR` の外を読める、といったことがない)
- 所要時間は約 1 分(リクエスト約 200 回)。匿名サインインは **1 時間に 30 回まで**(Supabase の既定。IP ごと)で、1 回の実行で 3 回使う。続けて何度も流すと 429 になり、S01 で止まる
- **実行制限**: JST 23:50〜00:15 は動かない(00:05 の grant-tickets・00:10 の close-day と、日付の変わり目に重ならないように)。新しいペアの `started_on` は今日なので、昨日の確定の対象にも入らない

### 何を通すか(S 番号は出力と対応)

アプリが実際に送るヘッダ・本文の形で呼ぶ(Edge Functions は `Authorization: Bearer` だけ・PostgREST は `apikey` + `Authorization`・署名付きアップロードはどちらも付けない)。登場人物は新しい匿名ユーザー 3 人: A(招待する側)・B(受ける側)・C(ペア外。ソロのチェックインと、見えてはいけないものの確認に使う)。

| 手順 | 確かめること |
|---|---|
| S01 | 匿名サインアップ(JWT の role・sub・is_anonymous)・`users` の骨組み行(トリガー)・`refresh_token` での更新(同じユーザー ID のまま) |
| S02 | 認証なし・不正な JWT は 401 `unauthorized`・メソッド違い 405・壊れた JSON 400 |
| S03 | `users` の PATCH(アプリの `updateProfile` と同じ本文) |
| S04〜S06 | `GET /snapshot` の新規(`snapshot.empty.json`)とソロ(`snapshot.solo.json`)・`promise-set`(新規 / 編集 = 同じ id で `created:false` / 不正入力の 400) |
| S07 | ソロ: 写真の要求は 400 `no_pair`・日付の検査・C のソロのチェックイン(`checkin.solo.json`)と冪等 |
| S08 | `invite-create` → `invite-accept`(`invite-accept.ok.json`)・失敗系(形式・存在しない token・自分の招待・使用済み)・**1 ユーザー 1 ペア**: ペア済みの B が未ペアの C の招待を受けると 409 `already_paired`、未ペアの C が、ペア済みの A が成立前に作った 2 つ目の招待を受けると 409 `partner_already_paired`(どちらも claim の前に返るので、ペアも招待の使用状態も変わらない = 本番で安全に起こせる)・ペア成立後の `invite-create` は 409。「存在しない token」は `ZZZZ0000`(`0` はサーバーの生成器が出さない文字なので、実ユーザーの有効な招待と一致しない) |
| S09, S11, S15, S16 | 各段階の snapshot: 成立直後(段階 0・回数 0・次は 1 回)・A だけ完了(fidget・相手の写真あり)・ふたり達成(ストリーク 1・成長 1 回・段階 1・次は 3 回・happy)・A と B で共通の項目が同じ |
| S10 | 写真つきチェックイン: `requestPhotoUpload` → 署名付きアップロード(原寸 + サムネ)→ `photoPath` 付きで再送 → 差し替え(x-upsert)・本人の区画以外のパスは 400 `invalid_photo_path` |
| S12 | **#59 PV の経路**: 相手(B)が PostgREST で `checkins.photo_path` を読む → `POST /storage/v1/object/sign/photos/<path>` で署名付き URL を作る → ヘッダなしで GET して同じバイト列(SHA-256)が取れる。ペア外(C)・未ログイン・署名を改ざんした URL(署名部の途中の 1 文字を変える)は取れない。署名の**発行**の失敗は HTTP 400 + 本文の `statusCode` / `error` を `contracts/storage-sign.not-found.json`(#59 側の手書きフィクスチャ)と突き合わせる(HTTP 400 でなくなったら FAIL。フィクスチャが無い間は「ずれ」として FAIL) |
| S13, S14 | `nudge`(3 回まで・4 回目は 429・語彙外 400・完了済みの相手は 409)・`react`(新規 / 同じスタンプは `changed:false` / 6 種すべてに付け替え・自分のチェックインは 403・ペアなしは 409)・ペア外(C)・未ログインから `reactions` は見えない |
| S17 | `plant-name`: `first` は先着(2 人目は 409 `already_named` と今の名前)・`rename` は上書き・不正な名前(空・9 字・ゼロ幅・改行)は 400 |
| S18 | `checkin-cancel`(冪等・当日以外は 400)→ 成長回数が戻る → やり直しで「ふたり達成」に戻る・ソロの取消 |
| S19 | **PushTokenSync の経路**: 自分の `users.push_token` / `push_env` を読める(登録前は null)→ 書ける → 読み戻せる → `push_env` の不正値は CHECK で 400。相手の行は読めない・書き換えられない。push を送る操作をしても本処理は成功する。最後に偽のトークンを消す |
| S20 | クライアントから書けないもの: `premium_until`・`checkins` の直接 INSERT / DELETE・`plants`・Storage の写真の削除 |
| S21 | Management API で SELECT: 初期のお休みチケット 2 枚・close-day が走っていない(`streak_days` 0 行・`plants.grown_days` 0)・`nudges` 3 行・取消で `reactions` が CASCADE で消える・招待は使用済み 1 件と未使用 2 件(S08 の 409 で使われなかったもの)・Storage のオブジェクト数・作ったユーザーはすべて匿名でサインアップの印あり |
| S22 | ペア外(C)・未ログインから A–B ペアの `promises` / `pairs` / `pair_members` / `plants` / `nudges` / `ticket_ledger` / `streak_days` / `invites` が見えない。表ごとに同じ問い合わせを、メンバー(対照: 読めて行がある)・C(200 で 0 件)・未ログイン(GRANT が無いので 401 など。行が返らない)で流す。ペアの相手 B から A の `invites` も 0 件(`invites_select_own`)。`streak_days` は close-day を呼んでいないので行が無く、対照も 0 件(問い合わせが通ることと GRANT の確認にとどまる)。`reactions` は取消の CASCADE で消えるので S14 で確かめる。`users` / `checkins` / Storage は S19 / S12 |
| S23 | **pair-dissolve**(ブロック = ペア解消。T23 #23): 未ログイン 401・GET 405 → 解消の前(対照)は B が A の写真の署名付き URL を作れる → A が解消 `{ dissolved: true, snapshot }`(ソロの形・自分の約束と今日の完了は残る)→ A の再送・B からの解消は `dissolved: false`(冪等)→ B の snapshot がソロ → 解消後は B が A の写真の署名付き URL を作れない(HTTP 400)・A の今日の `checkins` 行と約束が B から読めない(0 件)・A は自分の履歴を読める・B の nudge は 409 `no_pair` → DB: ペアは `dissolved`・メンバー 2 人・植物の名前も残る(アーカイブ) |
| S24 | **組み直し**: 解消のあと A が `invite-create` → B が `invite-accept`(200)。新しいペアの ID は別で、植物の名前なし・ストリーク 0・成長 0 回(解消したペアの記録は復活しない) |
| S25 | **delete-account**(A。現役のペアあり): 未ログイン 401・GET 405 → DB: 削除の前に A の写真が Storage に 2 オブジェクト → 200 `{ deleted: true }` → A の JWT は `snapshot` が 401 `unauthorized`(認証サーバーの確定した拒否は 503 にならない)・もう一度の `delete-account` も 401・**認証サーバーに直接たしかめても 403 `user_not_found`**(アプリの `GoTrueSessionVerifier` が `.rejected` と見る応答)・refresh token も 4xx → B はソロに戻り、自分の `users` 行は無傷 → DB: A の auth・users・約束・チェックイン・所属・Storage の写真が 0、B の auth は 1、2 つのペアは `dissolved` で B だけが所属(植物の行も残る) |
| S26 | **delete-account**(B = 最後の所属者・C = ソロ): 200 → DB: 3 人の auth・users・約束・チェックイン・招待が 0、誰も残らなくなった 2 つのペアの行・所属・植物・台帳・nudges・Storage が連鎖して 0。**S25・S26 でテストユーザー自身を消す**ので、全部通ると A / B / C は存在しない(`--cleanup` は「記録にあるが、もう DB に無い」として扱う) |

応答は `products/lien/contracts/` のフィクスチャと **形(キー・型)** で突き合わせる(`e2e/shape.ts`)。フィクスチャは 1 つの状態の標本なので、同じ系統のフィクスチャを合成した形で見る(例: `snapshot` の `plantName` は名前の前は null・ソロはペア関連が null)。整数の標本には小数を許さない(Swift の `Int` でデコードできない)。新規ユーザー・ソロ・ペア成立直後のように値が決まっている状態は、**値まで**フィクスチャと比べる。エラーは `errors.json` のコードと HTTP ステータスに一致するかを見る。ずれは FAIL にして、最後に「契約フィクスチャとのずれ」にまとめる。

### 読み方

- `PASS` 期待どおり / `FAIL` 期待と違う(終了コード 1)/ `NOTE` 失敗ではないが知っておくべき観測 / `SKIP` 前提が満たされず確認できなかった
- FAIL の行の下に、期待と実際(応答の抜粋。鍵・JWT は伏せる)が出る。FAIL のまま終わっても作ったデータの ID は状態ファイルに残る(`cleanup` で消せる)
- 「作ったデータ」のブロックに ID が出る(この端末の画面だけ。issue・ログ・コミットには貼らない。台帳 §8 には ID を書く)

### 作るデータと後片付け

- **S25・S26 が `delete-account` でテストユーザー自身を消す**(2026-10-13 に足した。T23 #23)。最後まで通れば A / B / C・2 つのペア・Storage の写真はすべて消えていて、`--cleanup` は「記録にあるが、もう DB に無い」ものとして何もしない。途中で失敗・中断したときに残ったものを、下の `cleanup` が消す
- 作るもの: 匿名ユーザー 3 人(サインアップの印 `lien_e2e`・`E2E-A` / `E2E-B` / `E2E-C`・絵文字 🧪)・ペア 1 組(+ 植物・お休みチケットの初期付与・招待 3 通 = 使用済み 1・未使用 2)・チェックイン・nudge・Storage の写真 2 枚(`pairs/<ペア>/<今日>/<A>/photo.jpg` と `photo_thumb.jpg`)
- 消す順序(`cleanup`): ① Storage の実体(Storage API。**secret key をこの削除にだけ**使い、Management API から取って表示しない)② `pairs`(`pair_members` / `plants` / `streak_days` / `ticket_ledger` / `nudges` / `ticket_grant_runs` が CASCADE)③ `auth.users`(`public.users` → `promises` / `checkins` / `reactions` / `invites` が CASCADE)。ペアは users から CASCADE されないので先に消す。最後に SELECT で残りが 0 件であることを確かめる。この順序は T23(アカウント削除)の予行にもなる
- 安全装置(実ユーザーも同じ匿名ユーザーで、ニックネームは自由に付けられるので、ニックネームだけでは区別しない): 消すのは「この実行が状態ファイルに記録した ID」か `--user` で明示した ID だけ(ニックネームでの一括削除はしない)。対象のユーザーは**次の目印をすべて満たすものだけ**(`e2e/marker.ts`): 匿名ユーザー・**サインアップ時の印 `lien_e2e = true`**(`auth.users.raw_user_meta_data`。`signup` の `data` に入れる。アプリは付けない)・ニックネームが `E2E-A/B/C`(状態ファイルのときに限り空も可)・約束のタイトルがすべて「E2E 」で始まる・`--user` 指定のときはさらに絵文字 🧪。**1 人でも満たさなければ、何も消さずに止まる**(止めるメッセージにはユーザー ID と理由だけを出し、ニックネームなどの中身は出さない)。対象のペアに対象外のメンバーがいる、またはメンバー一覧を配列として読めないときも止まる(確かめられないものは消さない)。ID は UUID の形式を検査してから SQL に入れる。`--dry-run` は SELECT だけ。`list` も同じ判定を使い、`--user` で消せるものと、消せないもの(印の無い `E2E-A`・途中で止まった実行の残りなど)を分けて出す。印を付ける前の版の実行が残した行は印が無いので `cleanup` が止まる(残っているときは、中身を確かめてから、明示した ID だけを SQL で手で消す。2026-10-13 時点で残りは無い)
- 状態ファイルは ID だけ(JWT・鍵は書かない)。`cleanup` は直近のものを使う。`--state` で指定できるのは `E2E_STATE_DIR` の中のものだけ。`--user` と `--state` は同時に指定できず、`--user=`(空の値)は使い方の誤りとして止まる(直近の状態ファイルの削除に黙って切り替わらない)
- 実行前後で、`auth.users` / `pairs` / Storage のオブジェクトの件数は変わらない(2026-10-13 に確認)

### 本番で確かめた契約(#59 PV の実装向けに)

- 相手の当日の行: `GET /rest/v1/checkins?select=id,user_id,date_local,photo_path&date_local=eq.<今日>&user_id=neq.<自分>&limit=1`(`apikey` + `Authorization: Bearer <JWT>`)→ 200 `[{id, user_id, date_local, photo_path}]`。`photo_path` は原寸のパス。サムネのパスは同じ区画の `photo_thumb.jpg`(行には持たない)
- 署名付き URL: `POST {base}/storage/v1/object/sign/photos/<photo_path>`(`apikey` + `Authorization`、本文 `{"expiresIn": 3600}`。アプリの `StoragePhotoURLSigner.expiresInSeconds` と通しテストが使う値)→ 200 `{"signedURL": "/object/sign/photos/<path>?token=..."}`。画像の URL は **`{base}/storage/v1` + signedURL**。これをヘッダなしで GET すると 200・`image/jpeg`
- 署名の**発行**に失敗するとき(ペア外・存在しないオブジェクト・未ログイン)は **HTTP 400** で本文が `{"statusCode":"404","error":"not_found","message":"Object not found",...}` になる(HTTP ステータスは 404 ではない)。クライアントは「200 以外 = 静かに植物だけに戻す」でよい。取消されて行が消えた日は、そもそも行が 0 件になる
- 署名付き URL の**取得**(GET)が失敗するとき: 寿命切れは **HTTP 400** `{"statusCode":"400","error":"InvalidJWT","message":"\"exp\" claim timestamp check failed"}`、トークンの改ざんも 400。アプリの `.expired`(400 / 401 / 403 → 署名からやり直す)と合う。「署名は有効だがオブジェクトが消えた」ときの GET のステータスは未確認(取消時に写真を消す案 #68 が入ったら確かめる)
- 署名付きアップロード(`PUT {base}/storage/v1/object/upload/sign/photos/<path>?token=...`)は、アプリの `uploadPhoto` の現状の形(`Content-Type: image/jpeg` と `x-upsert: true` だけ。`apikey` も `Authorization` も付けない)で通る。同じパスへの差し替えも通る

### 2026-10-13 の結果(初回)

最終回: **244 項目 PASS・FAIL 0**・NOTE 3・SKIP 0。契約フィクスチャとの突き合わせは形(キー・型)34 回・値 4 回で、ずれ 1 件(下の NOTE 1)。Edge Function の応答のフィクスチャ 14 ファイル(`snapshot` 3 状態・`checkin` 3 種・`checkin-cancel`・`promise-set`・`invite-create` / `invite-accept`・`nudge`・`react`・`plant-name` 2 種)は、本番の実応答と形が一致した。エラーは `errors.json` のコード 28 種類(のべ 53 回。HTTP ステータスとの組)を引き出して一致を確認した。未確認なのは、本番では安全に起こせないもの(500 系・`user_not_found`・`invite_expired`・`plant_not_found`・`token_generation_failed`)と、APNs のペイロード(`push.*.json`。実機・APNs が要る)。スタンプは react の 6 種すべてと nudge の 3 種(1 日 3 回の上限のため)を通した。PV の手書きフィクスチャ(`partner-checkin.*.json` / `storage-sign.ok.json`)の形も一致した。

- NOTE 1: 署名付き URL の**発行**(`POST …/object/sign/photos/<path>`)の失敗は、ペア外・存在しないオブジェクト・未ログインのいずれも **HTTP 404 でなく 400**(本文が `{"statusCode":"404","error":"not_found",...}`)。`contracts/README.md` の手書きフィクスチャの説明(404 = 無い・読めない)と、`StoragePhotoURLSigner`(404 だけ `notFound`)は実態とずれる。実際は `.server(400)` になるが、結果(写真を出さない・サムネが無いときは原寸で代わりを作る)は同じ。説明か写像をそろえるのは #59 側
- NOTE 2: 取消後も写真の実体が Storage に残り、相手は決まったパスから署名付き URL を作って取れる(通常のアプリの画面からは見えない)。DESIGN §5.7-3 の前提が #59 の方式で崩れている → **issue #68**
- NOTE 3: APNs の secrets(`APNS_AUTH_KEY` / `APNS_KEY_ID` / `APPLE_TEAM_ID` / `APNS_ENV` / `APNS_TOPIC`)が 5 つとも未設定で、push は送られない(G0 待ち)。偽のトークンは残る。G0 のあとに流すと、偽のトークンが 400 BadDeviceToken で掃除される側の観測に変わる(DESIGN §4.1)
- 最も遅い呼び出しは 1〜3 秒(Edge Function の初回呼び出し・Management API の SQL)

### 2026-10-13 の結果(Opus レビューの修正後)

初回の通しテストへの Opus レビュー(issue #67)の指摘を直し、本番で流し直した。

- 最終回(`run --cleanup`): **263 項目 PASS・FAIL 0**・NOTE 2・SKIP 0。契約フィクスチャとの突き合わせは形(キー・型)35 回・値 4 回で、ずれ 0 件。作ったデータは `--cleanup` で削除し、users・pairs・invites・promises・checkins・Storage のオブジェクトの件数が実行前と同じに戻ったことを SELECT で確認した。NOTE が 3 → 2 になったのは、署名の**発行**の失敗(HTTP 400)が、NOTE + ずれから、手書きフィクスチャ `storage-sign.not-found.json` との突き合わせ(PASS)に変わったため
- 直したもの:
  - **招待 token の正規表現**が仕様より狭く、大文字の `I` も除いていた。本物の生成器で 20 万回作ると 13% の token が通らず、約 8 回に 1 回は S08 が偽の FAIL になった(本番の 4 回が PASS だったのは偶然)。仕様どおり `0` `O` `1` `l` だけを除く式にして、サーバーの文字集合(`invite-create/core.ts` の `INVITE_TOKEN_ALPHABET`)の 58 文字がすべて通ること・生成器の token がすべて通ることを単体テストで固定した(同じ 20 万回で 0 件)
  - 後片付けと一覧の安全装置を強めた(サインアップの印・絵文字・約束の接頭辞。上の「安全装置」)。`--user=`(空の値)は黙って直近の状態ファイルの削除に切り替わらず、使い方の誤りとして止まる。メンバー一覧が配列として読めないペアは「メンバーなし」として素通りせず止まる(fail-closed)
  - 署名付き URL の改ざんの確認は、署名部の途中の 1 文字を変える。以前は URL の最後の文字を変えていて、署名の最後の文字は下位 2 ビットが詰め物なので、末尾が `A` のとき(1/16)に寛容な復号では同じ署名バイトになり、偽の FAIL がありえた
  - 契約フィクスチャとのずれが 1 件でもあれば終了コード 1(以前は「ずれ 1 件」なのに「結果: PASS」になりえた)。`run --cleanup` は、Management API のトークンが無ければ、本番に何も作らずに終了コード 2 で止まる。「存在しない token」は `ZZZZ0000`(サーバーの生成器が出さない文字を含むので、実ユーザーの有効な招待と一致しない)。`run.sh` に `--no-prompt`
  - lien-ci に `e2e-tests` ジョブを足した(単体テスト 61 件 + `e2e.ts` の型検査。以前は CI で一度も走っていなかった)
- 足した確認: S08 の 409 `already_paired` / `partner_already_paired`(初回は「本番では安全に起こせない」として未確認だったが、どちらも claim の前に返るので副作用がなく、未ペアの C を使えば起こせる)・S14 の `reactions`・S22(ペア外・未ログインから 8 つの表が見えない)・S21 の未使用の招待とサインアップの印
- 安全装置を本番でも確かめた(いずれも終わったら削除済み): 印のある A / B / C を `--user` で指定すると通り、削除後に残りは 0 件 / `--user` で A だけを指定すると、ペアの相手が対象外で止まる / 本番にもともとある別のテストユーザー(台帳 §8 のもの)を `--user --dry-run` で指定すると、印・ニックネーム・絵文字・約束のどれも合わず止まる(何も消えない)/ 契約フィクスチャの一部を隠した複製で流すと、ずれ 1 件で「結果: FAIL」(終了コード 1)になり、後片付けは済む

### 変更するとき

- 応答の形が変わったら、`contracts/tools/generate.ts` でフィクスチャを再生成する(`contracts/README.md`)。通しテストはフィクスチャを読むだけなので自動で追従する(キーや型が変わった / 増えたら、本番に出す前後でずれとして FAIL になる)
- 新しい API やエラーコードを足したら、`steps_*.ts` に手順を足す(`rep.run("S23", ...)`。`scenario.ts` の一覧にも書く)。共有の道具は `scenario_lib.ts`。`errors.json` にあるコードの確認は `expectError`
- 単体テスト(ネットワーク不要。形の突き合わせ・フィクスチャの読み込み・後片付けの安全装置・招待 token の形・引数の解釈): `deno test --allow-read products/lien/scripts/e2e/`。型検査は `deno check products/lien/scripts/e2e/e2e.ts`。どちらも lien-ci の `e2e-tests` ジョブで回る
- 招待 token の仕様(`0` `O` `1` `l` だけを除く 58 文字)を変えるときは、`invite-create/core.ts` と `scenario_lib.ts` の `INVITE_TOKEN_RE` を一緒に直す(`scenario_lib_test.ts` が食い違いで落ちる)
- close-day / grant-tickets は呼ばない(§10)。両方を通したいときは、§4 の手動の再実行と §2 の監視の手順に従う

## 13. 運営がユーザーを削除する・停止するとき(通報への対応など。issue #23 のレビュー指摘)

利用者本人の削除は `delete-account` Function(アプリの設定 →「アカウントを削除する」)が行う。**運営が他人のアカウントを消す手段はこの Function にはない**(対象は呼び出した本人の JWT の userId だけ)。通報への対応などで運営が消すときは、**ダッシュボードで auth ユーザーを直接消さない**。

### なぜ直接消してはいけないか

auth ユーザーを消すと `public.users` と、そこから CASCADE でつながる行(`pair_members.user_id` を含む。migration 0001)が消える。しかし **`pairs` の行は `status = 'active'` のまま残り、相手の `pair_members` だけが残る**。

- 相手の画面は、`getActivePair` が相手方の所属を見つけられず `null` を返すので、ソロに見える。しかし**ペアの解消(`pair-dissolve`)も同じ `getActivePair` を使うので、`dissolved: false` で何も起きない**(幽霊のペアが DB に残り続ける)
- 相手が新しい招待を受けると、現役のペアの所属が 2 行になり、`getActivePair`(`maybeSingle`)が壊れて、以後その人の `snapshot` などが 500 になりうる
- Storage の写真は消えない(行を辿れなくなって、孤児として残る)

### 手順(`delete-account` と同じ順序。失敗したらやり直せる)

`bash products/lien/scripts/ops/db-query.sh "<SQL>"`(`set -a; source .env; set +a` のあと。書き込みも通るので、対象の `<uid>` を必ず確かめてから)。

1. **現役のペアを解消する**(行は消さない。相手の履歴・植物はアーカイブとして残る):
   `update public.pairs set status = 'dissolved', dissolved_at = now() where status = 'active' and id in (select pair_id from public.pair_members where user_id = '<uid>');`
   相手のアプリには、次の同期(前面復帰・push 受信)でソロに戻る。**運営の SQL は相手にサイレント更新を送らない**(`pair-dissolve` / `delete-account` だけが送る)
2. **本人の写真を Storage から消す**: 対象は `pairs/<pair_id>/<date_local>/<uid>/photo.jpg` と `photo_thumb.jpg`(`select name from storage.objects where bucket_id = 'photos' and name like 'pairs/%/<uid>/%'` で一覧を出し、**Storage API で remove**。SQL で `storage.objects` の行を消しても実体は消えない)。通報された写真だけを消すなら、この手順だけでよい
3. **本人の所属と、本人しか居ないペアを消す**: まず本人しか所属していないペア(相手が先に消えていたもの)を `delete from public.pairs where id = '<pair_id>';`(`pair_members`・`plants`・`streak_days`・`ticket_ledger`・`nudges` が連鎖)、続けて `delete from public.pair_members where user_id = '<uid>';`
4. **auth ユーザーを消す**: ダッシュボードの Authentication → Users → Delete user(または Auth の admin API)。`public.users` と、`promises`・`checkins`・`reactions`・`nudges`・`invites` が CASCADE で消える

- 停止だけ(消さない)で足りるときは、手順 1(ペアの解消 = 相手との共有を止める)と 2(該当の写真の削除)までにする。アカウントの停止そのもの(サインインを止める)の仕組みは v1.0 には無い
- 通報への対応の期限・基準(terms 第 6 条の「容認しない」「24 時間以内」の文言)は G4(#42)で人間が決める。決まったら、この節に対応の記録の書き方(通報の ID・対応・日時。**公開リポジトリなので個人情報・内容は書かない**)を足す
- 手順の模範は `scripts/e2e/cleanup.ts`(通しテストのユーザーを Storage → pairs → auth.users の順で消す。印の無いユーザーは消さない安全装置つき)。実ユーザーに使うときは、あの安全装置は効かない(印が無いため)ので、ID を二重に確かめる
