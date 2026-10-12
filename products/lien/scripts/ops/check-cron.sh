#!/usr/bin/env bash
# check-cron.sh — 本番の cron(close-day / grant-tickets)の健全性を確認する(読み取りだけ)
#
#   毎朝 00:40 JST の GitHub Actions(lien-cron-watch)と同じ検査を手元で実行する。
#   /status や、workflow が赤になったときの切り分けに使う。検査の中身は cron_check.ts。
#
# 使い方:
#   set -a; source .env; set +a        # SUPABASE_ACCESS_TOKEN を環境変数に読む(値は表示されない)
#   bash products/lien/scripts/ops/check-cron.sh
#   MAX_AGE_HOURS=0 bash products/lien/scripts/ops/check-cron.sh   # 必ず赤になる(失敗時の動作確認)
#
# 終了コード: 0 = 赤なし(黄色の警告はありうる)/ 1 = 赤あり / 2 = 使い方の誤り
#
# 環境変数:
#   SUPABASE_ACCESS_TOKEN  (必須)sbp_...
#   PROJECT_REF            (任意)既定 lniheehfbtpfhglinfjm
#   MAX_AGE_HOURS          (任意)最後の起動の許容経過時間の上限。既定 26(通常は予定の回の検査が先に働く。0 で必ず赤)
#
# 注意: 本番 DB を SELECT するだけ。秘密の値は取得も表示もしない(SHA-256 の照合)

set -euo pipefail

if [ -z "${SUPABASE_ACCESS_TOKEN:-}" ]; then
  echo "ERROR: SUPABASE_ACCESS_TOKEN を設定してください(set -a; source .env; set +a)" >&2
  exit 2
fi

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# deno は PATH に無いことが多い(~/.deno/bin/deno)
if command -v deno > /dev/null 2>&1; then
  DENO="deno"
elif [ -x "$HOME/.deno/bin/deno" ]; then
  DENO="$HOME/.deno/bin/deno"
else
  echo "ERROR: deno が見つかりません(https://deno.com または ~/.deno/bin/deno)" >&2
  exit 2
fi

exec "$DENO" run \
  --allow-net=api.supabase.com \
  --allow-env=SUPABASE_ACCESS_TOKEN,PROJECT_REF,MAX_AGE_HOURS,GITHUB_ACTIONS,GITHUB_STEP_SUMMARY \
  "$HERE/cron_check.ts"
