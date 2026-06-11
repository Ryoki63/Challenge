# G1 計測 RUNBOOK — G0残作業からp50計測完了まで(人間向け手順書)

対象: issue #8(T08)/ 全体計画 #50。G1 = 「実機2台で checkin → 相手ウィジェット更新を10回計測し、**p50 ≦ 60秒**を JOURNAL に記録」(TASKPLAN §1)。

Supabase プロジェクトは作成済み(ref: `lniheehfbtpfhglinfjm`)。本書は残りの人間作業を上から順にやれば G1 が終わる構成。

## 所要時間の全体像

| # | 手順 | 所要(作業) | 待ち時間 |
|---|---|---|---|
| 1 | Apple Developer Program 加入 | 15分 | 審査 最大48h |
| 2 | APNs キー発行 + Supabase secrets 投入 | 15分 | — |
| 3 | Anonymous sign-ins 有効化 | 5分 | — |
| 4 | GitHub secrets 登録 + デプロイ実行 | 15分 | — |
| 5 | スモークテスト | 15分 | — |
| 6 | 実機2台へアプリ導入+ウィジェット配置 | 30〜60分 | — |
| 7 | measure.sh で10回計測 → JOURNAL記録 | 30分 | — |

手順 3〜5 は Apple Developer(手順1〜2)を**待たずに先行できる**。全 Edge Functions は APNs シークレット未投入でも動く(push をスキップして `console.warn` を出すだけ — 各 `index.ts` で確認済み)。

---

## 1. Apple Developer Program 加入 [待ち最大48h]

1. https://developer.apple.com/programs/ から加入(¥12,800/年)
2. 審査完了メールを待つ(最大48時間)。**待っている間に手順3〜5を進める**

## 2. APNs 認証キー発行 + Supabase secrets 投入(15分)

1. https://developer.apple.com/account → Certificates, Identifiers & Profiles → **Keys** → 「+」
2. 名前任意、**Apple Push Notifications service (APNs)** にチェック → Continue → Register
3. **AuthKey_XXXXXXXXXX.p8 をダウンロード(1回しかできない。安全な場所に保管)**。Key ID(10桁)を控える
4. Team ID は Membership ページ右上(10桁英数)
5. Supabase secrets へ投入(env 名は `_shared/apns.ts` の実装どおり。5つすべて必須 — 1つでも欠けると push 無効で運転):

```bash
cd products/lien
supabase secrets set --project-ref lniheehfbtpfhglinfjm \
  APNS_AUTH_KEY="$(cat ~/path/to/AuthKey_XXXXXXXXXX.p8)" \
  APNS_KEY_ID=XXXXXXXXXX \
  APPLE_TEAM_ID=YYYYYYYYYY \
  APNS_ENV=sandbox \
  APNS_TOPIC=com.ryoki63.lien
```

- `APNS_AUTH_KEY` は .p8 の **PEM 全文**(ファイルパスではない)
- `APNS_ENV`: Xcode から実機へ直接インストール(development ビルド)= **sandbox**。TestFlight 配布になったら **production** に変更(DESIGN §10)
- `APNS_TOPIC` = Bundle ID `com.ryoki63.lien`(ios/Config/Base.xcconfig の `LIEN_BUNDLE_ID_BASE`)
- `SERVICE_ROLE_KEY` の手動投入は不要(Edge Runtime が `SUPABASE_SERVICE_ROLE_KEY` を自動注入し、コードはそちらを先に読む)

## 3. Anonymous sign-ins 有効化(5分)

1. https://supabase.com/dashboard/project/lniheehfbtpfhglinfjm → **Authentication** → **Sign In / Providers**(旧 UI では Providers)
2. **Anonymous sign-ins** を ON → Save

※ これが OFF だと seed-pair.sh の匿名サインアップ(`POST /auth/v1/signup`)が 422 `anonymous_provider_disabled` で失敗する。

## 4. GitHub secrets 登録 + デプロイ実行(15分)

1. アクセストークン発行: https://supabase.com/dashboard/account/tokens → Generate new token(`sbp_...`)
2. DB パスワード: プロジェクト作成時に設定したもの。忘れた場合は Dashboard → Project Settings → **Database** → Reset database password
3. GitHub リポジトリ → Settings → Secrets and variables → **Actions** → New repository secret で2つ登録:
   - `SUPABASE_ACCESS_TOKEN`
   - `SUPABASE_DB_PASSWORD`
4. デプロイ実行(どちらか):

```bash
# CLI から
gh workflow run lien-deploy
gh run watch
# または GitHub → Actions → lien-deploy → Run workflow
```

ローカル(Mac)でやる場合の代替:

```bash
# リポジトリ直下の .env.example を .env にコピーして値を入れてから
set -a; source .env; set +a
bash products/lien/scripts/deploy.sh
```

成功すると: migration 0001 が適用され、Edge Functions 7本(checkin / checkin-cancel / snapshot / invite-create / invite-accept / close-day / grant-tickets)が verify_jwt=false でデプロイされる。

## 5. スモークテスト(15分)

ターミナルで(キーは Dashboard → Project Settings → **API keys**。anon=`sb_publishable_...` か legacy anon、service_role=`sb_secret_...` か legacy service_role):

```bash
export SUPABASE_ANON_KEY='<anon key>'
export SUPABASE_SERVICE_ROLE_KEY='<service_role key>'   # promises 作成に必要
bash products/lien/scripts/g1/seed-pair.sh
```

成功すると userA/B の JWT・pair_id・次のコマンド例が表示される。続けて:

```bash
# 1) checkin が 200 + alreadyCheckedIn:false で返ること
curl -sS -X POST "https://lniheehfbtpfhglinfjm.supabase.co/functions/v1/checkin" \
  -H "Authorization: Bearer <JWT_A>" -H "content-type: application/json" \
  -d "{\"dateLocal\":\"$(TZ=Asia/Tokyo date +%Y-%m-%d)\"}"

# 2) snapshot に反映されていること(自分の checkedIn が true)
curl -sS "https://lniheehfbtpfhglinfjm.supabase.co/functions/v1/snapshot" \
  -H "Authorization: Bearer <JWT_A>"

# 3) functions のログ確認(APNs 未投入なら「APNs 未設定のため push をスキップ」の warn が出る)
cd products/lien && supabase functions logs checkin --project-ref lniheehfbtpfhglinfjm

# 4) 後始末(当日の checkin を取り消し。measure.sh は冪等クリーンアップ付きなので任意)
curl -sS -X POST "https://lniheehfbtpfhglinfjm.supabase.co/functions/v1/checkin-cancel" \
  -H "Authorization: Bearer <JWT_A>" -H "content-type: application/json" \
  -d "{\"dateLocal\":\"$(TZ=Asia/Tokyo date +%Y-%m-%d)\"}"
```

※ seed-pair.sh は実行のたびに新しい匿名ペアを作る(再実行可)。匿名 JWT は約1時間で失効する点だけ注意(失効したら seed の出力にある refresh コマンドか、seed やり直し)。

## 6. 実機2台へアプリ導入+ウィジェット配置(30〜60分)

**前提**: 手順1(Apple Developer)完了。push 通知は実機のみ(シミュレータ不可)。

**経路A(推奨): Xcode automatic signing**
1. Mac で `cd products/lien/ios && xcodegen generate` → `Lien.xcodeproj` を Xcode で開く
2. Signing & Capabilities → Team に自分の Developer アカウントを選択、Automatically manage signing を ON(4ターゲットすべて。App Group / Push の capability も自動解決)
3. iPhone 2台を USB 接続し、それぞれへ Run(初回は端末側で開発者を信頼)

**経路B(フォールバック): CI で ad-hoc IPA を作って配る**
- 2台の UDID を Developer サイトに登録 → ad-hoc プロビジョニングプロファイル+配布証明書を作成 → CI(GitHub Actions macos)で署名付きビルド → IPA を Apple Configurator 等で導入
- 証明書・プロファイルの secrets 管理が必要で手間が多い。Mac が使えるなら経路Aを推奨

**push トークンの取得と登録**(T08準備②のハーネス実装済み):
- アプリは通知許可後に APNs 登録を行う(オンボの通知許可直後+許可済みなら毎起動時に再登録)。**DEBUG ビルドではオンボ完了後の画面(solo/paired)に「Device Token(G1計測用)」**が hex 文字列で表示される(未取得時は「未取得(通知許可後に表示)」)
- 各端末で「コピー」を押してトークンを取得し、seed-pair.sh の引数(`bash seed-pair.sh <tokenA> <tokenB>`)か、seed 出力末尾の PATCH コマンドで `users.push_token` に設定する(hex 文字列をそのまま渡してよい)
- 計測に最低限必要なのは**デバイスB(観察側)のトークンのみ**(push は A→B 方向)

**ウィジェット配置**: デバイスBのホーム画面長押し → 「+」→ Lien ウィジェット(S)を配置。

## 7. 10回計測 → JOURNAL 記録(30分)

2人(または2台を1人で)体制。デバイスA=チェックインする側(JWT_A を使うターミナル)、デバイスB=ウィジェットを目視する側。

```bash
export JWT='<JWT_A>'   # seed-pair.sh の出力(失効していたら refresh)
bash products/lien/scripts/g1/measure.sh
```

各ラウンドの流れ(スクリプトが対話で誘導):
1. デバイスBのアプリを一度開いて閉じる(GET /snapshot の自己修復でウィジェットが未チェック表示に戻る)→ Enter
2. スクリプトが checkin POST(この瞬間が T0)
3. デバイスBのウィジェットがチェック済み表示に変わった瞬間に Enter(T1)
4. スクリプトが checkin-cancel で取り消し(同日でも次ラウンドで再び push が飛ぶ。checkin は UNIQUE(user_id, date_local) で冪等のため、cancel しないと2回目以降 push が発火しない)

最後に p50 / p90 と JOURNAL 貼り付け用スニペットが出力される。**p50 ≦ 60s なら G1 合格** → スニペットを `progress/JOURNAL.md` に貼り、issue #8 へ完了コメント。

## トラブルシュート

| 症状 | 原因と対処 |
|---|---|
| seed の signup が 422 `anonymous_provider_disabled` | 手順3(Anonymous sign-ins)が未実施 |
| functions が 401 | JWT 失効(匿名セッション約1時間)→ refresh か seed やり直し |
| checkin が 409 `no_promise` | promises 未作成 → `SUPABASE_SERVICE_ROLE_KEY` 付きで seed-pair.sh を再実行(promises への書き込みは service_role のみ。クライアント書き込みは RLS/GRANT で deny — migration 0001) |
| push がデバイスBに届かない | ① `supabase secrets list` で APNs 5変数を確認 ② `APNS_ENV` の sandbox/production がビルド配布経路と一致しているか(Xcode直=sandbox) ③ `users.push_token` がデバイスBの最新トークンか ④ `supabase functions logs checkin` で送信結果を確認 |
| db push が失敗 | `SUPABASE_DB_PASSWORD` の誤り → Dashboard でリセットして GitHub secret も更新 |
| close-day を手動で叩きたい | `Authorization: Bearer <service_role key>` の**完全一致**が必要(Edge Runtime が注入する `SUPABASE_SERVICE_ROLE_KEY` と同じ値 = Dashboard の legacy `service_role` キー)。一致しない場合は 401 |
