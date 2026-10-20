#!/usr/bin/env bash
# partner.sh — 審査用デモの相手役(issue #30)を deno で実行するラッパ
#
#   本番に匿名ユーザーを1人作る手動実行専用(CI では動かさない)。使い方と注意は README.md。
#
# 使い方(リポジトリルートから):
#   export SUPABASE_ANON_KEY='<公開キー(anon / publishable)>'   # service_role は使わない
#   bash products/lien/scripts/review-demo/partner.sh create --slot 1
#   bash products/lien/scripts/review-demo/partner.sh status --slot 1
#   bash products/lien/scripts/review-demo/partner.sh checkin --slot 1
#   bash products/lien/scripts/review-demo/partner.sh delete --slot 1
#
# 環境変数:
#   SUPABASE_ANON_KEY       (必須)公開キー。Supabase Dashboard > Project Settings > API keys
#   SUPABASE_URL            (任意)既定 https://lniheehfbtpfhglinfjm.supabase.co
#   PROJECT_REF             (任意)通信を許すホストの指定。既定 lniheehfbtpfhglinfjm
#   REVIEW_DEMO_STATE_DIR   (任意)状態ファイルの置き場所。既定 ~/.lien-review-demo(リポジトリの外)
#
# 権限は必要最小限: 本番 Supabase への通信・状態ファイルの読み書き・写真の読み取りだけ。
# 鍵と refresh_token は表示しない(状態ファイルは 0600)。

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REF="${PROJECT_REF:-lniheehfbtpfhglinfjm}"
STATE_DIR="${REVIEW_DEMO_STATE_DIR:-${HOME}/.lien-review-demo}"
STATE_DIR="${STATE_DIR%/}"

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
chmod 700 "$STATE_DIR" 2> /dev/null || true

exec "$DENO" run \
  --no-prompt \
  --allow-net="${REF}.supabase.co" \
  --allow-env=SUPABASE_URL,SUPABASE_ANON_KEY,REVIEW_DEMO_STATE_DIR,HOME,PROJECT_REF \
  --allow-read \
  --allow-write="$STATE_DIR" \
  "$HERE/partner.ts" "$@"
