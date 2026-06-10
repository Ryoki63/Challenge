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
  "plantMood": "normal | happy | fidget | sad",
  "plantName": "みどり",
  "hasPartnerPhotoToday": false
}
```

- 書き込むのは**アプリ本体と NSE の2者だけ**。ウィジェットは読み取り専用
- snapshot は**受信者視点**でサーバーが組み立てる(me/partner の向きをクライアントで反転しない)
- 相手の今日の写真サムネは `photo_thumb.jpg` として同コンテナに保存(NSE がダウンロード、200KB上限)。失敗時は植物表示にフォールバック

### 3.5 ウィジェット実装方針

- TimelineProvider のエントリは2点: `now`(現在状態)と `翌日0:00`(日付跨ぎで両者「未完」表示に戻す)。`policy: .atEnd`
- reload のトリガーは NSE とアプリ本体のみ(WidgetKit の reload 予算を浪費しない)
- ドット絵は `Image(...).resizable().interpolation(.none)` で整数倍拡大(にじみ禁止)
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
  - 写真(Storage): パスを `pairs/<pair_id>/...` とし、メンバーのみ読める署名付きURLで配布

### 5.3 Edge Functions 一覧(すべて deno / TypeScript)

| name | 種別 | 入力 | 主処理 |
|---|---|---|---|
| checkin | POST | dateLocal, photoPath? | upsert → 両者状態判定 → 相手へ可視push(snapshot同梱) → 自分用snapshot返却 |
| checkin-cancel | POST | dateLocal | 当日のみ削除 → 相手へサイレント更新 |
| invite-create | POST | — | token発行(8桁, 72h, 1回限り) |
| invite-accept | POST | token | ペア作成(双方が未ペアであること検査) → 両者へpush |
| nudge | POST | stamp | 1日3回制限 → 相手へpush(文言は messages.ts からサーバーが選ぶ) |
| react | POST | checkinId, stamp | リアクション保存 → 相手へpush |
| snapshot | GET | — | 自分視点の PairSnapshot(起動時の自己修復用) |
| close-day | cron 00:10 JST | — | 前日確定(§5.4)。チケット消費・リセットの通知送信 |
| grant-tickets | cron 毎月1日 00:05 JST | — | free: balance=min(2, balance+2) / premium: balance=min(10, balance+5) |
| _shared/ | — | — | streak.ts / tickets.ts(純粋ロジック)、apns.ts(JWT発行・送信)、snapshot.ts、messages.ts |

- **純粋ロジックは I/O から分離**して `_shared/` に置き、`deno test` 可能にする。これが Windows レーンで回せる唯一の自動テストなので、ストリーク・チケットの全エッジケースをここで担保する
- apns.ts は送信クライアントを注入可能にし、テストではモック

### 5.4 ストリーク確定アルゴリズム(これが正本)

定義:
- 「日 d のふたり達成」= ペア両メンバーに `date_local = d` の checkin が存在すること
- `streak_days(pair_id, d, kind)` に行があれば「d は継続日」。kind は `both` | `ticket`

確定処理(close-day が毎日 00:10 JST に前日 d を処理):
1. `pairs.status = active` かつ `started_on <= d` のペアを列挙
2. 両者 checkin あり → `streak_days(d, 'both')` を upsert
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
