# Lien Android v1.0 要件差分・推奨

- 作成日: 2026-10-21
- 正本: [REQUIREMENTS.md](../REQUIREMENTS.md)（WHAT）/ [DESIGN.md](../DESIGN.md)（現行実装・HOW）
- 目的: Android 版が iOS v1.0 の共有仕様と Android 固有の実装・公開条件を分けて検討できるようにする。これは Android の実装完了・公開承認を示す文書ではない。
- 判定: **同じ** = 製品挙動とデータ契約を維持 / **変える** = Android の仕組みに置換・適応 / **捨てる/後続** = v1.0 には入れない（既存の v1.0.1 / v1.1 / v2+ の扱いを維持）

## 推奨決定

| 論点 | Android v1.0 の推奨 | 根拠・境界 |
|---|---|---|
| 製品スコープ | iOS の **[v1.0]** 要件を共有し、既に明記された P1 は P0 完了後の候補とする。Android 専用の機能は追加しない。iOS の 10/31 公開を遅らせない | iOS v1.0 は全機能無料。P1 の優先順位は GROWTH.md §6.1 を維持する。実顧客による Android 需要の観察・試用・購入証拠は、このタスク資料から確認できないため、需要を確定事実としない（hypothesis） |
| ウィジェット | Android のホーム画面 S 相当は **Jetpack Glance** を推奨。iOS の表示内容と snapshot データを共有し、レイアウトとサイズ適応は Android 用に実装する | Glance は Compose ランタイム上の Android App Widget フレームワーク。WidgetKit と API・更新保証が同一という意味ではない。iOS ロック画面ウィジェットに相当する Android v1.0 対象は置かない。Google は定期更新をできるだけ少なくし、`updatePeriodMillis` を最大でも1時間程度にするよう案内している。可視プッシュからの更新と 60 秒 p50 は実機・ランチャー別に検証する目標であり、保証済みではない ([Android Glance](https://developer.android.com/develop/ui/compose/glance), [作成・更新属性](https://developer.android.com/develop/ui/compose/glance/create-app-widget)) |
| 通知 | サーバー発の Android 配送は **FCM** を推奨。端末内リマインド/21時通知は iOS と同じ製品目的を保ち、Android の通知権限・通知チャンネル・バックグラウンド制約に適応する | Android 13+ は `POST_NOTIFICATIONS` の実行時許可、Android 8+ は通知チャンネルが必要。FCM はバックグラウンドの通知メッセージをシステム通知欄へ出し、アプリコールバックは通常呼ばない。snapshot でウィジェットをすぐ更新する経路は別途設計・検証する。高優先度 FCM の用途、権限拒否時の挙動、Doze 中の実機結果は未確定 ([通知権限](https://developer.android.com/develop/ui/compose/notifications/notification-permission), [チャンネル](https://developer.android.com/develop/ui/compose/notifications/channels), [FCM 受信](https://firebase.google.com/docs/cloud-messaging/android/receive-messages), [優先度](https://firebase.google.com/docs/cloud-messaging/android-message-priority)) |
| 課金 | Android v1.0 は **課金なし・全機能無料**。v1.1 課金時は Google Play Billing を RevenueCat 経由で使い、iOS と **同一 RevenueCat project / entitlement** に集約する案を推奨 | RevenueCat は Google Play の subscription product を扱い、同じ project の entitlement と同じ安定した custom App User ID による platform 間の顧客識別をサポートする。Supabase の user UUID を各プラットフォームで同じ RevenueCat App User ID として使うことが条件。ストア商品 ID・購入/返金処理は各ストア別。iOS v1.1 の設定・Webhook・Play Console 側設定は別途実装/確認が必要で、Android v1.0 の範囲には含めない ([RevenueCat Android](https://www.revenuecat.com/docs/getting-started/installation/android), [entitlements](https://www.revenuecat.com/docs/getting-started/entitlements), [顧客 ID](https://www.revenuecat.com/docs/customers/identifying-customers)) |
| ペア混在 | iOS/Android 利用者のペアは **同じ Supabase project / Auth / Edge Functions / Postgres / Storage** を使う。招待コード/リンクで異なる端末・OSの別ユーザーを結ぶ | Supabase Auth の anonymous user も JWT を持つ `authenticated` 利用者として RLS が適用される。匿名ユーザーの ID を OS 間で共有するのではなく、各人が自分の Auth user として登録・招待受諾する ([匿名認証](https://supabase.com/docs/guides/auth/auth-anonymous), [RLS](https://supabase.com/docs/guides/database/postgres/row-level-security)) |
| Play 公開ゲート | Android 実装は iOS 作業と独立して進めるが、**一般公開日は Play Console のアカウント種別・作成日・closed-test 要件確認後に決める**。新規の対象個人アカウントでは 12 人以上の tester が14日連続で opt-in する要件がある。「募集しない」条件と両立しないため、組織アカウント等の扱いは #AND-PMO の判断に委ねる | Google 公式ヘルプは、2023-11-13 以降作成の個人アカウントに 12 人以上×14日連続の closed testing と production access 申請を要求する。Issue 内の「募集せず」はこの条件の代替にならない。対象アカウントの種別・作成日・組織アカウント可否は本作業では確認していない（null: アカウントアクセス対象外）([Google Play testing requirements](https://support.google.com/googleplay/android-developer/answer/14151465)) |

## REQUIREMENTS.md 節ごとの分類

| REQUIREMENTS 節 | Android v1.0 分類 | 適用内容・差分 |
|---|---|---|
| §0 確定事項 | **同じ** | 1人1つの約束、ペアのふたりストリーク、植物、毎日、無料提供など製品決定を共有。アプリアイコン/ストア表示と SVG の描画だけ各 OS の配布・描画形式に合わせる。 |
| §0.1 2026-10-12 決定 | **同じ / 捨てる** | D1/D2 の植物仕様、D3 の v1.0.1/v1.1 送り、D6 の分析 SDK なしを維持。D4/D5 は共通バックエンドの運用事項で Android 固有要件を追加しない。Apple 固有の Sign in with Apple は Android v1.0 に移植せず、既定どおり後続扱い。 |
| §1 用語定義 | **同じ** | ペア、約束、日付、チケット、植物等の意味を共有。画面や OS 固有機能の呼び名は Android UI に読み替える。 |
| §2 ユーザーストーリー | **同じ / 変える / 後続** | ストーリー1〜9のユーザー価値を維持し、通知・ウィジェット・シェアを Android の OS API に置換。ストーリー10 の Apple アカウント連携は Apple 固有として Android v1.0 から捨てる。Android のアカウント引継ぎ方式は本書で新規決定しない。 |
| §3.1 アカウント | **同じ / 変える** | 匿名 Supabase Auth、ニックネーム、絵文字、リマインド時刻、アカウント削除は共有。Auth セッションを Android 端末に安全に保持。Sign in with Apple は v1.0.1 のまま Android v1.0 から捨てる。機種変更時に匿名 ID を復元できない場合がある説明を維持する。 |
| §3.2 ペア管理 | **同じ / 変える** | 8文字招待、QR、72時間・一回限り、ソロ利用、ペア解消/アーカイブの挙動を共有。`lien://` の受信・アプリ起動は Android Intent/deep link に実装し、リンクを開いただけで自動受諾しない。ユニバーサル/Android App Links の導入は v1.1 扱いを維持。 |
| §3.3 約束 | **同じ** | 1人1つ、20字、絵文字、時刻、編集後もストリーク継続。サーバー上の約束はユーザー所有でペア所有に変更しない。 |
| §3.4 チェックイン | **同じ / 変える / 後続** | 1日1回、本人のローカル日付、当日取消、冪等なオフラインキュー、任意写真は共有。写真選択は Android のシステム Photo Picker 等を使う。カメラ撮影は v1.0.1 のまま v1.0 から捨てる。共有 Storage の署名付き URL と写真上限・権限は共通。 |
| §3.5 ふたりストリーク | **同じ / 変える** | サーバー計算・チケット自動消費・責めない表示は共有。21時危機通知は Android の端末内通知で実装し、正確な時刻の許可と遅延許容は Android 対応 OS 上で検証して決める。 |
| §3.6 お休みチケット | **同じ / 後続** | 無料月2枚・自動消費・履歴とストリーク/植物の扱いを共有。プレミアム月5枚は v1.1、事前のお休み宣言 UI は v1.0.1 のまま。 |
| §3.7 つつく | **同じ / 変える / 後続** | 回数制限、相手名義、定型文・スタンプ、自由文なしを共有。サーバー配送は FCM に置換。定型返事は v1.0.1 のまま。 |
| §3.8 リアクション | **同じ / 変える** | 既定スタンプと1人1つのルールを共有し、通知配信だけ FCM に置換。アルバムでの履歴は v1.1。 |
| §3.9 植物 | **同じ / 変える / 後続** | 同じペア状態・成長閾値・段階・名前を共有し、SVG の合成/アニメーションは Android 描画方式に移す。花壇・おきゃくさんは v1.0.1、花色・品種・鉢は v1.1、複数ペアは v2+ のまま。 |
| §3.10 ウィジェット | **変える / 後続** | ホーム画面 S 相当を Glance で提供し、表示する2人の状態・ストリーク・植物・進捗は共有。Android v1.0 はロック画面用 iOS ウィジェットを捨てる。M+写真は v1.0.1。ウィジェットからアプリホームへの遷移は維持。OS が widget 更新を遅らせる可能性を含む実機計測を行う。 |
| §3.11 履歴・アルバム | **同じ / 後続** | カレンダーと当日の写真の閲覧/通報/ブロックを共有。過去写真アルバムは v1.1。Android で写真へのアクセスは OS Picker と署名付き URL を使い、端末へ永続保存しない方針を保つ。 |
| §3.12 通知一覧 | **同じ / 変える / 後続** | 通知の意味・相手名義・v1.0 で節目/植物名通知を送らないことは共有。サーバー通知を FCM にし、端末ローカルのリマインド/危機通知と Android 通知チャンネルを設ける。サーバー側の種別別設定は v1.1。Android 13+ の通知許可を拒否した場合でも、アプリ内の状態表示とチェックインは使えるようにする。 |
| §3.13 シェア画像 | **同じ / 変える** | 生成内容・節目・写真を含めないプライバシー方針を共有。OS の share sheet で利用者が共有先を選ぶ。 |
| §3.14 課金 | **捨てる（v1.0）/ 推奨（v1.1）** | v1.0 は Android も課金なし・全機能無料。v1.1 で Play Billing + RevenueCat SDK を推奨し、iOS と同一 RevenueCat project の同じ entitlement を付与する。iOS/Android の商品 ID は各ストアで別作成し、Supabase Auth user UUID を同一 App User ID にする。Webhook が `users.premium_until` を更新し、既存の pairPlan 導出を共用できるかを T33/G6 統合時に確認する。 |
| §3.15 設定 | **同じ / 変える / 後続** | プロフィール、約束/通知設定、ペア解消、規約、問い合わせ、削除、匿名利用の注意を共有。通知許可/チャンネル設定への導線は Android に合わせる。Apple 連携は Android に置かず、サーバー通知種別別設定と特商法表示は v1.1。 |
| §4 非機能要件 | **同じ / 変える / 仮説** | RLS、写真のペア内限定、広告/位置情報/ATTなし、分析 SDK なし、日本語のみは共有。OS 最低版は本書で決めず、Android 機種カバレッジと Glance/FCM の実機検証後に別タスクで合意する。起動3秒・ウィジェット60秒 p50 は Android でも測る候補目標で、達成済みとは扱わない。 |
| §5 データモデル | **同じ / 変える** | `users`・`pairs`・`pair_members`・`promises`・`checkins`・`streak_days`・`ticket_ledger`・`nudges`・`reactions`・`plants`・`invites`、制約・RLS・snapshot 契約を共用する。既存 `users.push_token` / `push_env` は APNs 用。Android FCM token をそこへ上書きしてはならない。FCM 登録・失効・複数端末/複数 provider の表現と Edge Function の provider 別配送を eng と決め、必要なら後方互換 migration を設計する。 |
| §6 画面一覧 | **同じ / 変える / 後続** | オンボ、招待、約束、ホーム、カレンダー、設定を共有。OS 固有の画面遷移・Photo Picker・share sheet・通知許可を Android にする。アルバム/ペイウォールは v1.1、widget picker は Android の追加導線。 |
| §7 計測 | **同じ** | 分析 SDK・計測用テーブルを追加せず、共有 Supabase の業務データを SQL で見る。Firebase Analytics は v1.0 要件に含めない。FCM で配信レポートが必要な場合に Google Analytics が前提となることは公式資料に記載されるが、そのレポートは v1.0 の計測要件ではない ([FCM Android セットアップ](https://firebase.google.com/docs/cloud-messaging/android/get-started))。 |
| §8 App Store 審査対策 | **変える** | Apple 固有の審査項目を Android にコピーしない。Play Console のアプリコンテンツ/Data safety、対象年齢、UGC通報・ブロック、プライバシーポリシー、アカウント削除、課金説明を Android/Play 要件で確認する。個人アカウントの closed test 要件は一般公開ゲートに含める。 |
| §9 マイルストーン | **同じ / 変える** | iOS 10/31 最優先と機能凍結・審査作業を維持し、Android のコード・ビルド・Play 準備は独立して並行する。iOS E2E/審査/課金への担当・ファイル・時間の競合を作らない。Android の一般公開日は Play のテスト条件・レビュー所要を確認して設定し、本 Issue では確定しない。 |
| §10 保留事項 | **同じ / 仮説** | 時差ペア・曜日指定・通知追加等の保留を維持。Android 独自の需要、OS 最低版、widget 更新の達成値、正確なローカル通知時刻は未検証 hypothesis として残す。 |

## iOS / Android 混在ペアのデータ互換チェック

Android の実装・結合試験で次を確認する。現時点ではデータ共有を可能とする設計根拠の確認であり、Android 実機 E2E の合格記録ではない。

1. **同一バックエンド**: 両 OS が同じ Supabase project の Auth、Edge Functions、DB、Storage、contracts を利用する。クライアントから `service_role` 等の秘密鍵を使わず、利用者 JWT と既存 RLS を通す。
2. **ユーザー ID と招待**: 各端末で別々の Supabase anonymous user UUID を持つ。招待受諾後に `pair_members` が異なる Auth UUID を結び、iOS/Android の組合せで同じ招待コードの期限・一回性・同時受諾競合が保たれることを確認する。OS 間で匿名セッション/UUIDを自動移行できるとは仮定しない。
3. **業務テーブル制約**: 約束は user 所有かつ現役1人1つ、チェックインは `(user_id, date_local)` 一意、相手データは同じ pair/RLS 条件、写真は共有 Storage の user 別パス・署名URL、解消後は相互に読めないことをクロス OS で確認する。
4. **日付・snapshot**: timezone、端末ローカル日付、0:00〜1:00 の `dateLocal`、チケット `0` とソロ `null`、植物段階と `null` 値、`pairPlan` を同じ契約フィクスチャで両クライアントが解釈する。時差ペア厳密対応は v2+ のまま。
5. **push token と配信**: iOS の APNs `push_token` / `push_env` を維持し、FCM 登録 token の上書きを避ける。ログアウト、再インストール、token rotation、無効 token、複数端末、ペア解消/アカウント削除時の token 清掃と provider 選択を確認する。FCM credentials はサーバー側の秘密管理へ置く。
6. **通知後 widget 更新**: Android 受信処理で短時間内に payload snapshot を端末キャッシュへ保存し、Glance の update を要求する。メッセージ配信/処理が遅れた・欠落した場合は、アプリ前面復帰時の snapshot 取得で回復する。通知権限拒否、Doze、アプリ停止、異なる launcher/API level での更新時間を計測し、iOS の NSE/WidgetKit と同等の配送保証を前提にしない。
7. **課金（v1.1 時点）**: iOS/Android が同一 RevenueCat project・同一 custom App User ID（Supabase UUID）・同一 entitlement を使う。App Store 購入者が Android で、また Play 購入者が iOS で entitlement を認識できること、Webhook から `premium_until` → pairPlan までの状態遷移、期限切れ/返金/解約後の反映を sandbox で確認する。購読の管理・解約操作は購入した store に残る。

## 需要と未確定事項

- **需要の証拠**: この作業で参照した Issue とリポジトリの資料には、Android 実顧客の試用・購入・継続を示す記録は見つからなかった。件数を 0 と断定するのではなく、本調査範囲では `null`（資料内に証拠を確認できず）とする。Android 需要は hypothesis。
- **Play アカウント条件**: 対象 Play developer account の種別・作成日は本タスクでは確認していない（`null`）。Issue 記載の一般条件は Google 公式ヘルプで照合した。
- **外部作業**: Play Console 登録・テスト配布・審査申請・公開操作、契約、支払い、認証情報は本成果物の対象外。iOS への影響を避け、別部署の判断/実行タスクで扱う。

## 参照資料

- [REQUIREMENTS.md](../REQUIREMENTS.md)
- [DESIGN.md](../DESIGN.md)
- [Supabase contracts README](../../products/lien/contracts/README.md)
- [Google Play: 新しい個人アカウントのテスト要件](https://support.google.com/googleplay/android-developer/answer/14151465)
- [Android Developers: Jetpack Glance](https://developer.android.com/develop/ui/compose/glance)
- [Firebase: FCM Android 受信](https://firebase.google.com/docs/cloud-messaging/android/receive-messages)
- [RevenueCat: Android SDK](https://www.revenuecat.com/docs/getting-started/installation/android)
- [RevenueCat: Customer identity](https://www.revenuecat.com/docs/customers/identifying-customers)
