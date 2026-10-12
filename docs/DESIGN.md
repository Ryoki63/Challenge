# Lien — 技術設計書(コーディングエージェント向け)

- 作成日: 2026-06-10
- 対象読者: このリポジトリで実装タスクを実行するエージェント(ループ・対話セッション両方)
- 位置づけ: **What = [REQUIREMENTS.md](REQUIREMENTS.md) / How = 本書 / 実行順序 = [TASKPLAN.md](TASKPLAN.md)**
- 本書にない実装判断で迷ったら、AGENTS.md 原則5(迷ったら止まる)に従い BLOCKED にして質問を残す

## 1. 全体アーキテクチャ

```
 iPhone A(あなた)                    Supabase                       iPhone B(相手)
┌──────────────┐    HTTPS    ┌─────────────────────┐              ┌──────────────┐
│ Lien アプリ   ├────────────>│ Edge Functions       │   APNs push  │ LienNSE       │
│  └ 送信キュー │  (全書き込み)│  checkin/nudge/...   ├─────────────>│ (通知拡張)    │
│ LienWidget    │             │  └ streak.ts(純粋)   │ snapshot同梱 │  └ AppGroupへ │
│  ↑ AppGroup   │             ├─────────────────────┤              │     書き込み  │
│ LienNSE       │             │ Postgres + RLS       │              │ LienWidget    │
└──────────────┘             │ Storage(写真)        │              │  ↑ 即reload   │
                              └─────────────────────┘              └──────────────┘
```

設計の核は2つ:

1. **ロジックは可能な限りサーバー(Edge Functions)に置く** — ストリーク判定の正は1箇所だけ。TypeScript なので Windows 側ループでも実装・`deno test` 検証が完結する。iOS は「表示と同期」に徹する
2. **プッシュに状態を同梱する** — 通知拡張(NSE)が受信ペイロード内のスナップショットを App Group に書いてウィジェットを reload する。受信側はネットワーク往復なしでウィジェットが更新される(60秒目標の根拠)

## 2. ディレクトリ構成

```
products/lien/
├── ios/
│   ├── project.yml          # XcodeGen 定義(.xcodeproj はコミットしない)
│   ├── Lien/                # アプリ本体ターゲット
│   ├── LienWidget/          # ウィジェット拡張
│   ├── LienNSE/             # Notification Service Extension
│   ├── LienTests/           # 単体テスト
│   └── Config/              # *.xcconfig(Secrets.xcconfig は gitignore)
├── supabase/
│   ├── migrations/          # NNNN_name.sql 連番
│   └── functions/           # Edge Functions(deno)
│       └── _shared/         # streak.ts / tickets.ts / apns.ts / snapshot.ts / messages.ts
├── assets/
│   ├── plant/               # ドット絵スプライト(原寸PNG)
│   └── icon/
├── web/invite/              # 招待用静的ページ(GitHub Pages)
└── marketing/               # ASO文言・スクショ・privacy-policy.md・terms.md
```

## 3. iOS アプリ設計

### 3.1 ターゲット構成

| ターゲット | 役割 |
|---|---|
| Lien | アプリ本体。SwiftUI |
| LienWidget | systemSmall / systemMedium / accessoryCircular / accessoryInline |
| LienNSE | プッシュ受信時に snapshot を App Group へ書き、`WidgetCenter.reloadAllTimelines()` |

- iOS 17.0+ / Swift 5.10+
- Bundle ID: `com.ryoki63.lien` を推奨(**G0 で人間が最終決定**。本書では `<BUNDLE_ID>` と表記)
- App Group: `group.<BUNDLE_ID>.shared`
- 外部依存は **supabase-swift のみ**(v1.1 で RevenueCat を追加)。これ以外はタスク本文に明記がない限り追加禁止

### 3.2 プロジェクト生成は XcodeGen

- `.xcodeproj` はコミットしない(`.gitignore` 登録)。`project.yml` が正
- 理由: エージェントが Windows からでもプロジェクト定義を編集でき、`.pbxproj` のコンフリクト・破損が構造的に起きない
- Mac / CI では `xcodegen generate && xcodebuild ...`

### 3.3 アプリ内アーキテクチャ

- SwiftUI + Observation(`@Observable`)。ViewModel は画面単位
- データ層は `Core/Repositories/`(SupabaseService をラップ)。View から Supabase を直接呼ばない
- **状態の正はサーバー**。アプリが永続するのは「最後に取得した PairSnapshot」+「未送信キュー」のみ(ローカルDBは持たない。SwiftData不使用)
- ルートは `AppPhase` enum(`onboarding` / `solo` / `paired`)で画面系統を切替

```
ios/Lien/
├── App/            LienApp.swift, AppPhase.swift, DeepLinkHandler.swift
├── Core/
│   ├── Config.swift            # xcconfig→Info.plist 経由でURL/キー読込
│   ├── SupabaseService.swift   # auth + functions呼び出し
│   ├── AppGroupStore.swift     # pair_snapshot.json / pending_ops.json の読み書き
│   ├── PushManager.swift       # 許可・トークン登録
│   ├── Models/                 # PairSnapshot, Promise, CheckinDay, ...
│   ├── DesignSystem/           # Colors.swift, Spacing.swift, PixelImage.swift
│   └── Strings.swift           # ユーザー向け文言を全て集約
└── Features/
    ├── Onboarding/  ├── Pairing/  ├── PromiseSetup/
    ├── Home/        ├── History/  ├── Album/        └── Settings/
```

### 3.4 App Group 共有契約(ウィジェットとの境界。変更時は要レビュー)

App Group コンテナ直下 `pair_snapshot.json`。スキーマ(schemaVersion = 1):

```json
{
  "schemaVersion": 1,
  "pairId": "uuid | null(ソロ状態)",
  "updatedAt": "ISO8601",
  "streakCurrent": 23,
  "streakBest": 40,
  "todayMeDone": true,
  "todayPartnerDone": false,
  "myPromiseTitle": "筋トレ", "myPromiseEmoji": "💪",
  "partnerName": "ゆうき",
  "partnerPromiseTitle": "ランニング", "partnerPromiseEmoji": "🏃",
  "plantStage": 3,
  "plantGrownDays": 9,
  "plantStageFloor": 7,
  "plantNextStageAt": 14,
  "plantMood": "normal | happy | fidget | sad",
  "plantName": "みどり",
  "hasPartnerPhotoToday": false
}
```

- 書き込むのは**アプリ本体と NSE の2者だけ**。ウィジェットは読み取り専用
- snapshot は**受信者視点**でサーバーが組み立てる(me/partner の向きをクライアントで反転しない)
- **植物のキー(成長ルール v2。2026-10-12・issue #54 / docs/GROWTH.md)**
  - `plantStage`: 成長段階 0〜9(0=たね 1=ふたば 2=めばえ 3=わかば 4=よりそい 5=つぼみ 6=いろづき 7=ほころび 8=ふたりざき 9=みのり)。サーバーの閾値配列 `PLANT_STAGE_THRESHOLDS = [0,1,3,7,14,21,30,45,66,100]` の添字で、段階名はアプリ側(Strings)が持つ。アプリが知らない大きい段階が来たら、知っている最大の段階として描く
  - `plantGrownDays`: 成長回数(ふたり達成日の累計)。数え方は §5.4「成長回数」。ソロは 0
  - `plantStageFloor`: 今の段階に入る回数(= 閾値配列の `plantStage` 番目)。ソロは 0
  - `plantNextStageAt`: 次の段階に必要な回数。最後の段階(みのり)とソロは `null`(キーは省略せず `null` で出す)。アプリは閾値表を持たずに「あと `plantNextStageAt - plantGrownDays` 回」と区間の進み具合 `(plantGrownDays - plantStageFloor) / (plantNextStageAt - plantStageFloor)` を作れる(あとからサーバー側で閾値を下げても、古いアプリが追従する)
  - `plantMood` の `sad` はアプリでは「すやすや」眠る絵で描く(値は互換性のため `sad` のまま)
- **互換性**: キーの**追加のみ**(`schemaVersion` は 1 のまま)。古いアプリは未知のキーを無視し、新しいアプリは無いキーを nil として扱いゲージを出さない(表示がちらつかない)。古いアプリは段階 6 以上を 5 として描く(外部配布の前にサーバーと新しいアプリをそろえる — GROWTH §8.6)。この snapshot を組み立てる全関数(§5.3)は**まとめてデプロイする**(一部だけ出すと、通知ごとに古い形と新しい形が混ざる)
- 相手の今日の写真サムネは `photo_thumb.jpg` として同コンテナに保存(NSE がダウンロード、200KB上限)。失敗時は植物表示にフォールバック

### 3.5 ウィジェット実装方針

- TimelineProvider のエントリは2点: `now`(現在状態)と `翌日0:00`(日付跨ぎで両者「未完」表示に戻す)。`policy: .atEnd`
- reload のトリガーは NSE とアプリ本体のみ(WidgetKit の reload 予算を浪費しない)
- 植物は SVG のレイヤーを同じキャンバス(viewBox 240×320)で重ねて描く(`PlantCharacterView`)。拡大縮小は自由(ドット絵のときの整数倍・`interpolation(.none)` の制約はない)。レイヤーの規則と重ね順は `products/lien/assets/plant/mapping.md`(取込後)/ 現時点の正本は `products/lien/assets/plant/v4_drafts/README.md`
- ウィジェットも `PlantCharacterView` を共有する(SwiftUI と Foundation だけに依存させる)。全レイヤーを重ねてメモリに収まるかは実機(G1 / T20)で確かめ、収まらなければ「段階 × 葉の状態」を合成済みの1枚にしたウィジェット専用画像で代える(GROWTH.md §9.5)
- 表示原則(REQUIREMENTS §3.10): 自分未完=自分側グレー / 相手が先に完了=「(名前)が待ってるよ」

### 3.6 ディープリンク

- カスタムスキーム `lien://invite/<token>`(v1.0)
- `onOpenURL` → invite-accept 呼び出し → 失敗時はコード手入力画面へ誘導
- ユニバーサルリンクは独自ドメイン取得(G4 で判断)後の v1.1

### 3.7 オフライン

- チェックイン操作はまず `pending_ops.json` に積み、即座にUI反映(楽観更新)
- 送信成功でキューから削除。再送はアプリ起動時+フォアグラウンド復帰時
- サーバー側が冪等(同 user×date は重複OK応答)なので再送は安全

### 3.8 文言・デザイン

- ユーザー向け文言は全て `Strings.swift`(アプリ)と `_shared/messages.ts`(プッシュ)に集約。**罰・恥系の文言は禁止**(REQUIREMENTS §3.5。「あと◯日で枯れる」「サボり」等のワードを使わない)
- 色・余白・フォントは DesignSystem の定数のみ。View 内に直書きしない

## 4. プッシュ → ウィジェット更新パイプライン(M0 の検証対象)

```
A: チェックインtap → POST /functions/v1/checkin
  └ DB更新 → ストリーク再計算 → B視点のsnapshot組み立て
     → APNs可視プッシュ(mutable-content: 1, snapshotをペイロード同梱)
B端末: LienNSE 起動(通知表示の前に実行される)
  └ payloadのsnapshotをApp Groupへ書く → 写真サムネDL(あれば)
     → WidgetCenter.reloadAllTimelines() → 通知を表示
```

ペイロード仕様:

```json
{
  "aps": { "alert": {"title": "<相手名>", "body": "<messages.tsから>"},
           "sound": "default", "mutable-content": 1 },
  "lien": { "type": "partner_checkin | nudge | reaction | streak_risk | milestone | ticket_used | pair_update | streak_reset",
            "snapshot": { ...受信者視点のPairSnapshot... } }
}
```

- `streak_reset` は close-day(§5.4 手順4)が「責めない文言」とともに送出する(2026-06-11 実装同期。`_shared/apns.ts` の `LienPushType` にも追記すること)

- 通知を出さない更新(チェックイン取消など)は `content-available: 1` のサイレントプッシュ。ただし**サイレントは配送保証がない(OSスロットル)ため、フォールバック扱い**
- 自己修復: アプリ本体はフォアグラウンド復帰時に必ず `GET /snapshot` で最新を取得し App Group を上書きする

### 4.1 APNs の環境はトークン単位(2026-10-12 決定・issue #53)

APNs は sandbox(`api.sandbox.push.apple.com`)と production(`api.push.apple.com`)でエンドポイントが別で、環境が違うトークンは `400 BadDeviceToken` になる。サーバー全体の `APNS_ENV` 1値で切り替えると、開発ビルド(Xcode 直インストール = sandbox)と TestFlight・App Store(= production)が混在した瞬間に片方へ届かない。そこでトークンごとに環境を持つ。

- **保存**: `users.push_env`(`sandbox` | `production` | null。migration 0005)。クライアントは `push_token` と**同時に** `PATCH /rest/v1/users?id=eq.<uid>` で更新する(列 GRANT は本人の行の `push_token` / `push_env`。値は端末が自分の環境から決める。iOS 側の自動保存は issue #55 W1)
- **送信先の選択**: 送信時にトークンごとに `users.push_env` を引き、その環境のエンドポイントへ送る。**null(未設定・古い行)は `APNS_ENV` にフォールバック**する(`APNS_ENV` は Supabase secrets のまま。5変数のうち1つでも欠ければ push 無効 — §7)
- **無効トークンの掃除**: APNs が `410`(Unregistered / ExpiredToken)または `400 BadDeviceToken` を返したら、そのトークンを持つ `users.push_token` を null にする(`push_env` は診断用に残す)。次回の起動でクライアントが再登録する。`DeviceTokenNotForTopic`・`403`(JWT)・`429`・5xx はトークンのせいと言い切れないので消さない(設定ミスで全員のトークンを消さないため)。条件は「いまの `push_token` がそのトークンと一致」なので、送信と同時に再登録された新しいトークンは消えない
- **失敗の扱いは従来どおり**(§5.5): 5xx・ネットワーク断はリトライ1回、失敗しても本処理は成功扱い。環境の取得や掃除の失敗も本処理を止めない(ログに残して `APNS_ENV` で送る)
- **実装**: `_shared/apns.ts`(`ApnsClient.send` の `environment` 指定・失敗結果の `invalidToken`・`TokenAwarePusher`)と `_shared/pusher.ts`(Supabase 版の `PushTokenStore`・`createPusher`)。Function の `index.ts` は `createPusher(adminClient, "<関数名>")` を使う(新しい push 送信 Function もこれを使うこと)。テストは `apns_test.ts` / `pusher_test.ts`

## 5. バックエンド設計(Supabase)

### 5.1 マイグレーション

- `supabase/migrations/NNNN_<name>.sql` 連番。スキーマの正は REQUIREMENTS §5
- 補足決定: `invites.token` は8文字英数(紛らわしい文字 0/O/1/l を除外)、有効期限72h、1回限り

### 5.2 RLS 方針

- 既定 deny。helper `is_pair_member(pair_id uuid) returns boolean`(security definer)を用意
- **クライアントからの書き込みは原則すべて Edge Function 経由**(service role)。RLS は読み取り保護+防波堤
  - users: 自分の行のみ select / update
  - pairs, plants, streak_days, ticket_ledger: メンバーのみ select。書き込みは Function のみ
  - checkins, nudges, reactions: メンバーのみ select。書き込みは Function のみ
  - 写真(Storage): パスは **`pairs/<pair_id>/<date_local>/<user_id>/photo.jpg`**(サムネは同じ区画の `photo_thumb.jpg`)。**本人単位**(2026-10-12 決定・issue #52。旧 `pairs/<pair_id>/<date_local>/photo.jpg` はペア×日付単位で、同じ日に2人目が付けると上書きできた)
    - 読み取り(select): 現役ペアのメンバーのみ。署名付きURLで配布。`pairs/<pair_id>/` 配下なら新旧どちらの形式でも読める(既存の旧パスの写真は読めるまま)
    - 書き込み(insert / update): 現役ペアのメンバーで、かつ**パスの `<user_id>` 区画が `auth.uid()` と一致**するときだけ(migration 0004 の `is_valid_own_photo_upload`)。他人の区画・旧形式のパスへは書けない。delete はクライアントに許さない
    - checkin Function は署名付きアップロードURLを**本人の区画にだけ**発行し、`photoPath` も本人の原寸写真パス(`.../<user_id>/photo.jpg`)でなければ 400 `invalid_photo_path`。§5.6 の経路・手順は変わらない(§5.6 に書かれたパス `pairs/<pair_id>/<date>/photo.jpg` は本項の規約に読み替える)

### 5.3 Edge Functions 一覧(すべて deno / TypeScript)

| name | 種別 | 入力 | 主処理 |
|---|---|---|---|
| checkin | POST | dateLocal, photoPath? | upsert → 両者状態判定 → 相手へ可視push(snapshot同梱) → 自分用snapshot返却 |
| checkin-cancel | POST | dateLocal | 当日のみ削除 → 相手へサイレント更新 |
| invite-create | POST | — | token発行(8桁, 72h, 1回限り) |
| invite-accept | POST | token | ペア作成(双方が未ペアであること検査) → 両者へpush |
| promise-set | POST | title, emoji, remindAt? | 自分の現役の約束を upsert(編集は同一 promise_id への UPDATE = checkins の FK 継続でストリーク非影響 — REQUIREMENTS §3.3)→ ペアなら相手へサイレント更新(2026-06-11 実装同期・T12。§5.2「書き込みは Function 経由」のギャップを充足) |
| nudge | POST | stamp | 1日3回制限 → 相手へpush(文言は messages.ts からサーバーが選ぶ) |
| react | POST | checkinId, stamp | リアクション保存 → 相手へpush |
| plant-name | POST | name, mode(`first` \| `rename`) | 植物の名前を付ける・変える(2026-10-12 追加・issue #54。下の補足)→ 自分用 snapshot 返却 + 変わったときだけ相手へサイレント更新(`pair_update`・snapshot 同梱) |
| snapshot | GET | — | 自分視点の PairSnapshot(起動時の自己修復用)。成長回数は streak_days から数え、昨日の仮判定を含む(§5.4) |
| close-day | cron 00:10 JST | — | 前日確定(§5.4)。チケット消費・リセットの通知送信。both の確定では plants.grown_days を both の行数で数え直す(stage は書かない) |
| grant-tickets | cron 毎月1日 00:05 JST | — | free: balance=min(2, balance+2) / premium: balance=min(10, balance+5) |
| _shared/ | — | — | streak.ts / tickets.ts(純粋ロジック)、apns.ts(JWT発行・送信)、snapshot.ts、messages.ts |

- **純粋ロジックは I/O から分離**して `_shared/` に置き、`deno test` 可能にする。これが Windows レーンで回せる唯一の自動テストなので、ストリーク・チケットの全エッジケースをここで担保する
- apns.ts は送信クライアントを注入可能にし、テストではモック
- **plant-name の仕様(2026-10-12・issue #54 / docs/GROWTH.md §5.3・§8.1)**
  - 入力: `POST { name, mode }`。`mode` は `first`(最初に付ける)か `rename`(あとから変える)。それ以外は 400 `invalid_mode`
  - `name`: 前後の空白を除き、NFC に正規化したうえで **1〜8字**(Unicode コードポイントで数える。ニックネームと同じ字数、promise-set と同じ数え方)。改行・タブなどの制御文字、行/段落区切り、対になっていないサロゲート、見える文字が1つも無い名前(空白・ゼロ幅文字だけ)は 400 `invalid_name`。入力検査は DB を引く前に行う
  - `first`: plants.name が null のときだけ書く(**先に付けた人の名前に決まる**)。すでに名前があれば **409 `already_named`** と今の名前 `{ "error": "already_named", "name": "<今の名前>" }` を返し、何も書かない・相手へ送らない。誰が付けたかは返さない(再インストールで「自分が付けたか」の記録が消えても誤表示にならない)。同時に2人が送っても、書けるのは先に着いた1人だけ(`UPDATE ... WHERE name IS NULL` の更新行数で一意に決着し、負けた側は決まった名前で 409)
  - `rename`: 上書き。名前がまだ無くても書ける。**今の名前と同じなら何も書かず、相手へも送らない**(200)
  - 前提: 有効な(active の)ペアが必須(無ければ 409 `no_pair`)。書き込むのは呼び出し本人のペアの鉢だけ(pairId は入力に取らず、JWT の userId から引く)。鉢の行が無い(データ不整合)ときは 404 `plant_not_found`。そのほか 404 `user_not_found`・400 `invalid_json`・401 `unauthorized`・405 `method_not_allowed`
  - 応答 200: `{ "name": "<保存された名前>", "snapshot": <呼び出し本人視点の PairSnapshot(plantName が入る)> }`
  - 相手への知らせ: 変わったときだけ、相手視点の snapshot を同梱した**サイレント push**(`type: pair_update`・`content-available`)。相手のアプリは、次に開いたとき `snapshot.plantName` の変化から「名前が『みどり』にかわったよ」を出す。相手名義の可視通知(「ゆうき: 『みどり』と名づけたよ」)は P1 で、messages.ts の文言を T16 と調整してから(GROWTH §5.3)。サイレントは配送保証がない(§4)。送信失敗でも 200
  - 契約フィクスチャ: `products/lien/contracts/plant-name.ok.json` / `plant-name.already-named.json`
- **ワンタップ返事の扱い(2026-06-11 決定・issue #15)**: つつかれた側の定型4種返事(REQUIREMENTS §3.7)は、T15 では記録APIを実装しない。`nudges.replied` 列は migration 0001 で先行確保済みだが未使用のまま残し、実際の記録(通知アクションカテゴリでの受信 → `replied` 更新)は T16(issue #16。通知UI全体の担当)で行う

### 5.4 ストリーク確定アルゴリズム(これが正本)

定義:
- 「日 d のふたり達成」= ペア両メンバーに `date_local = d` の checkin が存在すること
- `streak_days(pair_id, d, kind)` に行があれば「d は継続日」。kind は `both` | `ticket`

確定処理(close-day が毎日 00:10 JST に前日 d を処理):
1. `pairs.status = active` かつ `started_on <= d` のペアを列挙
2. 両者 checkin あり → `streak_days(d, 'both')` を upsert し、`plants.grown_days` を **both の行数で数え直して**書く(「+1」ではない。stage は書かない — 下の「成長回数」)
3. 欠けあり(1人でも) → `ticket_balance > 0` なら balance−1、`streak_days(d, 'ticket')` upsert、ledger に `consume` 記録、両者へ `ticket_used` push
4. チケットなし → 行を作らない(=途切れ)。`streak_reset` イベント記録。push は「責めない文言」(messages.ts の reset 系)
   - **既知の未決事項(2026-06-11 注記)**: `streak_reset` イベントの記録は現状 close-day 実装では構造化 console ログのみで、永続化先は未定(events テーブル新設 or ticket_ledger 拡張)。issue #47 でユーザー判断待ち

現在値の導出:
- `current = streak_days を d 降順に走査し、昨日(close-day確定済みの最新日)から連続する行数`
- **プレビュー**: アプリ/ウィジェット表示は `current +(今日両者完了なら 1)`。確定はあくまで close-day
- `best` は確定時に更新してキャッシュ(pairs か plants に持たず、専用の集計列を streak_days から再計算可能に保つ)

例:
- 6/1〜6/3 両者達成、6/4 片方未達(チケット1枚あり)、6/5 両者達成 → current = 5(6/4 は kind=ticket)
- 同上で 6/4 チケットなし → 6/5 時点 current = 1
- ペア成立 6/10(started_on=6/10)→ 6/9 以前は判定対象外。ソロ期間のチェックインはストリークに影響しない(本人の記録としては残る)

エッジケース:
- 相手完了通知の後に相手が取消 → 確定は close-day 時点の状態で行う(リアルタイム表示が一時的にズレるのは許容)
- close-day の再実行は安全(upsert・PK 衝突で冪等)
- 「2人とも未達」の日もチケット1枚で守る(枚数は1日1枚。罰なし原則を優先し、人数では数えない)

成長回数(植物。2026-10-12 追加・issue #54 / docs/GROWTH.md §3.2・§7.2):
- **成長回数 = streak_days の `kind='both'` の行数(昨日まで)+ 昨日の仮判定(下記)+ 今日の先取り(今日両者完了なら +1)**。純粋関数 `countBothDays` / `derivePlantProgress`(`_shared/snapshot.ts`)。`kind='ticket'` の日(お休みチケットで守った日)は数えない: ストリークは守られるが、植物は育たない。回数は減らない(ストリークが途切れても縮まない。例外: 当日のチェックイン取消で、先取りしていた1回分は戻る)
- 今日(以降)の行は数えない(今日の分は「先取り」で別に足すので二重にならない)。同じ日付の行は1日と数える
- **`plants.grown_days` / `plants.stage` は snapshot では読まない**。表示用の段階は、10段階の閾値配列 `PLANT_STAGE_THRESHOLDS = [0,1,3,7,14,21,30,45,66,100]`(添字 = 段階)から snapshot が計算する。close-day が plants に書くのは `grown_days`(both の行数で数え直した控え。分析用と v1.1 用)だけで、**`stage` は書かない**: 旧実装は段階 6 以上を書くと `plants.stage` の CHECK(0〜5)に違反し、行(streak_days)は書けたのに成長だけ失敗して、再実行も `already_finalized` で飛ばされるため成長が永久に欠けた。これで **v1.0 に migration は要らない**(CHECK を外すのは v1.1 の plants 改修と一緒に行う)
- 閾値の調整ルール(GROWTH §3.6): 閾値は**下げる方向にだけ**動かす(上げると到達済みのペアの植物が戻って見える)・段階は**末尾にだけ**足す・変更は2週間に1回まで。`snapshot_test.ts` のラチェットテスト(凍結基準 `[0,1,3,7,14,21,30,45,66,100]`)が機械的に守る。みのり(100回)はあとから延ばせない(延ばしたいときは段階を後ろに足す)
- 既知の上限: `listStreakDays` は PostgREST の既定の上限 1000 行(≒ 2.7 年分)で切られる。v1.0 では問題ないが、v1.x のうちに件数を数える問い合わせ(count)に置き換える(ストリークの最高記録の計算にも同じ上限がある)

昨日の仮判定(0時台の誤表示対策。2026-10-12 追加・GROWTH §7.3 の最小版):
- 0:00 から close-day(00:10 JST)が昨日の行を書くまでの間は、昨日の `streak_days` 行がまだ無い。そのまま数えると、ストリークが 0 に見え、昨日の分で上がった段階が1つ戻り、昨日を「未達成」と数えて `sad`(すやすや)が誤って出る
- 次の3つがそろえば、昨日を **both とみなす**: ① 昨日の行がない ② 昨日がペア成立日(`started_on`)以降 ③ 2人とも昨日チェックインしている。この扱いは**ストリーク・すやすやの判定・成長回数のすべて**に使う(`loadSnapshotForUser` が昨日の行を足してから `buildPairSnapshot` に渡す)
- 確定結果と必ず一致する: 両者がチェックインしていれば close-day は必ず both を記録し、チェックインの取消は当日しかできないので、昨日のチェックインはもう動かない。昨日の行があれば(確定済み)二重に足さず、昨日の checkin も問い合わせない。問い合わせるのは昨日の行が無いときだけで、自分と相手の2回
- checkin・checkin-cancel・invite-accept・nudge・promise-set・react・snapshot の各 `index.ts` は変更なし(変更は `_shared/snapshot.ts` だけ。ただし全関数のデプロイのやり直しは要る — §3.4 の互換性)
- 残る誤表示: 「片方だけチェックインして、お休みチケットで守られる日」は 0:00〜0:10 の間だけストリークが 0 に見える(close-day が送る `ticket_used` 通知の snapshot で直る)。完全版(T19 に相乗り。P1)は、`decideCloseDay` を close-day と同じ入力で呼んで昨日を仮判定する(ふたり達成以外の仮判定は 0:00〜1:00 JST に限る)

### 5.5 冪等性・整合性

- checkin: `UNIQUE(user_id, date_local)`。重複リクエストは 200(idempotent)
- push: DB コミット後に送信。送信失敗はリトライ1回まで、失敗しても処理は成功扱い(自己修復経路があるため)
- レート制限(nudge 3回/日)は Function 内で当日カウント

### 5.6 写真アップロード経路(2026-06-11 決定・issue #48)

- **checkin Function が Supabase Storage の署名付きアップロードURL(createSignedUploadUrl)を発行**し、クライアントが直接アップロード → checkin 行に photo_path を記録する
- 理由: Edge Function でのバイナリプロキシはメモリ/実行時間を浪費する。署名URLならバケット非公開・RLS を維持したままクライアント直送できる
- サムネ(NSE 用 200KB 上限)は**クライアント側で縮小してからアップロード**(サーバー画像処理を持たない=シンプル最優先)。原寸用とサムネ用の2オブジェクトを `pairs/<pair_id>/<date>/photo.jpg` / `photo_thumb.jpg` に置く
- 必要な storage ポリシー追記は migration 0002 で行う(T14 実装時)

### 5.7 仕様ギャップの決定事項(2026-06-11 ユーザー回答・issue #47)

1. **お休み宣言(declare)の返金なし**: 宣言した日に結果的に両者達成だった場合もチケットは返金しない(kind=both で確定するのみ。シンプル優先)
2. **streak_reset は永続化しない**: console ログのみで確定(現状実装どおり)。将来は §7 相当の計測イベント基盤に統合する
3. **ペア解消後の photo_path 行は現状維持**: 行自体は SELECT 可能だが、署名付きURLを発行しないため画像実体は見えない(これを仕様とする)

## 6. 招待フロー(v1.0)

1. A が invite-create → アプリは2形式を得る: `lien://invite/<token>` と `https://<GH_PAGES>/lien/i/?t=<token>`
2. 共有シートで LINE 等へ送る。受け手は静的ページ経由: アプリあり→「アプリで開く」ボタン(カスタムスキーム起動) / なし→TestFlight・App Store 誘導+コード表示
3. アプリ内「コードを入力」(8桁手入力)でも成立する
- web/invite は JS 数十行の静的ページ。GitHub Pages でホスト(リポジトリ公開設定は G0 で人間が判断)

## 7. シークレットと環境変数(誰が・何を・どこに)

| 名前 | 置き場所 | 設定者 | 用途 |
|---|---|---|---|
| SUPABASE_URL / SUPABASE_ANON_KEY | `ios/Config/Secrets.xcconfig`(gitignore。`Secrets.example.xcconfig` をコミット) | 人間(G0) | アプリ→Supabase |
| SERVICE_ROLE_KEY | Supabase Functions 環境変数(ダッシュボード) | 人間(G0) | Function→DB |
| APNS_AUTH_KEY(.p8) / APNS_KEY_ID / APPLE_TEAM_ID / APNS_ENV | Supabase secrets | 人間(G0) | push 送信 |
| REVENUECAT_API_KEY(v1.1) | 同上+xcconfig | 人間(G6) | 課金 |

- エージェントは `.env` を読めない(settings.json で deny 済み)。**シークレットが必要な検証は人間ゲート([H])に回す**設計を崩さない
- コードにキーをハードコードしたらその時点でタスク失敗(AGENTS.md 禁止事項)

## 8. ビルド・テスト・検証(レーン別)

| 対象 | 検証コマンド | 動く場所 |
|---|---|---|
| functions 純粋ロジック | `deno test` | **Windowsループ可**(主力) |
| functions 統合 | `supabase functions serve` + curl | Mac(Docker)または G0 後のリモート dev |
| iOS ビルド | GitHub Actions(macos): `xcodegen generate` → `xcodebuild build CODE_SIGNING_ALLOWED=NO` | push 時自動。ループは `gh run` で結果確認 |
| iOS 単体テスト | LienTests(日付処理・スナップショット解釈・キュー) | CI / Mac |
| 実機 E2E | TASKPLAN のチェックリスト | 人間+Mac(G1, M1末, G3) |

- CI 予算: GitHub Free 2,000分/月、macOS は10倍消費 → iOS ビルド job は `products/lien/ios/**` 変更時のみ起動、8分以内に収める。deno test job は ubuntu(等倍)で全 push
- ループ(Windows)の完了条件は原則「deno test 緑」または「CI 緑」のどちらかで書く

## 9. エージェント向けコーディング規約

1. 新しい外部依存はタスク本文に明記がない限り追加しない
2. タイムゾーン既定は `Asia/Tokyo`。日付計算は必ず `date_local`(各ユーザーTZ)を使い、UTC日付と混同しない
3. ユーザー向け文言は Strings.swift / messages.ts のみ。**罰・恥系の表現禁止**
4. Swift ファイルは300行目安で分割。1画面1ディレクトリ(View + ViewModel)
5. 完了条件にない既存コードのリファクタをしない(LOOP.md のスコープ規律)
6. 磨く優先順位: S ウィジェット > ホーム画面 > その他(生活の98%は前者2つ)
7. snapshot スキーマ(§3.4)とプッシュペイロード(§4)を変えるタスクは、互換性影響を JOURNAL に明記する

## 10. 既知の制約・落とし穴

- サイレントプッシュは配送保証なし → 可視プッシュ+NSE が主経路である理由。逆に「通知を出さない状態変化」はウィジェット反映が遅れてよい仕様と割り切る
- NSE は実行30秒・メモリ約24MB → サムネ200KB上限、失敗時フォールバック必須
- WidgetKit の reload には日次予算がある → reload は NSE・アプリ起動時のみに限定
- APNs は sandbox / production でエンドポイントが別(`APNS_ENV` で切替)。TestFlight は production 側
- 匿名認証→Apple連携は Supabase の anonymous sign-in + linkIdentity を使う(再インストール時、未連携ユーザーは救済不可 — オンボで明示)
- App Store の表示名「Lien」単独は重複の可能性 → 「Lien − ふたりの約束」等で回避(G4 で確定)
