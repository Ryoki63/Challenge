# 審査リジェクト一次返信・証拠ガイド — Lien / G5b #107

更新: 2026-10-20 (Asia/Tokyo)。**返信の下書き・採証の手引き**であり、審査通過・実機検証・申請の完了記録ではない。初回の返信で必要な説明を揃えることを目指すが、通過や審査日数は保証しない。

## 1. 受信した日の進め方

1. メールのリンクから操作せず、正規の App Store Connect (ASC) に入り、チーム・Lien・対象バージョン・ビルド・審査メッセージを照合する。メールの表示名だけで Apple と判断しない。
2. 指摘の条項・原文・審査端末/OS・再現手順を、アクセス制限された審査記録へ残す。公開 Issue/PR には個人情報・スクショ原本・ユーザー ID・認証情報を転記せず、匿名化した要点と証拠 ID だけを書く。未提供値は `null` と理由を残す。
3. [審査導線1枚索引](review-quick-reference.md)から正本を開き、**指摘された提出ビルド**で再現する。現在の main、CI のモック、ストア用画像だけで「再現せず」「修正済み」としない。
4. 指摘を「既存動作の説明不足」「メタデータの誤り」「実装/設定の不備」に分け、§3 の該当項目を選ぶ。再現前の受領連絡と、証拠付き回答を混ぜない。複数条項は1通の中で条項ごとに回答し、未解決項目を消さない。
5. eng-exec が下書きと証拠対応表を作り、eng-review が根拠と提出ビルドの一致を確認する。仕様変更は eng-lead、運営基準/日程判断は担当者へ渡す。**ASC への返信・デモ運用・再提出・公開は承認を持つ担当者だけ**が実施する。このガイドを根拠にエージェントが送信しない。

ASC の返信と添付、メタデータ不備を直した同じビルドの再提出は Apple の [S2] に従う。単なる説明/追加情報と、修正後の再提出は区別する [S3]。受領連絡が必要なら次の型から、調査が本当に始まっている文だけを使う。

```text
Hello App Review Team,
Thank you for reviewing Lien <VERSION> (<BUILD>).
We are investigating the issue under Guideline <EXACT_CLAUSE>.
<If missing: Could you share the device, OS version and exact steps?>
We will follow up with verified reproduction steps and supporting evidence.
```

## 2. 添える証拠の作り方

- **対象を固定**: 版/ビルド、端末/OS、言語、採証日時(ISO 8601 +09:00)、初回/既存インストール、ソロ/ペア、通知状態、ネットワーク状態を記録する。アプリの修正なら失敗した旧ビルドと修正ビルドを区別する。未測定は `null` + 理由で、成功/0件に置き換えない。
- **スクショ**: 各表の到達画面・結果を同じビルドで撮る。番号と簡潔な説明を付ける。ユーザーの写真ではなく架空のデモ画像を使い、通知・メール宛先・ID・招待コード・署名付き URL・購入者情報を写さない。公開用は必要箇所をマスクし、挙動を示す UI を加工しない。
- **動画**: 1指摘につき開始状態→タップ→結果を連続収録する(目安30〜90秒、長い場合は観測に必要な尺)。待ち時間を隠して成功を演出せず、タップ順と該当時刻を手順書へ記す。通知は実機で、2端末の証拠には A/B を表示する。安全なデモ用データだけを使い、問題部分で録画が途切れたら撮り直す。
- **手順**: 前提→操作→期待値→実測値→証拠ファイル/動画時刻を1行ずつ書く。再現できる操作名は [review-notes](review-notes.md) と一致させる。コードや認証値の代わりに「ASC Notes の現行値」を参照する。
- **保管/送付**: 原本はアクセス制限された審査記録に保管し、Git には本ガイドと匿名化した検証結果だけを置く。承認担当者が ASC の Attach File で送る前に、形式/容量が受理されるか、添付が実際に開くかを確認する。動画が受理されなければ同じ操作の連番画像+手順にする。公開ストレージへのアップロードや動画公開で代替しない。

### 証拠対応表の型

以下は**未記入の例**。実機検証したことを示さない。実際の値は制限付き審査記録で管理する。

| 指摘/証拠 ID | 版/ビルド・端末/OS・日時 | 前提・操作・期待値 | 実測値・結果 | 添付と参照時刻 |
|---|---|---|---|---|
| `<EXACT_CLAUSE>` / `<E-ID>` | `null` (未採証) | `<verified steps>` | `null` (未実施) | `null` (未作成) |

ファイル名例: `E-21-completeness-buildNN-01.png` / `E-21-completeness-buildNN.mp4` / `E-21-steps.txt`。ID と本文の参照を揃え、古い証拠を上書きして出典を失わない。

## 3. 条項別の返信型・添付

以下の英語は**確認後に埋める型**。`<...>` と選択肢/注記は送信前に置換/削除する。§1 の受領連絡以外は、記載した挙動を提出ビルドで確認し、証拠を揃えてから送る。「fixed」「tested」「no purchases」などの断定は未確認のまま残さない。

### 3.1 2.1 完了度 — E-21

Apple [S1] §2.1 は、動く最終ビルド・稼働するバックエンド・有効な URL・レビュー可能な機能を求める。Lien のソロ操作と匿名認証の説明は [review-notes §1.1〜1.3](review-notes.md#11-solo-mode-works-without-a-pair-no-must-have-2-users-blocker) が正本。

| 添付 | 採証の手順・見る結果 |
|---|---|
| スクショ `E-21-01/02` | 新規起動から正本 §1.1 のオンボーディング・約束設定を終え、ソロ Home とチェックイン後の完了表示を撮る。2人目がいなくてもここまで進むことを確認する。 |
| 動画 `E-21` | 同じ初期状態からチェックインまで連続収録。招待/ペア機能が指摘対象なら正本 §1.2 または §1.3 の経路も撮り、通知を主張する場合は許可済み実機で検証する。 |
| 手順 `E-21-steps` | 審査の失敗手順を再現→修正後の同じ操作→実測結果。URL 不備なら提出ビルド内リンクを開いた結果、バックエンド不備なら復旧後の実操作結果も添える。 |

```text
Hello App Review Team,
Thank you for the feedback under Guideline 2.1 for Lien <VERSION> (<BUILD>).
Finding: <reproduced problem OR verified navigation misunderstanding>.
Resolution: <specific fix and new build OR clarification for the same build>.
The verified solo flow does not require a second user or sign-in credentials.
Steps: <paste the verified steps from E-21-steps>.
Expected and observed result: <result on DEVICE / OS / BUILD>.
Evidence: <E-21 filenames and video timestamps>.
For paired features, the current setup is in Notes for Review.
Please review the steps above; let us know if further information is needed.
```

**送信を止める条件**: 対象クラッシュが未解決、法務/サポート URL が開かない、バックエンド未稼働、デモコードが失効/使用済み。説明だけでバイナリ不具合を修正扱いにしない。

### 3.2 5.1.1 権限・データ — E-511

Apple [S1] §5.1.1 の指摘小項目を原文で特定する(同意/最小収集/ポリシー/削除など)。通知を必須にしない点は §5.1.2 も照合する。Lien の正本は [review-notes §1.2](review-notes.md#12-no-demo-account-is-required--authentication-is-anonymous)、[§1.5](review-notes.md#15-account-deletion)、[§2](review-notes.md#2-提出前チェックapp-store-connect-提出時に必要な回答設定の台帳)。

| 添付 | 採証の手順・見る結果 |
|---|---|
| スクショ `E-511-01/02` | 初回オンボーディングの通知説明と拒否後の Home/チェックイン成功を撮る。写真が対象ならペアでチェックイン後に「写真を添える」→システムピッカーを撮る。 |
| 動画 `E-511` | 通知を拒否または後回し→基本操作が続く。写真ピッカーをキャンセル→チェックインは保持。権限再設定が対象なら設定からの導線も収録する。 |
| 手順 `E-511-steps` | 権限の初期状態/拒否/再許可、データ用途、提出ビルドの表示を記録。ポリシー/削除が指摘対象なら設定内リンク/削除導線と削除後の実測結果を追加する(削除は承認済みデモだけ)。 |

```text
Hello App Review Team,
Regarding Guideline <EXACT_5.1.1_SUBCLAUSE>, we verified Lien <VERSION> (<BUILD>).
Affected permission or data: <item and purpose>.
Change or clarification: <exact change OR existing behavior>.
Consent/denial behavior and data handling: <verified behavior only>.
Steps: <paste the verified steps from E-511-steps>.
Observed result: <result on DEVICE / OS / BUILD>.
Evidence: <E-511 filenames and timestamps>.
Privacy policy or deletion details, if relevant: <verified location>.
```

**境界**: ソース上の v1.0 写真入力は `CheckinFlowView.swift` の `PhotosPicker`。カメラ撮影やライブラリ全体の許可を求める手順を創作しない。通知拒否時は push/その経路の Widget 更新を約束せず、アプリを開いた時の更新を確認する。App Privacy・マニフェスト・SDK の実データ利用を、画面の許可有無だけで証明しない。

### 3.3 1.2 UGC 通報・ブロック — E-12

Apple [S1] §1.2 は、投稿される不適切な内容のフィルタ、通報と適時対応、ブロック、公表した連絡先を求める。**招待制/2人限定や規約への同意だけで免除・完全適合を主張しない**。正本: [review-notes §1.4](review-notes.md#14-report-flow-and-blocking-ugc--guideline-12) / [§2.6](review-notes.md#26-ugc-guideline-12-適合性の総括)。

| 添付 | 採証の手順・見る結果 |
|---|---|
| スクショ `E-12-01/02/03` | 架空のペアで、相手の写真/ニックネーム/約束/植物名の長押しメニューと、設定→サポート→「不適切な内容を通報する」を撮る。確認後のメール下書きは宛先・ID・内容をマスクする。 |
| 動画 `E-12` | 通報選択→確認→メール下書き(自動送信なし)。別の承認済みデモでブロックの2段階確認→解消後に旧相手の共有内容が見えないことを A/B で収録。VoiceOver の同じアクションも確認する。 |
| 手順 `E-12-steps` | 正本 §1.4 に沿った各入口・メール未設定時の代替連絡表示・連絡先の有効性・解消後の再読込結果を記録。フィルタと運営の適時対応が問われたら、実在する仕組み・承認済み運用・匿名化した試験結果を別項目で対応付ける。 |

```text
Hello App Review Team,
Regarding Guideline 1.2 for Lien <VERSION> (<BUILD>):
Content scope: <verified content shared only with an accepted partner>.
Reporting: <verified entry points and confirmation-to-mail-draft behavior>.
Blocking: <verified pair-dissolution steps and post-dissolution access result>.
Filtering and operator response: <actual mechanism, verified test and approved process>.
Published contact: <verified in-app/public location; no invented address>.
Steps and evidence: <E-12 steps, filenames and timestamps for each finding>.
Changes made: <only changes actually shipped or operations actually verified>.
Please let us know if further evidence is required for the cited findings.
```

**現時点の未確認/送信ゲート**: `SupportLinks.contactEmail` は空、正本 §1.4 は運営の対応期限/基準を G4 待ちとしている。本文・コード参照だけでは投稿時フィルタの実動作も確認できていない。これらを「実装済み」「24時間以内対応」と埋めない。該当指摘を受けたら eng-lead/運営へ対応判断を渡し、解決した実測結果が揃うまで適合回答/再提出をしない。ブロック後に予約済みローカル通知が最大1件残り得る既知制約も正本どおり説明し、「一切届かない」と書かない。

### 3.4 3.1.1 課金 — E-311

Apple [S1] §3.1.1 の指摘内容を読み、サブスクリプションなら §3.1.2 も照合する。**先に提出ビルドの課金の有無を確定する**。[REQUIREMENTS §8](../../../docs/REQUIREMENTS.md#8-app-store-審査対策チェックリスト) は v1.0 無料/課金未導入としている一方、T33 の購入/復元コードは存在する。ソースの有無やキーの未設定だけで表示/購入不可を断定しない。秘密の設定ファイルやキー値を採証しない。

| 添付 | 採証の手順・見る結果 |
|---|---|
| スクショ `E-311-01/02` | 無料提出: 提出ビルドの Home/設定と、課金入口になり得る履歴/ストリーク保険の到達結果。課金提出が別途承認された場合だけ: 実商品名・Apple の表示価格/期間・購入/復元・法務リンク。 |
| 動画 `E-311` | 無料提出: 対象機能が支払要求/外部決済誘導なしで使えることを撮る。承認済み課金提出: Sandbox で購入成功/キャンセル/復元と entitlement の反映を撮る(実課金・購入者情報の収録は禁止)。 |
| 手順 `E-311-steps` | 無料/課金の判断根拠、提出版の全課金入口、ASC 商品設定との整合を担当者が記録。課金時は新規購入者/既存購入者・復元の前提と結果も記す。 |

**A: 全課金入口の実測が「無料提出」と一致した場合のみ**:

```text
Hello App Review Team,
Regarding Guideline 3.1.1, the submitted Lien <VERSION> (<BUILD>) is free.
We verified the relevant purchase entry points and the features cited in your message.
No payment or external checkout is required for <verified scope> in this build.
Steps and results: <verified E-311-steps>.
Evidence: <E-311 filenames and timestamps>.
Metadata clarification or change: <actual correction, if any>.
```

**B: 課金提出の承認・商品設定・Sandbox 検証が揃った場合のみ**:

```text
Hello App Review Team,
Regarding Guideline 3.1.1 for Lien <VERSION> (<BUILD>),
Digital feature: <feature>; in-app purchase: <submitted product identifier>.
Resolution: <actual purchase, restoration or metadata fix>.
Steps: <verified Sandbox purchase/cancel/restore steps from E-311-steps>.
Observed result: <transaction and entitlement behavior; no transaction IDs>.
Evidence: <E-311 filenames and timestamps>.
Price/period, renewal terms and legal links: <verified display locations>.
```

**送信を止める条件**: 無料の正本とビルドの購入導線が食い違う、商品がレビューできない、復元/権利反映が失敗する。A/B を混ぜたり、未承認の課金導入・機能隠しで回避したりせず eng-lead に差分を渡す。

### 3.5 4.0 デザイン — E-40

Issue の「4.0」は Apple [S1] の **§4 Design 全体の分類**として扱う。実際の指摘が 4.1(模倣)、4.2(最低限の機能)、UI 不備のどれかを確認し、小項目を返信に書く。シンプルさはそれだけでは適合の証明にならない。

| 添付 | 採証の手順・見る結果 |
|---|---|
| スクショ `E-40-01/02` | 指摘画面の修正前/後を同じ端末/文字サイズで撮る。切れ・重なり・判読性を確認。機能性が対象ならソロ Home・ペア Home・実 Widget など、提出版の価値が分かる画面を選ぶ。 |
| 動画 `E-40` | 指摘された導線の開始→完了。最低限の機能の指摘なら、約束→チェックイン→相手への反映→Widget から Home の実操作で、単なるリンク集ではないことを示す。 |
| 手順 `E-40-steps` | 正本 §1.1/§1.2 の操作と実測値に加え、指摘端末、文字サイズ、VoiceOver、必要な明暗モードの表示確認を記録。模倣指摘なら制作由来/権利の確認資料を添え、競合の素材を無断複製しない。 |

```text
Hello App Review Team,
Regarding Guideline <EXACT_DESIGN_SUBCLAUSE> for Lien <VERSION> (<BUILD>),
Finding: <specific usability, functionality or originality concern>.
Change or clarification: <verified UI fix OR existing native functionality>.
The demonstrated user value is <specific task the submitted app completes>.
Steps and observed result: <verified E-40-steps on DEVICE / OS / text size>.
Evidence: <E-40 before/after filenames and video timestamps>.
<For originality only: relevant provenance or rights evidence>.
```

**送信を止める条件**: 将来機能・ストア用モック画像・未実装アルバム等で価値を説明する、指摘端末で不備が残る、権利が未確認。独断で機能を増やさず、承認済み仕様の範囲で修正/説明する。

## 4. 1回で通らなかった場合の再提出チェックリスト

- [ ] 前回と今回の指摘を条項/原文ごとに並べ、追加質問・未解決事項・証拠 ID・担当者を1対1で紐付けた。「同じ説明を再送」だけにしていない。
- [ ] 説明不足は具体的手順+実測証拠で補い、メタデータ不備は実欄を修正、実装/設定不備は根本修正した。全指摘を解決するまで再提出しない [S3]。
- [ ] バイナリ不備なら修正ビルドをアップロードして対象を選び直す。メタデータだけなら同じビルドを使える場合がある [S2]。説明だけで解決する場合は [S3] に沿って返信し、不要な再提出を避ける。操作はいずれも承認担当者が行う。
- [ ] 修正差分の関連テスト・必要な型/lint/buildを通し、提出ビルド・審査端末で元の失敗手順と影響するソロ/ペア導線を確認した。コード修正なしなら機械検査の対象外理由を書く。CI 緑を実機成功に読み替えない。
- [ ] [1枚索引](review-quick-reference.md)からデモ/審査正本を確認し、使用済み/期限切れコードは承認担当者が再発行して ASC Notes を更新した。相手役の運用を引き受ける担当者が決まり、アプリ/バックエンド/通知の前提を満たした。
- [ ] 公開連絡先・通報対応/フィルタ・法務ページ・アカウント削除・App Privacy/マニフェスト・無料/課金の実ビルド整合を、指摘と影響範囲に応じて再確認した。未解決を N/A にしていない。
- [ ] スクショ/動画/手順の版・ビルド・証拠 ID が一致し、添付を開いて読めた。プレースホルダ、架空の試験結果、秘密/個人情報、旧コード/購入者情報を含まない。旧証拠は履歴として区別した。
- [ ] eng-review の確認後、承認担当者がチーム/アプリ/版/ビルドを再照合し、返信と再提出を区別して実施する。送信後は ASC のメッセージ/状態を再読み込みして成功を確認し、曖昧なら連打しない。手動公開設定を維持し、公開は別承認とする。
- [ ] 解釈の不一致が残る場合は eng-lead と承認担当者が Apple への追加質問/相談、必要なら正式な異議申立てを判断する [S4]。返信欄を異議申立ての代用にせず、実装不備を残したまま申立てに逃げない。申立て中の再提出は申立てを閉じ得るため並行操作しない [S3]。
- [ ] 審査結果を待ち、2026-10-24 機能凍結・10-27 提出・10-30〜31 公開への影響は HQ に報告する。日程やリリース範囲を独断で変えない。この文書の完成を審査通過扱いにしない。

## 5. 出典・適用境界

Apple 公式ページは 2026-10-20 に確認。送信日にも指摘条項/ASC の現在の案内を確認する。長文の転載ではなく、この作業向けに要約した。審査要件と本ガイドの採証目安(動画尺・命名等)は別である。

- [S1: App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/) — §2.1 / §5.1.1・5.1.2 / §1.2 / §3.1.1・3.1.2 / §4・4.1・4.2。
- [S2: Reply to App Review messages](https://developer.apple.com/help/app-store-connect/manage-submissions-to-app-review/reply-to-app-review-messages/) — 返信/添付/メタデータ不備の場合の同一ビルド。
- [S3: Track a submission's review status](https://developer.apple.com/help/app-review/after-submitting-for-review/review-status/) — 返信と再提出、全指摘の解消、申立て中の注意。
- [S4: App Review / Contacting us](https://developer.apple.com/app-store/review/) — 質問/相談/正式な異議申立て。
- プロダクトの正本: [REQUIREMENTS](../../../docs/REQUIREMENTS.md) → [DESIGN](../../../docs/DESIGN.md) → [CONCEPT](../../../docs/CONCEPT.md)。提出手順の正本は [review-notes](review-notes.md)。本ガイドはそれらを書き換えない。
- 実装照合箇所: [写真ピッカー](../ios/Lien/Features/Checkin/CheckinFlowView.swift)、[通知許可](../ios/Lien/Features/Onboarding/OnboardingViewModel.swift)、[運営連絡先](../ios/Lien/Core/SupportLinks.swift)、[課金の組み立て](../ios/Lien/App/AppServices+Live.swift)、[購入導線](../ios/Lien/Features/Home/HomeView.swift)。ソース確認と実ビルド採証は別。
