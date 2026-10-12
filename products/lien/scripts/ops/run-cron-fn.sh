#!/usr/bin/env bash
# run-cron-fn.sh — cron 専用 Edge Function(close-day / grant-tickets)を手動で呼ぶ
#
#   cron が動かなかった日の取りこぼしを埋める、または動作を手で確かめるときに使う。
#   scripts/OPS.md の「取りこぼしの再実行」から呼ぶ。
#
# 使い方:
#   set -a; source .env; set +a        # SUPABASE_ACCESS_TOKEN を環境変数に読む(値は表示されない)
#
#   # close-day: 指定した日(JST の date_local)を確定する。範囲指定は古い日から新しい日の順に実行
#   bash products/lien/scripts/ops/run-cron-fn.sh close-day 2026-10-01 2026-10-11   # 両端を含む
#   bash products/lien/scripts/ops/run-cron-fn.sh close-day 2026-10-11              # 1日だけ
#
#   # grant-tickets: 取りこぼした月の付与。月の1日の日付を1つだけ渡す。確認の環境変数が必須
#   CONFIRM_GRANT=yes bash products/lien/scripts/ops/run-cron-fn.sh grant-tickets 2026-11-01
#
# 通知(重要):
#   close-day は **常に notify:false** で呼ぶ(リセット・チケット消費の通知を送らない)。
#   リセットの日は streak_days に行が残らないので、再実行するとその日のリセット通知(「また今日から」)を
#   もう一度送ってしまう。取りこぼした日の通知は、何時間も何日も遅れて届くと混乱するので送らない。
#   データ(streak_days・チケット・植物)は通常どおり確定する。
#
# 注意:
#   - close-day は冪等(確定済みの日は skipped になり、何も書かない・何も送らない)。ただし必ず古い日から
#     新しい日へ(ストリーク・チケットの判定が前日に依存するため。範囲指定はその順で実行)
#   - 確定できるのは終わった日だけ(JST の昨日まで)。今日・未来はサーバーが 400 で断る
#   - **月をまたいで止まっていたとき**は、1回の範囲指定で通さず、OPS.md「月をまたぐ停止」の順に分ける
#     (前月末日の前日まで close-day → grant-tickets → 残り)。付与は 00:05、前月末日の確定は 00:10 に
#     動く(= 付与が先)ので、その順を再現しないと、付与で救えたはずのリセットが起きる
#   - grant-tickets は月ごとの実行記録(ticket_grant_runs)で冪等。同月に処理済みのペアはスキップされるので、
#     月の途中に動かしても二重付与しない。未来の月はサーバーが 400 で断る
#
# 認証:
#   cron 専用シークレット LIEN_CRON_SECRET(Function secrets)と同じ値が Vault の lien_cron_secret にある。
#   Management API 経由で Vault から読んで Bearer に使う(service role key は使わない・受け付けられない)。
#   値は変数に入れて使うだけで、画面・ログには出さない。
#
# 環境変数:
#   SUPABASE_ACCESS_TOKEN  (必須)sbp_...
#   PROJECT_REF            (任意)既定 lniheehfbtpfhglinfjm

set -euo pipefail

: "${SUPABASE_ACCESS_TOKEN:?SUPABASE_ACCESS_TOKEN を設定してください(set -a; source .env; set +a)}"
export PROJECT_REF="${PROJECT_REF:-lniheehfbtpfhglinfjm}"
export FN="${1:-}"
export FROM_DATE="${2:-}"
export TO_DATE="${3:-${2:-}}"
export CONFIRM_GRANT="${CONFIRM_GRANT:-}"

case "$FN" in
  close-day | grant-tickets) ;;
  *)
    echo "使い方: $0 close-day <from YYYY-MM-DD> [<to>]" >&2
    echo "        CONFIRM_GRANT=yes $0 grant-tickets <YYYY-MM-01>" >&2
    exit 1
    ;;
esac
[ -n "$FROM_DATE" ] || { echo "ERROR: 日付 (YYYY-MM-DD) を指定してください" >&2; exit 1; }

command -v python3 > /dev/null || { echo "ERROR: python3 が必要です" >&2; exit 1; }

python3 - << 'PY'
import datetime, json, os, sys, urllib.request, urllib.error

REF = os.environ["PROJECT_REF"]
FN = os.environ["FN"]
UA = "lien-agent/1.0"  # Cloudflare 対策

def http(method, url, headers, body=None):
    data = body.encode("utf-8") if body is not None else None
    req = urllib.request.Request(url, data=data, method=method, headers=dict(headers, **{"User-Agent": UA}))
    try:
        with urllib.request.urlopen(req, timeout=120) as r:
            return r.status, r.read().decode("utf-8", "replace")
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode("utf-8", "replace")

def parse_date(s):
    try:
        return datetime.date.fromisoformat(s)
    except ValueError:
        sys.exit("ERROR: 日付は YYYY-MM-DD で指定してください: %s" % s)

start, end = parse_date(os.environ["FROM_DATE"]), parse_date(os.environ["TO_DATE"])
if end < start:
    sys.exit("ERROR: to が from より前です")

JST = datetime.timezone(datetime.timedelta(hours=9))
today_jst = datetime.datetime.now(JST).date()

if FN == "grant-tickets":
    if start != end or start.day != 1:
        sys.exit("ERROR: grant-tickets は「月の1日」の日付を1つだけ指定してください(例 2026-11-01)")
    if start.replace(day=1) > today_jst.replace(day=1):
        sys.exit("ERROR: 未来の月は付与できません(実行記録が残って、その月の本当の cron が空振りします)")
    if os.environ.get("CONFIRM_GRANT") != "yes":
        sys.exit("ERROR: grant-tickets は「取りこぼした月の付与」専用です。その月の cron が動かなかったと確認できたら"
                 " CONFIRM_GRANT=yes を付けて再実行してください(同月に処理済みのペアは実行記録でスキップされます)")
else:
    if (end - start).days > 120:
        sys.exit("ERROR: 範囲が広すぎます(120日まで)。分けて実行してください")
    if end >= today_jst:
        sys.exit("ERROR: 確定できるのは終わった日だけです(JST の昨日 %s まで)" % (today_jst - datetime.timedelta(days=1)).isoformat())

# 1. cron 専用シークレットを Vault から読む(Management API 経由。値は画面に出さない)
st, raw = http("POST", "https://api.supabase.com/v1/projects/%s/database/query" % REF,
               {"Authorization": "Bearer " + os.environ["SUPABASE_ACCESS_TOKEN"], "Content-Type": "application/json"},
               json.dumps({"query": "select decrypted_secret from vault.decrypted_secrets where name = 'lien_cron_secret'"}))
if st not in (200, 201):
    sys.exit("ERROR: Vault の読み取りに失敗 (HTTP %d)" % st)
rows = json.loads(raw)
if not rows or not rows[0].get("decrypted_secret"):
    sys.exit("ERROR: Vault に lien_cron_secret がありません。scripts/OPS.md の「鍵の更新」で作成してください")
secret = rows[0]["decrypted_secret"]

url = "https://%s.supabase.co/functions/v1/%s" % (REF, FN)
def call(d):
    body = {"dateLocal": d.isoformat()}
    if FN == "close-day":
        body["notify"] = False  # 通知を再送しない(上の「通知」参照)
    return http("POST", url, {"Authorization": "Bearer " + secret, "Content-Type": "application/json"},
                json.dumps(body))

failed = False
day = start
while day <= end:
    st, body = call(day)
    print("%s %s HTTP %d %s" % (FN, day.isoformat(), st, body))
    if st == 401:
        print("  → 認証に失敗しました。Vault の lien_cron_secret と Function secrets の LIEN_CRON_SECRET が"
              "違う可能性があります。scripts/OPS.md の「鍵の更新」を参照", file=sys.stderr)
    if st != 200:
        failed = True
        break
    day += datetime.timedelta(days=1)
sys.exit(1 if failed else 0)
PY
