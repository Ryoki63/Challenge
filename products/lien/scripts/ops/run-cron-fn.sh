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
# 注意:
#   - close-day は冪等(確定済みの日は skipped になる)。迷ったら範囲を広めに取ってよい
#     ただし必ず古い日から新しい日へ(ストリーク・チケットの判定が前日に依存するため。範囲指定はその順で実行)
#   - grant-tickets は月の途中に動かしてはいけない(上限に達していたペアは冪等キーの ledger 行が残らず、
#     チケットを使った後に再付与される — docs/GROWTH.md §7.1)。その月の付与を丸ごと取りこぼしたときだけ使う
#
# 認証:
#   両関数は「Authorization: Bearer <Edge Function が見る SUPABASE_SERVICE_ROLE_KEY>」の完全一致で認証する。
#   このプロジェクトではその値は default の secret key(sb_secret_...)で、legacy の service_role(eyJ...)
#   ではない(2026-10-12 実測)。そこで Management API でプロジェクトの API キーを引き、
#   secret(default 優先)→ legacy service_role の順に、401 にならないキーを使う。
#   鍵は変数に入れて使うだけで、画面・ログには出さない。
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

if FN == "grant-tickets":
    if start != end or start.day != 1:
        sys.exit("ERROR: grant-tickets は「月の1日」の日付を1つだけ指定してください(例 2026-11-01)")
    if os.environ.get("CONFIRM_GRANT") != "yes":
        sys.exit("ERROR: grant-tickets は月の途中に動かすと再付与が起きます。"
                 "その月の付与を丸ごと取りこぼしたと確認できたら CONFIRM_GRANT=yes を付けて再実行してください")
else:
    if (end - start).days > 120:
        sys.exit("ERROR: 範囲が広すぎます(120日まで)。分けて実行してください")

# 1. プロジェクトの API キー(候補)を取得: secret(default 優先)→ legacy service_role
st, raw = http("GET", "https://api.supabase.com/v1/projects/%s/api-keys?reveal=true" % REF,
               {"Authorization": "Bearer " + os.environ["SUPABASE_ACCESS_TOKEN"]})
if st != 200:
    sys.exit("ERROR: API キーの取得に失敗 (HTTP %d)" % st)
keys = json.loads(raw)
secrets = sorted([k for k in keys if k.get("type") == "secret"], key=lambda k: k.get("name") != "default")
legacy = [k for k in keys if k.get("name") == "service_role"]
candidates = [k["api_key"] for k in secrets + legacy if k.get("api_key")]
if not candidates:
    sys.exit("ERROR: 使える API キーが見つかりません")

url = "https://%s.supabase.co/functions/v1/%s" % (REF, FN)
def call(key, d):
    return http("POST", url, {"Authorization": "Bearer " + key, "Content-Type": "application/json"},
                json.dumps({"dateLocal": d.isoformat()}))

# 2. 最初の日で 401 にならないキーを選ぶ(401 は何も処理されないので試して安全)
day = start
chosen = None
for key in candidates:
    st, body = call(key, day)
    if st != 401:
        chosen = key
        break
if chosen is None:
    sys.exit("ERROR: どのキーも %s に認証されませんでした(401)。scripts/OPS.md「鍵」を参照" % FN)

failed = False
while day <= end:
    if day != start:
        st, body = call(chosen, day)
    print("%s %s HTTP %d %s" % (FN, day.isoformat(), st, body))
    if st != 200:
        failed = True
        break
    day += datetime.timedelta(days=1)
sys.exit(1 if failed else 0)
PY
