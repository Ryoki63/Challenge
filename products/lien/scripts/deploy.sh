#!/usr/bin/env bash
# deploy.sh — Lien バックエンドを Supabase へ冪等デプロイする
#
#   link → db push(migration)→ Edge Functions 8本 deploy
#
# 必要なもの:
#   - supabase CLI(https://supabase.com/docs/guides/cli)
#   - SUPABASE_ACCESS_TOKEN(https://supabase.com/dashboard/account/tokens)
#     ※ ローカルで `supabase login` 済みなら不要
#   - SUPABASE_DB_PASSWORD(db push に必要。未設定なら db push をスキップして警告)
#
# 使い方:
#   SUPABASE_ACCESS_TOKEN=sbp_... SUPABASE_DB_PASSWORD=... bash products/lien/scripts/deploy.sh
#   DRY_RUN=true bash products/lien/scripts/deploy.sh   # 前提チェックのみ(変更なし)
#
# 何度実行しても安全(link は上書き、db push は未適用 migration のみ、deploy は上書き)。
# verify_jwt=false は supabase/config.toml が正(このスクリプトでは指定しない)。

set -euo pipefail

# ---- 定数 ----------------------------------------------------------------
PROJECT_REF="${PROJECT_REF:-lniheehfbtpfhglinfjm}" # G0 で作成済み(issue #38)
LIEN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)" # = products/lien
FUNCTIONS=(checkin checkin-cancel snapshot invite-create invite-accept promise-set close-day grant-tickets)
DRY_RUN="${DRY_RUN:-false}"

step() { echo ""; echo "==> $*"; }
warn() { echo "WARN: $*" >&2; }
die()  { echo "ERROR: $*" >&2; exit 1; }

# ---- 前提チェック ----------------------------------------------------------
step "前提チェック"

command -v supabase > /dev/null 2>&1 \
  || die "supabase CLI が見つかりません。brew install supabase/tap/supabase などで導入してください"
echo "supabase CLI: $(supabase --version)"

# 認証: SUPABASE_ACCESS_TOKEN または supabase login 済みセッション
if ! AUTH_ERR="$(supabase projects list 2>&1 > /dev/null)"; then
  echo "--- supabase projects list の出力 ---" >&2
  echo "$AUTH_ERR" >&2
  die "Supabase CLI で projects list が通りません。SUPABASE_ACCESS_TOKEN を設定するか 'supabase login' を実行してください(上の出力が認証以外のエラーならそちらを解決)"
fi
echo "CLI 認証: OK"

[ -f "$LIEN_DIR/supabase/config.toml" ] \
  || die "config.toml が見つかりません: $LIEN_DIR/supabase/config.toml"

for fn in "${FUNCTIONS[@]}"; do
  [ -f "$LIEN_DIR/supabase/functions/$fn/index.ts" ] \
    || die "function のエントリポイントがありません: supabase/functions/$fn/index.ts"
done
echo "functions ${#FUNCTIONS[@]} 本のエントリポイント: OK"

HAS_DB_PASSWORD=true
if [ -z "${SUPABASE_DB_PASSWORD:-}" ]; then
  HAS_DB_PASSWORD=false
  warn "SUPABASE_DB_PASSWORD が未設定のため db push(migration 適用)をスキップします"
fi

if [ "$DRY_RUN" = "true" ]; then
  step "DRY_RUN=true のためここで終了(link / db push / deploy は実行しない)"
  echo "実行予定: link --project-ref $PROJECT_REF → db push($HAS_DB_PASSWORD) → deploy: ${FUNCTIONS[*]}"
  exit 0
fi

cd "$LIEN_DIR" # supabase CLI は supabase/ ディレクトリを持つこの階層を基点にする

# ---- 1. link ---------------------------------------------------------------
step "1/3 link --project-ref $PROJECT_REF"
if [ "$HAS_DB_PASSWORD" = "true" ]; then
  supabase link --project-ref "$PROJECT_REF" --password "$SUPABASE_DB_PASSWORD"
else
  # パスワードなしでも link 自体は可能(DB 接続検証が警告になるだけ)
  supabase link --project-ref "$PROJECT_REF" --password ""
fi

# ---- 2. db push(migrations)------------------------------------------------
step "2/3 db push(supabase/migrations/ の未適用分)"
if [ "$HAS_DB_PASSWORD" = "true" ]; then
  supabase db push --password "$SUPABASE_DB_PASSWORD"
else
  warn "db push をスキップしました(SUPABASE_DB_PASSWORD 未設定)。"
  warn "migration が未適用のままだと functions は実行時にエラーになります"
fi

# ---- 3. functions deploy ----------------------------------------------------
step "3/3 Edge Functions deploy(verify_jwt は config.toml の宣言どおり)"
for fn in "${FUNCTIONS[@]}"; do
  echo "--- deploy: $fn"
  supabase functions deploy "$fn" --project-ref "$PROJECT_REF"
done

step "完了"
echo "エンドポイント例: https://${PROJECT_REF}.supabase.co/functions/v1/checkin"
echo "次: products/lien/scripts/g1/RUNBOOK.md のスモークテストへ"
