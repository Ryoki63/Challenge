#!/usr/bin/env bash
# seed-pair.sh — G1 計測用のテストペアを Supabase 上に作る
#
#   匿名ユーザー A/B 作成 → ニックネーム(+push_token)設定 → A が invite-create
#   → B が invite-accept でペア成立 →(service role があれば)両者に約束(promise)を作成
#
# 必要な環境変数:
#   SUPABASE_ANON_KEY          (必須)Dashboard > Project Settings > API keys
#                              (legacy anon / sb_publishable_ のどちらでも可)
#   SUPABASE_URL               (任意)既定 https://lniheehfbtpfhglinfjm.supabase.co
#   SUPABASE_SERVICE_ROLE_KEY  (推奨)promises 行の作成に使用。
#                              ※ promises への書き込みは service_role のみ(RLS/GRANT。
#                                migration 0001)。未設定だと checkin が 409 no_promise に
#                                なり measure.sh で計測できない
#
# 使い方:
#   bash seed-pair.sh [push_token_A] [push_token_B]
#   push_token は後から PATCH でも設定できる(末尾に出力するコマンド例を参照)
#
# 前提: Supabase ダッシュボードで Anonymous sign-ins が有効(RUNBOOK 手順3)。
# 冪等性: 実行のたびに新しい匿名ユーザー+新ペアを作る(再実行で衝突しない)。

set -euo pipefail

SUPABASE_URL="${SUPABASE_URL:-https://lniheehfbtpfhglinfjm.supabase.co}"
: "${SUPABASE_ANON_KEY:?SUPABASE_ANON_KEY を設定してください(Dashboard > Project Settings > API keys)}"
PUSH_TOKEN_A="${1:-}"
PUSH_TOKEN_B="${2:-}"

command -v curl > /dev/null || { echo "ERROR: curl が必要です" >&2; exit 1; }
command -v python3 > /dev/null || { echo "ERROR: python3 が必要です(JSON解析)" >&2; exit 1; }

BODY_FILE="$(mktemp)"
trap 'rm -f "$BODY_FILE"' EXIT

# JSON からドットパスで値を取り出す: json_get '<json>' 'user.id'
json_get() {
  printf '%s' "$1" | python3 -c '
import json, sys
d = json.load(sys.stdin)
for k in sys.argv[1].split("."):
    d = d[k]
print(d)
' "$2"
}

# api <METHOD> <URL> <期待ステータス> [curl 追加引数...] → ボディを標準出力
api() {
  local method="$1" url="$2" expected="$3"
  shift 3
  local status
  status="$(curl -sS -o "$BODY_FILE" -w "%{http_code}" -X "$method" "$url" "$@")"
  if [ "$status" != "$expected" ]; then
    echo "ERROR: $method $url -> HTTP $status(期待: $expected)" >&2
    cat "$BODY_FILE" >&2
    echo "" >&2
    if grep -q "anonymous" "$BODY_FILE" 2> /dev/null; then
      echo "HINT: Anonymous sign-ins が無効の可能性。Dashboard > Authentication > Sign In / Providers で有効化(RUNBOOK 手順3)" >&2
    fi
    exit 1
  fi
  cat "$BODY_FILE"
}

# ---- 1. 匿名サインアップ ×2 -------------------------------------------------
# GoTrue の匿名サインインは POST /auth/v1/signup に email/phone なしの JSON
# (supabase-js signInAnonymously と同じ。auth-js GoTrueClient.ts で確認済み)
echo "==> 1/4 匿名ユーザー A/B を作成"
anon_signup() {
  api POST "$SUPABASE_URL/auth/v1/signup" 200 \
    -H "apikey: $SUPABASE_ANON_KEY" \
    -H "content-type: application/json" \
    -d '{"data":{}}'
}
RES_A="$(anon_signup)"
JWT_A="$(json_get "$RES_A" access_token)"
REFRESH_A="$(json_get "$RES_A" refresh_token)"
UID_A="$(json_get "$RES_A" user.id)"
echo "    user A: $UID_A"

RES_B="$(anon_signup)"
JWT_B="$(json_get "$RES_B" access_token)"
REFRESH_B="$(json_get "$RES_B" refresh_token)"
UID_B="$(json_get "$RES_B" user.id)"
echo "    user B: $UID_B"

# ---- 2. プロフィール更新(users は自分の行のみ・許可列のみ UPDATE 可)---------
# migration 0001 の列レベル GRANT: nickname / avatar_emoji / timezone / remind_at /
# push_token のみ authenticated が更新可。ここでは nickname と push_token だけ触る。
echo "==> 2/4 ニックネーム(+push_token)を設定"
patch_user() { # jwt uid nickname push_token
  local body
  if [ -n "$4" ]; then
    body="$(printf '{"nickname":"%s","push_token":"%s"}' "$3" "$4")"
  else
    body="$(printf '{"nickname":"%s"}' "$3")"
  fi
  local res
  res="$(api PATCH "$SUPABASE_URL/rest/v1/users?id=eq.$2" 200 \
    -H "apikey: $SUPABASE_ANON_KEY" \
    -H "Authorization: Bearer $1" \
    -H "content-type: application/json" \
    -H "Prefer: return=representation" \
    -d "$body")"
  # RLS で弾かれると 200 + 空配列になるので明示チェック
  if [ "$res" = "[]" ]; then
    echo "ERROR: users 更新が RLS で空振り(uid=$2)。JWT と uid の対応を確認" >&2
    exit 1
  fi
}
patch_user "$JWT_A" "$UID_A" "テストA" "$PUSH_TOKEN_A"
patch_user "$JWT_B" "$UID_B" "テストB" "$PUSH_TOKEN_B"
[ -n "$PUSH_TOKEN_A" ] || echo "    NOTE: push_token A 未指定(後から PATCH 可。末尾のコマンド例)"
[ -n "$PUSH_TOKEN_B" ] || echo "    NOTE: push_token B 未指定(後から PATCH 可。末尾のコマンド例)"

# ---- 3. 招待 → 受諾でペア成立 ------------------------------------------------
echo "==> 3/4 invite-create(A)→ invite-accept(B)"
RES_INVITE="$(api POST "$SUPABASE_URL/functions/v1/invite-create" 200 \
  -H "Authorization: Bearer $JWT_A" \
  -d '')"
INVITE_TOKEN="$(json_get "$RES_INVITE" token)"
echo "    invite token: $INVITE_TOKEN"

RES_ACCEPT="$(api POST "$SUPABASE_URL/functions/v1/invite-accept" 200 \
  -H "Authorization: Bearer $JWT_B" \
  -H "content-type: application/json" \
  -d "{\"token\":\"$INVITE_TOKEN\"}")"
PAIR_ID="$(json_get "$RES_ACCEPT" pairId)"
echo "    pair_id: $PAIR_ID"

# ---- 4. 約束(promise)作成 — checkin の前提条件 -------------------------------
# NOTE(T12): promise-set Function が入ったため、デプロイ済み環境ならユーザーJWTで
#   POST /functions/v1/promise-set {"title":...,"emoji":...} でも作成できる(service_role 不要)。
#   本スクリプトは promise-set 未デプロイの環境でも動くよう service_role 直書きのまま。
echo "==> 4/4 promises 行を作成(checkin は現役の約束が無いと 409 no_promise)"
if [ -n "${SUPABASE_SERVICE_ROLE_KEY:-}" ]; then
  api POST "$SUPABASE_URL/rest/v1/promises" 201 \
    -H "apikey: $SUPABASE_SERVICE_ROLE_KEY" \
    -H "Authorization: Bearer $SUPABASE_SERVICE_ROLE_KEY" \
    -H "content-type: application/json" \
    -H "Prefer: return=representation" \
    -d "[{\"user_id\":\"$UID_A\",\"title\":\"まいにち散歩\",\"emoji\":\"🚶\"},
         {\"user_id\":\"$UID_B\",\"title\":\"まいにち水やり\",\"emoji\":\"🌿\"}]" > /dev/null
  echo "    A/B の約束を作成しました"
else
  echo "    WARN: SUPABASE_SERVICE_ROLE_KEY 未設定のためスキップ。" >&2
  echo "          このままでは checkin が 409 no_promise になります(RUNBOOK 手順5)" >&2
fi

# ---- 出力 -------------------------------------------------------------------
cat << SUMMARY

============================================================
 seed 完了
============================================================
 SUPABASE_URL : $SUPABASE_URL
 pair_id      : $PAIR_ID
 invite token : $INVITE_TOKEN

 user A (チェックインする側)
   id            : $UID_A
   access_token  : $JWT_A
   refresh_token : $REFRESH_A

 user B (ウィジェットを観察する側)
   id            : $UID_B
   access_token  : $JWT_B
   refresh_token : $REFRESH_B

 ※ 匿名セッションの access_token は約1時間で失効。失効したら:
   curl -sS -X POST "$SUPABASE_URL/auth/v1/token?grant_type=refresh_token" \\
     -H "apikey: \$SUPABASE_ANON_KEY" -H "content-type: application/json" \\
     -d '{"refresh_token":"<上の refresh_token>"}'

------------------------------------------------------------
 次にやること
------------------------------------------------------------
 1) (未設定なら)実機の APNs デバイストークンを users.push_token へ:
   curl -sS -X PATCH "$SUPABASE_URL/rest/v1/users?id=eq.$UID_B" \\
     -H "apikey: \$SUPABASE_ANON_KEY" -H "Authorization: Bearer <JWT_B>" \\
     -H "content-type: application/json" -H "Prefer: return=representation" \\
     -d '{"push_token":"<デバイスBのAPNsトークン>"}'

 2) スモーク(A がチェックイン → B に push が飛ぶ):
   curl -sS -X POST "$SUPABASE_URL/functions/v1/checkin" \\
     -H "Authorization: Bearer <JWT_A>" -H "content-type: application/json" \\
     -d "{\"dateLocal\":\"\$(TZ=Asia/Tokyo date +%Y-%m-%d)\"}"

 3) 計測(10回ループ):
   export JWT='<JWT_A>'
   bash products/lien/scripts/g1/measure.sh
============================================================
SUMMARY
