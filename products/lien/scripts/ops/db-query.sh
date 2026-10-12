#!/usr/bin/env bash
# db-query.sh — 本番 Supabase に SQL を1回流して結果を JSON で表示する(Management API 経由)
#
#   運用の読み取り(cron の監視など)用。scripts/OPS.md の SQL をそのまま渡せる。
#
# 使い方:
#   set -a; source .env; set +a        # SUPABASE_ACCESS_TOKEN を環境変数に読む(値は表示されない)
#   bash products/lien/scripts/ops/db-query.sh "select jobname, schedule, active from cron.job"
#   bash products/lien/scripts/ops/db-query.sh -f path/to/query.sql
#
# 環境変数:
#   SUPABASE_ACCESS_TOKEN  (必須)https://supabase.com/dashboard/account/tokens で発行した sbp_...
#   PROJECT_REF            (任意)既定 lniheehfbtpfhglinfjm
#
# 注意:
#   - 書き込み系の SQL も通る。変更は migration として書き、レビューを通すこと
#   - トークンは python3 の中で使うだけで、コマンドライン引数・出力には出さない
#   - Cloudflare 対策で User-Agent を付ける(付けないと 403 になることがある)

set -euo pipefail

: "${SUPABASE_ACCESS_TOKEN:?SUPABASE_ACCESS_TOKEN を設定してください(set -a; source .env; set +a)}"
export PROJECT_REF="${PROJECT_REF:-lniheehfbtpfhglinfjm}"

command -v python3 > /dev/null || { echo "ERROR: python3 が必要です" >&2; exit 1; }

if [ "${1:-}" = "-f" ]; then
  [ -n "${2:-}" ] && [ -f "$2" ] || { echo "ERROR: -f にはファイルを指定してください" >&2; exit 1; }
  SQL="$(cat "$2")"
elif [ -n "${1:-}" ]; then
  SQL="$1"
else
  echo "使い方: $0 \"<SQL>\"   または   $0 -f <file.sql>" >&2
  exit 1
fi
export SQL

python3 - << 'PY'
import json, os, sys, urllib.request, urllib.error

req = urllib.request.Request(
    "https://api.supabase.com/v1/projects/%s/database/query" % os.environ["PROJECT_REF"],
    data=json.dumps({"query": os.environ["SQL"]}).encode("utf-8"),
    method="POST",
    headers={
        "Authorization": "Bearer " + os.environ["SUPABASE_ACCESS_TOKEN"],
        "Content-Type": "application/json",
        "User-Agent": "lien-agent/1.0",
    },
)
try:
    with urllib.request.urlopen(req, timeout=120) as r:
        status, raw = r.status, r.read().decode("utf-8", "replace")
except urllib.error.HTTPError as e:
    status, raw = e.code, e.read().decode("utf-8", "replace")

try:
    print(json.dumps(json.loads(raw), ensure_ascii=False, indent=2))
except ValueError:
    print(raw)
if not 200 <= status < 300:
    print("ERROR: HTTP %d" % status, file=sys.stderr)
    sys.exit(1)
PY
