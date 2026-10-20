# review-demo — 審査用デモの「相手役」(issue #30 / T30)

App Review の審査員が **1台の端末**で「ペアの相手がいる状態」を試せるように、開発者が操作する相手役の
匿名アカウントを作り、招待コードの発行・チェックイン・つつき・状態確認・削除を行う手動実行専用の道具です。

- 正本: `docs/REQUIREMENTS.md` §3.2(招待は8文字英数・72時間・1回きり)/ §8(審査用のテストペア)
- 運用: `products/lien/marketing/review-notes.md` §1.3
- テスト: `partner_lib_test.ts`(ネットワーク不要)。CI の e2e-tests ジョブで回る。**この道具自体は CI では実行しない**(本番にユーザーを作るため)

## なぜ「アカウント情報」ではなく「招待コード+相手役」なのか

v1.0 は匿名認証だけで、ユーザー名・パスワード・メールログインがありません(REQUIREMENTS §3.1)。
したがって審査用の「テストアカウント」は、**相手役の匿名アカウントと、そのアカウントが発行する招待コード**として提供します。
招待は **72時間・1回きり**なので、コードは提出日に発行して App Store Connect の **Notes for Review** に貼ります。
**リポジトリには書きません**(公開リポジトリに生きたコードを置くと、誰でもデモの相手役とペアになれてしまうため)。

## 安全上の約束

- 使うのは **公開の anon キーだけ**。`service_role` キー・APNs キー・`.env` は使いません。
- 匿名セッション(`refresh_token`)は **リポジトリの外**の状態ファイル(既定 `~/.lien-review-demo/partner-<slot>.json`、0600)にだけ保存します。標準出力・ログには出しません。
- 相手役は **新しい匿名ユーザー**(ニックネーム `レビュー相手1` / `レビュー相手2`)で、G1 の計測用ペアとは分離します。個人情報は持ちません。
- レビューが終わったら `delete` でアカウントとデータを消します(アプリと同じ `delete-account`)。

## 準備

```bash
export SUPABASE_ANON_KEY='<Supabase Dashboard > Project Settings > API keys の anon / publishable>'
# 任意: export SUPABASE_URL='https://<ref>.supabase.co'  PROJECT_REF='<ref>'
# 任意: export REVIEW_DEMO_STATE_DIR="$HOME/.lien-review-demo"
```

`deno` が必要です(PATH か `~/.deno/bin/deno`)。`partner.sh` が権限(本番 Supabase への通信・状態ファイルの読み書き・写真の読み取り)を付けます。

## 提出日の流れ(2組)

```bash
# 1. 相手役を2人作る(それぞれ招待コードが出る)
bash products/lien/scripts/review-demo/partner.sh create --slot 1
bash products/lien/scripts/review-demo/partner.sh create --slot 2

# 2. 出た「招待コード」を App Store Connect > App Review Information > Notes for Review に貼る
#    例: 「Home → 相手を招待する → コードを入力 → ペアになる」に <code> を入れてください

# 3. レビュー中: 相手役としてチェックインする(審査員のホームに相手の完了が出る)
bash products/lien/scripts/review-demo/partner.sh checkin --slot 1
#    写真つき(JPEG。原寸とサムネに同じ画像を送る)
bash products/lien/scripts/review-demo/partner.sh checkin --slot 1 --photo ~/Desktop/demo.jpg
#    つつき(定型スタンプのみ。自由文は送れない)
bash products/lien/scripts/review-demo/partner.sh nudge --slot 1 --stamp 👋
#    状態(ペア・今日の完了・招待の期限)
bash products/lien/scripts/review-demo/partner.sh status --slot 1

# 4. コードが72時間で失効したら再発行して Notes を差し替える(アプリの再提出は不要)
bash products/lien/scripts/review-demo/partner.sh new-invite --slot 1

# 5. レビュー後に消す
bash products/lien/scripts/review-demo/partner.sh delete --slot 1
bash products/lien/scripts/review-demo/partner.sh delete --slot 2
```

- `--slot` は 1 か 2(既定 1)。2組を別々の状態ファイルで管理します。
- `create` のオプション: `--nickname`(8文字まで)/ `--promise`(20文字まで)/ `--emoji`。
- 状態ファイルを消すと、その匿名アカウントは**二度と操作できません**(匿名認証に再ログインは無い)。消すときは `delete` を使ってください。

## 審査員から見えること

- `checkin` → 審査員のホームに相手の「今日のぶんは完了」が出る(相手の名前・約束・ストリークも出る)。
- `checkin --photo` → 審査員のホームに「<相手>の今日の写真」のカードが出る。タップで全画面、長押しで通報・ブロック(§1.4)。
- `nudge` → 審査員に「つつかれた」通知が届く(通知を許可している場合)。相手が当日まだ未完了のときだけ送れます(1日3回まで)。
- 審査員がペアを解消すると相手役はソロに戻ります。`new-invite` で新しいコードを出せば、もう一度ペアになれます。

## うまくいかないとき

| 症状 | 原因と対処 |
|---|---|
| `SUPABASE_ANON_KEY がありません` | 環境変数を設定する(公開キーのみ) |
| `匿名サインアップ: HTTP 429` | 匿名サインインのレート制限(1時間あたりの回数)。時間をおく |
| `セッションの更新に失敗しました` | `refresh_token` が失効。状態ファイルを消して `create` からやり直す(相手役は作り直し) |
| `checkin: HTTP 409 no_promise` | 約束が無い。`create` は約束も作るので、通常は起きない(状態ファイルが古いとき) |
| `checkin: HTTP 400 no_pair` | まだペアが成立していない。審査員がコードを入れて「ペアになる」まで待つ |
| `nudge: HTTP 409` | 相手が今日すでに完了している、またはペアが無い |
| 写真が送れない | JPEG だけ(`.jpg`)。PNG は不可(アプリと同じく `image/jpeg` で送る) |

## テスト

```bash
deno test products/lien/scripts/review-demo/
deno check products/lien/scripts/review-demo/partner.ts
```

`partner_lib_test.ts` は引数・JST の日付・招待コードの形・状態ファイルの検証を、ネットワークなしで確かめます。
