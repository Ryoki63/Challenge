# Lien — 計測設計(UTM・App Store Analytics・週次 SQL)

- 作成日: 2026-10-20(issue #78 / MK5)
- 表記: App Store Connect を「ASC」、ASC の Analytics(旧 App Analytics)を「ASC Analytics」と書く。「DL」= ダウンロード。D1 / D7 / D30 は [docs/KPI.md](../../../docs/KPI.md) §4 の「両者継続」を指す
- 正本: 指標の定義と SQL は [docs/KPI.md](../../../docs/KPI.md)。本書は「チャネル」と「週次」の読み方を足す。数え方が食い違ったら KPI.md を正とし、本書を直す
- 前提: **D6** — v1.0 は分析 SDK を入れず、機能のために既にある Supabase のテーブルを SQL で集計する([REQUIREMENTS.md](../../../docs/REQUIREMENTS.md) §7)。App Privacy の申告は #30 の [review-notes.md](review-notes.md) §2.1 と `PrivacyInfo.xcprivacy` に合わせ、**本書のためにアプリ側は何も変えない**

## 0. 結論(先に)

1. **DL のチャネル別 attribution は、Apple のキャンペーンリンク(`pt` / `ct`)と App Store Connect Analytics で取る。** 標準の `utm_*` は App Store のキャンペーン計測には使われない(Apple のヘルプに `utm_*` を読む記載がない)。「UTM 命名規則」は、この `ct` の命名規則と、将来 Web 計測を入れるときの `utm_*` の対応として定義する(§2)
2. **アプリ内のファネル(招待 → ペア成立 → D1/D7/D30)は Supabase の SQL(KPI.md)で取る。** ただし **チャネル別には分けられない**。ASC のキャンペーンデータと DB のユーザーは、ユーザー単位では結合できない(§1・§4)
3. **SDK・計測専用テーブル・ATT は入れない。** 代替は「ASC の集計」+「KPI.md の SQL」+「チャネルを時間で分けた比較」。App Privacy の申告(#30 §2.1 の5型)は変えない(§5・§6)

## 1. 全体像 — 2層で読む

```
投稿 / 記事 / ティザー
  └─ App Store キャンペーンリンク(pt / ct)
        └─> ASC Analytics
              Impressions → Product Page Views → First-Time Downloads
              (合計のみ。ユーザー単位では DB と結合できない)

アプリ(匿名認証)
  └─> Supabase(users / invites / pairs / pair_members / streak_days / ...)
        └─> docs/KPI.md の SQL
              招待 → ペア成立 → D1/D7/D30 → つつき → 名前付け → North Star
              (全体。チャネル別には分けられない)
```

- **層A: チャネル(ASC Analytics)** — どの投稿・記事・ページが App Store の product page を見せ、DL につながったか。Apple の集計で、しきい値未満は見えない
- **層B: プロダクト(SQL)** — DL した人がオンボを終え、招待し、ペアになり、続けられたか。テストユーザーを除いた実ユーザー・実ペアで見る
- **橋** — 同じ週の「First-Time Downloads(ASC)」と「作成された実ユーザー(SQL)」を並べる。これは**近似**で、ユーザー単位の結合ではない。DL した人がすぐオンボを終えるとは限らず、前の週の DL が今週オンボを終えることもある

### 1.1 できること・できないこと

| 知りたいこと | できる | できない |
|---|---|---|
| どのチャネルが DL を生んだか | `ct` 別の First-Time Downloads、Impressions、Product Page Views | その DL がどのユーザーか(Apple は集計だけを返す) |
| どのチャネルがペア成立・D7 につながったか | チャネル別の **DL** と、全体の **ペア成立・D7** を同じ週で並べる | チャネル別のペア成立率・D7 率(ユーザー単位の結合ができない) |
| App Store 検索からの DL | Sources の `App Store search` / `App Store browse` | 検索語(ASC Analytics では見えない) |
| 投稿を見て名前を検索した人 | 投稿日の前後 48 時間の Search の増加として**推測**できる | 投稿と検索 DL の因果。campaign には付かない |
| 招待 → ペア成立 | KPI.md の `invite_accepted`(分母 = 結果の決まった招待) | 招待した人がどのチャネルから来たか |

> **因果ではない。** 投稿した日に DL が増えても、別の要因(リリース、祝日、紹介記事)が同時に動く。チャネルを比べるときは、同じ週に複数のチャネルを同時に動かさない(§4.4)。

## 2. チャネル別の命名規則(UTM と `ct`)

### 2.1 App Store のキャンペーンリンク

Apple のキャンペーンリンクは、通常の App Store URL に3つのパラメータを足したもの:

```
https://apps.apple.com/jp/app/id<APP_ID>?pt=<PT>&ct=<CT>&mt=8
```

| パラメータ | 意味 | 決め方・制約 |
|---|---|---|
| `<APP_ID>` | App Store のアプリ ID(数字) | G0 で ASC にアプリレコードを作った後に確定する。**まだ無い** |
| `pt` | provider token。開発者アカウントを識別する。全キャンペーンで同じ | **ASC で最初のキャンペーンリンクを作ったときに Apple が発行する。手で作れない**。値は secret ではないが、台帳(§2.7)以外に散らさない |
| `ct` | campaign token。キャンペーンごとに1つ | 30文字まで。英数字と一部の記号。本書では **小文字英数字と `_` だけ**を使う(§2.2) |
| `mt=8` | media type(iOS) | 固定。Apple が生成した値をそのまま使う |

- **短縮 URL・リンクまとめサービスを挟まない。** `apps.apple.com` へ直行させる。リダイレクトが増えると、blocker・in-app browser・bot の判定で途切れる
- X の `t.co` は自動で挟まる。`ct` は維持されるが、Web referrer は `t.co` や X アプリになる。**campaign は `ct` で読む**(§3.3)
- Apple のヘルプ: [Campaign links](https://developer.apple.com/help/app-store-connect-analytics/acquisition/campaign-links)(2026-10-20 確認)

### 2.2 命名規則(`ct`)

```
{channel}_{placement}_{YYMMDD}[{variant}]
```

| 部分 | ルール | 例 |
|---|---|---|
| `channel` | 3つだけ。`x`(X) / `tz`(ティザー) / `ref`(紹介) | `x` |
| `placement` | リンクを置く場所。§2.3 の語彙だけを使う | `bio` |
| `YYMMDD` | **そのリンクを最初に使う日**(Asia/Tokyo)。使い回すときは変えない | `261031` |
| `variant` | 同じ placement で文案を変えたときだけ `a` / `b`。不要なら付けない | `b` |

- 使える文字は **`[a-z0-9_]` だけ**。空白・日本語・大文字・ハイフンは使わない(Apple はより広い文字を許すが、URL の見た目と突き合わせを単純にするため絞る)
- **30文字以内**。`channel` + `_` + `placement` + `_` + 6桁 + `variant` の合計で数える
- **1つの ct は1つの配置だけ**。同じ投稿を複数の場所に貼るときは、場所ごとに ct を分ける(分けないと、どこが効いたか分からない)
- **ct を再利用しない。** 文案・遷移先・訴求を変えたら新しい ct にする。古い ct は台帳に残す
- **ct に個人情報を入れない。** ニックネーム・ユーザー ID・メール・生年月日・招待コードを入れない
- `ct` は大文字小文字を区別し得るので、**すべて小文字**にする

### 2.3 チャネルと placement の語彙

| `channel` | 意味 | `utm_source`(将来) | `utm_medium`(将来) | `placement` の例 |
|---|---|---|---|---|
| `x` | X の投稿・プロフィール | `x` | `social` | `bio`(プロフィール) / `post`(単発投稿) / `thread`(連投) / `reply`(返信) / `pin`(固定投稿) |
| `tz` | ティザーページ(GitHub Pages)からの導線 | `teaser` | `referral` | `lp`(ページ内の App Store ボタン) / `qr`(QR コード) / `footer`(フッター) |
| `ref` | 紹介記事・プレス・知人への紹介 | `referral` | `referral` | `article`(紹介記事) / `press`(プレス) / `dm`(知人への DM) / `comm`(コミュニティ投稿) |
| — | App Store 検索・ブラウズ(ct なし) | `app_store` | `organic` | — |
| — | タグなし(起動直後・貼り忘れ) | — | — | — |

- **アプリ内の「招待」は `ref` ではない。** 招待はユーザーがアプリから送るもので、`ct` を付けられない。KPI.md の `invite_accepted`(分母 = 結果の決まった招待)で読む(§4.3)
- **公開前に X で出すティザー投稿は `x_`**。`tz_` はティザーページ(Web)から App Store へ出る導線。同じ「ティザー」でも、置き場所で分ける
- `aso` という ct は作らない。App Store 検索は ASC の Sources で読む。存在しない ct を作ると、台帳と実データがずれる

### 2.4 具体例

| `ct` | 長さ | 置く場所 | 備考 |
|---|---:|---|---|
| `x_bio_261101` | 12 | X のプロフィール | 公開直後はタグなし。11/1 に差し替え |
| `x_pin_261101` | 12 | X の固定投稿 | 公開翌日に固定投稿を campaign link へ |
| `x_post_261101` | 13 | X の単発投稿 | 公開翌日以降の投稿 |
| `x_thread_261101` | 15 | X の連投 | 開発ストーリーのスレッド |
| `x_reply_261105` | 14 | X の返信 | 他人の投稿への返信。乱用しない |
| `tz_lp_261101` | 12 | ティザーページの CTA | ページ内の主ボタン |
| `tz_qr_261101` | 12 | ティザーページの QR | オフライン配布用 |
| `ref_article_261101` | 18 | 紹介記事 | 記事内の App Store ボタン |
| `ref_press_261101` | 16 | プレスリリース | 配信先の本文 |
| `ref_dm_261101` | 13 | 知人への DM | 個別送信。文面は承認済みのものだけ |
| `x_post_261101b` | 14 | X の単発投稿(文案B) | 同じ placement の A/B。同時に出すときだけ |

- `x_post_261101b` のように **variant を付けるのは、同じ placement で文案を比べるときだけ**。通常は付けない
- `ct` の長さは、実際に ASC に入れる前に上の式で数える。30文字を超えたら `placement` を短くする(例: `article` → `art`)。**短くした語は §2.3 の語彙に追加してから使う**

### 2.5 UTM との対応(将来の Web 計測用)

いまは Web のアクセス解析を入れていない(ティザーページは静的。個人情報を集めるフォームも置かない)。将来、ティザーページや紹介記事の Web 計測を入れるときのために、`utm_*` の値を `ct` と同じ語彙に揃える。

| UTM | 値 | 例 |
|---|---|---|
| `utm_source` | チャネル | `x` / `teaser` / `referral` / `app_store` |
| `utm_medium` | 種別 | `social` / `referral` / `organic` |
| `utm_campaign` | **`ct` と同じ文字列** | `x_post_261101` |
| `utm_content` | placement + variant | `post` / `post_b` |
| `utm_term` | 使わない(検索広告を出すときだけ) | — |

- **App Store の URL に `utm_*` を付けない。** Apple は `utm_*` を campaign として読まない。付けると URL が長くなるだけで、`ct` の代わりにはならない
- Web ページから App Store へ遷移する場合、**Web 側の URL に `utm_*`、App Store ボタンに `pt`/`ct`** を付ける。Web 側の計測ツールが無い間は、`utm_*` を付けても記録されないので付けない
- ティザーページの CTA は、Web 側の UTM ではなく **`tz_lp_...` の `ct`** で DL を読む

### 2.6 最初のリンクが作れない期間(重要)

Apple の仕様上、**Campaigns タブは、アプリが Analytics のデータを持ち、公開後に DL が発生して 24 時間以上たつまで表示されない**。そのため、最初のキャンペーンリンクもその時点まで作れない。

そのため、**公開日(10/31)の投稿には `ct` を付けられない**。公開日の DL は Sources の `App Store search` / `App Store browse` / `Web referrer` / `App referrer` に出る。**公開日を含む最初の 1〜2 日は「タグなし」として記録し、0 ではなく `null`(又は `—`)と理由を書く**。

立ち上げの順序:

1. **10/31(公開日)** — 投稿・プロフィール・ティザーページの CTA は、`ct` なしの通常の App Store URL。DL は Sources で見る
2. **ASC に Campaigns が出たら(公開後 24 時間以上・最初の DL の後)** — 最初のキャンペーンリンクを作る。`pt` を台帳(§2.7)に記録する。プロフィール・固定投稿・ティザーページの CTA を campaign link に差し替える。**過去の投稿は無理に編集しない**(編集すると時系列が変わる)。必要なときは固定投稿とプロフィールだけ
3. **Campaigns が出てからの投稿** — すべて `ct` 付き。文案と配置が決まったら、投稿前に台帳へ ct を追加する

### 2.7 リンク台帳

`ct` は、作ったら必ずここに残す。ASC の画面を閉じた後に「あの ct は何だったか」を防ぐ。**`pt` と `<APP_ID>` は G0 後に1回だけ記入する**(secret ではないが、リンク台帳以外に散らさない)。

| `ct` | チャネル | placement | 置く場所 | 文案・素材 | 公開日 | 状態 | メモ |
|---|---|---|---|---|---|---|---|
| `x_bio_261101` | x | bio | X プロフィール | 表示名+1行説明 | 11/1 | 未発行 | ASC の最初のリンク作成後 |
| `x_pin_261101` | x | pin | X 固定投稿 | 公開告知 | 11/1 | 未発行 | 公開日の投稿は別(タグなし) |
| `x_post_261101` | x | post | X 単発 | 開発ストーリー | 11/1 | 未発行 | |
| `x_thread_261101` | x | thread | X 連投 | 開発ストーリー | 11/1 | 未発行 | |
| `tz_lp_261101` | tz | lp | ティザーページ CTA | 主ボタン | 11/1 | 未発行 | 公開日の CTA はタグなし |
| `ref_article_261101` | ref | article | 紹介記事 | 記事内ボタン | 11/1 | 未発行 | |
| `ref_press_261101` | ref | press | プレス | 本文 | 11/1 | 未発行 | |
| `ref_dm_261101` | ref | dm | 知人 DM | 募集文 | 11/1 | 未発行 | 承認済み文面のみ |
| — | x | post | 公開日の投稿 | 公開告知 | 10/31 | **タグなし** | Campaigns が出る前なので ct を発行できない。通常の App Store URL で出す |

- 状態は `未発行` / `発行済み` / `停止` の3つ。`停止` にした ct も消さない(過去の DL が残る)
- 台帳に無い `ct` を投稿に使わない。使った場合は、後から台帳に足して「いつ・どこで」を書く

## 3. App Store Connect Analytics で見る指標

以下、**App Store Connect の Analytics(旧 App Analytics)** を「ASC Analytics」と書く。画面名・指標名は 2026-10-20 時点の Apple のヘルプに基づく。**Apple の UI は変わるので、提出時に画面のツールチップで最終確認する**(§7)。

### 3.1 見る画面

| 画面 | パス | 何を見る |
|---|---|---|
| Campaigns | Analytics → Acquisition → Campaigns | `ct` 別の Impressions / Product Page Views / First-Time Downloads / Conversion Rate |
| Metrics + Campaign filter | Analytics → Metrics → Add Filter → Campaign | 任意の指標を `ct` で切る。Sessions / Active Devices / Retention も、しきい値を満たせば見える |
| Sources | Analytics → Acquisition → Sources | `App Store search` / `App Store browse` / `App referrer` / `Web referrer` / `Campaign` / `Unavailable` |
| Retention | Analytics → Engagement → App retention | インストール日ごとの D1/D7。Source / Campaign で切れる場合がある |

- 期間は **直近7日**(傾向)と **直近30日**(チャネルの判断)の両方で見る。Campaigns は 30 日で見ないと、しきい値に届かず「0 に見える」ことがある
- `ct` は**キャンペーン名**として ASC に表示される。台帳(§2.7)と突き合わせる

### 3.2 指標の一覧(これだけ見る)

| 指標 | Apple の定義(要約) | 分母 | 何に使う | 注意 |
|---|---|---|---|---|
| **Impressions (Unique Devices)** | Today / Games / Apps / Search で1秒以上見られたユニーク端末数。Product Page View を含む | ユニーク端末 | チャネルの到達。CVR の分母 | 通常の Impressions(ユニークでない)は水増しされるので使わない |
| **Product Page Views (Unique Devices)** | App Store の product page を見たユニーク端末数。StoreKit の表示を含む | ユニーク端末 | ページ到達。ページ CVR の分母 | Impressions と混同しない |
| **First-Time Downloads** | 初回ダウンロード数 | — | **チャネル別 DL の主指標** | 再DL・更新・復元は含まない |
| **Total Downloads** | First-Time Downloads + Redownloads | — | 全体の整合チェック | 再DLを含むので、チャネルの質の比較には使わない |
| **Conversion Rate** | Total Downloads + pre-orders ÷ ユニーク端末の Impressions | ユニーク Impressions | App Store 全体の CVR | **Apple の定義は分子が Total Downloads**。キャンペーン別に読むときは `First-Time Downloads / ユニーク Impressions` を別に計算し、混同しない |
| **Sessions** | 2秒以上使われた回数。バックグラウンドから再開すると1回 | — | DL 後の利用 | 利用データは **opt-in したユーザーだけ**。しきい値あり |
| **Active Devices** | 期間中に1回以上セッションのあった端末数 | 端末 | DL 後の利用の広がり | opt-in・しきい値あり |
| **App retention(D1 / D7)** | インストール日にアプリを開いた端末のうち、n日後に開いた割合 | インストール後に一度でも開いた端末 | DL 後の定着 | **ペアの D1/D7 とは別物**(§3.4)。opt-in・しきい値あり |
| **Crashes** | クラッシュ数 | — | 品質の見張り | 任意。細かいログは Xcode |
| **Sources** | DL 元の種別(`App Store search` など) | — | `ct` で拾えない DL の受け皿 | `Campaign` は campaign link 経由。`Unavailable` はギフトコード等 |
| **Campaign** | `ct` で切るフィルタ | — | チャネル別の分析 | 5 App Units 未満は表示されない。詳細レポートはさらに秘匿処理 |

- Apple のヘルプ: [Metric definitions](https://developer.apple.com/help/app-store-connect-analytics/reference/metrics-definitions) / [Filters and dimensions](https://developer.apple.com/help/app-store-connect-analytics/reference/filters-and-dimensions) / [Acquisition](https://developer.apple.com/help/app-store-connect-analytics/acquisition/acquisition)(2026-10-20 確認)
- 指標名は、ASC の画面では `App Units` などの旧称で出ることがある。**画面のツールチップの定義を読み、上の表の意味と対応させる**。名前だけで判断しない

### 3.3 しきい値・欠測・attribution の限界

1. **アプリ全体の App Store 指標**は、初回 DL(又は予約注文)が **5件** 以上ないと表示されない
2. **キャンペーン**は、公開後 **24時間以上** かつ、選択期間内に **5 First-Time Downloads**(5人の個別ユーザー)以上で表示される。**新規キャンペーンは 24時間後に出る**
3. **利用データ(Sessions / Active Devices / Retention)** は、**opt-in したユーザー**だけ。**5 Active Devices** 以上で表示され、Retention は「十分な人数が opt-in したとき」だけ。opt-in 率は Retention 画面で見られる
4. **詳細レポート**は、少人数の行を **非表示又は他の行と結合**する。行が欠けていても異常ではない
5. **しきい値未満は `null`(又は `—`)と理由を書く。0 と書かない。** 「データが無い」と「DL が 0」は違う
6. **attribution の窓は24時間。** campaign link をタップしてから **24時間以内**の初回 DL が対象。最後にタップしたリンクが優先される(**last click**)
7. **App Store Search は、投稿を見て名前を検索した人も吸収する。** campaign の数字は**下限**。投稿が効いていても Search に付くことがある
8. **再DLで source がリセットされる。** 同じ人が再DLすると、その後の利用・課金は新しい source に付く。過去の campaign の成果が減って見えることがある
9. **in-app browser の扱い。** iOS では Safari 以外(Chrome、X アプリ内など)からのタップは `App referrer` になり、`Web referrer` にならない。`ct` は維持されるので、campaign で読む
10. **地域・端末で切れる。** 日本だけ、iPhone だけ、などのフィルタを必要に応じて使う。ただし、切った後の分母を必ず書く

### 3.4 見ない・混ぜない指標

- **Proceeds / Sales / Subscriptions** — v1.0 は無料。v1.1 の課金時に RevenueCat と合わせて別途決める(REQUIREMENTS §7)
- **Apple の Retention を、ペアの D1/D7 の代わりにしない。** Apple は「端末がアプリを開いたか」、KPI.md は「ペアの2人がふたり達成したか」。**分母が違う**(§4.3)
- **Total Downloads をチャネルの質の比較に使わない。** 再DLを含む。チャネル比較は First-Time Downloads
- **5件未満の Campaign CVR を比較しない。** 1件で 20ポイント動く。30日で見る
- **DL 数をユーザー数として使わない。** `users` の行はオンボのニックネーム送信でできる(DESIGN §3.3)。DL してもオンボを終えなければ `users` には入らない

## 4. 週次の見方(分母つき)

### 4.1 毎週金曜の手順

TASKPLAN §5 のとおり、毎週金曜に `/status` で記録する。手順は固定する。

1. **cron を確認する。** `lien-cron-watch` が緑で、close-day が昨日まで書いていること(KPI.md §2.2)。赤なら KPI を読まずに OPS.md §4 で再実行する
2. **KPI.md の SQL を流す。** `include_test = false` のまま。結果の `as_of` と、`num / den / rate` を保存する。**ペア ID・ユーザー ID・ニックネームは保存しない**
3. **ASC Analytics を見る。** 直近7日と直近30日。Campaigns は `ct` ごと、Sources は種別ごと。**表示されているセルだけ**記録し、しきい値未満は `null` と理由を書く
4. **週次シート(§4.2)を埋める。** 先週との差、分母の変化(成熟したペアが増えた、招待の期限が切れた)、新しく出た `ct` をメモする
5. **JOURNAL に3行で書く。** 「数字」「分母の注意」「次の一手」。個人情報は書かない
6. **異常を止まる。** 未来の日付、同じ指標で2つの違う数字、`den = 0` なのに `rate` がある、などは片方を選ばず、異常として報告する(共通ポリシー3)

### 4.2 週次シート(テンプレート)

```
週: 2026-10-26 〜 2026-11-01 / as_of: 2026-11-01(JST) / include_test: false
ASC(直近7日 / 直近30日):
  ct / Impressions(unique) / Product Page Views(unique) / First-Time Downloads / CVR / メモ
  x_bio_261101  — / — / — / — / 5件未満は null
  (タグなし)     — / — / — / — / Sources で Search/Browse を見る
SQL(KPI.md):
  invite_accepted:      num / den = — / — (—%)
  paired_within_7d:     num / den = — / — (—%)
  d7_both:              num / den = — / — (—%)
  nudge_checkin_2h:     num / den = — / — (—%)
  both_days_week:       num / den = — / — (—)
橋:
  users_created_week:   —人(分母 = 同じ週の First-Time Downloads —件 → オンボ到達 —%)
解釈: …
次: …
```

- `—` は「まだ見えない・しきい値未満・未実行」。**0 と書かない**
- 数値は `num / den` と率の両方を残す。率だけだと、母数が 2 ペアのときに誤読する
- 週次シートは JOURNAL か issue に貼る。**ペア ID・ユーザー ID・ニックネームは貼らない**(KPI.md §0.4)

### 4.3 率の分母(一覧)

| 率 | 分子 | 分母 | 混ぜてはいけないもの |
|---|---|---|---|
| チャネル CVR | First-Time Downloads(`ct`) | ユニーク Impressions(`ct`) | Total Downloads / 全チャネルの Impressions |
| ページ CVR | First-Time Downloads(`ct`) | ユニーク Product Page Views(`ct`) | Impressions(ページを見ていない人を含む) |
| DL シェア | First-Time Downloads(`ct`) | 全 source の First-Time Downloads(タグなし・Search を含む) | DL 数 / ユーザー数 |
| オンボ到達率(**近似**) | 同じ週に作成された実ユーザー | 同じ週の First-Time Downloads | 厳密なコホート。時差・未起動・再DLを含む |
| ペア成立率 | 使われた招待(`used_at` あり) | 結果の決まった招待(`used_at` あり、又は `expires_at` 経過) | 未使用で期限内の招待 / 招待の作成数 |
| 7日以内ペア成立 | 作成から7日以内にペアに入ったユーザー | 作成から7日以上たった実ユーザー | DL 数 / 全ユーザー |
| D1 / D7 / D30 両者継続 | 窓(d0+n−2〜d0+n)に `kind='both'` が1日以上あるペア | その日まで確定した実ペア(`started_on + n + 1 <= 今日`) | ユーザー数 / 未成熟のペア / Apple の Retention |
| つつき → 2時間以内チェックイン | 相手が2時間以内にチェックインしたつつき | 2時間以上たったつつき | 全つつき / 送り手自身のチェックイン |
| 名前付け率 | 名前が入った植物のペア | 最初のふたり達成から3日以上たったペア | 全ペア / 名前を付けた人数 |
| North Star(週あたり) | その週のふたり達成日の合計(ペア×日) | その週にふたり達成日があったペア数 | DL 数 / 全ペア数 |
| Apple の D1/D7 Retention | n日後にアプリを開いた端末 | インストール後に一度でも開いた端末 | ペアの D1/D7 / 全 DL |
| 500 DL(リリース+1か月) | First-Time Downloads の累計 | —(件数。率ではない) | 「500 ユーザー」と言い換えない |
| 招待 → ペア 40% | 使われた招待 | 結果の決まった招待 | 500 DL を分母にしない |
| D30 25% | 窓に `both` のあるペア | 30日分が確定したペア | 500 DL / 全ユーザー |

- **分母は「母数に入る条件」まで書く。** 上の表の「分母」列は、KPI.md §4 の「母数に入る条件」と同じ
- **率の分母に、別の層の数字を使わない。** 例: 招待→ペア 40% の分母は「結果の決まった招待」で、DL でもユーザーでもない
- **1ペア = 2ユーザー。** ペアの率とユーザーの率を混ぜない。ユーザーからペアに換算するときは、2で割るのではなく「ペアの行」で数える

### 4.4 読む順番と判断

1. **App Store の入口** — Impressions が多いのに Product Page Views が少ない → アイコン・名前・サブタイトル(ASO)。Product Page Views が多いのに First-Time Downloads が少ない → スクショ・説明文・価格・レビュー
2. **チャネル** — 直近30日の First-Time Downloads を比べる。**1週間の空欄でチャネルを殺さない**(5件しきい値)。CVR はページ CVR と合わせて見る
3. **プロダクトの入口** — `paired_within_7d` と `invite_accepted`。低い → オンボ・招待の導線。招待の期限切れ・作成し直しが増えていないか
4. **コアループ** — `d7_both` / `d30_both`。低い → 通知・つつき・約束の設計。**DL が増えても D7 が低いなら、獲得よりプロダクト**
5. **質** — `nudge_checkin_2h` / `plant_named` / `both_days_week`。North Star が増えているか
6. **次の一手** — 1つだけ決める。チャネルを増やす / 投稿を直す / オンボを直す / コアループを直す。**同時に複数を動かすと、次の週に因果が分からない**

判断の例(数字は仮定しない。`—` のまま):

| 見えたこと | 判断 | 動かすもの |
|---|---|---|
| X の First-Time Downloads は多いが、オンボ到達率(近似)が低い | 投稿とストア/オンボの約束がずれている | 投稿の訴求、ストアのスクショ・説明、オンボの1画面目 |
| 招待の作成は多いが `invite_accepted` が低い | 招待の期限・導線・相手の負担 | 招待文、期限の見せ方、コード入力の導線 |
| `paired_within_7d` は高いが `d7_both` が低い | ペア成立後の中だるみ | 通知文言、つつき、約束の設定 |
| `nudge_checkin_2h` が低い | つつきが行動につながっていない | つつきのタイミング・文言・スタンプ |
| Search の DL が投稿日に増えた | 投稿が「名前検索」を生んだ可能性 | 投稿の継続。ただし因果とは書かない |

### 4.5 週次の補助 SQL(新規テーブルなし)

KPI.md の SQL は「成熟した率」を出す。週次の**量**(新規ユーザー・ペア成立・招待の作成)は、KPI.md の SQL の最後の `select` を次に差し替えて出す。**`params` / `test_users` / `real_users` / `real_pairs` は KPI.md §3 の CTE をそのまま使う**ので、テストユーザーの一覧を二重に持たない。

```sql
-- docs/KPI.md §3 の SQL の `-- 結果:` 以降を、これに差し替える。
-- params / test_users / real_users / real_pairs は KPI.md の CTE をそのまま使う。
select 'new_users_week:' || to_char(w.week_start, 'YYYY-MM-DD') as metric,
       'その週に作成された実ユーザー(オンボ完了)' as meaning,
       count(u.id) as num, null::bigint as den, null::numeric as rate
from (
  select generate_series(
           date_trunc('week', (select today from params)::timestamp) - interval '49 days',
           date_trunc('week', (select today from params)::timestamp),
           interval '7 days')::date as week_start
) w
left join real_users u
  on (u.created_at at time zone 'Asia/Tokyo')::date >= w.week_start
 and (u.created_at at time zone 'Asia/Tokyo')::date <  w.week_start + 7
group by w.week_start
union all
select 'pairs_started_week:' || to_char(w.week_start, 'YYYY-MM-DD'),
       'その週に成立した実ペア',
       count(p.id), null::bigint, null::numeric
from (
  select generate_series(
           date_trunc('week', (select today from params)::timestamp) - interval '49 days',
           date_trunc('week', (select today from params)::timestamp),
           interval '7 days')::date as week_start
) w
left join real_pairs p
  on p.started_on >= w.week_start and p.started_on < w.week_start + 7
group by w.week_start
union all
select 'invites_created_week:' || to_char(w.week_start, 'YYYY-MM-DD'),
       'その週に作成された実ユーザーの招待',
       count(i.token), null::bigint, null::numeric
from (
  select generate_series(
           date_trunc('week', (select today from params)::timestamp) - interval '49 days',
           date_trunc('week', (select today from params)::timestamp),
           interval '7 days')::date as week_start
) w
left join public.invites i
  on (i.created_at at time zone 'Asia/Tokyo')::date >= w.week_start
 and (i.created_at at time zone 'Asia/Tokyo')::date <  w.week_start + 7
 and ((select include_test from params) or i.from_user not in (select id from test_users))
group by w.week_start
order by metric;
```

- これは**量**だけ。率は KPI.md の `invite_accepted` / `paired_within_7d` / `d1_both` / `d7_both` を使う。補助 SQL で率を出さない(分母の成熟条件を二重に実装しないため)
- 初回は `include_test = true` で流し、`select count(*) from public.users` などの素朴な数と突き合わせる(KPI.md §5.2)。**確かめたら `false` に戻す**
- 本番では読み取りのみ(`set transaction read only`)。新しいテーブル・列・migration は作らない
- 2026-10-20 時点: KPI.md の SQL にこの差し替えを適用した全文を PostgreSQL のパーサ(`pglast`)で構文確認済み。**本番 DB では未実行**(実行は毎週の手元。§4.1)

### 4.6 記録の例(数字は入れない)

```
2026-11-06(金) 週次
- 数字: invite_accepted —/—、paired_within_7d —/—、d7_both —/—、North Star —/—
- 分母: ペアがまだ少なく、D7 は成熟した —ペアだけ。率は読まず num/den を見る
- ASC: x_bio_261101 は 5件未満で null。Search が大半。公開日の投稿はタグなし
- 次: 固定投稿の文案を1つ変える(ct は x_pin_261101b)
```

- 「0」と「見えない」を混ぜない。`—` の理由(5件未満 / opt-in 不足 / 未実行 / 期間外)を1行で書く

## 5. 分析 SDK を入れない代替案

### 5.1 結論

v1.0 は **分析 SDK を入れない**(D6)。チャネル別の DL は ASC Analytics、アプリ内は KPI.md の SQL。**ユーザー単位のチャネル attribution はしない**。この制約を受け入れる代わりに、App Privacy の申告・ATT・プライバシーポリシーを単純に保つ。

### 5.2 代替案の一覧

| 知りたいこと | 代替 | できる | できない | アプリの追加実装 | App Privacy への影響 |
|---|---|---|---|---|---|
| どのチャネルが DL を生んだか | ASC のキャンペーンリンク(`pt`/`ct`) | `ct` 別の Impressions / Product Page Views / First-Time Downloads / CVR | ユーザー単位の特定。5件未満。24時間の窓 | なし | なし(Apple の集計。アプリは送らない) |
| どの source から DL したか | ASC の Sources | Search / Browse / App referrer / Web referrer / Campaign / Unavailable | 検索語。campaign 以外の詳細 | なし | なし |
| 招待 → ペア → D7 | KPI.md の SQL | 全体のファネル。分母つき | チャネル別のファネル | なし | なし(既存テーブルの読み取り) |
| チャネル × アプリ内 | **チャネルを時間で分けた比較** | 週ごとに1チャネルを動かし、次の週の KPI と比べる | 個人の attribution。同時に複数チャネルを動かすと分離できない | なし | なし |
| 先行ペア・テスターの反応 | TestFlight のグループをチャネル別に分ける | グループごとのテスター数・反応 | DL の attribution。外部 TestFlight は省略(TASKPLAN §9.2) | なし | なし |
| 有料検索広告の効果 | Apple Search Ads + AdServices(Apple のフレームワーク) | 広告経由の attribution(ASA のみ) | オーガニック投稿の attribution。導入にはアプリ改修 | あり(検討時) | 要確認(ATT・プライバシーマニフェスト) |
| Web ページの反応 | いまは計測しない(静的ページ) | `ct` 付き CTA からの DL | ページの閲覧数・クリック数 | Web analytics を入れるならあり | 入れるなら要確認 |
| 「どこで知ったか」 | **採用しない** | — | — | オンボに質問を足すと、計測専用の列・テーブルが要る | D6 の見直しが必要 |

- **「チャネルを時間で分けた比較」**は、週ごとに動かすチャネルを1つに絞る。前の週と同じ KPI を読み、差を見る。因果ではなく「同時に動いていない」ことを担保する程度の強さ
- **TestFlight のグループ分け**は、先行ペアの募集(MK4 / #77)で使える。ただし TestFlight のテスター数は DL ではない。公開後の ASC の数字とは別に記録する
- **Apple Search Ads / AdServices** は、広告を出す場合の候補。third-party SDK ではないが、アプリにフレームワークを足すので、D6 の見直し・#30 の再確認・ATT の要否確認が必要。**v1.0 ではやらない**
- **Web analytics** は、ティザーページに個人情報を集めない方針(MK3 / #76)と、D6 の「アプリは計測のために何も送らない」に留意する。ページ側の解析を入れるなら、Cookie・同意・プライバシーポリシーの確認が要る。**v1.0 では入れない**

### 5.3 SDK を入れたくなったときの手順

1. **D6 を変える判断カード**をオーナーに取る(「計測のために SDK を入れる」は D6 の変更)
2. **#30 の App Privacy を再確認**する。データ型・用途・トラッキング・ATT・プライバシーポリシー・`PrivacyInfo.xcprivacy`・review-notes §2.1
3. **プライバシーポリシー(md / html)とマニフェスト**を同時に更新する
4. **ユーザーへの説明・同意**が必要なら、オンボか設定に足す
5. **静的テスト**(`marketing_docs_static_test.ts`)と CI を緑にする
6. **「計測のためだけ」に黙って入れない。** 入れるなら、何を・どの用途で・どこへ送るかを先に書く

## 6. #30(App Privacy)との整合

| 対象 | いまの状態 | 本書の設計で変わるか |
|---|---|---|
| [review-notes.md](review-notes.md) §2.1 の App Privacy 草案 | 5型(Name / Photos / Other User Content / User ID / Device ID)。利用状況の計測なし。トラッキングなし | **変わらない** |
| `products/lien/ios/Lien/PrivacyInfo.xcprivacy`(と NSE / Widget) | `NSPrivacyTracking = false`、追跡ドメインなし、収集データは上記5型 | **変わらない** |
| [privacy-policy.md](privacy-policy.md) / [legal/privacy.html](legal/privacy.html) | 分析 SDK・計測専用テーブルを入れず、アプリは計測のために何も送らない | **変わらない** |
| [legal/CHECKLIST-G4.md](legal/CHECKLIST-G4.md) | D6 の確認項目あり | **変わらない** |
| ATT(App Tracking Transparency) | 使っていない | **使わない**。App Analytics は Apple の集計で、アプリがユーザーを追跡するものではない |
| App Store Connect の「アプリのプライバシー」 | #30 の草案どおり | **変えない**。提出時に質問票で最終確認する |

- **ASC Analytics は、アプリが送る利用状況データではない。** Apple が App Store 側で集計し、開発者に aggregate を返す。だから App Privacy の「利用状況」を足さない(#30 の方針)
- **キャンペーンリンクの `ct` は URL パラメータ**で、アプリには渡らない。アプリのデータ収集を増やさない
- **App Store の質問票は毎回変わり得る。** 提出日(10/27)に、#30 の §2.1 と画面の選択肢を突き合わせる。迷ったら「利用状況を収集する」に倒さず、#30 の記録に戻る

## 7. 未決・要確認

| 項目 | 状態 | いつ決めるか |
|---|---|---|
| `<APP_ID>`(App Store のアプリ ID) | 未確定 | G0 で ASC にアプリレコードを作った後 |
| `pt`(provider token) | 未発行 | 公開後、ASC で最初のキャンペーンリンクを作った時。台帳(§2.7)に記録 |
| 最初の `ct` を発行できる日 | 公開後 24時間以上・DL 後 | 10/31 はタグなし。11/1 以降に発行 |
| Apple の画面名・指標名・しきい値 | 2026-10-20 時点のヘルプ | 提出時(10/27)と毎四半期に再確認 |
| `ct` の文字種・長さ | 本書は `[a-z0-9_]`・30文字に絞る | ASC の入力画面で最終確認 |
| カスタム product page(`ppid`)をチャネル別に使うか | 未決。`ct` との併用は Apple のヘルプに明記がない(2026-10-20 時点) | v1.0 では使わない。必要なら検証してから |
| Apple Search Ads / AdServices | 未決。v1.0 では使わない | 広告を出す判断をした時。D6・#30 の再確認とセット |
| Web analytics(ティザーページ) | 未決。v1.0 では入れない | MK3 / #76 のページ公開後、必要なら |
| 「どこで知ったか」のオンボ質問 | 未決。D6 の見直しが要る | v1.1 以降。v1.0 では入れない |

## 8. 受け入れ条件との対応

| Issue #78 の完了条件 | 本書の節 |
|---|---|
| チャネル別 UTM 命名規則(X / ティザー / 紹介) | §2(§2.2 の `ct` 命名規則、§2.3 のチャネル、§2.4 の例、§2.5 の UTM 対応) |
| App Store Connect の App Analytics で見る指標の一覧 | §3(§3.2 の表、§3.3 のしきい値) |
| docs/KPI.md の SQL と組み合わせた週次の見方(分母つき) | §4(§4.1 手順、§4.2 シート、§4.3 分母一覧、§4.5 補助 SQL) |
| 分析 SDK を入れない代替案(App Privacy / #30 と整合) | §5(代替案)、§6(#30 との整合) |

## 9. 参考(Apple の一次情報)

- [Campaign links](https://developer.apple.com/help/app-store-connect-analytics/acquisition/campaign-links) — `pt` / `ct` / `mt`、24時間・last click、5件しきい値、リンク作成の条件
- [Acquisition](https://developer.apple.com/help/app-store-connect-analytics/acquisition/acquisition) — Sources の定義、impression → product page → download の funnel
- [Metric definitions](https://developer.apple.com/help/app-store-connect-analytics/reference/metrics-definitions) — Impressions / Product Page Views / Conversion Rate / First-Time Downloads / Sessions / Active Devices / Retention
- [Filters and dimensions](https://developer.apple.com/help/app-store-connect-analytics/reference/filters-and-dimensions) — Campaign / Source Type / App Referrer / Web Referrer
- [App retention](https://developer.apple.com/help/app-store-connect-analytics/engagement/app-retention) — opt-in・しきい値・分母の定義

(2026-10-20 に確認。Apple の UI とヘルプは変わるので、提出時に再確認する)
