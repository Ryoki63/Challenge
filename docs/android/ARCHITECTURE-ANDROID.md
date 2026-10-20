# Lien Android — 技術選定・構成・実装契約

作成: 2026-10-21 JST / eng-lead / Issue #121。**設計 + 空アプリの提出であり、Android 製品の完成・本番接続・配布承認ではない。**

## 1. 決定と境界

- 推奨: **Kotlin + Jetpack Compose / Glance / FCM**。既存の Supabase Auth・Postgres・Storage・Edge Functions と `products/lien/contracts/` を共用する。Firebase Auth や Android 専用の業務 DB は作らない。
- 正本は `docs/REQUIREMENTS.md` → `docs/DESIGN.md` → `docs/CONCEPT.md`。Android の製品範囲は #120、表示は #122、QA は #123、Play 公開条件・日程は #119 / #127 に従う。本書の未実装構成は技術提案であり、これらの承認を代替しない。
- iOS の **2026-10-24 機能凍結 → 10-27 審査提出 → 10-31 公開**を優先する。役職カードの旧 12/11 は採用しない。Android の公開日は未確定。
- 今回変更するのは `products/lien/android/`、専用 CI、本書と実行記録・補助キューのみ。`ios/`、`supabase/`、`contracts/`、既存 CI、Web、課金設定を変更しない。
- 今回は空の Compose Activity だけ。Glance・FCM・Supabase SDK・App Links は後続実装。API 呼出し、権限要求、課金、分析 SDK、アカウント設定、ドメイン購入、署名鍵投入、ストア申請を実施しない。

## 2. 比較と概算工数

以下は**計画用の概算（実績ではない）**。1 人日 = 8 時間。熟練実装者1名、既存 API を再利用し、#120 の承認後に匿名開始・約束・チェックイン・招待・植物・ウィジェット・通知・設定/削除・写真を移植する前提。実機確認と1回の独立レビュー・修正を含む。テスター確保・14日待機・審査・人間の登録/認証待ち・新規課金機能は含まない。AI 実行時間や暦日への換算はしない。

| 候補 | Android 単体の概算 | iOS への影響 | 判定と理由 |
| --- | --- | --- | --- |
| Kotlin + Compose | 17–25 人日 | SwiftUI の再ビルド・書換え不要 | **採用推奨**。主役のウィジェット、FCM、ライフサイクルを Android API で直接扱い、専用 CI に分離できる [S1][S3] |
| Flutter + Dart | 21–31 人日 | Android のみなら影響なし。将来 iOS を共用するなら別途移植 | 既存 SwiftUI はそのまま共有できない。ウィジェット・バックグラウンドはネイティブとの境界が残り、Dart と Kotlin の保守面が増える [S9] |
| KMP（共有ロジック + Android Compose / iOS SwiftUI） | 23–34 人日 | 実際に共有すると Xcode framework 組込みと iOS 再検証が必要 | 将来再検討。現時点は共有する Kotlin 業務ロジックがなく、サーバー契約の共有で十分。iOS を変えず Android のみで始めるなら今回のネイティブ案と実質同じ [S10] |

内訳（ネイティブ案）: 認証/契約 3–4、主画面 2–3、Glance 2–3、通知の DB/送信/受信 4–6、招待リンク 1–2、写真/設定 3–4、統合確認 2–3 = **17–25 人日**。本 #121 の設計・雛形 1–2 人日は別枠。各工数の重複加算はしない。見積り幅の主因は OEM の省電力制限、植物の描画適合、混在ペア通知、App Links のホスト/署名準備。

採用しないもの: iOS の KMP/Flutter 化、共有クライアントライブラリの先行開発、汎用マルチモジュール基盤、常駐 foreground service、到達秒数の保証。既存要件の「罰を使わない」「約束1つ」を維持する。

## 3. リポジトリと依存の方向

```text
products/lien/
  android/                 独立 Gradle project / :app（今回）
    app/src/main/          Compose Activity とリソース（今回）
    app/src/test/          JVM の局所テスト（今回）
    gradle/wrapper/        検証用 wrapper（今回）
    README.md              JDK/SDK・ビルド・制約（今回）
  contracts/*.json         実サーバーハンドラ由来の唯一の契約フィクスチャ（既存・変更しない）
  supabase/                共有 DB・API（既存・変更しない）
  ios/                     SwiftUI / WidgetKit / APNs（既存・変更しない）
```

後続も当初は `:app` の1モジュール。`ui/` → `domain/`（必要な use case/状態）→ `data/`（Auth/HTTP/保存）、`widget/` と `push/` は同じ Repository を使う。機能数だけ Gradle module を増やさない。UI は Coroutine/StateFlow + ViewModel、依存注入はコンストラクタから始める。ライブラリは使用する Issue で固定し、Supabase Kotlin SDK + Kotlin serialization/HTTP の互換を検証する。SDK 自体はコミュニティ保守である点も保守リスクに含める [S11]。

`minSdk = 26` は今回の雛形の技術基準で、製品の対応 OS 承認ではない。#123 の端末マトリクス / #120 と突合して実装前に再確認する。`compileSdk`・`targetSdk`・JDK・AGP・Kotlin・Compose の正確な固定値と検証は `android/README.md` / Gradle 定義を正とする。ストア提出時の target 条件を満たす保証とは分ける。

## 4. 認証: 匿名開始 → 将来の任意連携

1. 保存済みセッションを読み、復旧中に新規匿名ユーザーを作らない。初回のみ Supabase `signInAnonymously`。匿名でも `authenticated` ロールの JWT が発行されるため、既存の `auth.uid()` に基づく RLS を共用できる [S5]。
2. `public.users` の作成は既存 Auth trigger に任せる。プロフィール列だけ本人 JWT で更新し、pair/checkin/課金列は直接書かない。Firebase Authentication は使わない。
3. refresh token は Keystore で保護する専用永続化境界を設け、バックアップ/ログ/クラッシュ情報へ含めない。暗号鍵を失った保存を復元済みと誤認しない。Auth の初期化・refresh・サインアウトは single-flight / 世代番号で調停する。
4. 401 と一時的な Auth 障害（503 `auth_unavailable`）を分離。ネットワーク不調で匿名再作成・データ消去をしない。匿名の端末消去・アンインストール・未連携の機種変更では復元できない旨を既存要件どおり表示する。
5. **v1.0 は匿名のみ**（REQUIREMENTS §3.1）。匿名→連携は将来の設計として OAuth の `linkIdentity` 系で同一 UUID を維持する [S6]。手動連携の有効化は人間の設定が前提。email/phone を選ぶ場合は `updateUser` と検証の別経路 [S5]。Google を無断で v1.0 に追加しない。Apple/Google/email の採用と OAuth 設定・リダイレクトは #120 の決定後の別タスク。既存別ユーザーへ連携衝突したら勝手にペアや履歴をマージしない。匿名端末同士の iOS→Android 移行は本設計だけでは提供できない。

## 5. 共有 API / 契約 / 保存

確認した実装: `ios/Lien/Core/SupabaseService.swift`、`supabase/functions/_shared/{snapshot,user_rows,pusher}.ts`、`supabase/migrations/0001_init.sql` と `0005_push_env.sql`。本書の以下の既存挙動はこれらと `contracts/README.md` を根拠とする。

| 用途 | 再利用する入口 | Android の境界 |
| --- | --- | --- |
| 起動・前面復帰・補完 | `GET snapshot` | `snapshot` envelope を decode。ETag / 304 と `X-Lien-Snapshot-Confirmed-At` を扱う |
| 約束・名前 | `POST promise-set` / `plant-name` | 長さ/emoji/error を既存契約に合わせる |
| 達成・取消 | `POST checkin` / `checkin-cancel` | `dateLocal` はユーザー TZ。再送は既存の冪等意味を守る |
| ペア・通知の行動 | `POST invite-create` / `invite-accept` / `nudge` / `react` | 8文字コード・期限・409/410 等はサーバー判定 |
| 設定・離脱 | 本人プロフィール PATCH / `POST pair-dissolve` / `delete-account` | 確認と成功応答後のローカル消去。削除失敗を完了表示しない |
| 写真 | `checkin` の署名付き upload / Storage の署名 URL | パス・Content-Type・サイズ・失効・解消後の非表示を共用 |
| 日次確定・付与 | `close-day` / `grant-tickets` | サーバー専用。Android から起動しない |

- Edge API は `Authorization: Bearer <Supabase user JWT>`、gateway に必要な公開 publishable/anon key のみ。service role・APNs/FCM credentials はアプリへ入れない。今回は公開キーも未投入。
- Kotlin DTO は JSON の camelCase を保持。未知キーは許容するが、必須キー欠損・型違い・未対応 `schemaVersion` はデコード失敗として扱う。`pairId` / `ticketBalance` / `plantNextStageAt` の null を 0 や空文字に変えない。`dateLocal` は `updatedAt` の日付と一致するとは限らない（0時台）。`pairPlan` はサーバー導出、未確定な課金表示を独断で有効化しない。
- `app` の test resources は `../contracts` を参照し、JSON の複製を作らない。既存の全フィクスチャを用途ごとに decode し、snapshot の未知キー許容、null、型不正、errors の HTTP status を検査する。APNs の `aps` は iOS 専用で、共通 JSON の全キーを FCM と取り違えない。
- ローカル `SnapshotStore` はアカウント UUID + 世代 + schemaVersion + 確認時刻を持ち、アプリ/worker/widget が1つの調停経路で更新。逆順・重複・304後の古い push を採用しない。ログアウト/削除後の古い worker が書き戻せないようにする。未初期化ストアは push だけで初期化しない。アプリが認証済み GET を成功させて初期化する。
- オフラインは最終状態と未同期表示。業務成功を捏造しない。自動リトライは read/冪等操作だけに限定し、招待・ナッジ等を盲目的に再送しない。再起動/前面復帰で snapshot を補完する。

## 6. ウィジェット: Glance

Glance は Compose runtime ベースでも通常の Compose UI をそのまま再利用するものではなく、AppWidget/RemoteViews の制約を持つ [S1]。WidgetKit の Swift ビューを移植せず、共通の snapshot 解釈だけを再現する。

- `GlanceAppWidget` / receiver が `SnapshotStore` を読み、#122 の小サイズ案から約束・二人の状態・植物を描画。View 内でネットワークを呼ばない。未同期/期限切れ/未ペアの表示を明示する。
- app の同期成功、checkin/取消成功、worker の確定保存後に `updateAll`。Glance のメモリ状態に永続化を任せず、読み直し可能にする [S2]。
- タップは該当画面へ遷移する安全な明示 Intent から始める。ウィジェットで直接達成するかは #120 の承認が先。写真/署名 URL/JWT は RemoteViews・Intent extras に置かない。
- 同期補完は WorkManager。定期実行は OS に遅延されうるため、秒単位の表示鮮度を保証しない [S4]。Doze、force-stop、通知拒否、再起動、日付跨ぎ、複数配置、削除後、フォント拡大/暗色を #123 の対象にする。
- 植物は既存アセットのライセンス/レイヤーを確認し、Glance が表示できる bitmap 等へ描画する。全 SVG の Compose/Glance 直接表示を前提にしない。

## 7. 通知: FCM（サーバー追加点を分離）

### 7.1 現状と必要な変更

現状は `users.push_token` + `push_env`（sandbox/production）の **APNs 専用1トークン**。`createPusher` は APNs 設定がないと no-op、各 core は `user.pushToken` がある場合だけ送信する。**FCM token をこの列へ保存してはいけない**。`pusher.ts` に FCM を足すだけでも Android の受信者は送信条件に入らない。

後続の提案（今回は migration もサーバー実装も行わない）:

1. Android 専用の `android_push_registrations` を追加（`user_id` PK/FK → public.users ON DELETE CASCADE、`token` UNIQUE、更新時刻、可視通知許可状態）。当初はユーザー当たり最新1端末で既存 iOS 相当、多端末機能は追加しない。既存 APNs 列を改名・変換しない。
2. JWT 本人だけの `register-push` Edge API を設け、登録/更新/失効を transaction/RPC で処理。クライアントの users 任意列更新は増やさない。新テーブルを他ユーザーに公開せず、RLS + deny-by-default / service role 経由とする。token が別アカウントへ再登録される場合、以前の配送先を原子的に失効させる。解除は一致する user/token のみ、ローテーション後の新 token を消さない。
3. 送信口を token 指定だけでなく**受信者 UUID ベース**にする。Android 登録を読み FCM adapter、既存 `push_token` には既存 APNs adapter を使う。対象は `checkin` / `checkin-cancel` / `close-day` / `invite-accept` / `nudge` / `plant-name` / `promise-set` / `react` / **`pair-dissolve` / `delete-account` の計10経路**。`pushToken` だけで早期 return する条件と close-day の送信対象抽出も含めてテストする。
4. 従来 APNs payload・sandbox/production 分岐・無効 token 清掃を維持する。FCM 無設定なら Android の配送不可を明示して iOS を継続。片側 provider が失敗してももう片側/業務 mutation を巻き添えにしない。iOS→Android / Android→iOS / Android→Android を検査する。
5. FCM HTTP v1 の `projects/*/messages:send` + 短期 OAuth2 access token をサーバー内だけで扱う [S7]。プロジェクト作成・権限設定・service account credential 投入は人間の作業。値もファイルも公開 repo、APK、PR、ログに置かない。認可前は mock transport のみ。
6. FCM `UNREGISTERED` は user/token の条件一致で失効、429/5xx は限定 backoff。汎用 `INVALID_ARGUMENT` だけで token を削除しない（payload 不正かもしれない）。APNs の清掃とは独立にする。

### 7.2 payload / Android 受信

- APNs の `aps.alert` を FCM に丸ごと渡さない。既存通知イベントの type と、受信者視点の snapshot を transport 非依存の内部 envelope に変換する。FCM data は文字列値であり、全体4KB内に収める。サイズ超過時は snapshot を省いた invalidation とし、認証済み GET で補完する [S8]。
- 静かな状態更新は data-only / normal priority。可視通知は data-only の受信から NotificationChannel に自前で1回表示し、実際に可視通知を出す場合だけ high priority を検討 [S3]。OS の background 自動表示とアプリ表示を重ねない。通知の日本語文言・送り主表示は既存意味を守り、#122 に合わせる。
- `FirebaseMessagingService.onMessageReceived` の短い処理で envelope を検査し、必要な通信/画像は WorkManager へ。FCM token の更新とログイン成立を両方監視し、未認証時は端末内だけに保留する。onNewToken だけに登録を依存しない。
- Android 13+ の `POST_NOTIFICATIONS` と channel を扱う。拒否時もアプリ同期は動き、可視通知を前提にした high priority にしない。サインアウト/削除はローカル配送世代と通知を無効化し、サーバー登録解除は認証が生きている間に行う。
- 重複/逆順/force-stop/Doze/通知拒否では配信・即時更新を保証できない [S3][S4]。push は正本ではなく補助。表示前も account/世代/TTL を検査し、完全な相手写真・認証情報を payload に入れない。機密状態は GET を正とする。
- リマインド時刻は既存の個人設定に従う。FCM の相手イベントと端末のローカルリマインダーを分離し、exact alarm の権限や新しい通知を独断で追加しない。

## 8. 招待・ディープリンク: App Links

既存 `invite-create` の `lien://invite/<token>` と HTTPS `.../lien/i/?t=<token>`、8文字コードを維持する。既存 iOS の Universal Links 化は本件で行わない。Android もまず厳密な入力検査とコード手入力を実装し、招待受信は参加の自動実行にせず確認画面へ渡す。

App Links の完成条件 [S12]:

1. 所有・管理できる HTTPS host に `/.well-known/assetlinks.json` を HTTP 200、リダイレクトなしで配置し、Android の確定 package と署名証明書 SHA-256 を登録。
2. manifest の `VIEW` / `DEFAULT` / `BROWSABLE` / `android:autoVerify="true"` を**確定 host/path に限定**。OAuth callback は招待と別 filter にする。任意 host や token を信用しない。
3. query `t` の重複、不正長、文字集合違反、余計な path、非対応 scheme を拒否。token は小文字化しない。未ログインの一時保留はアカウント世代で消去し、サーバーの有効期限/一回限り判定を優先。
4. Play App Signing 利用時は upload/debug 鍵ではなく**配信署名**の fingerprint を使う [S13]。debug と配布ビルドの検証を混同しない。
5. `adb shell pm verify-app-links --re-verify <package>` → `pm get-app-links` と cold/warm start を確認。未インストールは Web のコード表示へフォールバックし、deferred deep link が自動復元されるとは言わない。

既定の GitHub Pages は `https://ryoki63.github.io/Challenge` という**project path**である。`/Challenge/.well-known/assetlinks.json` では host ルートの関連付けを満たさない。ルート host の管理権限、確定 Android package、配信 fingerprint は現在未確定（値は `null`）。新ドメイン購入や別 repo 変更はせず、T-AND-8 と #119 の人間ゲートへ渡す。host の承認前は偽の autoVerify 成功や公開完了を記録しない。

## 9. CI・レビュー・ロールバック

- 新規 `lien-android` は Android paths と自分の workflow の変更だけで起動。Linux、JDK17、固定 Gradle wrapper / distribution SHA。iOS の Xcode/macOS 枠、署名 secrets、release/deploy workflow は使わない。異なる concurrency group、最小 read 権限、時間上限、公式 action の SHA 固定を守る。
- 今回の必須は `assembleDebug testDebugUnitTest lintDebug`。デバッグ署名は build tool の一時生成のみでコミットしない。配布鍵、Google services 設定、Supabase/FCM credentials なしで成立する。release AAB/配布署名の緑は本タスクの対象外で、verified と表現しない。
- ビルドと JVM テストは端末での表示確認ではない。空画面の emulator 起動/Compose 表示は CI smoke として切り分け、製品の Auth/通知/widget/E2E は後続の完了条件にする。結果・テスト件数・run/SHA・未検証項目は README/JOURNAL と PR に残す。
- この PR は独立レビュー1回、指摘修正は該当箇所だけ確認。マージは eng-review/HQ に渡す。共有サーバーに触る T-AND-5/6 は `difficulty:high` とし、iOS 凍結/審査/公開を脅かすので HQ の critical_review と Deno + 既存 iOS CI の緑が揃うまでマージ/適用しない。
- **今回の rollback**: PR を閉じれば未導入。マージ後は Android 追加 commit の revert で戻せる。DB migration = なし、データ移行 = 不要、iOS 配布 = なし。
- **将来の DB rollout**: 追加 table/API → provider mock 検証 → staging の混在 E2E → 人間の認可/設定 → 明示 enable の順。APNs 既存列/契約を残す。rollback は FCM routing を無効化して旧 APNs 経路を維持、Android は前面 GET 補完。データを drop せず追加 table を残す（token 削除/保持方針を記録）。本番 migration・deploy は別承認で、この Issue から行わない。

## 10. 後続実装 Issue 契約

正式な Issue 番号・URL は `tasks/BACKLOG.md` の Android セクション。今回の設計 Issue を実装 Issue の代わりに close しない。後続 Issue は依存がマージ済み/製品判断済みになるまで着手不可。表の人日は §2 の内訳と同じ（別加算しない）。

| ID / 担当 | 依存 | 許可範囲 / 完了条件 | 人日 |
| --- | --- | --- | --- |
| T-AND-1 / eng-exec | #121, #120 | android の Auth/保存のみ。匿名再利用、refresh 調停、Keystore 境界、401/503/ログアウトのテスト。任意連携は設計境界だけ | 1.5–2 |
| T-AND-2 / eng-exec | #121 | android DTO/HTTP/test のみ。全共有 fixture、ETag/304、unknown/null/error、不正型、snapshot世代のテスト。contracts 正本は変更しない | 1.5–2 |
| T-AND-3 / eng-exec | 1, 2, #120, #122 | android UI。約束1つ/ソロ/招待/チェックイン/植物の最小経路。mock UI と取消/通信失敗を確認 | 2–3 |
| T-AND-4 / eng-exec | 2, 3, #120, #122 | android widget。Glance 小サイズ、同一 store、日付/消去/再配置/遅延試験。製品承認なしに直接 checkin を足さない | 2–3 |
| T-AND-5 / eng-exec | #121, #120 | supabase の追加 table/登録API/test のみ。JWT本人、RLS、token競合/失効/CASCADE、既存APNs列不変。migration の本番適用は禁止 | 1–1.5 |
| T-AND-6 / eng-exec | 5 | supabase push adapter + 10経路/test のみ。UUID送信、APNs後方互換、FCM mock、provider失敗分離、混在配送。critical_review | 1.5–2.5 |
| T-AND-7 / eng-exec | 1, 2, 4, 5, 6, #122 | android FCM/worker/channel/登録のみ。permission、rotation、重複、Doze、消去後、payload上限/補完。credentialなしmockと認可後実機を区別 | 1.5–2 |
| T-AND-8 / eng-exec | 1, 3, #119 | android link parser + docs。旧招待互換、App Links手順/検査。host/package/配信fingerprint の人間ゲート解消後のみ関連付け。Web正本変更は別の範囲承認 | 1–2 |
| T-AND-9 / eng-exec | 1, 2, 3, #120, #122 | android 写真/履歴。既存Storage契約、取消/解消/削除、署名URL失効、サイズ/オフラインを検証 | 1.5–2 |
| T-AND-10 / eng-exec | 1, 2, 3, #120, #122 | android 設定。プロフィール、任意reminder、二段解消、削除、匿名注意。課金/新OAuth導入なし | 1.5–2 |
| T-AND-11 / eng-exec | 3–10, #123 | android の統合テスト/CI/docs。QA計画に沿うmock通しと認可済みstaging混在確認。iOS regressions/署名/人間ゲートの引渡し。公開しない | 2–3 |

並列化: 1 と 2、後に 4 と 9/10（write set を別 package に固定）。5/6 は共有サーバー担当1名で直列、iOS リリース作業と同時編集しない。7 は配送基盤の確認後、8 は host 準備と parser を分ける。11 で統合。既存 main へ直接 push しない。

遅延リスク: Android 自体の空アプリ/設計は iOS runtime に影響なし。ただし CI は同一アカウントの runner 枠を消費し得る。Android の優先度を下げ、iOS CI/審査対応を待たせるなら Android を延期する。サーバー変更のマージ・本番適用は iOS gate 安定を優先。Play 条件の充足・公開可能日・登録費/予算判断は #119/#126 に委譲し、本書では法的免除や公開日を断定しない。

## 11. 一次資料

参照日: 2026-10-21 JST。外部仕様は実装 Issue の着手時に再確認する。工数・技術選定・追加テーブル/送信口は本書の判断であり、公式資料の保証ではない。

- [S1] Android Developers — Jetpack Glance: https://developer.android.com/develop/ui/compose/glance
- [S2] Android Developers — Manage and update GlanceAppWidget: https://developer.android.com/develop/ui/compose/glance/glance-app-widget
- [S3] Firebase — Android message priority / receive: https://firebase.google.com/docs/cloud-messaging/android/message-priority / https://firebase.google.com/docs/cloud-messaging/android/receive-messages
- [S4] Android Developers — Background tasks: https://developer.android.com/develop/background-work/background-tasks
- [S5] Supabase — Anonymous Sign-Ins: https://supabase.com/docs/guides/auth/auth-anonymous
- [S6] Supabase — Kotlin link identity: https://supabase.com/docs/reference/kotlin/auth-linkidentity
- [S7] Firebase — HTTP v1 REST: https://firebase.google.com/docs/reference/fcm/rest
- [S8] Firebase — Message types: https://firebase.google.com/docs/cloud-messaging/customize-messages/set-message-type
- [S9] Flutter — Platform-specific code: https://docs.flutter.dev/platform-integration/platform-channels
- [S10] Kotlin — iOS integration: https://kotlinlang.org/docs/multiplatform/multiplatform-ios-integration-overview.html
- [S11] Supabase — Kotlin introduction / installing: https://supabase.com/docs/reference/kotlin/introduction / https://supabase.com/docs/reference/kotlin/installing
- [S12] Android Developers — App Links: https://developer.android.com/training/app-links/add-applinks
- [S13] Android Developers — Website associations: https://developer.android.com/training/app-links/configure-assetlinks
