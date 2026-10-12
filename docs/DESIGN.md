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
- データ層はプロトコル境界(`AuthServicing` / `InviteClient` / `PromiseAPIClient` / `SnapshotClient` / `CheckinAPIClient` など)で隔離し、ViewModel へ注入する(テストはモック)。View から Supabase を直接呼ばない。Edge Functions のクライアントは URLSession ベース(`Core/Api/`・`Core/Repositories/`。共通の下回りは `EdgeFunctionTransport`)で、JWT は `AuthServicing.accessToken()`(supabase-swift のセッション。期限切れは自動更新)から渡す。**supabase-swift を import するのは `SupabaseService.swift` だけ**(匿名サインイン・users の更新・accessToken)
- **状態の正はサーバー**。アプリが永続するのは「最後に取得した PairSnapshot」+「未送信キュー」のみ(ローカルDBは持たない。SwiftData不使用)。画面系統を決める「オンボ済み」のような独自の永続フラグも持たない
- ルートは `AppPhase` enum の **4状態**で画面系統を切り替える。値は純粋関数 `AppRouter.phase(hasSession:snapshot:)` が、「セッションの有無」と「App Group の最後の snapshot」だけから導く(2026-10-13・issue #61。W1 #55 の実装に合わせて改訂した。旧記述は `onboarding` / `solo` / `paired` の3状態で、約束設定の独立画面と下の構成図が無かった)

| AppPhase | 条件 | 出す画面 |
|---|---|---|
| `onboarding` | セッションが無い | オンボ3画面(コンセプト → ニックネーム/アイコン → 通知)。ニックネームの送信で匿名サインインする |
| `promiseSetup` | セッションがあり、現役の約束が無い(`myPromiseTitle` が null か空白だけ。snapshot が未取得もここ) | 約束設定(**Home の前の独立画面**。REQUIREMENTS §3.3)。snapshot が未取得の間は、初回同期の結果が来るまで読み込み表示にする(`isResolving`。再インストールで、サーバーに既にある約束・ペアを取りこぼして約束設定を見せないため) |
| `solo` | 約束があり、`pairId` が null | ホーム(ソロ): 土の鉢+チェックイン+招待ボタン。写真・つつく・リアクション・ストリークはペア後 |
| `paired` | 約束があり、`pairId` がある | ホーム(ペア) |

- `solo` と `paired` はどちらもホームを出す(`AppPhase.isHome`)。ペア成立による `solo` → `paired` も、ペア解消による `paired` → `solo` も、同じ導出で扱う(分岐を増やさない)
- 約束はユーザーに属する(REQUIREMENTS §3.3)ので、ペアがあっても自分の約束が無ければ先に `promiseSetup` になる

構成図(`products/lien/ios/Lien/`。主要なファイルだけ):

```
ios/Lien/
├── App/
│   ├── LienApp.swift              # エントリ。AppServices と AppModel を1回だけ作ってつなぐ
│   ├── AppServices.swift          # 依存の束(Live / Stub)。Config が無いときの Stub 構成もここ
│   ├── AppServices+Live.swift     # make(): Config があれば Live、無ければ Stub を返すファクトリ+Live の組み立て
│   ├── AppPhase.swift             # onboarding / promiseSetup / solo / paired
│   ├── AppRouter.swift            # phase の導出(純粋関数)
│   ├── AppModel.swift             # ルート状態の保持+サーバー同期の司令塔(@Observable)
│   ├── RootView.swift             # phase で画面系統を切替+招待シート+onOpenURL
│   ├── AppDelegate.swift          # APNs トークン・リモート通知の受け口(→ PushTokenSync / AppModel)
│   └── DeepLinkHandler.swift      # lien://invite/<token> のパース(純粋関数。§3.6)
├── Core/
│   ├── Config.swift               # xcconfig→Info.plist 経由でURL/キー読込
│   ├── AuthServicing.swift        # 認証の抽象+スタブ(accessToken() もここ)
│   ├── SupabaseService.swift      # 本実装(匿名サインイン・users 更新・push 登録)。supabase-swift を import する唯一のファイル
│   ├── SnapshotSynchronizer.swift # GET /snapshot の結果を App Group へ反映(自己修復 — §4)
│   ├── PushTokenSync.swift        # APNs トークンと push_env を users へ自動保存(§4.1)
│   ├── PushManager.swift          # 通知許可・APNs 登録
│   ├── AppGroupStore.swift        # pair_snapshot.json / pending_ops.json の読み書き
│   ├── CheckinService.swift / PendingOps.swift / PhotoProcessor.swift   # チェックイン+未送信キュー+写真縮小
│   ├── NudgeReactService.swift / LiveNudgeReactService.swift            # つつく・リアクション
│   ├── Api/                       # Edge Functions(と PostgREST)の Live クライアント。EdgeFunctionTransport が共通の下回り
│   ├── Repositories/              # InviteClient とその Live 実装
│   ├── Models/                    # PairSnapshot, Promise, Invite
│   ├── DesignSystem/              # Colors.swift, Spacing.swift, 植物の描画(§3.5)
│   └── Strings.swift              # ユーザー向け文言を全て集約
└── Features/                      # 1画面1ディレクトリ(View + ViewModel)
    ├── Onboarding/  ├── PromiseSetup/  ├── Pairing/(招待シート)
    ├── Home/        ├── Checkin/       ├── Nudge/
    └── Debug/(DEBUG ビルドのみ)     ※ History/(T18)・Settings/(T23)は未実装、Album/ は v1.1
```

主要部品の役割(W1・issue #55):

- `AppServices`: アプリ全体の依存の束(`auth` / `inviteClient` / `promiseClient` / `snapshotClient` / `checkinService` / `nudgeService` / `reactionService` / `pendingOps` / `store` / `pushTokenSync` / `reloadWidgets` など)。`AppServices.make()` が **Config(Supabase URL・anon key)があれば Live、無ければ Stub** を返す。Stub はネットワークを一切使わず、オンボ → 約束 → ソロのチェックイン → ペア成立の画面遷移までが動く(CI・Secrets なしのビルド用)。View / ViewModel はどちらの構成かを意識しない。既知: 今は Release ビルドでも Config が欠けると Stub に落ちる(T28準備 #28 で、Release では致命扱いにする予定)
- `AppRouter`: 上の表の導出。入力は「セッションの有無」と「最後の snapshot」だけの純粋関数で、起動時・同期の後・約束の保存後・ペア成立後のたびに再導出する
- `AppModel`(`@MainActor @Observable`): `phase` を保持し、サーバー同期を起動する司令塔。招待ディープリンクの token も保持する(§3.6)。同期の起点:
  1. 起動(`start()`)
  2. 前面復帰(`sceneDidBecomeActive()`。起動直後の二重取得を避けるため、直前の同期から数秒以内は省く)
  3. リモート通知の受信(`remoteNotificationReceived()`。AppDelegate → `RemoteNotificationRelay`。可視 push・サイレント push・通知のタップ。**サイレント push の更新(取消・約束変更・ペア更新)はこの同期が主経路** — §4。サイレントで起こすには `UIBackgroundModes: remote-notification` が要る)
  4. 招待シートが開いている間の定期同期(招待した側が、相手の受諾=ペア成立を push なしでも画面上で知る。成立するとシートは自動で閉じる)
  5. 画面側の変更の直後(`onboardingFinished` / `promiseSaved` / `pairingSucceeded`。App Group の snapshot を読み直して phase を導き直し、そのうえでサーバーとも突き合わせる)

  同期は同時に1本だけ走り、走行中に来た要求は、終わった直後に1回だけ取り直す
- `SnapshotSynchronizer`: GET /snapshot の結果で `pair_snapshot.json` を上書きし、**見た目が変わるときだけ**ウィジェットを reload する(`updatedAt` だけの差では reload しない — §3.5・§10 の reload 予算)。**端末の方が新しい可能性があるときは上書きしない**: ① 未送信キューが残っている(オフラインで記録したチェックインがサーバーへ届く前に上書きすると、画面が一瞬戻る。キューが空になった次回の同期で反映する)② 取得中に端末の snapshot が変わった(ホームのチェックイン完了や NSE の書き込みの方が新しい。取得結果は捨てて1回だけ取り直す)。取得に失敗したときは端末の snapshot を残す(オフラインでも表示は壊れない)
- `PushTokenSync`(actor): `users.push_token` / `push_env` の自動保存(§4.1)。**トークンの取得とセッションの確立の両方がそろうまで保留**する(どちらが先でもよい)。最後に送信成功した (userID, token, env) を覚えて**変化時だけ**送り、ユーザーが変わった(再インストールで匿名ユーザーが作り直された)ときは同じトークンでも再送する。失敗は保留にして、次のトリガー(前面復帰・トークンの更新・セッションの確立)で再送する。この「最後に送信成功した登録」は、画面の状態ではなく送信の重複防止の記録なので、上の「のみ」の例外として端末ローカルの UserDefaults に置く(App Group には置かない — NSE・ウィジェットは読まない。再インストールで消えるのは正しい挙動で、新しい匿名ユーザー・新しいトークンとして再送される)
- 読み取りは RLS の範囲で PostgREST を直接使ってよい(現状: react の対象にする相手の当日の `checkins` 行 — `PartnerCheckinResolving`。PV #59 が `photo_path` と署名付き URL に広げる)。書き込みは、本人の users 行(プロフィール・push 登録 — §4.1)を除いて Edge Functions 経由(§5.2)

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

- カスタムスキーム `lien://invite/<token>`(v1.0。token は8文字英数 — §5.1)。Info.plist の `CFBundleURLTypes`(project.yml)で登録する。パースは `DeepLinkHandler.inviteToken(from:)`(純粋関数)で、静的招待ページの URL(`https://<GH_PAGES>/lien/i/?t=<token>`)の形式も解釈できる(ユニバーサルリンク化に備えた救済。v1.0 ではこの URL は OS からアプリへ飛んでこず、貼り付けを拾う呼び出し元も無い。ページの「アプリで開く」ボタンが `lien://invite/<token>` を開く — §6)
- **自動受諾はしない**(2026-10-13 決定・issue #61。W1 #55 の実装に合わせた。旧記述は「`onOpenURL` → invite-accept 呼び出し → 失敗時はコード手入力画面へ誘導」)。流れ: `onOpenURL` → `AppModel.handleDeepLink` が token を保持 → **ソロのホームで招待シート(`PairingView`)を開き、コード入力欄にプリフィルする** → 利用者が「ペアになる」を**明示的にタップ**して初めて invite-accept を呼ぶ
  - 理由1: T23(ペア解消)が入るまで、成立したペアを取り消せない。リンクを開いただけ・誤って開いただけでペアが成立すると戻せない
  - 理由2: 受諾は同意の表明にあたる。招待してくれた人の名前は invite-accept の応答で初めて分かる(リンクの中には無い)ので、受諾の前に確認の一歩を置く
  - T23 のあとに自動受諾へ戻すかは、実機 E2E の結果で判断する(戻すなら本節と `PairingView` を同時に直す)
- 受け口の状態別の振る舞い(`AppModel.applyPendingInvite`):

| phase | 振る舞い |
|---|---|
| `onboarding` / `promiseSetup` | token を保持するだけでシートは出さない。約束設定を終えてソロのホームに着いた時点で、招待シートが自動で開く |
| `solo` | すぐ招待シートを開き、プリフィルする |
| `paired` | 無視する(保持中のコードも捨てる。1ユーザー1ペア — REQUIREMENTS §1) |

  招待リンクでない URL・8文字英数でない token は、どの phase でも無視する
- 招待の発行・コードの手入力・リンク経由の受諾は、すべてこの1つのシート(`PairingView`)で行う。入口はソロのホームの招待ボタンで、ペア成立後は出ない
- 受諾に失敗したとき(期限切れ・使用済み・存在しない・どちらかが別のペア済みなど): invite-accept のエラーを `Strings.Pairing` の責めない文言でシート内に出し、コード入力欄はそのまま残す(直して再試行できる)。コードの手入力は最初から同じシートにあるので、別画面へ誘導する必要がなくなった
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
- **送信先の選択**: 受信者の `users.push_env` の環境のエンドポイントへ送る。各 Function が送り先の users 行を `push_token` と**一緒に読み**(`_shared/user_rows.ts`)、送信オプションの `environment` に渡す(送信のたびに `push_token` から users を逆引きしない — §5.3 の pusher.ts)。**null(未設定・古い行)は `environment` を付けず `APNS_ENV` にフォールバック**する(`APNS_ENV` は Supabase secrets のまま。5変数のうち1つでも欠ければ push 無効 — §7)
- **無効トークンの掃除**: APNs が `410`(Unregistered / ExpiredToken)または `400 BadDeviceToken` を返したら、そのトークンを持つ `users.push_token` を null にする(`push_env` は診断用に残す)。次回の起動でクライアントが再登録する。`DeviceTokenNotForTopic`・`403`(JWT)・`429`・5xx はトークンのせいと言い切れないので消さない(設定ミスで全員のトークンを消さないため)。条件は「いまの `push_token` がそのトークンと一致」なので、送信と同時に再登録された新しいトークンは消えない
- **失敗の扱いは従来どおり**(§5.5): 5xx・ネットワーク断はリトライ1回、失敗しても本処理は成功扱い。無効トークンの掃除の失敗も本処理を止めない(ログに残す)
- **実装**: `_shared/apns.ts`(`ApnsClient.send` の `environment` 指定・失敗結果の `invalidToken`・`TokenAwarePusher`)と `_shared/pusher.ts`(Supabase 版の `PushTokenStore`=無効トークンの掃除だけ・`createPusher`)・`_shared/user_rows.ts`(users 行の読み出し)。Function の `index.ts` は `createPusher(adminClient, "<関数名>")` を使い、users の読み出しは `USER_COLUMNS` / `PARTNER_SELECT` / `toSnapshotUser` を使う(新しい push 送信 Function もこれを使うこと)。テストは `apns_test.ts` / `pusher_test.ts` / `user_rows_test.ts`(+ `scripts/ops/push_env_static_test.ts`)

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
| invite-create | POST | — | token発行(8文字の英数字・大文字小文字を区別, 72h, 1回限り) |
| invite-accept | POST | token | ペア作成(双方が未ペアであること検査) → 両者へpush |
| promise-set | POST | title, emoji, remindAt? | 自分の現役の約束を upsert(編集は同一 promise_id への UPDATE = checkins の FK 継続でストリーク非影響 — REQUIREMENTS §3.3)→ ペアなら相手へサイレント更新(2026-06-11 実装同期・T12。§5.2「書き込みは Function 経由」のギャップを充足) |
| nudge | POST | stamp | 1日3回制限 → 相手へpush(文言は messages.ts からサーバーが選ぶ) |
| react | POST | checkinId, stamp | リアクション保存(1チェックインにつき1人1つ。別のスタンプへの付け替えは上書き) → 相手へ push は**最初の1回だけ**(付け替え・同じスタンプの再送では送らない。2026-10-12・TASKPLAN §9.4 の仕様修正)。push に同梱する snapshot は相手視点で、「今日」は**相手のタイムゾーン**で決まる(送り手の日付は使わない)。応答 `{ changed }` は**保存内容が変わったか**(新規・付け替え = `true` / 同じスタンプの再送 = `false`)で、push を送ったかとは別 |
| plant-name | POST | name, mode(`first` \| `rename`) | 植物の名前を付ける・変える(2026-10-12 追加・issue #54。下の補足)→ 自分用 snapshot 返却 + 変わったときだけ相手へサイレント更新(`pair_update`・snapshot 同梱) |
| snapshot | GET | — | 自分視点の PairSnapshot(起動時の自己修復用)。成長回数は streak_days から数え、昨日の仮判定を含む(§5.4) |
| close-day | cron 00:10 JST | `dateLocal?`, `notify?` | 前日確定(§5.4)。チケット消費・リセットの通知送信。both の確定では plants.grown_days を both の行数で数え直す(stage は書かない)。cron は本文 `{}`。手動の再実行は `{dateLocal, notify:false}`(リセットの日は行が残らず、再実行で通知を再送するため。下の補足)。今日・未来の日は 400 `date_not_closable`。認証は cron 専用シークレット |
| grant-tickets | cron 毎月1日 00:05 JST | `dateLocal?` | free: balance=min(2, balance+2) / premium: balance=min(10, balance+5)。**ペア×月の実行記録 `ticket_grant_runs`(migration 0006)で冪等**(上限到達で 0 付与でも記録する)。未来の月は 400 `future_month`。認証は cron 専用シークレット |
| _shared/ | — | — | streak.ts / tickets.ts(純粋ロジック)、apns.ts(JWT発行・送信・`TokenAwarePusher`・`sendOptionsFor`)、pusher.ts(`createPusher`・無効トークンの掃除)、user_rows.ts(users 行の読み出し)、cron_http.ts(cron 専用 Function の認証・本文)、snapshot.ts、messages.ts |

- **純粋ロジックは I/O から分離**して `_shared/` に置き、`deno test` 可能にする。これが Windows レーンで回せる唯一の自動テストなので、ストリーク・チケットの全エッジケースをここで担保する
- apns.ts は送信クライアントを注入可能にし、テストではモック
- **pusher.ts と push_env(2026-10-13・issue #60)**: push を送る 8 関数(checkin / checkin-cancel / close-day / invite-accept / nudge / plant-name / promise-set / react)は、`index.ts` で `createPusher(adminClient, "<関数名>")` を作る。APNs の 5 変数(§7)が揃っていなければ push をスキップする no-op、揃っていれば `TokenAwarePusher`。**送信先の環境は呼び出し側が渡す**: 受信者の users 行を `getUser` / `getActivePair` で読むとき `push_token` と `push_env` を一緒に読み(`USER_COLUMNS` / `PARTNER_SELECT` → `toSnapshotUser` で `SnapshotUserRow.pushEnv`)、`core.ts` が `pusher.send(token, payload, sendOptionsFor(受信者, 〈サイレントなら SILENT_PUSH_OPTS〉))` で `environment` を渡す。以前は送信のたびに `push_token` で users を逆引きして `push_env` を取っていたが、`push_token` には索引が無く users の全件走査になるためやめた。`push_env` が null のユーザーは `environment` を付けず `APNS_ENV` で送る。`TokenAwarePusher` が DB に触るのは、APNs が `410` / `400 BadDeviceToken` を返したトークンの `users.push_token` を null にする掃除だけ(`PushTokenStore.clearPushToken`)
- **cron 専用 Function の認証と要求(close-day / grant-tickets。2026-10-13・issue #60)**
  - 認証は `Authorization: Bearer <LIEN_CRON_SECRET>` の**完全一致**(定数時間比較)だけ。`LIEN_CRON_SECRET` は乱数 32 バイト(16 進 64 文字)で、Function secrets と Vault の `lien_cron_secret` に同じ値を置く(§7・`scripts/OPS.md` §6)。**service role key(万能鍵)もユーザー JWT も受け付けない**。未設定・32 文字未満のときは全リクエストを 401 にし、起動ログに理由を出す。cron の秘密は JWT ではないので `verify_jwt = false`(`config.toml`)
  - 実装は `_shared/cron_http.ts` の `handleCronRequest`(405 → 401 → 400 → 本体 → 500 の順。認証前に本文は読まない)。本文は「空」か「JSON オブジェクト」だけで、壊れた JSON は 400 `invalid_json`(空として扱わない)、知らないキーは 400 `unknown_field`、型違いは 400 `invalid_date_local` / `invalid_notify`。`index.ts` は `createClient` と `handleCronRequest` に本体を渡すだけの薄い層
  - **close-day の `notify`**: 省略 = `true`(cron の素朴な POST は従来どおり通知する)。`false` なら ticket_used とリセットの push を一切送らない。リセットの日は `streak_days` に行が残らないため、再実行するとその日のリセット通知を再送してしまう(§5.4「close-day の再実行は安全」はデータについての話で、通知は別)。手動の再実行(`scripts/ops/run-cron-fn.sh`)は常に `notify:false`。応答に `notify` を含める。確定できるのは JST の昨日まで(今日・未来は 400 `date_not_closable`)
  - **grant-tickets の実行記録**: `ticket_grant_runs(pair_id, month_start)` が冪等キー。RPC `apply_monthly_ticket_grant`(service_role 専用)が実行記録・残高・ledger を1トランザクションで書く。応答の `alreadyGranted` は「今月は処理済み」(付与済み + 上限到達で記録だけ残したもの)、`unchanged` は今回 0 付与で記録だけ書いたペア数。同月の ledger の monthly 行(0006 より前の付与のほか、invite-accept の初期付与 = `reason='monthly'`・`date_local = started_on`。実行記録は作らない)も処理済みと見る — ペアを作った月は初期付与がその月の付与なので、月初の直前にできたペアなどに上乗せしない(この判定は消さない。`scripts/ops/cron_static_test.ts` が検査する)。月の途中の再実行は二重付与にならない
  - 定期実行の登録(pg_cron + pg_net)は migration 0003 → 0007。スケジュールの JST 換算・「JST の1日だけ」の条件・呼び先・鍵は `scripts/ops/cron_static_test.ts`、毎朝 00:40 JST の監視(GitHub Actions `lien-cron-watch`)は `scripts/ops/cron_check.ts`(読み取りだけ。直近の予定の回 = close-day の JST 00:10・grant-tickets の JST 00:05 に **起動したか**、月初は付与の `1 row` と応答、ジョブの定義が migration のとおりか、鍵の整合など)。運用は `scripts/OPS.md`
- **plant-name の仕様(2026-10-12・issue #54 / docs/GROWTH.md §5.3・§8.1)**
  - 入力: `POST { name, mode }`。`mode` は `first`(最初に付ける)か `rename`(あとから変える)。それ以外は 400 `invalid_mode`
  - `name`: 前後の空白を除き、NFC に正規化したうえで **1〜8字**(Unicode コードポイントで数える。ニックネームと同じ字数、promise-set と同じ数え方)。改行・タブなどの制御文字、行/段落区切り、対になっていないサロゲート、**書式文字**(双方向制御 U+202A〜202E・U+2066〜2069、ゼロ幅スペース U+200B、語結合子 U+2060、BOM U+FEFF、ソフトハイフン U+00AD など。相手の画面で表示を崩したり別の名前に見せかけたりできるため。**絵文字をつなぐ ZWJ U+200D だけ許す**。絵文字表示の VS16 U+FE0F は書式文字でなく結合記号なので通る)、見える文字が1つも無い名前(空白・ゼロ幅文字だけ)は 400 `invalid_name`。入力検査は DB を引く前に行う
  - `first`: plants.name が null のときだけ書く(**先に付けた人の名前に決まる**)。すでに名前があれば **409 `already_named`** と今の名前 `{ "error": "already_named", "name": "<今の名前>" }` を返し、何も書かない・相手へ送らない。誰が付けたかは返さない(再インストールで「自分が付けたか」の記録が消えても誤表示にならない)。同時に2人が送っても、書けるのは先に着いた1人だけ(`UPDATE ... WHERE name IS NULL` の更新行数で一意に決着し、負けた側は決まった名前で 409)
  - **クライアントの注意(#57)**: 名前を付けた本人が `first` を再送する(通信失敗のあとの再試行など)と、すでに自分の名前が入っているので 409 `already_named` が返り、`name` は今の名前になる。サーバーは誰が付けたかを返さないので、クライアントは **409 の `name` が自分が送った名前と同じなら成功として扱う**(違えば相手が先に付けた=その名前を採用)。字数の事前検査は NFC に正規化したあと Swift の `unicodeScalars.count` で数える(`count` は書記素クラスタ数で、サーバーの数え方と食い違う)
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
- **成長回数 = streak_days の `kind='both'` の行数(昨日まで)+ 昨日の仮判定(下記。close-day の確定前の 0:00〜1:00 だけ)+ 今日の先取り(今日両者完了なら +1)**。純粋関数 `countBothDays` / `derivePlantProgress`(`_shared/snapshot.ts`)。`kind='ticket'` の日(お休みチケットで守った日)は数えない: ストリークは守られるが、植物は育たない。回数は減らない(ストリークが途切れても縮まない。例外: 当日のチェックイン取消で、先取りしていた1回分は戻る)
- 今日(以降)の行は数えない(今日の分は「先取り」で別に足すので二重にならない)。同じ日付の行は1日と数える
- **`plants.grown_days` / `plants.stage` は snapshot では読まない**。表示用の段階は、10段階の閾値配列 `PLANT_STAGE_THRESHOLDS = [0,1,3,7,14,21,30,45,66,100]`(添字 = 段階)から snapshot が計算する。close-day が plants に書くのは `grown_days`(both の行数で数え直した控え。分析用と v1.1 用)だけで、**`stage` は書かない**: 旧実装は段階 6 以上を書くと `plants.stage` の CHECK(0〜5)に違反し、行(streak_days)は書けたのに成長だけ失敗して、再実行も `already_finalized` で飛ばされるため成長が永久に欠けた。これで **v1.0 に migration は要らない**(CHECK を外すのは v1.1 の plants 改修と一緒に行う)
- 閾値の調整ルール(GROWTH §3.6): 閾値は**下げる方向にだけ**動かす(上げると到達済みのペアの植物が戻って見える)・段階は**末尾にだけ**足す・変更は2週間に1回まで。`snapshot_test.ts` のラチェットテスト(凍結基準 `[0,1,3,7,14,21,30,45,66,100]`)が機械的に守る。みのり(100回)はあとから延ばせない(延ばしたいときは段階を後ろに足す)
- 既知の上限: `listStreakDays` は PostgREST の既定の上限 1000 行(≒ 2.7 年分)で切られる。v1.0 では問題ないが、v1.x のうちに件数を数える問い合わせ(count)に置き換える(ストリークの最高記録の計算にも同じ上限がある)

昨日の仮判定(0時台の誤表示対策。2026-10-12 追加・GROWTH §7.3 の最小版。同日のレビューで「close-day が確定する前の時間帯だけ」に絞った):
- 0:00 から close-day(00:10 JST)が昨日の行を書くまでの間は、昨日の `streak_days` 行がまだ無い。そのまま数えると、ストリークが 0 に見え、昨日の分で上がった段階が1つ戻り、昨日を「未達成」と数えて `sad`(すやすや)が誤って出る
- 次の4つがそろえば、昨日を **both とみなす**: ① いまが close-day の確定前の時間帯(**実効の今日の 1:00・ユーザーTZ より前**。定数 `CLOSE_DAY_SETTLE_HOUR = 1`) ② 昨日の行がない ③ 昨日がペア成立日(`started_on`)以降 ④ 2人とも昨日チェックインしている。この扱いは**ストリーク・すやすやの判定・成長回数のすべて**に使う(`loadSnapshotForUser` が昨日の行を足してから `buildPairSnapshot` に渡す)。実効の今日は、`todayLocalOverride`(checkin のリクエスト日付)があればそれ(下の「override」)、なければ now のユーザーTZの日付
- **① が肝心(レビュー指摘)**: 昨日の行が「無い」ことは、確定前と、確定して**リセットされた**後(リセットの日は行を作らない)のどちらでも起きる。しかも昨日付けの checkin は close-day の後からでも足せる(checkin は `dateLocal` ±1日を許し、iOS の PendingOps は日付をまたいで前日分を再送する)。窓の外でも仮判定すると、リセット済みの昨日をその日いっぱい「ふたり達成」と見せ、翌日に取り消すことになる(回数が減る・段階が戻る)。REQUIREMENTS §3.9・GROWTH §3.2「回数は減らない・後退しない(例外は当日の取消だけ)」に反する。実ハンドラでの再現: 6/1〜6/6 の 6 回・チケット 0 枚で、6/7 に A だけチェックイン → 6/8 00:10 に close-day がリセット → 6/8 08:00 に B のキュー済みの 6/7 付けが 200 で届く。窓が無いと 6/8 の GET /snapshot はストリーク 7・回数 7・段階 3(わかば)、6/9 は 0・6・2 に戻っていた。窓があれば 6/8 も 6/9 も 0・6・2 で変わらない(`close-day/late_checkin_test.ts`)
- 一致するのは窓の中だけ: 窓の中(確定前)なら、両者がチェックインしていれば close-day は必ず both を記録し、チェックインの取消は当日しかできないので、昨日のチェックインはもう動かない=確定結果と一致する。**窓の外は一致を保証できないので仮判定しない=行だけを信じる**。昨日の行があれば(確定済み)二重に足さず、昨日の checkin も問い合わせない。問い合わせるのは窓の中で昨日の行が無いときだけで、自分と相手の2回
- **override**: `checkin` などが渡す `todayLocalOverride`(リクエストの `dateLocal`。深夜0時前後のクライアント/サーバーの時計ずれ・送信キューの再送の許容)は、その日が確定前(翌日の 1:00 より前)のときだけ使う。確定を過ぎた日の override(close-day の後にキューから届いた昨日付けの checkin)は捨てて本当の今日を使う(`resolveTodayLocal`)。使うと、確定済みの昨日を「今日」として扱い、先取りの +1(段階アップを含む)を応答と相手への push に一瞬見せて、次の GET /snapshot で戻る(iOS の段階アップ演出が見かけの昇格で発火しうる)
- 残る誤差: ⓐ 「片方だけチェックインして、お休みチケットで守られる日」は 0:00〜0:10 の間だけストリークが 0 に見える(close-day が送る `ticket_used` 通知の snapshot で直る)。ⓑ 窓の端: close-day が動いた 0:10 以降〜 1:00 の間にキュー経由で昨日付けの checkin が届くと、1:00 までは「ふたり達成」と見え、1:00 に消える(極めてまれ)。完全に消すには `checkins.created_at`(その日の 24:00 より前に作られたものだけを数える)が要り、全関数の `getCheckin` が返す変更になる。ⓒ close-day が窓の外まで動かなかった夜(無料枠の自動停止など)は、行が書かれる(OPS §4 の再実行)まで確定前の分を数えない=書かれていない日を勝手に増やさない側に倒す。完全版(T19 に相乗り。P1)は `decideCloseDay` を close-day と同じ入力で呼んで昨日を仮判定する(窓は同じ 0:00〜1:00 JST)
- 仮判定そのもののための `index.ts` の変更は無い(変更は `_shared/snapshot.ts` だけ)。ただし全関数のデプロイのやり直しは要る — §3.4 の互換性

### 5.5 冪等性・整合性

- checkin: `UNIQUE(user_id, date_local)`。重複リクエストは 200(idempotent)
- push: DB コミット後に送信。送信失敗はリトライ1回まで、失敗しても処理は成功扱い(自己修復経路があるため)
- レート制限(nudge 3回/日)は Function 内で当日カウント

### 5.6 写真アップロード経路(2026-06-11 決定・issue #48)

- **checkin Function が Supabase Storage の署名付きアップロードURL(createSignedUploadUrl)を発行**し、クライアントが直接アップロード → checkin 行に photo_path を記録する
- 理由: Edge Function でのバイナリプロキシはメモリ/実行時間を浪費する。署名URLならバケット非公開・RLS を維持したままクライアント直送できる
- サムネ(NSE 用 200KB 上限)は**クライアント側で縮小してからアップロード**(サーバー画像処理を持たない=シンプル最優先)。原寸用とサムネ用の2オブジェクトを `pairs/<pair_id>/<date_local>/<user_id>/photo.jpg` / `photo_thumb.jpg` に置く(**本人単位**の区画。旧 `pairs/<pair_id>/<date>/photo.jpg` はペア×日付単位で、同じ日に2人目が付けると上書きできたため 2026-10-12 に変更 — §5.2・migration 0004・issue #52)
- storage ポリシー: migration 0002(現役ペアのメンバーのみ読み書き)→ migration 0004(書き込みは**パスの `<user_id>` 区画が `auth.uid()` と一致するときだけ**。`is_valid_own_photo_upload`)。checkin Function は署名付きアップロードURLを**本人の区画にだけ**発行し、`photoPath` が本人の原寸写真パスでなければ 400 `invalid_photo_path`。読み取りは `pairs/<pair_id>/` 配下なら新旧どちらの形式でも可(既存の旧パスの写真は読めるまま)

### 5.7 仕様ギャップの決定事項(2026-06-11 ユーザー回答・issue #47)

1. **お休み宣言(declare)の返金なし**: 宣言した日に結果的に両者達成だった場合もチケットは返金しない(kind=both で確定するのみ。シンプル優先)
2. **streak_reset は永続化しない**: console ログのみで確定(現状実装どおり)。将来は §7 相当の計測イベント基盤に統合する
3. **ペア解消後の photo_path 行は現状維持**: 行自体は SELECT 可能だが、署名付きURLを発行しないため画像実体は見えない(これを仕様とする)

## 6. 招待フロー(v1.0)

1. A が invite-create → アプリは2形式を得る: `lien://invite/<token>` と `https://<GH_PAGES>/lien/i/?t=<token>`
2. 共有シートで LINE 等へ送る。受け手は静的ページ経由: アプリあり→「アプリで開く」ボタン(カスタムスキーム起動) / なし→TestFlight・App Store 誘導+コード表示
3. 招待シートの「コードを入力」欄に、8文字の英数字コード(大文字小文字を区別。例 `AbCd2345`)を手入力しても成立する。シートの入口はソロのホームの招待ボタン(§3.6)
- web/invite は JS 数十行の静的ページ。GitHub Pages でホスト(リポジトリ公開設定は G0 で人間が判断)

## 7. シークレットと環境変数(誰が・何を・どこに)

| 名前 | 置き場所 | 設定者 | 用途 |
|---|---|---|---|
| SUPABASE_URL / SUPABASE_ANON_KEY | `ios/Config/Secrets.xcconfig`(gitignore。`Secrets.example.xcconfig` をコミット) | 人間(G0) | アプリ→Supabase |
| SUPABASE_SERVICE_ROLE_KEY | Supabase が Function に**自動注入**(自分では設定しない) | プラットフォーム | Function→DB。**このプロジェクトでは default の secret key(`sb_secret_...`)で、legacy の `service_role`(`eyJ...`)ではない**(2026-10-12 実測)。cron の認証には使わない |
| LIEN_CRON_SECRET | Function secrets と Vault の `lien_cron_secret`(**同じ値**) | エージェント(`scripts/OPS.md` §6。値は誰も画面で見ない) | pg_cron → close-day / grant-tickets の認証(cron 専用。DB には触れない)。SHA-256 の照合を監視が毎朝行う |
| APNS_AUTH_KEY(.p8) / APNS_KEY_ID / APPLE_TEAM_ID / APNS_ENV / APNS_TOPIC | Supabase secrets | 人間(G0) | push 送信。1つでも欠ければ push 無効。`APNS_ENV` は `users.push_env` が未設定のトークンのフォールバック(§4.1) |
| REVENUECAT_API_KEY(v1.1) | 同上+xcconfig | 人間(G6) | 課金 |

- Vault には `lien_cron_secret`(cron 用)だけを置く。**万能鍵(service role key)は Vault にも pg_net のキューにも載せない**(2026-10-13・issue #60。以前の `lien_service_role_key` は削除)
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
- APNs は sandbox / production でエンドポイントが別。環境は**トークン単位**(`users.push_env`。呼び出し側が受信者の users 行から読んで `environment` に渡す — §4.1・§5.3)で、`APNS_ENV` は `push_env` が未設定のトークンのフォールバックにすぎない。TestFlight は production 側(Xcode 直インストールは sandbox)。環境が違うトークンは `400 BadDeviceToken` になり、そのトークンは `push_token` を null にされる
- close-day の再実行はデータについては冪等だが、**リセットの日は行が残らないので通知を再送する** → 手動の再実行は `notify:false`(§5.3)。確定できるのは終わった日だけ。月をまたいで止まったときは「前月末日の前日まで close-day → grant-tickets → 残り」の順(`scripts/OPS.md` §4)
- pg_net(`net` スキーマ)の関数・表は `supabase_admin` 所有で `PUBLIC` に EXECUTE / SELECT が付いており、**postgres(migration を流すロール)からは `revoke` しても何も変わらない**(2026-10-13 実測)。守りは「公開 API から net に届かないこと」(PostgREST の公開スキーマは `public, graphql_public` だけ・pg_graphql は無効=有効にすると net の表が GraphQL に出る恐れ。監視が毎朝確認)と「万能鍵をキューに載せないこと」(`scripts/OPS.md` §9)
- pg_net の HTTP 応答(`net._http_response`)は 6 時間で消える。cron の結果の確認は、起動の 30 分後(00:40 JST)の自動監視が担う(リポジトリは公開なので、Actions のログには件数・ペア ID・応答の本文を出さない)。Supabase 無料枠の自動停止(D5)も監視が検知する
- 匿名認証→Apple連携は Supabase の anonymous sign-in + linkIdentity を使う(再インストール時、未連携ユーザーは救済不可 — オンボで明示)
- App Store の表示名「Lien」単独は重複の可能性 → 「Lien − ふたりの約束」等で回避(G4 で確定)
