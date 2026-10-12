# App Review Notes — Lien (v1.0)

- Status: **DRAFT** (T30準備 / issue #30 — prepared ahead of full backend deploy; see "状態" per section)
- Last updated: 2026-10-12
- Related issues: #30 (this task) / #8 (Supabase deploy, G0 待ち) / #23 (settings/report/delete UI, 未着手) / #28 (release build, 未着手)
- 正本の優先順位: `docs/REQUIREMENTS.md` → `docs/DESIGN.md` → `docs/CONCEPT.md`(矛盾時はこの順で優先)

> このファイルは2段構えです。**今回のコミット(T30準備)は「草案」**であり、TBDプレースホルダを含みます。T23(設定画面)・T08(G0後の本番デプロイ)・T28(TestFlightビルド)が完了した後、別コミットでTBDを実値に差し替えて完成させます(issue #30 の進め方コメントに記載された2段構え)。

---

## 1. App Review 用ノート本文(英語・App Store Connect "Notes for Review" 欄に貼る想定)

### 1.1 Solo mode works without a pair (no "must have 2 users" blocker)

Lien is a 2-person habit-tracking app, but **the app is fully usable before a pair is formed.**

- After onboarding (concept → nickname → notification permission), the user lands on the Home screen in a "solo" state.
- The user can set their own daily promise (title + emoji + optional reminder time) and check in (mark today as done, optionally attach a photo) **without ever pairing with anyone.**
- The "ふたりストリーク" (shared streak) only starts counting from the day a pair is formed; it does not block any core action beforehand.
- Reviewer verification steps:
  1. Complete onboarding (no sign-in credentials required — see §1.2 below).
  2. On the Home screen, set a promise (title + emoji).
  3. Tap the check-in button. Confirm the action completes and the plant sprite reacts, with no pairing prompt blocking the flow.
  4. (Optional) Open Settings → confirm an invite code/link can be generated, but is not required to continue using the app.
- Source of truth: `docs/REQUIREMENTS.md` §3.2 "招待待ちでも使える: ペア未成立でも約束設定とチェックインは可能(ソロ状態)" — this was an explicit design decision made specifically to avoid an App Review rejection risk and first-day churn.

**状態: 準備済み(文章済み)。実機/TestFlightビルドでの最終確認は T28(#28)完了後(G3後)に実施し、§8①にチェックを入れる。**

### 1.2 No demo account is required — authentication is anonymous

Lien v1.0 uses **anonymous authentication only** (Supabase anonymous sign-in). There is no username/password, and no email/password login screen exists in the app.

- Because there is no credential-gated login, the standard "demo account username/password" field in App Store Connect does not apply in the traditional sense.
- Recommended answer for the "Sign-In Information" / demo account section: **"No login is required. The app creates an anonymous session automatically on first launch. To demonstrate the 2-person pairing feature, follow the steps below to pair two instances of the app via an invite code."**
- Pairing demo procedure (for the reviewer, using two devices/simulators or two TestFlight testers):
  1. Device A: complete onboarding → Settings (or onboarding step) → generate an invite (8-digit code, QR, or link).
  2. Device B: complete onboarding → "招待コードを入力" (enter invite code) → enter the 8-digit code from Device A.
  3. Confirm both devices now show each other's nickname/avatar and promise on the Home screen, and that a check-in on one device reflects (within ~60s) on the other's widget/home.
- Sign in with Apple (T24, 未実装) is an **optional** account-linking feature for device-migration continuity, not a required login — so it does not change the above answer.

**状態: 文言(回答方針)は準備済み。実際の提出時に App Store Connect のテキスト欄へ転記するのは T28/G5 の作業。**

### 1.3 Test pair accounts (2 pairs, as requested by App Review guidance)

Because authentication is anonymous, "test accounts" are provided as **two pre-paired invite demonstrations** rather than username/password credentials. Supabase project ref: `lniheehfbtpfhglinfjm`。

**前提の正確な状態(issue #38/#8のJOURNAL記録より)**: Supabaseバックエンド自体(migration適用・functions 7本デプロイ・匿名サインイン有効化)は**2026-06-11時点で完了済み**であり、技術的にはテストペアを作成できる状態にある。一方、G0(#38)の残項目は**Apple Developer Program加入のみ**(審査待ち)で、APNs(.p8キー)投入・実機G1計測はこれに連なる未完了項目。本タスク(T30準備)は文書化スコープであり、審査提出用の実データをここで本番環境に投入することはしない(「外部送信はタスク本文に明記された場合のみ」というAGENTS.md禁止事項、および issue #30 進め方手順5が「T08完了後」の別フェーズとして明示している通り)。したがって以下は**実行手順のみ準備済み・実行は次段階**という位置づけ。

| ペア | ユーザーA | ユーザーB | 招待コード/手順 | 状態 |
|---|---|---|---|---|
| テストペア1 | `TBD: 実行後に実値`(匿名UUID) | `TBD: 実行後に実値` | `TBD: 実行後に実値`(seed-pair.sh実行時に発行される8桁コードを記載) | **TBD — 審査専用ペアの作成実行待ち** |
| テストペア2 | `TBD: 実行後に実値` | `TBD: 実行後に実値` | `TBD: 実行後に実値` | **TBD — 審査専用ペアの作成実行待ち** |

**作成手順(次段コミットまたは人間が実行)**:
1. `products/lien/scripts/g1/seed-pair.sh` を実行する(`SUPABASE_URL` / `SUPABASE_ANON_KEY` 必須、`SUPABASE_SERVICE_ROLE_KEY` 推奨 — 約束のseedに必要)。このスクリプトは匿名ユーザー2人を作成し、invite-create→invite-acceptでペアを成立させる(詳細: `products/lien/scripts/g1/RUNBOOK.md`)。Supabaseバックエンド自体は稼働中のため、シークレット(`.env.keys`等)が揃えば即実行可能。
2. 本番用には**審査専用に新規のペアを2組作成**し、既存のG1計測用ペアとは分離する(使い捨て前提。シークレット・トークンはコミットしない)。
3. 発行された招待コード(8桁英数)と、各ユーザーに設定したニックネームをこの表に転記する。パスワード等は存在しない(匿名認証のため)。
4. TestFlightの外部テスト(T28/G3)でも同じペアをそのまま審査用デモとして使い回せる。

**状態: TBD(実行待ち)。ハーネス(seed-pair.sh)・バックエンド(Supabase)はいずれも実装済み・稼働確認済み。実データ投入は本タスクのスコープ外のため次段階(T30コミット②、または人間)に委ねる。**

### 1.4 Report flow and blocking (UGC — Guideline 1.2)

Lien has one piece of user-generated content: an **optional photo attached to a check-in, visible only to the paired partner** (never public, never shown to third parties).

- **Report**: Settings → 通報 (Report). Implemented as a `mailto:` link that pre-fills subject/body with the pair ID and date, sent directly to the operator's contact email. (実装はT23の担当範囲 — 本タスク時点では **未実装**。下記「状態」参照)
- **Block**: In this app's closed 2-person design, "block" is implemented as **pair dissolution** (Settings → ペア管理 → ペアを解消する). Dissolving the pair immediately and permanently stops all sharing between the two users: no more shared photos, check-in visibility, nudges, or notifications pass between them. There is no partial-block state — dissolution is a full stop of sharing, which is the functional equivalent of a block in a 2-person-only sharing model.
- **Operator takedown rights**: The operator can remove violating content without prior notice (regardless of whether it was reported), per `products/lien/marketing/terms.md` 第6条3項.
- **Terms of Service references** (audited against REQUIREMENTS §8③④, confirmed consistent):
  - 第6条(通報および運営者によるコンテンツの削除等) — `products/lien/marketing/terms.md:46-51`: 利用者からの通報導線、運営者による確認・削除、事前通知なしの削除権、違反利用者への利用制限/停止/削除の措置を規定。
  - 第7条(ブロックとペアの解消) — `products/lien/marketing/terms.md:53-56`: ペア解消=ブロック相当であることと、解消後の共有停止範囲を規定。
  - 第8条(アカウントの削除) — `products/lien/marketing/terms.md:58-61`: 設定画面からの削除導線とデータ消去を規定。
  - プライバシーポリシー §9(通報とコンテンツの削除)にも同趣旨の記載あり(`products/lien/marketing/privacy-policy.md`)。

**審査リスクの特記(issue #30の敵対検証より)**: 「ブロック=ペア解消」という解釈はApple審査で「相手を完全に遮断する手段がない(新規ペアを組まれ直す可能性?)」と誤解されるリスクがある。本アプリは1ユーザー1ペア(v1.0)で、ペア解消後は相手が自分に対して新たな共有関係を強制的に再構築する手段がないため、実質的に完全なブロックと同等である旨をレビューノート本文で明示する(上記説明文がその明示に該当)。

**状態: ③(通報導線)④(ブロック=ペア解消導線)はいずれも **T23(#23)未着手** のため実装はまだ存在しない。規約(terms.md)の記載は済み。実装後、CI(lien-ios.yml)でSettingsビューの存在確認+証跡をもって§8③④にチェックする。**

### 1.5 Account deletion

Settings → アカウントを削除する(確認2段階)。Deletes the user's row (cascades to pair memberships, promises, check-ins per `auth.users` cascade — `products/lien/supabase/migrations/0001_init.sql`) and triggers pair dissolution for the partner if the user was in an active pair. Terms 第8条 / Privacy Policy §6 (保持期間とアカウントの削除) describe this to the end user.

**状態: T23(#23)未着手につき実装前。backend Function(`delete-account`)も未作成。**

---

## 2. 提出前チェック(App Store Connect 提出時に必要な回答・設定の台帳)

REQUIREMENTS §8(5項目)に加えて、App Store Connect 提出フローで実際に入力・判断が必要な項目をここに台帳化する。**Apple側の仕様詳細について確信が持てない記述は「要確認」と明記し、断定しない。**

### 2.1 App Store Connect「アプリのプライバシー」(データ収集の申告)草案

実装(`products/lien/supabase/migrations/0001_init.sql`)と `products/lien/marketing/privacy-policy.md` §1 の記載から、収集データを以下のように整理する。**Apple の「App Privacy」質問票のカテゴリ名・選択肢の正確な文言は要確認**(Appleの分類は "Contact Info" "User Content" "Identifiers" "Usage Data" 等のカテゴリに分かれるが、本アプリのどのフィールドがどのサブカテゴリに正確に対応するかは App Store Connect 上で実際の質問票を見ながら最終判断する必要がある)。

| データ種別 | 実装上のフィールド | 用途 | トラッキングに使うか | App Privacyカテゴリ(草案・要確認) |
|---|---|---|---|---|
| ニックネーム | `users.nickname` | アプリ機能(表示名) | しない | User Content または Identifiers(要確認) |
| アイコン絵文字 | `users.avatar_emoji` | アプリ機能(表示) | しない | User Content(要確認) |
| 約束の内容(タイトル・絵文字・リマインド時刻) | `promises.title/emoji/remind_at` | アプリ機能 | しない | User Content(要確認) |
| チェックイン記録(日付) | `checkins.date_local` | アプリ機能 | しない | User Content(要確認) |
| 写真(任意) | `checkins.photo_path`(Storage) | アプリ機能(ペア内共有) | しない | Photos or Videos |
| プッシュ通知トークン | `users.push_token` | 通知送信 | しない | Identifiers → Device ID(要確認。APNsトークン自体の分類は要確認) |
| タイムゾーン | `users.timezone` | 日付判定 | しない | Usage Data(要確認) |
| Sign in with Apple識別子(任意連携・T24未実装) | `users.apple_sub` | アカウント連携 | しない | Identifiers → User ID(要確認) |
| 利用状況の統計情報 | REQUIREMENTS §7(自前テーブル or TelemetryDeck。**どちらを採用するか未決定** — 現状コードに計測SDK実装は無し) | 品質改善 | しない | Usage Data(要確認。採用手段が確定するまで最終回答不可) |

**本アプリが収集しないと明記しているもの(privacy-policy.md冒頭)**: 位置情報・連絡先・広告識別子(IDFA)。これらは「収集なし」で回答できる想定(要確認)。

**トラッキングの有無**: 広告目的の第三者トラッキング(ATT)は実装なし → "Data Used to Track You" は該当なしと回答できる想定(要確認)。

**状態: 準備済み(草案)。最終回答は①REQUIREMENTS §7の計測手段(自前 or TelemetryDeck)の確定(CHECKLIST-G4.md 項目と同一)、②G4での事業者名/連絡先確定、③実機提出直前の再チェックが必要。確定は人間判断(G4/#42)+T28/G5担当者。**

### 2.2 年齢レーティング(Age Rating)質問票の想定回答

- 想定レーティング: **4+**(`terms.md` 第4条・`aso.md` に記載済み)。
- 想定根拠: 暴力・性的表現・ギャンブル・アルコール/薬物表現など、レーティングを上げる要素を含まない。UGC(写真)はペア内非公開共有のみで、不特定多数への公開機能はない。
- **要確認**: Apple の年齢レーティング質問票は2024年に新形式(年齢帯 4+/9+/12+/17+、カテゴリ別の頻度選択)に変更されている認識があるが、質問項目の正確な文言・選択肢・UGCの扱われ方(「ユーザー生成コンテンツの有無」を問う項目がどう4+判定に影響するか)はApp Store Connect上で実際の質問票を見て回答する必要があり、本ドラフトでは断定しない。
- **要確認**: UGCが存在する(写真共有機能がある)こと自体が年齢レーティングの質問票でどう扱われるかは、実際の質問内容を見て判断する。

**状態: 想定(4+)は準備済み。質問票の正確な回答は提出時(T28/G5)に要確認で進める。**

### 2.3 Export Compliance(暗号化の輸出コンプライアンス)

- `products/lien/ios/project.yml` の Info.plist 設定で **`ITSAppUsesNonExemptEncryption: false`** が既に設定済み(project.yml:54、T06実装時点)。
- 本アプリが使う暗号化は標準のHTTPS/TLS通信のみ(Supabase REST/Functions呼び出し、APNs)。独自暗号アルゴリズムの実装・カスタム暗号ライブラリは使用していない(コード上確認: 外部依存はsupabase-swiftのみ、DESIGN §3.1)。
- 一般的な理解として、標準OS提供の暗号化(HTTPS/TLS)のみを使うアプリは輸出コンプライアンス上の「免除」対象になることが多いという認識があるが、**この分類の正確な適用条件(免除カテゴリの文言・該当条文)はApple/米国輸出関連規則の正確な引用が必要なため要確認**とし、本ドラフトでは断定しない。
- `ITSAppUsesNonExemptEncryption: false` を設定済みであれば、通常はApp Store Connect提出時の輸出コンプライアンス質問が自動的にスキップされる(Info.plistの値が優先される)という理解があるが、これも**挙動の詳細は要確認**。

**状態: Info.plist設定は準備済み(project.yml:54、既存)。質問票が出た場合の回答根拠整理も準備済み。提出時(T28)に実際の挙動を確認し、想定外の挙動であれば本ファイルを更新する。**

### 2.4 Support URL / Privacy Policy URL の公開先

- 現状、`products/lien/marketing/legal/privacy.html` / `terms.html` は**リポジトリ内に存在するが、まだどこにもホストされていない**。
- `products/lien/marketing/legal/CHECKLIST-G4.md` 3節に「GitHub Pages の公開URLを確定する」とあるが、**具体的なURL(リポジトリ公開設定・パス構成)はまだ決定していない** — これは人間判断が必要な項目(下記「人間判断が必要な項目」参照)。
- Support URL(問い合わせ先)についても、`terms.md`/`privacy-policy.md`の連絡先メールアドレスが`【要記入: G4: 連絡先メールアドレス】`のまま未確定。Support URLとして専用ページを作るか、`mailto:`リンクのみにするかも未決定。
- 本リポジトリは `Ryoki63/Challenge` でPublicに設定済み(GitHub Pages自体は技術的に有効化可能な状態)。ただしこのリポジトリは本アプリ専用ではなく複数ドキュメントを含む構成のため、Pages公開時の対象ディレクトリ・公開範囲は要検討。

**状態: 人間ゲート(G4/#42)待ち。本タスクでは決定不可 — 下記「人間判断が必要な項目」に記載。**

### 2.5 テストペア2組の準備手順(審査用デモアカウント)

§1.3 に詳細を記載済み。要約:

1. ハーネス `products/lien/scripts/g1/seed-pair.sh`(実装済み・動作確認済み)で匿名ユーザー×2→ペア成立を自動化できる。
2. `SUPABASE_SERVICE_ROLE_KEY` があれば約束(promise)も同時にseedできる(無いと `checkin` が `409 no_promise` になるため推奨)。
3. 審査用には既存のG1計測用ペアと分離して**新規に2組作成**し、使い捨て前提で管理する。
4. Supabaseバックエンド(migration適用・functions 7本デプロイ・匿名サインイン有効化)は2026-06-11時点で既に完了・稼働済み(詳細: `products/lien/scripts/g1/RUNBOOK.md`、issue #8/#38のJOURNAL記録)。したがって本手順の実行自体に技術的な前提待ちはない。

**状態: ハーネス・バックエンドともに準備済み(稼働確認済み)。審査専用の2組作成という実データ投入そのものは、本タスク(文書化スコープ)では実施せず次段階(T30コミット②または人間)に委ねる。現時点では実行していない(§1.3のTBDはこの未実行を指す)。G0(#38)の残項目(Apple Developer Program加入)はAPNs投入・実機G1計測・TestFlight提出に必要だが、テストペア作成自体の前提ではない。**

### 2.6 UGC Guideline 1.2 適合性の総括

§1.4と内容重複するため要点のみ再掲:

| 要件 | 対応 | 状態 |
|---|---|---|
| 通報の仕組み | Settings→通報(mailto、pairId・日付プリフィル) | **未実装(T23待ち)**。規約(terms.md第6条)記載済み |
| 不適切ユーザーの排除(block) | ペア解消で共有完全停止 | **未実装(T23待ち)**。規約(terms.md第7条)記載済み |
| 利用規約への同意 | **未確認事項**: オンボーディング(T10実装済み、`OnboardingView.swift`)に規約同意UI(チェックボックス等)は現状存在しない。利用規約・プライバシーポリシーへのリンクはREQUIREMENTS §3.15により設定画面に配置予定(T23範囲)だが、オンボ時点の明示同意有無は未確認 | **T10/T27へ申し送り事項として提起**(issue #30の敵対検証コメントと同じ懸念) |
| コンテンツの連絡先情報公開 | 運営者連絡先(メール)は`terms.md`/`privacy-policy.md`に記載欄あり、現在プレースホルダ | **G4(#42)待ち** |

---

## 3. 証跡(terms.md 監査結果 — issue #30 進め方手順2)

`products/lien/marketing/terms.md` を読み、§8③④の「規約記載」要件を満たすことを確認した:

- 第6条(通報および運営者によるコンテンツの削除等): `products/lien/marketing/terms.md:46-51`
- 第7条(ブロックとペアの解消): `products/lien/marketing/terms.md:53-56`
- 第8条(アカウントの削除): `products/lien/marketing/terms.md:58-61`

いずれも条文としては記載済み。未実装なのはアプリ側のUI/APIのみ(T23)。

---

## 4. 人間判断が必要な項目(まとめ)

- **Support URL / Privacy Policy URL の公開先が未確定**: GitHub Pagesのどのパスで `privacy.html` / `terms.html` を公開するか(リポジトリ公開範囲含む)。`CHECKLIST-G4.md` 3節参照。G4(#42)で決定。
- **事業者名・連絡先メールアドレス・制定日・管轄裁判所が未確定**: `terms.md` / `privacy-policy.md` の `【要記入: G4: ...】` 箇所。G4(#42)で決定。
- **利用状況計測手段(自前テーブル or TelemetryDeck)が未確定**: REQUIREMENTS §7。App Privacy回答(本ファイル§2.1)の最終確定に影響する。CHECKLIST-G4.md項目と同一。
- **年齢レーティング質問票・Export Compliance質問票の正確な回答**: Apple側の最新の質問文言はApp Store Connect上で実際に確認する必要があり、本ドラフトは想定(4+、免除想定)に留めている(要確認)。
- **オンボーディングでの利用規約同意UIの要否**: 現状未実装。UGCアプリとしてApple審査が明示同意UIを求める可能性があるため、T10/T27担当エージェントへの確認・追加実装の要否判断が必要。
