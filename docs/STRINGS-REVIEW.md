# Lien — Strings.swift 文言レビューログ（T27 / #27）

- ファイル: `products/lien/ios/Lien/Core/Strings.swift`（ユーザー向け文言の集約 — DESIGN §3.8）
- 正本: `docs/REQUIREMENTS.md` §3.1・§3.2・§3.4・§3.5・§3.10・§3.12・§3.15・§6 / `docs/DESIGN.md` §3.8 / `docs/GROWTH.md` §4.4・§5・§6.6
- 実施日: 2026-10-20
- 実施: eng-exec（T27 本体）
- 検査: `LienTests/StringsReviewTests.swift`（罰なし lint・`StringsCatalog`・本ログの網羅）を CI `lien-ios` で毎回実行
AD
- 対象: 383 件（OK 377 / 修正 6 / 保留 0）
- 内訳: 379 単位（`StringsCatalog` の全出力を確認。関数型の文言は代表値で展開し、全通りを機械検査。2026-10-26 に約束の絵文字の2単位を外し、同日、絵文字24種の1単位をアイコンの名前13単位（§7.23）に替えた)
- 追記（2026-10-20・issue #72 の検証中）: T27 の本体（#27・PR #86）のあとに足された 43 単位（`Tickets.balance` / 履歴 T18 #18 / シェア画像 T22 #22）を、同じ判定基準で追記レビューした（§7.20〜§7.22）。文言は変えていない（すべて OK）


## 1. 結論

- **罰・恥・煽り系の表現は 0 件**。機械 lint（禁止ワード8語）と目視の両方で確認した。
- **6 件を修正**し、残り **291 件はそのまま採用**。修正はすべて文言だけで、画面遷移・API・データは変えていない。
- 空状態 **14 箇所**、エラー文言 **33 箇所**を点検。文言の欠落は 0。ただし、初回同期が失敗したときの画面遷移は文言だけでは決められない（§6.1 に判断材料を残した）。
- 用語は「相手」「ふたりの記録」「タネの子」に統一。画面に出ていた開発者ことば（「ストリーク」「アーカイブ」）を 1 件除去した。
- 表記のゆれ（「とじる」2件、「名前をかえる」1件、「おくっています」1件）を統一した。

## 2. 判定基準

1. **罰なし（REQUIREMENTS §3.5）**: 責める・脅す・損失をちらつかせる・相手を責める表現をしない。休んだ日・減ることに触れない。
2. **次の一歩**: エラーは「何が起きたか」＋「どうすればよいか」。ユーザーに責任がないことを前提にする。
3. **トーン**: ひらがな基調のやさしい話し言葉。設定・法務・通知の説明はです・ます。同じ画面で不必要に混ぜない（ラベルと本文の差は許容）。
4. **用語**: 相手（パートナーではない）／ふたりの記録（ストリークではない）／タネの子・植物／約束／チェックイン／つつく／リアクション。
5. **表記**: 「閉じる」「やめる」「あとで」を統一。数字は半角、括弧は半角（既存 UI に合わせる）。文末の「。」は、法務・同意・通知本文・複数文の説明には付ける。短いエラー（2文になっても `Plant.nameSaveError` のように軽く見せるもの）・ラベル・ボタンには付けない。
6. **事実整合**: v1.0 の機能（Sign in with Apple なし、相手の通知はアプリ内で OFF 不可、夜9時、写真は当日のみ）と食い違わない。
7. **VoiceOver**: 名前＋状態の形。記号だけに頼らない。

## 3. 修正した 6 件

| 名前 | 変更前 | 変更後 | 理由 |
|---|---|---|---|
| `Dissolve.effectArchive` | 植物とストリークの記録はアーカイブされ、同じ相手と組み直しても復活しません | 植物とふたりの記録は、ここでいったん区切られます。同じ相手と組み直しても、前の続きにはなりません | 「ストリーク」「アーカイブ」は画面の言葉ではない。ユーザーの呼び名「ふたりの記録」にし、何が起きるかを言い直した |
| `Plant.celebrationClose` | とじる | 閉じる | 設定・通報・名前の知らせと同じ「閉じる」に統一（5箇所中2箇所だけひらがなだった） |
| `PartnerPhoto.viewerCloseButton` | とじる | 閉じる | 同上。全画面の閉じるボタン |
| `Plant.renameTitle` | 名前をかえる | 名前を変える | 同じ画面の `renameHint = "ダブルタップで、名前を変えます"` と、設定の「約束を変える」に合わせる |
| `Checkin.attachPhotoSending` | 写真をおくっています… | 写真を送っています… | エラーの「写真を送れませんでした」と動詞を揃える |
| `Plant.nameInvalidError` | 使えない文字が入っています | 改行や見えない文字は、名前に使えません | 何を直せばよいかが分からない。入力規則（改行・見えない文字）を言い、責めない |

- 6 件とも、文言を参照しているテストは定数経由（`Strings.*`）なので、期待値の書き換えは不要。`StringsCatalog` の網羅検査はそのまま通る。
- 文言の変更に対する回帰検査として、`testUserFacingStringsAvoidDeveloperJargon`・`testCloseLabelsAreConsistent`・`testNetworkErrorMessagesAreIdentical` を追加した（§8）。

## 4. 空状態の点検（14 箇所）


| 画面 | 状態 | 出る文言 | 判定 | メモ |
|---|---|---|---|---|
| ウィジェット | snapshot が無い（初回起動前・未ログイン） | `Widget.emptyTitle` / `Widget.emptyMessage` | OK | アプリを開く導線。ウィジェットは状態を知らない |
| ホーム | snapshot が無い | `Home.emptyTitle` / `Home.emptyMessage` | OK | 「準備しています」。失敗とは言わない |
| ルート（初回同期） | セッションはあるが snapshot が未取得 | `Home.emptyMessage`（ProgressView と一緒に） | OK | 同期が終わるまでの待ち。失敗時は §6.1 |
| ホーム（ソロ） | ペア未成立 | `Home.soloCaption` / `Home.soloInviteHint` / `Home.inviteButton` | OK | タネの子は土の中で眠る。招待は任意 |
| ホーム | 約束が未設定 | `Home.promiseUnsetLabel` | OK | 「約束はこれから」。責めない |
| 設定 | 約束が未設定 | `Settings.promiseUnset` | OK | 「まだ決めていません」。事実のみ |
| 通知の設定 | 約束が無い | `NotificationSettings.reminderNoPromise` | OK | 約束を決めれば設定できる、と次の一歩 |
| 設定 | 読み込みに失敗 | `Settings.loadFailed` / `Settings.retry` | OK | 同じ行に再試行ボタン |
| 通知の設定 | 読み込みに失敗 | `NotificationSettings.loadFailed` / `NotificationSettings.retry` | OK | 同じ行に再試行ボタン |
| 相手の今日の写真 | 写真が無い日・読み込み失敗 | 何も出さない（文言なし） | OK | §3.11。相手を責めないための意図的な無表示 |
| 植物 | 名前が未設定 | `Plant.nameButton` | OK | 「名前をつける」の導線 |
| 通報 | ペアが無い | `Report.noPair` | OK | メール本文の項目。画面の空状態ではない |
| 設定 | ソロ | `Settings.soloNote` | OK | 「いまはひとりで使っています」。責めない |
| ログイン状態 | セッションが使えない | `Session.lostTitle` / `Session.lostMessage` | OK | 「あとで」を先に。破壊的な選択を最初に出さない |


- 空状態に「まだ」「ありません」「失敗」と書かない。**何も無いことを責めない**（§3.5）。
- 写真だけは、無い日・失敗したときに何も出さない（§3.11）。「写真がありません」と書くと、相手が添えなかったことを責めることになる。
- 初回同期の失敗だけは、文言ではなく画面遷移の問題として §6.1 に残した。

## 5. エラー文言の点検（33 箇所）


| 種別 | 画面・操作 | 文言 | 次の一歩 | 判定 |
|---|---|---|---|---|
| 入力 | オンボ・ニックネームが空白だけ | `Onboarding.nicknameEmptyError` | 入力する | OK |
| 入力 | オンボ・ニックネームが8文字超 | `Onboarding.nicknameTooLongError` | 短くする | OK |
| 入力 | 約束・タイトルが空白だけ | `PromiseSetup.titleEmptyError` | 入力する | OK |
| 入力 | 約束・タイトルが20文字超 | `PromiseSetup.titleTooLongError` | 短くする | OK |
| 入力 | 植物の名前が空白だけ | `Plant.nameEmptyError` | 入力する | OK |
| 入力 | 植物の名前が8文字超 | `Plant.nameTooLongError` | 短くする | OK |
| 入力 | 植物の名前に改行・見えない文字 | `Plant.nameInvalidError` | 改行・見えない文字を消す | 修正 |
| 通信 | オンボ・プロフィール送信 | `Onboarding.submitErrorMessage` | 同じ画面で再試行（ボタンが「もう一度ためす」） | OK |
| 通信 | 招待の発行・受諾 | `Pairing.errorNetwork` | もう一度 | OK |
| 操作 | すでにペアが成立 | `Pairing.errorAlreadyPaired` | シートを閉じる（事実のみ） | OK |
| 操作 | 相手がすでに別のペア | `Pairing.errorPartnerAlreadyPaired` | 新しい招待を待つ | OK |
| 操作 | 招待が見つからない | `Pairing.errorInviteNotFound` | コードを確認 | OK |
| 操作 | 招待が期限切れ | `Pairing.errorInviteExpired` | 新しい招待をもらう | OK |
| 操作 | 招待が使用済み | `Pairing.errorInviteAlreadyUsed` | 新しい招待をもらう | OK |
| 操作 | 自分の招待を受諾 | `Pairing.errorCannotAcceptOwnInvite` | 相手に送る | OK |
| 入力 | コードの形式が違う | `Pairing.errorInvalidTokenFormat` | 8文字の英数字を入れる | OK |
| 通信 | 約束の保存 | `PromiseSetup.saveErrorMessage` | もう一度 | OK |
| 通信 | チェックイン | `Home.checkinErrorMessage` | もう一度 | OK |
| 通信 | 当日取消 | `Checkin.cancelErrorMessage` | もう一度 | OK |
| 通信 | 写真の添付 | `Checkin.attachPhotoErrorMessage` | もう一度 | OK |
| 通信 | つつく | `Nudge.errorMessage` | もう一度 | OK |
| 上限 | つつくが1日3回を超えた | `Nudge.limitReachedMessage` | また明日 | OK |
| 通信 | リアクション | `Reaction.errorMessage` | もう一度 | OK |
| 通信 | 段階アップのハート | `Plant.celebrationHeartError` | あとでもう一度 | OK |
| 通信 | 植物の名前の保存 | `Plant.nameSaveError` | 下書きは残る。もう一度 | OK |
| 状態 | ペアが無いのに名前を保存 | `Plant.nameNoPairError` | ペア成立後に | OK |
| 通信 | プロフィールの保存 | `Settings.profileSaveError` | もう一度 | OK |
| 通信 | リマインドの保存 | `NotificationSettings.reminderSaveError` | もう一度 | OK |
| 通信 | ペアの解消 | `Dissolve.errorMessage` | もう一度 | OK |
| 通信 | アカウントの削除 | `DeleteAccount.errorMessage` | もう一度押すと続きから | OK |
| 通信 | 通報メールが開けない | `Report.mailFailedTitle` / `Report.mailFailedMessage` | メールの設定を確認 / 宛先へ直送 | OK |
| 権限 | 通知が拒否されている | `NotificationSettings.deniedNotice` | iOS の設定アプリで許可 | OK |
| 状態 | セッションが使えない | `Session.lostTitle` / `Session.lostMessage` | 「あとで」/「はじめからやり直す」 | OK |


- 通信エラーは 7 箇所で同じ「通信がうまくいきませんでした。もう一度お試しください」を使う。同じ状況で違う言い方にしない（`testNetworkErrorMessagesAreIdentical`）。
- 入力エラーは「入力してね」（誘い）と「◯文字までです」（事実）の2種類。上限は placeholder にも書いてある。
- 上限・権限・セッションのエラーは、ユーザーの落ち度にしない。「また明日」「iOS の設定で許可」「あとで」など、次の一歩を必ず添える。
- 破壊的な操作（解消・削除・サインアウト）は、エラーではなく確認画面で「何が起きるか」を先に示す。

## 6. 変えないと決めた点（理由つき）

### 6.1 初回同期が失敗したときの空状態（要 eng-lead 判断）

- 事実: `AppModel.refresh()` は同期に失敗しても `isResolving = false` にし、snapshot が無いと `.promiseSetup` のまま約束設定画面を出す（`AppModel.swift` の `refresh()` / `syncFirstTimeIfNeeded()`、`RootView.swift` の `ResolvingView`）。通信失敗の文言は出ない。
- 影響: オフラインで再インストールしたとき、既存の約束・ペアがあるのに「あなたの約束をきめよう」と出る可能性がある。データは消えないが、二重に約束を決める導線になりうる。
- 今回直さない理由: 「約束設定に進ませる」か「エラー画面で再試行させる」かは画面遷移の仕様判断で、T27 の完了条件（レビューログ）を超える。T30 か別 issue で決める。
- 推奨: 初回同期だけ「読み込めませんでした」＋「もう一度ためす」を出し、オフラインでも約束設定に進める逃げ道を残す。判断は eng-lead / T30。

### 6.2 「8文字」と絵文字の数え方

- ニックネーム・植物の名前の上限は DB の `char_length`（Unicode コードポイント）に合わせている。絵文字の組み合わせは、見た目が1文字でも複数と数えることがある。
- 表示は「8文字まで」。v1.0 はこのままで、審査・実機で問題になったら「絵文字は複数と数えることがあります」を足す（v1.0.1 の候補）。

### 6.3 `Plant.voicePending = "まだ"`

- VoiceOver の状態語（「あなた: 完了、ゆうき: まだ」）。GROWTH §5.4 がこの形を指定している。
- 禁止語の「まだやってない」とは別。状態を事実として読むだけで、責めるニュアンスはない。現状維持。

### 6.4 「ペア」と「相手」

- 設定のセクション名・解消・削除の説明では、関係の単位として「ペア」を使う。人物は「相手」。
- REQUIREMENTS もこの語を使っている。全部を「ふたり」に置き換えると、解消・削除の説明が曖昧になる。現状維持。

### 6.5 エラー文末の「。」

- 法務・同意・通知本文・複数文の説明には付ける。短いエラーは、2文になっても文末の「。」を省いて軽く見せる（例: `Plant.nameSaveError`）。
- 現状はこの使い分けにおおむね沿っている。`Report.mailFailedMessage` は複数文の案内なので「。」あり。一括で付け直すと差分が大きくなるため、個別の修正に留める。

### 6.6 「ストリーク危機」の「あと3時間」

- 夜9時の通知は「あと3時間。ふたりの◯日を、いっしょに守ろう🌱」。損失をちらつかせず、前向きな呼びかけにした（GROWTH §6.6 で案 A/B と比較済み）。
- 「あと3時間」は保険（お休みチケット）の訴えの核なので残す。現状維持。

## 7. 全文言のレビュー（352 単位）

- 「単位」は `StringsCatalog` の名前から引数部・添字を落としたもの。関数型の文言は代表値で1行にし、全通りを機械検査で確認している。
- 判定は `OK`（そのまま採用）/ `修正`（この PR で変更）/ `保留`（今回は変えない）。`保留` は 0。
- 文言の `⏎` は改行を表す。`（）` は既存 UI に合わせて半角。

### 7.1 ウィジェット（LienWidget と共有）

- 対象は 11 単位。表示名・ギャラリーの説明・空状態・約束名のフォールバック・VoiceOver。
- `partnerWaiting` は REQUIREMENTS §3.10 が指定する「相手が先に完了」の言い方。責める語ではない。
- `voicePending = "まだ"` は状態語（完了 / まだ）。禁止語の「まだやってない」とは別で、GROWTH §5.4 の指定どおり。
- `emptyMessage = "アプリを開いてはじめよう"` は、ウィジェットがアプリの状態を知らないための文言。タップでアプリが開くので、そのまま採用。

| 名前 | 文言（代表） | 判定 | メモ |
|---|---|---|---|
| `Widget.displayName` | Lien | OK | ホーム画面・ウィジェットの表示名 |
| `Widget.description` | ふたりの約束をそっと見守ります | OK | ウィジェットギャラリーの説明 |
| `Widget.emptyTitle` | Lien | OK | 空状態（snapshot なし） |
| `Widget.emptyMessage` | アプリを開いてはじめよう | OK | 空状態。アプリを開く導線 |
| `Widget.meFallbackLabel` | じぶん | OK | 約束名が未設定のときのラベル |
| `Widget.partnerFallbackLabel` | あいて | OK | 約束名が未設定のときのラベル |
| `Widget.soloCaption` | ペアになると、タネの子が目をさますよ | OK | ソロの空状態。ホームと同文言 |
| `Widget.partnerWaiting` | ゆうきが待ってるよ | OK | §3.10 の表示原則（相手が先に完了） / 代表値。全3通りを確認 |
| `Widget.partnerStatus` | ゆうき: 完了 | OK | VoiceOver。名前＋完了/まだ / 代表値。全6通りを確認 |
| `Widget.streakDays` | 0日 | OK | 日数（0日も表示できる） / 代表値。全4通りを確認 |
| `Widget.streakSpoken` | ふたりの記録: 0日 | OK | VoiceOver。インラインのストリーク / 代表値。全4通りを確認 |

### 7.2 オンボーディング

- 対象は 23 単位（3ページ＋規約同意＋匿名開始の注意＋通知プレ許可＋入力エラー）。アイコンの名前は §7.23 に分けた（2026-10-26 に絵文字24種からタネの子のイラスト12種に替えた）。
- 規約同意は App Store ガイドライン 1.2 の明示同意。`consentNote` で通報・ペア解消にも触れ、同意の前に手段を示している。
- `anonymousStartNote` は DESIGN §10 の「機種変更・入れ直しで引き継げない場合がある」の明示（T24 の代替）。設定の `accountFooter` と同じ事実。
- 入力エラーは「入力してね」（誘い）と「8文字までです」（事実）の2種類。同じ画面で混ぜているが、役割が違うため統一しない。

| 名前 | 文言（代表） | 判定 | メモ |
|---|---|---|---|
| `Onboarding.stepIndicator` | 3ステップ中1 | OK | 3画面の目印の読み上げ。先の見通しを示す |
| `Onboarding.conceptTitle` | ふたりで、ひとつの約束 | OK | タグライン |
| `Onboarding.conceptBody` | 大切な人と約束をひとつだけ決めて、⏎毎日そっと続けていくアプリです。 | OK | オンボ1。改行を含む |
| `Onboarding.conceptNote` | ひとりで始めて、あとから相手を招待できます | OK | オンボ1。ひとり開始の案内 |
| `Onboarding.conceptStart` | はじめる | OK | オンボ1 のボタン |
| `Onboarding.profileTitle` | あなたのことを教えてね | OK | オンボ2 |
| `Onboarding.nicknamePlaceholder` | ニックネーム(8文字まで) | OK | 上限（8文字）を明示 |
| `Onboarding.nicknameEmptyError` | ニックネームを入力してね | OK | 入力エラー。責めない |
| `Onboarding.nicknameTooLongError` | ニックネームは8文字までです | OK | 上限エラー。事実だけ |
| `Onboarding.nicknameRequiredHint` | ニックネームを入れると、次へ進めます | OK | 無効ボタンの理由。責めない |
| `Onboarding.consentRequiredHint` | 利用規約とプライバシーポリシーへの同意が必要です | OK | 無効ボタンの理由。事実だけ |
| `Onboarding.avatarTitle` | アイコンをえらんでね | OK | オンボ2 |
| `Onboarding.profileSubmit` | 同意してはじめる | OK | 規約への同意が入るまで無効 |
| `Onboarding.anonymousStartNote` | 登録なしですぐ始められます。機種変更やアプリの入れ直しでは、記録を引き継げない場合があります。 | OK | DESIGN §10。機種変更の注意（T24 の代替） |
| `Onboarding.notificationTitle` | おしらせを受け取る | OK | OS ダイアログ前のプレ許可 |
| `Onboarding.notificationBody` | 相手がチェックインしたときや、⏎約束の時間をそっとお知らせします。 | OK | 同上。改行を含む |
| `Onboarding.notificationAllow` | 通知を許可する | OK | 許可を選ぶ |
| `Onboarding.notificationLater` | あとで | OK | あとで（拒否しても完了できる） |
| `Onboarding.submitErrorMessage` | 通信がうまくいきませんでした。もう一度お試しください | OK | 送信失敗。同じ画面でリトライ可 |
| `Onboarding.retry` | もう一度ためす | OK | 失敗後のボタン |
| `Onboarding.consentLabel` | 利用規約とプライバシーポリシーに同意します | OK | App Store 1.2。明示の同意 |
| `Onboarding.consentTermsLink` | 利用規約を読む | OK | 規約へのリンク |
| `Onboarding.consentPrivacyLink` | プライバシーポリシーを読む | OK | ポリシーへのリンク |
| `Onboarding.consentNote` | 不適切な写真や言葉、迷惑行為は禁止されています。気になる内容は、画面を長押しして通報したり、ペアを解消したりできます。 | OK | 通報・ペア解消の案内（1.2） |
| `Onboarding.consentCheckedValue` | 同意済み | OK | VoiceOver の値 |
| `Onboarding.consentUncheckedValue` | 未同意 | OK | VoiceOver の値 |

### 7.3 招待・ペアリング

- 対象は 23 単位（発行・受諾・期限・エラー8種）。
- 発行は「リンク・QRコード・8文字のコード」の3導線。`shareMessage` はタグライン「ふたりで、ひとつの約束」をそのまま使う。
- 受諾のエラーは、原因（期限切れ・使用済み・存在しない・別ペア・自分の招待・形式）ごとに次の一歩がある。
- `errorAlreadyPaired` だけは次の一歩が無いが、起きうるのは例外的な経路で、シートを閉じればホームに戻れる。文言は事実のみで責めない。
- `closeButton = "あとで"` は、招待が任意であることを示す。ここだけ「閉じる」にしない。

| 名前 | 文言（代表） | 判定 | メモ |
|---|---|---|---|
| `Pairing.title` | ふたりをつなぐ | OK | 招待画面 |
| `Pairing.subtitle` | 大切な人を招待して、ひとつの約束をはじめよう。 | OK | 招待画面 |
| `Pairing.inviteSectionTitle` | 招待をおくる | OK | 招待を発行する側 |
| `Pairing.inviteExplainer` | リンク・QRコード・8文字のコード、どれでも招待できます。 | OK | 3導線（リンク・QR・コード）の説明 |
| `Pairing.issueButton` | 招待をつくる | OK | 招待をつくる |
| `Pairing.codeCaption` | 招待コード | OK | コード表示の見出し |
| `Pairing.qrCaption` | QRコードを読み取ってもらってね | OK | QR の説明 |
| `Pairing.shareButton` | リンクをおくる | OK | 共有シートを開く |
| `Pairing.shareMessage` | Lienで、ふたりでひとつの約束をはじめませんか? | OK | 共有文。タグラインの再現 |
| `Pairing.closeButton` | あとで | OK | 招待は任意。シートを閉じる |
| `Pairing.acceptSectionTitle` | コードを入力 | OK | コードで受諾する側 |
| `Pairing.acceptExplainer` | 相手から受け取った8文字のコードを入れてね。 | OK | 8文字のコードの案内 |
| `Pairing.codePlaceholder` | 例: AbCd2345 | OK | 入力例 |
| `Pairing.acceptButton` | ペアになる | OK | 受諾 |
| `Pairing.errorAlreadyPaired` | すでにペアが成立しています | OK | 事実のみ。画面を閉じられる |
| `Pairing.errorPartnerAlreadyPaired` | 招待をくれた相手は、すでにべつのペアをはじめているみたい | OK | 相手の状況。責めない |
| `Pairing.errorInviteNotFound` | この招待が見つかりませんでした。コードをもう一度確かめてみてね | OK | コードの確認を促す |
| `Pairing.errorInviteExpired` | この招待は期限が切れています。新しい招待をもらってね | OK | 新しい招待へ |
| `Pairing.errorInviteAlreadyUsed` | この招待はすでに使われています。新しい招待をもらってね | OK | 新しい招待へ |
| `Pairing.errorCannotAcceptOwnInvite` | これは自分がつくった招待です。相手に送ってあげてね | OK | 送る側へ案内 |
| `Pairing.errorInvalidTokenFormat` | コードは8文字の英数字です | OK | 形式を明示 |
| `Pairing.errorNetwork` | 通信がうまくいきませんでした。もう一度お試しください | OK | 通信エラー。リトライ |
| `Pairing.expiresNote` | 2026年10月20日 21:00 まで有効・1回かぎりの招待です | OK | 期限と1回限りを明示 / 代表値。全2通りを確認 |

### 7.4 約束設定

- 対象は 12 単位。入力・リマインド・保存・寛容設計の一言。
- 2026-10-26 追記: 約束の絵文字は UI から廃止した(オーナー判断。JOURNAL 2026-10-26)ため、`PromiseSetup.emojiSectionTitle`(絵文字をえらんでね)と `PromiseSetup.emojiPalette`(24種)の2単位をこのログから外した。文言の判定は変えていない。
- `editKeepsStreakNote = "約束を変えても、ふたりの記録はそのまま続きます"` が §3.3 の寛容設計の要。罰なしの原則を最もよく表す一文。
- 入力エラーは空欄と20文字超の2つだけ。上限は placeholder にも書いてある。
- `remindToggleLabel = "毎日そっとお知らせ"` は通知を強制しない言い方。`remindTimeLabel = "時刻"` は短いラベル。

| 名前 | 文言（代表） | 判定 | メモ |
|---|---|---|---|
| `PromiseSetup.title` | あなたの約束をきめよう | OK | 約束設定 |
| `PromiseSetup.subtitle` | 毎日続けたいことを、ひとつだけ。⏎あとからいつでも変えられます。 | OK | 変更しても記録は続く |
| `PromiseSetup.titleSectionTitle` | 約束 | OK | 入力欄の見出し |
| `PromiseSetup.titlePlaceholder` | 例: まいにち散歩(20文字まで) | OK | 上限（20文字）を明示 |
| `PromiseSetup.titleEmptyError` | 約束を入力してね | OK | 入力エラー。責めない |
| `PromiseSetup.titleTooLongError` | 約束は20文字までです | OK | 上限エラー。事実だけ |
| `PromiseSetup.remindSectionTitle` | リマインド | OK | リマインド（任意） |
| `PromiseSetup.remindToggleLabel` | 毎日そっとお知らせ | OK | リマインドの ON/OFF |
| `PromiseSetup.remindTimeLabel` | 時刻 | OK | 時刻 |
| `PromiseSetup.saveButton` | この約束にする | OK | 保存 |
| `PromiseSetup.editKeepsStreakNote` | 約束を変えても、ふたりの記録はそのまま続きます | OK | 寛容設計（§3.3） |
| `PromiseSetup.saveErrorMessage` | 通信がうまくいきませんでした。もう一度お試しください | OK | 通信エラー。リトライ |

### 7.5 植物（タネの子）

- 対象は 55 単位（段階名10・ゲージ4・VoiceOver 6・演出・おかえり・名前付け・今日のひとこと）。
- ゲージの文は「あと◯回」「◯回そろったよ」だけで、減る・枯れる・遅れるに触れない（GROWTH §5.1）。
- おかえりは `welcomeBackBody = "また いっしょに"` のみ。空いた日数を出さない（GROWTH §4.4）。
- 名前付けの `nameInvalidError` を「改行や見えない文字は、名前に使えません」に直した。何を直せばよいかが分かる。
- 今日のひとことは、ふたり達成・相手だけ・自分だけ・すやすや・時間帯・段階の6群。相手を責める言い方（「まだやってない」等）はない。
- `voicePending = "まだ"` と `Whisper.meDone` の「ねんね中」は、状態の言い換えであって責める語ではない（「まだ」は §6.3、「ねんね中」は相手の葉の状態の比喩）。

| 名前 | 文言（代表） | 判定 | メモ |
|---|---|---|---|
| `Plant.stageNames` | たね / ふたば / めばえ / わかば / よりそい / つぼみ / いろづき / ほころび / ふたりざき / みのり | OK | 10段階の名前（たね〜みのり） / 10段階 |
| `Plant.stageName` | たね | OK | 範囲外は 0〜9 に丸める / 代表値。全13通りを確認 |
| `Plant.gaugeRemaining` | ふたりそろって あと0回で めばえ | OK | ゲージ。残り回数（罰なし） / 代表値。全12通りを確認 |
| `Plant.gaugeSinceStage` | めばえになってから 0回そろったよ | OK | ゲージ。長い区間の前半 / 代表値。全12通りを確認 |
| `Plant.gaugeLast` | ふたりで 0回 そろったよ | OK | ゲージ。みのり以降 / 代表値。全4通りを確認 |
| `Plant.gaugeUnknownNext` | あと0回で つぎの おたのしみ | OK | ゲージ。知らない段階（1.0.1 の花壇） / 代表値。全4通りを確認 |
| `Plant.stageUpBody` | ふたりで 0回 そろったよ | OK | 段階アップの演出（日数） / 代表値。全4通りを確認 |
| `Plant.stageUpHeadline` | たねになった! | OK | 段階アップの演出 / 代表値。全10通りを確認 |
| `Plant.celebrationBefore` | さっきまで: たね | OK | VoiceOver（変わる前） / 代表値。全10通りを確認 |
| `Plant.celebrationAfter` | いま: たね | OK | VoiceOver（変えた後） / 代表値。全10通りを確認 |
| `Plant.voiceHeader` | みどり、たね | OK | VoiceOver。名前、段階名 / 代表値。全20通りを確認 |
| `Plant.voiceStatus` | あなた: まだ、ゆうき: まだ | OK | VoiceOver。あなた＋相手 / 代表値。全12通りを確認 |
| `Plant.celebrationHeart` | ゆうきにハートを送る | OK | リアクション（T15） / 代表値。全3通りを確認 |
| `Plant.nameSavedNote` | 『ゆうき』と名づけたよ | OK | 自分が付けた / 代表値。全3通りを確認 |
| `Plant.nameAdoptedNote` | 名前は『ゆうき』になったよ | OK | 相手が先に付けていた（409） / 代表値。全3通りを確認 |
| `Plant.nameFirstNotice` | 名前が『ゆうき』になったよ | OK | 相手が初めて付けた / 代表値。全3通りを確認 |
| `Plant.nameChangedNotice` | 名前が『ゆうき』にかわったよ | OK | 相手が変えた / 代表値。全3通りを確認 |
| `Plant.Whisper.bothDone` | ふたりの葉、そろってひらいたね | OK | 今日のひとこと。ふたり達成 / 全12通りを確認（代表を1行表示） |
| `Plant.Whisper.partnerDone` | ゆうきの葉、ひらいたよ | OK | 今日のひとこと。相手だけ完了 / 全12通りを確認（代表を1行表示） |
| `Plant.Whisper.meDone` | ひらいたよ。ゆうきの葉は ねんね中 | OK | 今日のひとこと。自分だけ完了 / 全9通りを確認（代表を1行表示） |
| `Plant.voiceDone` | 完了 | OK | VoiceOver の状態語 |
| `Plant.voicePending` | まだ | OK | VoiceOver の状態語（GROWTH §5.4 の「まだ」） |
| `Plant.voiceSolo` | 土の中で眠るタネの子 | OK | VoiceOver。ソロ |
| `Plant.renameHint` | ダブルタップで、名前を変えます | OK | VoiceOver のヒント |
| `Plant.whisperAction` | タネの子のひとこと | OK | VoiceOver のアクション名 |
| `Plant.meetingHeadline` | はじめまして! | OK | 段階0 の演出 |
| `Plant.meetingBody` | タネの子が、目をさましたよ | OK | 段階0 の演出 |
| `Plant.celebrationClose` | 閉じる | 修正 | **ほかの閉じるボタン（閉じる）に統一** / 演出を閉じる |
| `Plant.celebrationHeartSending` | 送っています… | OK | 送信中 |
| `Plant.celebrationHeartSent` | ハートを送ったよ | OK | 送信済み |
| `Plant.celebrationHeartError` | 送れませんでした。あとでもう一度お試しください | OK | 通信エラー。リトライ可 |
| `Plant.welcomeBackHeadline` | おかえり | OK | おかえり（日数を出さない） |
| `Plant.welcomeBackBody` | また いっしょに | OK | おかえり（日数を出さない） |
| `Plant.nameTitle` | 名前をつけてあげよう | OK | 名前付け |
| `Plant.renameTitle` | 名前を変える | 修正 | **同じ画面の「変えます」に合わせる** / 名前を変える |
| `Plant.namePlaceholder` | なまえ(8文字まで) | OK | 上限（8文字）を明示 |
| `Plant.nameNote` | どちらかが先につけると、その名前に決まります。あとからいつでも変えられます。 | OK | 先に付けた人の名前に決まる |
| `Plant.nameSubmit` | 名前をつける | OK | 名前をつける |
| `Plant.renameSubmit` | この名前にする | OK | この名前にする |
| `Plant.nameSaving` | 保存しています… | OK | 保存中 |
| `Plant.nameLater` | あとで | OK | あとで |
| `Plant.nameCancel` | やめる | OK | やめる |
| `Plant.nameButton` | 名前をつける | OK | 名前が無いときのホームのボタン |
| `Plant.nameEmptyError` | 名前を入力してね | OK | 入力エラー。責めない |
| `Plant.nameTooLongError` | 名前は8文字までです | OK | 上限エラー。事実だけ |
| `Plant.nameInvalidError` | 改行や見えない文字は、名前に使えません | 修正 | **何が使えないか（改行・見えない文字）を明示** / 何が使えないかを明示 |
| `Plant.nameSaveError` | 保存できませんでした。通信状態を確認して、もう一度お試しください | OK | 通信エラー。下書きは残る |
| `Plant.nameNoPairError` | いまはペアがいないので、名前をつけられません | OK | ペアが無いときの案内 |
| `Plant.nameNoticeClose` | 閉じる | OK | 知らせを閉じる |
| `Plant.Whisper.sleepy` | すやすや…ふたりのペースで いいよ | OK | 今日のひとこと。すやすや（休みの日） / 全3通りを確認（代表を1行表示） |
| `Plant.Whisper.morning` | おはよう。きょうも ふたりのペースでね | OK | 今日のひとこと。朝 / 全4通りを確認（代表を1行表示） |
| `Plant.Whisper.daytime` | おひるだね。ひとやすみも いいね | OK | 今日のひとこと。昼 / 全3通りを確認（代表を1行表示） |
| `Plant.Whisper.evening` | 夕方だね。きょうも おつかれさま | OK | 今日のひとこと。夕方 / 全3通りを確認（代表を1行表示） |
| `Plant.Whisper.night` | もう夜だね。おやすみの じゅんび? | OK | 今日のひとこと。夜 / 全3通りを確認（代表を1行表示） |
| `Plant.Whisper.stage` | ふたば、にあう? | OK | 今日のひとこと。段階ごと / 全10通りを確認（代表を1行表示） |

### 7.6 ホーム

- 対象は 17 単位。ストリーク・ふたりの今日・チェックイン・空状態・ソロ。
- ストリークの呼び名は「ふたりの記録」に統一。最高記録は `streakBestNote` で残す（§3.5）。
- `promiseUnsetLabel = "約束はこれから"` は、未設定を責めない言い方。設定側の `promiseUnset = "まだ決めていません"` と役割を分ける。
- `partnerWaiting` は §3.10 の指定文言。`bothDoneCelebration = "ふたり達成!"` は罰なしの到達点。
- 空状態は snapshot 未取得のときだけ。文言は「準備しています」で、失敗とは言わない（失敗時の扱いは §6.1）。

| 名前 | 文言（代表） | 判定 | メモ |
|---|---|---|---|
| `Home.soloCaption` | ペアになると、タネの子が目をさますよ | OK | ソロの空状態。ウィジェットと同文言 |
| `Home.soloInviteHint` | 招待した相手とペアになると、ふたりの約束がはじまります | OK | ソロの誘導（招待の動機付け） |
| `Home.inviteButton` | 相手を招待する | OK | ソロのホームの招待ボタン |
| `Home.streakCaption` | ふたりの記録 | OK | 「ふたりの記録」。ユーザー向けの呼び名 |
| `Home.todaySectionTitle` | ふたりの今日 | OK | ふたりの今日 |
| `Home.meFallbackLabel` | じぶん | OK | 約束名が未設定のときのラベル |
| `Home.partnerFallbackLabel` | あいて | OK | 約束名が未設定のときのラベル |
| `Home.promiseUnsetLabel` | 約束はこれから | OK | 約束が未設定。責めない |
| `Home.bothDoneCelebration` | ふたり達成! | OK | 両者完了の演出 |
| `Home.checkinButton` | できた! | OK | チェックイン |
| `Home.checkinDoneLabel` | 今日のぶんは完了 | OK | 完了済み |
| `Home.checkinErrorMessage` | 通信がうまくいきませんでした。もう一度お試しください | OK | 通信エラー。リトライ |
| `Home.emptyTitle` | Lien | OK | 空状態（snapshot 未取得） |
| `Home.emptyMessage` | ふたりの今日を準備しています | OK | 空状態・初回同期待ち |
| `Home.streakDays` | 0日 | OK | 日数 / 代表値。全4通りを確認 |
| `Home.streakBestNote` | 最高記録 0日 | OK | 最高記録は残す（§3.5） / 代表値。全4通りを確認 |
| `Home.partnerWaiting` | ゆうきが待ってるよ | OK | §3.10 の表示原則 / 代表値。全3通りを確認 |

### 7.7 チェックインフロー

- 対象は 10 単位。写真添付（任意・当日1枚）と当日取消（誤タップ対応）。
- 取消の確認は `cancelDialogMessage = "まちがえてタップしたときのために。いつでもまたチェックインできます"`。責めず、戻り道を示す。
- 写真の送信中を「写真をおくっています…」から「写真を送っています…」に直し、エラー文言の「送れませんでした」と動詞を揃えた。
- 写真は失敗してもチェックイン自体は完了している。エラーは「もう一度お試しください」で、取り消しを促さない。

| 名前 | 文言（代表） | 判定 | メモ |
|---|---|---|---|
| `Checkin.attachPhotoButton` | 写真を添える | OK | 写真を添える（任意） |
| `Checkin.attachPhotoSending` | 写真を送っています… | 修正 | **エラー文言の「送れませんでした」と動詞を統一** / 送信中 |
| `Checkin.attachPhotoDoneNote` | 今日の写真を添えました | OK | 添付できた |
| `Checkin.attachPhotoErrorMessage` | 写真を送れませんでした。もう一度お試しください | OK | 写真の送信失敗。リトライ |
| `Checkin.cancelButton` | 取り消す | OK | 当日取消 |
| `Checkin.cancelDialogTitle` | 今日のチェックインを取り消しますか? | OK | 取消の確認 |
| `Checkin.cancelDialogMessage` | まちがえてタップしたときのために。いつでもまたチェックインできます | OK | 誤タップ対応。責めない |
| `Checkin.cancelConfirm` | 取り消す | OK | 取り消す |
| `Checkin.cancelKeep` | そのままにする | OK | そのままにする |
| `Checkin.cancelErrorMessage` | 通信がうまくいきませんでした。もう一度お試しください | OK | 通信エラー。リトライ |

### 7.8 つつく

- 対象は 6 単位。自由テキストを持たず、スタンプ6種だけ（チャット化を避ける）。
- `limitReachedMessage = "今日はもうたくさんつついたよ。また明日ね"` は、1日3回の上限を責めずに伝える。
- `sentNote = "つつきました"` はセッション内の確認だけ。送信済みを強調し続けない。

| 名前 | 文言（代表） | 判定 | メモ |
|---|---|---|---|
| `Nudge.button` | つつく | OK | つつく（相手が未完のときだけ） |
| `Nudge.sheetTitle` | スタンプでつつく | OK | スタンプを選ぶ |
| `Nudge.sheetSubtitle` | ひとことの代わりに、スタンプを送ってみよう | OK | 自由テキストは無し |
| `Nudge.sentNote` | つつきました | OK | 送信済み |
| `Nudge.limitReachedMessage` | 今日はもうたくさんつついたよ。また明日ね | OK | 1日3回の上限。責めない |
| `Nudge.errorMessage` | 通信がうまくいきませんでした。もう一度お試しください | OK | 通信エラー。リトライ |

### 7.9 リアクション

- 対象は 4 単位。相手の今日のチェックインにスタンプ1つ。
- 文言は「リアクション」で統一。`sentNote = "リアクションしました"` は送信の確認だけ。
- 失敗は汎用の通信エラー。責める語・相手を急かす語はない。

| 名前 | 文言（代表） | 判定 | メモ |
|---|---|---|---|
| `Reaction.button` | リアクション | OK | リアクションの導線 |
| `Reaction.sheetTitle` | スタンプでリアクション | OK | スタンプを選ぶ |
| `Reaction.sentNote` | リアクションしました | OK | 送信済み |
| `Reaction.errorMessage` | 通信がうまくいきませんでした。もう一度お試しください | OK | 通信エラー。リトライ |

### 7.10 相手の今日の写真

- 対象は 6 単位。見出し・VoiceOver・読み込み中・全画面・通報メニュー。
- 写真が無い日・読み込みに失敗したときは**何も出さない**（§3.11）。「写真がありません」と書かないことで、相手を責めない。
- 全画面でも通報・ブロックに届く（`viewerMenuButton`）。App Store ガイドライン 1.2 の導線。
- `viewerCloseButton` を「とじる」から「閉じる」に統一した。

| 名前 | 文言（代表） | 判定 | メモ |
|---|---|---|---|
| `PartnerPhoto.openHint` | タップで大きく見ます | OK | VoiceOver のヒント |
| `PartnerPhoto.loadingLabel` | 写真を読み込んでいます | OK | 読み込み中の VoiceOver 名 |
| `PartnerPhoto.viewerCloseButton` | 閉じる | 修正 | **ほかの閉じるボタン（閉じる）に統一** / 全画面を閉じる |
| `PartnerPhoto.viewerMenuButton` | 通報・ブロック | OK | 通報・ブロック（1.2） |
| `PartnerPhoto.caption` | ゆうきの今日の写真 | OK | 写真の見出し（VoiceOver 名） / 代表値。全3通りを確認 |
| `PartnerPhoto.viewerLabel` | ゆうきの今日の写真(大きい表示) | OK | 全画面の VoiceOver 名 / 代表値。全3通りを確認 |

### 7.11 設定

- 対象は 37 単位。プロフィール・約束・通知・ペア・サポート・アカウント・バージョン。
- 説明（footer）は事実を並べ、不安を煽らない。解消・削除は「何が起きるか」を先に書く。
- `loadFailed = "読み込めませんでした"` は短いが、同じ行に `retry = "もう一度ためす"` がある。単独で不安を残さない。
- `accountFooter` は匿名開始の注意。オンボの `anonymousStartNote` と同じ事実を、設定でも読めるようにしている（DESIGN §10）。
- `soloNote` は「いまはひとりで使っています」と状態を書き、招待の導線を残す。責めない。

| 名前 | 文言（代表） | 判定 | メモ |
|---|---|---|---|
| `Settings.title` | 設定 | OK | 設定 |
| `Settings.closeButton` | 閉じる | OK | 閉じる |
| `Settings.openButtonLabel` | 設定 | OK | 歯車の VoiceOver 名 |
| `Settings.profileSection` | プロフィール | OK | プロフィール |
| `Settings.nicknameLabel` | ニックネーム | OK | ニックネーム |
| `Settings.loadFailed` | 読み込めませんでした | OK | 読み込み失敗。再試行ボタンと対 |
| `Settings.retry` | もう一度ためす | OK | 再試行 |
| `Settings.profileEditTitle` | プロフィールを編集 | OK | プロフィール編集 |
| `Settings.profileEditFooter` | ニックネームとアイコンは、ペアの相手にも表示されます。 | OK | 相手にも表示される |
| `Settings.profileSave` | 保存する | OK | 保存 |
| `Settings.profileSaving` | 保存しています… | OK | 保存中 |
| `Settings.profileSavedNote` | プロフィールを保存しました | OK | 保存できた |
| `Settings.profileSaveError` | 保存できませんでした。通信状態を確認して、もう一度お試しください | OK | 通信エラー。リトライ |
| `Settings.promiseSection` | 約束 | OK | 約束 |
| `Settings.promiseUnset` | まだ決めていません | OK | 未設定。責めない |
| `Settings.promiseEditRow` | 約束を変える | OK | 約束の編集 |
| `Settings.promiseSavedNote` | 約束を保存しました | OK | 保存できた |
| `Settings.notificationSection` | 通知 | OK | 通知 |
| `Settings.notificationRow` | リマインドとお知らせ | OK | 通知設定への入口 |
| `Settings.notificationFooter` | リマインドの時刻や、ふたりの記録のお知らせを変えられます。 | OK | 通知設定の説明 |
| `Settings.pairSection` | ペア | OK | ペア |
| `Settings.partnerLabel` | ペアの相手 | OK | ペアの相手 |
| `Settings.soloNote` | いまはひとりで使っています。相手を招待すると、ここからペアの管理ができます。 | OK | ソロの説明。責めない |
| `Settings.dissolveRow` | ペアを解消する | OK | ペア解消への入口 |
| `Settings.dissolveFooter` | ペアを解消すると、相手との共有がすべて止まります。いつでもまた新しい相手を招待できます。 | OK | 解消の説明（事実） |
| `Settings.dissolvedNote` | ペアを解消しました | OK | 解消できた |
| `Settings.supportSection` | サポート | OK | サポート |
| `Settings.contactRow` | お問い合わせ | OK | お問い合わせ |
| `Settings.reportRow` | 不適切な内容を通報する | OK | 通報 |
| `Settings.termsRow` | 利用規約 | OK | 利用規約 |
| `Settings.privacyRow` | プライバシーポリシー | OK | プライバシーポリシー |
| `Settings.supportFooter` | 相手の写真・ニックネーム・約束の文は、ホームで長押しして通報することもできます。 | OK | 長押しでも通報できる |
| `Settings.accountSection` | アカウント | OK | アカウント |
| `Settings.signOutRow` | サインアウト | OK | サインアウト |
| `Settings.deleteRow` | アカウントを削除する | OK | アカウント削除 |
| `Settings.accountFooter` | 登録なしで始めたので、機種変更やアプリの入れ直しで記録を引き継げない場合があります。 | OK | 機種変更の注意（DESIGN §10） |
| `Settings.versionLabel` | バージョン | OK | バージョン |

### 7.12 端末のローカル通知

- 対象は 5 単位（リマインド3通り・夜9時のストリーク危機3通り・タイトル）。
- リマインドは REQUIREMENTS §3.12 の例を含む3通り。約束名が入る(約束の絵文字は 2026-10-26 に UI から廃止したので、本文の末尾に付けない)。
- 夜9時は「あと3時間。ふたりの◯日を、いっしょに守ろう🌱」。損失をちらつかせず、前向きな呼びかけにした（GROWTH §6.6）。
- 相手が先に完了しているときは「◯◯が待ってるよ」。アプリ内の §3.10 と同じ言い方。
- 予約後に状況が変わって届いても困らないよう、「まだなら」の条件付きの文にしてある。

| 名前 | 文言（代表） | 判定 | メモ |
|---|---|---|---|
| `LocalNotification.title` | Lien | OK | 通知の名義は常に Lien |
| `LocalNotification.reminderBodies` | 今日の『筋トレ』、まだ間に合うよ | OK | リマインド3通り。§3.12 の例を含む。約束の絵文字は付けない(2026-10-26 に UI から廃止。末尾の💪を外した) / 全6通りを確認（代表を1行表示） |
| `LocalNotification.streakRiskNeither` | あと3時間。ふたりの0日を、いっしょに守ろう🌱 | OK | 夜9時。損失をちらつかせない（GROWTH §6.6） / 代表値。全4通りを確認 |
| `LocalNotification.streakRiskPartnerDone` | ゆうきが待ってるよ。あと3時間、ふたりの0日を守ろう🌱 | OK | 夜9時。相手が待っている（§3.10） / 代表値。全12通りを確認 |
| `LocalNotification.streakRiskMeDone` | あと3時間。ゆうきがまだなら、「つつく」で声をかけてみよう。ふたりの0日を守れるよ | OK | 夜9時。つつくを案内 / 代表値。全12通りを確認 |

### 7.13 通知の設定

- 対象は 21 単位。拒否時の案内・リマインド・夜9時・相手からの通知・状態表示。
- `deniedNotice` は OS の設定アプリへ誘導する。アプリ内で解決できないことを明示。
- `reminderNoPromise = "約束を決めると、リマインドを設定できます。"` は、約束が無いことを責めない。
- `partnerFooter` は「iOS の設定で通知をオフにすると、リマインドや夜9時を含め、Lien の通知がすべて止まる」と明示。相手の通知だけを切れるとは読ませない（T16 のレビュー指摘）。
- `streakFooter` は夜9時の条件（続いていて、その日まだそろっていないときだけ）を説明。

| 名前 | 文言（代表） | 判定 | メモ |
|---|---|---|---|
| `NotificationSettings.title` | 通知 | OK | 通知の設定 |
| `NotificationSettings.deniedNotice` | 通知が許可されていません。iOS の設定アプリで許可すると、お知らせが届きます。 | OK | OS で拒否されているときの案内 |
| `NotificationSettings.reminderSection` | リマインド | OK | リマインド |
| `NotificationSettings.reminderToggle` | 毎日そっとお知らせ | OK | リマインドの ON/OFF |
| `NotificationSettings.reminderTime` | 時刻 | OK | 時刻 |
| `NotificationSettings.reminderFooter` | 決めた時刻に、約束をそっとお知らせします。その日の分ができていたら、お知らせしません。 | OK | 済んだ日は出さない |
| `NotificationSettings.reminderNoPromise` | 約束を決めると、リマインドを設定できます。 | OK | 約束が無いとき。責めない |
| `NotificationSettings.reminderSave` | 保存する | OK | 保存 |
| `NotificationSettings.reminderSaving` | 保存しています… | OK | 保存中 |
| `NotificationSettings.reminderSaved` | リマインドを保存しました | OK | 保存できた |
| `NotificationSettings.reminderSaveError` | 保存できませんでした。通信状態を確認して、もう一度お試しください | OK | 通信エラー。リトライ |
| `NotificationSettings.loadFailed` | 読み込めませんでした | OK | 読み込み失敗 |
| `NotificationSettings.retry` | もう一度ためす | OK | 再試行 |
| `NotificationSettings.streakSection` | ふたりの記録 | OK | ふたりの記録 |
| `NotificationSettings.streakToggle` | 夜9時のお知らせ | OK | 夜9時の ON/OFF |
| `NotificationSettings.streakFooter` | ふたりの記録が続いていて、その日まだふたりそろっていないときだけ、夜9時に一度お知らせします。ふたりそろったら、お知らせしません。 | OK | 夜9時の条件を説明 |
| `NotificationSettings.partnerSection` | 相手からの通知 | OK | 相手からの通知 |
| `NotificationSettings.partnerFooter` | 相手のチェックイン・つつく・リアクションの通知は、アプリの中では切り替えられません。iOS の設定アプリで通知をオフにすると、リマインドや夜9時のお知らせを含め、Lien の通知がすべて止まります。 | OK | アプリ内では切り替えられない（v1.0） |
| `NotificationSettings.openSystemSettings` | iOS の通知設定を開く | OK | iOS の設定を開く |
| `NotificationSettings.summaryOff` | オフ | OK | 設定行の右側（オフ） |
| `NotificationSettings.summaryDaily` | 毎日 20:00 | OK | 設定行の右側（毎日 HH:MM） / 代表値。全2通りを確認 |

### 7.14 サインアウト

- 対象は 4 単位。確認は1段階。
- `confirmMessage` は長いが、匿名アカウントの性質上、戻れないこと・サーバーに残る記録を消せないことを先に伝える必要がある。事実のみで責めない。
- 「やめる」を用意し、取り返しのつくうちに止められる。

| 名前 | 文言（代表） | 判定 | メモ |
|---|---|---|---|
| `SignOut.confirmTitle` | サインアウトしますか? | OK | 確認 |
| `SignOut.confirmMessage` | この端末の記録は消えます。登録なしで始めたので、同じ記録には戻れません。ペアの相手とのつながりも、この端末からは戻せなくなります。サーバーに残る記録は、サインアウトしたあとでは削除できません。記録も消したいときは、先に「アカウントを削除する」を選んでください。 | OK | 取り返しのつくうちに止める（事実） |
| `SignOut.confirmButton` | サインアウト | OK | サインアウト |
| `SignOut.cancel` | やめる | OK | やめる |

### 7.15 ペアの解消（= ブロック）

- 対象は 14 単位。確認は2段階（説明 → 最後の確認）。
- 何が止まるか（写真・約束・チェックイン・つつく・リアクション・通知）を箇条書きの文で示す。
- `effectArchive` の「ストリーク」「アーカイブ」を、ユーザーの言葉「ふたりの記録」「ここでいったん区切られます」に直した。開発者ことばを画面に出さない。
- `partnerNote` は「相手には通知は届きません」。事実で、脅しではない。
- `finalMessage = "この操作は取り消せません。"` は必要最小限の警告。

| 名前 | 文言（代表） | 判定 | メモ |
|---|---|---|---|
| `Dissolve.screenTitle` | ペアを解消する | OK | ペア解消（= ブロック） |
| `Dissolve.lead` | ペアを解消すると、相手との共有がすべて止まります。 | OK | 何が止まるかの説明 |
| `Dissolve.effectPhotos` | 相手の写真・約束・チェックインは、お互いに見えなくなります | OK | 写真・約束・チェックイン |
| `Dissolve.effectNudges` | つつく・リアクション・通知も、相手とのあいだで届かなくなります | OK | つつく・リアクション・通知 |
| `Dissolve.effectArchive` | 植物とふたりの記録は、ここでいったん区切られます。同じ相手と組み直しても、前の続きにはなりません | 修正 | **「ストリーク」「アーカイブ」をユーザーの言葉に** / 植物と記録。開発者ことばを避ける |
| `Dissolve.effectHistory` | あなたのチェックイン履歴は、あなたの記録として残ります | OK | 自分の履歴は残る |
| `Dissolve.partnerNote` | 相手には通知は届きません。次にアプリを開いたときに、ペアが終わったことがわかります。 | OK | 相手への通知は無い（事実） |
| `Dissolve.button` | ペアを解消する | OK | 解消する |
| `Dissolve.finalTitle` | 本当にペアを解消しますか? | OK | 最後の確認 |
| `Dissolve.finalMessage` | この操作は取り消せません。 | OK | 取り消せない（事実） |
| `Dissolve.finalConfirm` | 解消する | OK | 解消する |
| `Dissolve.cancel` | やめる | OK | やめる |
| `Dissolve.working` | 解消しています… | OK | 処理中 |
| `Dissolve.errorMessage` | うまくいきませんでした。通信状態を確認して、もう一度お試しください | OK | 通信エラー。リトライ |

### 7.16 アカウントの削除

- 対象は 13 単位。確認は2段階。App Store ガイドライン 5.1.1(v) と terms 第8条。
- 何が消えるか（プロフィール・約束・記録・写真・ペアの共有）を列挙し、`irreversible` で元に戻せないことを明示。
- 失敗時は「もう一度押せば、続きから進みます」。途中で止まっても、やり直せることを伝える。

| 名前 | 文言（代表） | 判定 | メモ |
|---|---|---|---|
| `DeleteAccount.screenTitle` | アカウントを削除する | OK | アカウント削除 |
| `DeleteAccount.lead` | アカウントを削除すると、次のものがすべて消えます。 | OK | 何が消えるかの説明 |
| `DeleteAccount.effectProfile` | ニックネーム・約束・チェックインの記録 | OK | プロフィール・約束・記録 |
| `DeleteAccount.effectPhotos` | 添えた写真 | OK | 写真 |
| `DeleteAccount.effectPair` | ペアの相手との共有(いまのペアは解消されます) | OK | ペアの共有 |
| `DeleteAccount.irreversible` | 削除したあとは、元に戻せません。 | OK | 元に戻せない（事実） |
| `DeleteAccount.button` | アカウントを削除する | OK | 削除する |
| `DeleteAccount.finalTitle` | 本当に削除しますか? | OK | 最後の確認 |
| `DeleteAccount.finalMessage` | 削除すると元に戻せません。 | OK | 元に戻せない（事実） |
| `DeleteAccount.finalConfirm` | 削除する | OK | 削除する |
| `DeleteAccount.cancel` | やめる | OK | やめる |
| `DeleteAccount.working` | 削除しています… | OK | 処理中 |
| `DeleteAccount.errorMessage` | 削除できませんでした。通信状態を確認して、もう一度お試しください。もう一度押せば、続きから進みます | OK | 通信エラー。続きから再開できる |

### 7.17 通報

- 対象は 26 単位。長押しメニュー・確認・メールの下書き・種別・項目名。
- 通報は運営宛のメール下書きを開く方式。`confirmMessage` で「内容を確認して、そのまま送信」と手順を示す。
- メールを開けないときは `mailFailedMessage` で設定の確認を促し、`SupportLinks.contactEmail` があれば宛先への直送も案内する。
- ブロックは「ペアを解消」と同じ意味であることを `menuBlock` に書く。

| 名前 | 文言（代表） | 判定 | メモ |
|---|---|---|---|
| `Report.menuReportPhoto` | 写真を通報する | OK | 長押しメニュー |
| `Report.menuReportNickname` | ニックネームを通報する | OK | 長押しメニュー |
| `Report.menuReportPromise` | 約束の文を通報する | OK | 長押しメニュー |
| `Report.menuReportPlantName` | 植物の名前を通報する | OK | 長押しメニュー |
| `Report.menuBlock` | ブロック(ペアを解消) | OK | ブロック（ペア解消） |
| `Report.confirmTitle` | この内容を通報しますか? | OK | 通報の確認 |
| `Report.confirmMessage` | 運営に送るメールの下書きが開きます。内容を確認して、そのまま送信してください。 | OK | メールの下書きが開く |
| `Report.openMail` | メールを開く | OK | メールを開く |
| `Report.cancel` | やめる | OK | やめる |
| `Report.mailFailedTitle` | メールを開けませんでした | OK | メールが開けない |
| `Report.mailFailedMessage` | メールアプリの設定を確認してから、もう一度お試しください。 / メールアプリの設定を確認してから、もう一度お試しください。⏎メールアプリを使わずに、次の宛先へ直接お送りいただいてもかまいません。⏎support@example.com | OK | 設定の確認。宛先の直送も案内 / 2通り |
| `Report.mailFailedOK` | 閉じる | OK | 閉じる |
| `Report.kindPhoto` | 写真 | OK | 通報の種別 |
| `Report.kindNickname` | ニックネーム | OK | 通報の種別 |
| `Report.kindPromise` | 約束の文 | OK | 通報の種別 |
| `Report.kindPlantName` | 植物の名前 | OK | 通報の種別 |
| `Report.kindGeneral` | その他 | OK | 通報の種別 |
| `Report.bodyIntro` | このまま送信してください。気づいたことがあれば、下に書き足してもかまいません。 | OK | 通報メールの本文（運営が読む） |
| `Report.kindLabel` | 種別 | OK | 通報メールの項目 |
| `Report.pairIdLabel` | ペアID | OK | 通報メールの項目 |
| `Report.dateLabel` | 日付 | OK | 通報メールの項目 |
| `Report.targetLabel` | 対象 | OK | 通報メールの項目 |
| `Report.noPair` | (ペアなし) | OK | 通報メールの項目 |
| `Report.appVersionLabel` | アプリのバージョン | OK | 通報メールの項目 |
| `Report.notesLabel` | 補足(任意) | OK | 通報メールの項目 |
| `Report.subject` | 【Lien】通報: 写真 | OK | 通報メールの件名 / 代表値。全5通りを確認 |

### 7.18 お問い合わせ

- 対象は 3 単位。件名・本文の導入・記入例。
- 運営宛のメール下書き。必要最小限で、責める語はない。

| 名前 | 文言（代表） | 判定 | メモ |
|---|---|---|---|
| `Contact.subject` | 【Lien】お問い合わせ | OK | お問い合わせメールの件名 |
| `Contact.bodyIntro` | お問い合わせの内容を、下に書いてください。 | OK | お問い合わせメールの本文 |
| `Contact.bodyPlaceholder` | (お問い合わせの内容) | OK | お問い合わせの記入例 |

### 7.19 ログイン状態

- 対象は 4 単位。セッションが使えなくなったときの確認。
- `lostMessage` は「通信状態が悪いだけのときは『あとで』」を先に書く。破壊的な「はじめからやり直す」を最初に選ばせない。
- 「はじめからやり直す」は端末の記録を消すことを明示。匿名アカウントの性質上、必要。

| 名前 | 文言（代表） | 判定 | メモ |
|---|---|---|---|
| `Session.lostTitle` | ログイン状態を確認できません | OK | セッション無効の確認 |
| `Session.lostMessage` | この端末のログイン情報が使えなくなっているようです。通信状態が悪いだけのときは「あとで」を選んでください。「はじめからやり直す」を選ぶと、この端末の記録を消して、最初の画面に戻ります。 | OK | 「あとで」を先に。取り返しのつくうちに止める |
| `Session.restart` | はじめからやり直す | OK | やり直す（端末の記録を消す） |
| `Session.later` | あとで | OK | あとで |


### 7.20 お休みチケットの残数（残数バッジ — T19a #19）

- 対象は 1 単位。ホームの残数バッジ（表示と VoiceOver で同じ文言）。
- 0 枚も事実として出す（0 枚でもバッジを出す — REQUIREMENTS §3.5・§3.6）。減ったこと自体には触れず、責める語・急かす語を足さない。
- 枚数は半角の数字。単位は「枚」。

| 名前 | 文言（代表） | 判定 | メモ |
|---|---|---|---|
| `Tickets.balance` | お休みチケット 残り0枚 | OK | ホームの残数バッジ / 代表値（0 枚）。0 枚でも出す。罰なし（§3.5） |

### 7.21 ふたりの記録（カレンダー履歴 — T18 #18）

- 対象は 18 単位。月の見出し・曜日・凡例・読み上げ・空状態。
- 用語は「ふたりの記録」（§2-4）。「ストリーク」は使わない。凡例の「じぶんだけ」「あいてだけ」は事実で、責める語を足さない。
- `noRecord` / `beforePair` / `future` / `todayPending` は画面に文字を出さない（VoiceOver の読み上げだけ）。記号に頼らず、状態を言葉で伝える（§2-7）。
- `weekdaySymbols` は日曜はじまり（`Calendar.lienHistory` の `firstWeekday = 1` と揃える）。
- `loadFailed` は「何が起きたか」＋「どうすればよいか」（§2-2）。`retry` は既存の `Settings.retry`（もう一度ためす）より短い形だが、再試行の意味は同じで、責めない。
- `empty` は誘いの文（ペアになると記録がのこる）。まだ無いことを責めない。

| 名前 | 文言（代表） | 判定 | メモ |
|---|---|---|---|
| `History.title` | ふたりの記録 | OK | 画面の題名。用語は「ふたりの記録」（ストリークではない） |
| `History.openButtonLabel` | ふたりの記録を開く | OK | ホームからの導線の VoiceOver |
| `History.previousMonth` | 前の月 | OK | 月を戻す |
| `History.nextMonth` | 次の月 | OK | 月を進める |
| `History.weekdaySymbols` | 日 | OK | 曜日（日曜はじまり） / 代表値。7 種すべて確認 |
| `History.bothDone` | ふたり達成 | OK | 凡例・読み上げ。ストリークの語を使わない |
| `History.meOnly` | じぶんだけ | OK | 凡例・読み上げ。事実で、責めない |
| `History.partnerOnly` | あいてだけ | OK | 凡例・読み上げ。事実で、相手を責めない |
| `History.restTicket` | お休み | OK | お休みチケットで守った日。罰の語を足さない |
| `History.noRecord` | 記録なし | OK | 画面には出さず VoiceOver だけ。事実 |
| `History.beforePair` | ペアになる前 | OK | ペア成立前の日。事実 |
| `History.future` | これから | OK | 未来の日。急かさない |
| `History.todayPending` | 今日 | OK | 確定前の今日。事実 |
| `History.loadFailed` | 記録を読み込めませんでした。通信状態を確認して、もう一度お試しください | OK | 何が起きたか＋どうすればよいか（§2-2）。記録は失われない |
| `History.retry` | もう一度 | OK | 再試行。短い形（`Settings.retry` は「もう一度ためす」） |
| `History.empty` | ペアになると、ふたりの記録がのこります | OK | 空状態。誘いの文で、責めない |
| `History.monthTitle` | 2025年1月 | OK | 月の見出し / 代表値 |
| `History.dayTitle` | 10月1日 | OK | 日を選んだときの見出し / 代表値 |
| `History.dayAccessibility` | 10月5日、ふたり達成 | OK | VoiceOver（名前＋状態 — §2-7） / 代表値。全 5 種を確認 |

### 7.22 シェア画像（T22 #22）

- 対象は 24 単位。シェアのシートと、画像の中に描く文言。
- 画像に**チェックインの写真を含めない**ことを `privacyNote` で明示する（REQUIREMENTS §3.13。プライバシーの約束）。
- 画像の中は「ふたりの記録」「N日」。ストリークの語を使わない（§2-4）。名前が無いときは「あなた」「あいて」— 2 人の名前を並べる文脈なので、ウィジェットの「じぶん」ではなく「あなた」を使う。
- エラーは「何が起きたか」＋「どうすればよいか」（§2-2）。写真・記録が消えるとは書かない。
- 「閉じる」「もう一度ためす」は既存の表記に揃える。

| 名前 | 文言（代表） | 判定 | メモ |
|---|---|---|---|
| `Share.title` | シェア画像 | OK | シートの題名 |
| `Share.createButton` | シェア画像をつくる | OK | ホームの導線。動作の言葉 |
| `Share.shortButton` | シェア | OK | 補助の行に並べる短いラベル |
| `Share.subtitle` | ふたりの記録を、画像にして残せます | OK | 何ができるかの説明 |
| `Share.formatPickerLabel` | 画像の形 | OK | 形の選択の見出し |
| `Share.formatStory` | ストーリーズ(9:16) | OK | 縦。括弧は半角（§2-5） |
| `Share.formatSquare` | 正方形(1:1) | OK | 正方形。括弧は半角（§2-5） |
| `Share.loading` | 画像をつくっています… | OK | 生成中。進行形で、待たせていることを責めない |
| `Share.shareButton` | シェアする | OK | 共有シートを開く |
| `Share.closeButton` | 閉じる | OK | 閉じる（統一 — §2-5） |
| `Share.retry` | もう一度ためす | OK | 再試行。既存の表記に揃える |
| `Share.unavailableMessage` | シェアできる記録がまだありません | OK | 空状態。事実で、責めない |
| `Share.errorMessage` | シェア画像を準備できませんでした。通信状態を確認して、もう一度お試しください | OK | 何が起きたか＋どうすればよいか。記録は失われない |
| `Share.privacyNote` | チェックインの写真は入りません | OK | 写真を含めないことの明示（§3.13） |
| `Share.streakCaption` | ふたりの記録 | OK | 画像の中の見出し。ストリークの語を使わない |
| `Share.dayUnit` | 日 | OK | 画像の中の日数の単位 |
| `Share.meFallbackName` | あなた | OK | 名前が無いとき。2 人の名前を並べる文脈 |
| `Share.partnerFallbackName` | あいて | OK | 名前が無いとき。相手を責めない |
| `Share.milestoneBody` | この記録を、画像にして残そう | OK | 節目のお祝い。誘いの文 |
| `Share.names` | ゆうき と ゆうき | OK | 画像の中の 2 人の名前 / 代表値。全 3 通りを確認 |
| `Share.previewLabel` | ゆうきとゆうきの30日のシェア画像 | OK | 共有シートの VoiceOver / 代表値 |
| `Share.startedOn` | 2026年10月20日 21:00から | OK | 画像の中の開始日 / 代表値 |
| `Share.milestoneTitle` | 🎉 ふたりで0日! | OK | 節目のお祝い。数字は半角（§2-5） / 代表値。全 4 通りを確認 |
| `Share.sharePreviewTitle` | 0日の記録 | OK | 共有シートの題名 / 代表値 |

### 7.23 アイコン（タネの子のイラスト12種）

- 対象は 13 単位。プロフィールのアイコン（オンボーディングと設定のプロフィール編集で選ぶ）の名前と、読み上げの形。画面に文字としては出さず、VoiceOver が読む。
- 2026-10-26 に、絵文字24種（旧 `Onboarding.avatarPalette`）から、アプリのマスコット「タネの子」を着替えさせたイラスト12種に替えた。絵は `products/lien/assets/avatar/`、並びと名前の正本は `avatars.json`。
- 絵柄は、ふたば・サボテン・ほし・きのこ・クローバー・つき・チューリップ・ひまわり・どんぐり・さくら・いちご・しずく。怖い絵柄・罰を連想させる絵柄はない。
- `Avatar.cactus` は「カクタス」。`avatars.json` の名前は「サボテン」だが、「サボ」が罰なし lint の禁止ワード（サボり）に表記だけで当たる。lint は緩めず、読み上げは英語由来の呼び名にした。
- `Avatar.label` は、選ぶ場面ではない表示だけの絵（設定のプロフィール行）の読み上げ。「名前: 値」の形（§2-7）。選ぶときのボタンは、見出し「アイコンをえらんでね」の直後に並ぶので、絵の名前だけを読む。

| 名前 | 文言（代表） | 判定 | メモ |
|---|---|---|---|
| `Avatar.sprout` | ふたば | OK | 1つめ。最初から選ばれている絵 |
| `Avatar.cactus` | カクタス | OK | 禁止ワード「サボ」を避けた呼び名（上記） |
| `Avatar.star` | ほし | OK | ひらがな基調 |
| `Avatar.mushroom` | きのこ | OK | ひらがな基調 |
| `Avatar.clover` | クローバー | OK | 外来語は既存の植物の名前の書き方に合わせた |
| `Avatar.moon` | つき | OK | ひらがな基調 |
| `Avatar.tulip` | チューリップ | OK | 外来語の通常表記 |
| `Avatar.sunflower` | ひまわり | OK | ひらがな基調 |
| `Avatar.acorn` | どんぐり | OK | ひらがな基調 |
| `Avatar.sakura` | さくら | OK | ひらがな基調 |
| `Avatar.strawberry` | いちご | OK | ひらがな基調 |
| `Avatar.drop` | しずく | OK | ひらがな基調 |
| `Avatar.label` | アイコン: ふたば | OK | 表示だけの絵の読み上げ（名前＋値 — §2-7） / 代表値 |

## 8. このログの検査（CI）

`StringsReviewTests.swift` が、このログと `Strings.swift` のずれを CI で検出する。

| テスト | 検査内容 |
|---|---|
AD
| `testReviewLogCoversEveryStringsCatalogEntry` | `StringsCatalog` の全 369 単位が、このログの表に**ちょうど1回**出ていること。文言を足してログを忘れると落ちる |
| `testReviewLogTextsMatchStringsCatalog` | 表の文言が現在の `Strings.swift` と一致すること（1件の単位は完全一致、関数型は代表値が含まれること）。文言を変えてログを忘れると落ちる |
| `testReviewLogSummaryMatchesVerdicts` | 冒頭の「369 件（OK 363 / 修正 6 / 保留 0）」が、表の判定の数と一致すること |

| `testUserFacingStringsAvoidDeveloperJargon` | 画面の文言に「ストリーク」「アーカイブ」「セッション」などの開発者ことばが戻らないこと |
| `testCloseLabelsAreConsistent` | 閉じるボタンの文言が「閉じる」に揃っていること |
| `testNetworkErrorMessagesAreIdentical` | 通信エラーの文言が7箇所で同じであること |

- 既存の罰なし lint（`Strings.swift` の全リテラル・`StringsCatalog`・サーバー側 `BANNED_PATTERN` との整合）はそのまま。本ログは**目視レビューの記録**で、lint の代わりではない。
- 実行: `cd products/lien/ios && scripts/macos-check/check.sh`（Xcode の無い Mac の下見）。CI は `.github/workflows/lien-ios.yml` のシミュレータ上の `LienTests` が正本。

## 9. 変更したファイル

- `products/lien/ios/Lien/Core/Strings.swift` — 6 件の文言
- `products/lien/ios/LienTests/StringsReviewTests.swift` — ログの網羅・整合と、用語・表記の回帰検査
- `docs/STRINGS-REVIEW.md` — 本ログ
- `docs/DESIGN.md` §3.8 — 本ログと CI 検査への参照
- `docs/TASKPLAN.md` §9.4 — T27 本体の完了
- `progress/JOURNAL.md` — 実施記録

## 10. 残課題

- §6.1 の初回同期失敗時の画面（eng-lead / T30 の判断）。
- T30 の審査チェックリストで、実際の画面（スクリーンショット）と文言の最終確認。
- 実機の VoiceOver で、植物・ウィジェット・通知の読み上げを確認（T20）。

## 11. プレミアム（課金）の文言 — T33

- 追加日: 2026-10-20（T33 / REQUIREMENTS §3.14）
- 3文脈（節目・アルバム30日超・チケット切れ）で見出しと説明を出し分ける。価格・トライアル日数は offerings から表示し、コードに書かない。
- 押し売りしない: 閉じる（「あとで」）と復元を常に置き、罰・恥・煽りの語を使わない。

| 名前 | 文言（代表） | 判定 | メモ |
|---|---|---|---|
| `Paywall.title` | プレミアム | OK | 課金の名前。画面の見出し |
| `Paywall.closeButton` | あとで | OK | 押し売りしない。常に閉じられる |
| `Paywall.benefitsTitle` | ペアのふたりに、できること | OK | 特典の見出し。ふたりに効くことを先に言う |
| `Paywall.benefits` | 写真アルバムに制限がない | OK | 特典の代表（配列の先頭）。REQUIREMENTS §3.14 のプレミアム特典 |
| `Paywall.monthlyPrefix` | 月額 | OK | 価格の見出し。価格そのものは StoreKit の表示 |
| `Paywall.yearlyPrefix` | 年額 | OK | 価格の見出し。年額を推す |
| `Paywall.recommended` | おすすめ | OK | 年額のバッジ。煽らない |
| `Paywall.trialNote` | 17日間 無料で試せます | OK | トライアル日数は offerings から。代表 17 日（G6 で最終化） |
| `Paywall.purchaseButton` | このプランにする | OK | 購入ボタン。選んだプランであることを言う |
| `Paywall.purchasing` | 購入しています… | OK | 購入中の表示 |
| `Paywall.restoreButton` | 購入を復元する | OK | 復元。機種変更・再インストール用 |
| `Paywall.restoring` | 復元しています… | OK | 復元中の表示 |
| `Paywall.appliedByPartner` | 相手がすでにプレミアムなので、このペアは適用済みです。購入は不要です | OK | 誤課金防止（REQUIREMENTS §3.14）。責めない |
| `Paywall.purchaseDone` | プレミアムがはじまりました | OK | 購入完了 |
| `Paywall.restoreDone` | 購入を復元しました | OK | 復元成功 |
| `Paywall.restoreNotFound` | 復元できる購入が見つかりませんでした | OK | 復元するものが無い。事実のみ |
| `Paywall.unavailable` | いまは購入できません。準備ができたらお知らせします | OK | G6 前・API キー未設定。偽の価格を出さない |
| `Paywall.errorMessage` | 購入を完了できませんでした。時間をおいて、もう一度お試しください | OK | 通信・ストアの失敗。次の一歩 |
| `Paywall.cancelled` | 購入をキャンセルしました | OK | 利用者が閉じたとき（画面には出さない想定） |
| `Paywall.pending` | 購入の確認を待っています。完了するとプレミアムがはじまります | OK | Ask to Buy など。保留を説明する |
| `Paywall.legalNote` | 料金は App Store のアカウントに請求されます。自動更新は、購入後いつでも設定から止められます | OK | 特商法・自動更新の説明。G6 で最終確認 |
| `Paywall.terms` | 利用規約 | OK | 法務ページへのリンク |
| `Paywall.privacy` | プライバシーポリシー | OK | 法務ページへのリンク |
| `Paywall.milestoneHeadline` | 30日、ふたりで続いたね | OK | 節目の文脈。代表 30 日 |
| `Paywall.milestoneMessage` | この記録も写真も、これから先も残せるように。プレミアムで、ふたりの場所がもう少し広がります | OK | 節目の文脈。押し売りしない |
| `Paywall.albumHeadline` | 30日より前の写真も、残しておける | OK | アルバム30日超の文脈（T21） |
| `Paywall.albumMessage` | プレミアムなら、写真アルバムに制限がありません。ふたりで重ねた日を、ずっと見返せます | OK | アルバム30日超の文脈 |
| `Paywall.ticketEmptyHeadline` | チケットがなくなっても、続けられる | OK | チケット切れの文脈。罰・恥を出さない |
| `Paywall.ticketEmptyMessage` | プレミアムなら、お休みチケットが毎月5枚。ペアのふたりで使えます | OK | チケット切れの文脈。事実のみ |

