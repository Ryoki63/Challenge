#!/usr/bin/env bash
# measure.sh — G1 計測: checkin POST → デバイスBのウィジェット更新の Δt を10回計測
#
# 計測設計(TASKPLAN §1 G1: p50 ≦ 60秒):
#   - checkin は UNIQUE(user_id, date_local) で冪等 = 同日2回目は push が飛ばない
#     (alreadyCheckedIn: true。checkin/core.ts)。そのため各ラウンドの最後に
#     checkin-cancel(当日のみ取消可・冪等)で行を消し、checkin → cancel → checkin …
#     の繰り返しで同じ日のまま10回 push を発火させる
#   - cancel はデバイスBへ「サイレント push」(配送保証なし)なので、ラウンド間で
#     B のアプリを一度開いて自己修復(GET /snapshot)させ、ウィジェットを
#     未チェック表示に戻してから次ラウンドを開始する
#   - Δt は「POST 送信直前」→「B のウィジェット変化を目視して Enter」の人間計測
#
# 必要な環境変数:
#   JWT           (必須)ユーザーA(チェックインする側)の access_token(seed-pair.sh の出力)
#   SUPABASE_URL  (任意)既定 https://lniheehfbtpfhglinfjm.supabase.co
#   ROUNDS        (任意)既定 10
#   DATE_LOCAL    (任意)既定 = JST の今日
#
# 注意: 匿名セッションの JWT は約1時間で失効(401 になったら refresh か seed し直し)

set -euo pipefail

SUPABASE_URL="${SUPABASE_URL:-https://lniheehfbtpfhglinfjm.supabase.co}"
: "${JWT:?JWT(ユーザーAの access_token)を設定してください。seed-pair.sh の出力参照}"
ROUNDS="${ROUNDS:-10}"
DATE_LOCAL="${DATE_LOCAL:-$(TZ=Asia/Tokyo date +%Y-%m-%d)}"

command -v curl > /dev/null || { echo "ERROR: curl が必要です" >&2; exit 1; }
command -v python3 > /dev/null || { echo "ERROR: python3 が必要です" >&2; exit 1; }

BODY_FILE="$(mktemp)"
trap 'rm -f "$BODY_FILE"' EXIT

call_fn() { # <function名> <jsonボディ> → ボディを標準出力(200 以外は exit 1)
  local fn="$1" body="$2" status
  status="$(curl -sS -o "$BODY_FILE" -w "%{http_code}" \
    -X POST "$SUPABASE_URL/functions/v1/$fn" \
    -H "Authorization: Bearer $JWT" \
    -H "content-type: application/json" \
    -d "$body")"
  if [ "$status" != "200" ]; then
    echo "ERROR: $fn -> HTTP $status" >&2
    cat "$BODY_FILE" >&2
    echo "" >&2
    [ "$status" = "401" ] && echo "HINT: JWT 失効の可能性(匿名セッション約1時間)。refresh するか seed-pair.sh をやり直し" >&2
    grep -q "no_promise" "$BODY_FILE" 2> /dev/null \
      && echo "HINT: 約束が未作成。SUPABASE_SERVICE_ROLE_KEY 付きで seed-pair.sh を実行(RUNBOOK 手順5)" >&2
    exit 1
  fi
  cat "$BODY_FILE"
}

json_bool() { # '<json>' '<key>' → true/false
  printf '%s' "$1" | python3 -c '
import json, sys
print(str(json.load(sys.stdin)[sys.argv[1]]).lower())
' "$2"
}

now_s() { python3 -c 'import time; print(f"{time.time():.3f}")'; }

echo "G1 計測: $ROUNDS 回 / dateLocal=$DATE_LOCAL / $SUPABASE_URL"
echo ""

# 事前クリーンアップ: スモークテスト等で当日 checkin が残っていると
# 1回目が alreadyCheckedIn=true になり push が飛ばないため、先に取り消す(冪等)
echo "==> 事前クリーンアップ(当日分の checkin-cancel。無ければ何も起きない)"
call_fn checkin-cancel "{\"dateLocal\":\"$DATE_LOCAL\"}" > /dev/null
echo ""

DTS=() # 各ラウンドの Δt(秒)

for i in $(seq 1 "$ROUNDS"); do
  echo "---- ラウンド $i / $ROUNDS ----"
  read -r -p "  準備: デバイスBのアプリを一度開いて閉じ、ウィジェットが未チェック表示に戻ったら Enter > "

  T0="$(now_s)"
  RES="$(call_fn checkin "{\"dateLocal\":\"$DATE_LOCAL\"}")"
  if [ "$(json_bool "$RES" alreadyCheckedIn)" = "true" ]; then
    echo "ERROR: alreadyCheckedIn=true(前ラウンドの取消が効いていない)。push は飛んでいないので計測無効。再実行してください" >&2
    exit 1
  fi
  echo "  checkin 200(push 発火)。デバイスBを見ていてください…"
  read -r -p "  デバイスBのウィジェットがチェック済み表示に変わった瞬間に Enter > "
  T1="$(now_s)"

  DT="$(python3 -c "print(f'{$T1 - $T0:.1f}')")"
  DTS+=("$DT")
  echo "  Δt = ${DT}s"

  call_fn checkin-cancel "{\"dateLocal\":\"$DATE_LOCAL\"}" > /dev/null
  echo "  checkin-cancel 200(次ラウンドへリセット)"
  echo ""
done

# ---- 集計(nearest-rank percentile)------------------------------------------
STATS="$(python3 -c '
import sys, math
xs = sorted(float(x) for x in sys.argv[1:])
n = len(xs)
def pct(p):
    return xs[max(0, math.ceil(p / 100 * n) - 1)]
print(f"{pct(50):.1f} {pct(90):.1f}")
' "${DTS[@]}")"
P50="${STATS%% *}"
P90="${STATS##* }"
if python3 -c "import sys; sys.exit(0 if float('$P50') <= 60 else 1)"; then
  VERDICT="合格(p50 ≦ 60s)"
else
  VERDICT="不合格(p50 > 60s)"
fi

echo "============================================================"
echo " 結果"
echo "============================================================"
echo ""
echo "| ラウンド | Δt (秒) |"
echo "|---|---|"
i=1
for dt in "${DTS[@]}"; do
  echo "| $i | $dt |"
  i=$((i + 1))
done
echo ""
echo "p50 = ${P50}s / p90 = ${P90}s → G1 判定: $VERDICT"
echo ""
echo "---- JOURNAL 貼り付け用 ----------------------------------------"
cat << SNIPPET
- G1 計測(checkin POST → デバイスBウィジェット更新の目視 Δt): $(TZ=Asia/Tokyo date '+%Y-%m-%d %H:%M') JST / N=$ROUNDS / dateLocal=$DATE_LOCAL
  - 各回: ${DTS[*]} 秒
  - **p50 = ${P50}s / p90 = ${P90}s → $VERDICT**(基準: p50 ≦ 60s — TASKPLAN §1 G1)
SNIPPET
echo "----------------------------------------------------------------"
