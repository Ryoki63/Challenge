#!/usr/bin/env bash
# run.sh — 本番に対する 2 ユーザーの API 通しテスト(issue #67)を deno で実行するラッパ
#
#   本番にテスト用の匿名ユーザーを作って API を通す。手動実行専用(CI では動かさない)。
#   中身は e2e.ts。手順・読み方・後片付けは scripts/OPS.md の「通しテスト」。
#
# 使い方(リポジトリルートから):
#   set -a; source .env; set +a        # SUPABASE_ACCESS_TOKEN を環境変数に読む(値は表示されない)
#   bash products/lien/scripts/e2e/run.sh check              # 環境の確認だけ(データは作らない)
#   bash products/lien/scripts/e2e/run.sh run --cleanup      # 通しテスト → 最後に作ったデータを片付ける
#   bash products/lien/scripts/e2e/run.sh run                # 通しテスト(データは残る)
#   bash products/lien/scripts/e2e/run.sh cleanup --dry-run  # 直近の run の後片付けの予定だけ見る
#   bash products/lien/scripts/e2e/run.sh cleanup            # 直近の run が作ったデータを削除
#   bash products/lien/scripts/e2e/run.sh list               # 残っているテストユーザーの一覧(SELECT のみ)
#   bash products/lien/scripts/e2e/run.sh help
#
# 環境変数:
#   SUPABASE_ACCESS_TOKEN  (推奨)sbp_...。公開キーの取得・DB の確認・後片付けに使う
#   SUPABASE_ANON_KEY      (任意)アプリが使う公開キー(publishable / anon)。指定すれば Management API なしで run できる
#   PROJECT_REF            (任意)既定 lniheehfbtpfhglinfjm
#   E2E_STATE_DIR          (任意)作ったデータの ID を書く状態ファイルの置き場所。既定 ${TMPDIR:-/tmp}/lien-e2e
#
# 終了コード: 0 = すべて PASS / 1 = FAIL あり / 2 = 使い方・環境の誤り
#
# 注意: 本番に書き込む(匿名ユーザー・ペア・チェックイン・写真)。close-day / grant-tickets は呼ばない(OPS §10)。
#       鍵・JWT は表示しない。作ったデータは --cleanup か cleanup コマンドで消す。

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REF="${PROJECT_REF:-lniheehfbtpfhglinfjm}"
TMP_BASE="${TMPDIR:-/tmp}"
STATE_DIR="${E2E_STATE_DIR:-${TMP_BASE%/}/lien-e2e}"
STATE_DIR="${STATE_DIR%/}"
CONTRACTS_DIR="$(cd "$HERE/../../contracts" && pwd)"

# deno は PATH に無いことが多い(~/.deno/bin/deno)
if command -v deno > /dev/null 2>&1; then
  DENO="deno"
elif [ -x "$HOME/.deno/bin/deno" ]; then
  DENO="$HOME/.deno/bin/deno"
else
  echo "ERROR: deno が見つかりません(https://deno.com または ~/.deno/bin/deno)" >&2
  exit 2
fi

mkdir -p "$STATE_DIR"

# 権限は必要最小限: 本番の API と Management API だけに通信、状態ファイルの置き場所だけに書く
exec "$DENO" run \
  --allow-net="${REF}.supabase.co,api.supabase.com" \
  --allow-env=SUPABASE_ACCESS_TOKEN,SUPABASE_ANON_KEY,PROJECT_REF,E2E_STATE_DIR,TMPDIR,CI,E2E_ALLOW_CI,NO_COLOR \
  --allow-read="$CONTRACTS_DIR,$STATE_DIR" \
  --allow-write="$STATE_DIR" \
  "$HERE/e2e.ts" "$@"
