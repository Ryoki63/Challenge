// Strings.swift — ユーザー向け文言の集約(DESIGN §3.8)
//
// - ユーザーの目に触れる文言は必ずここに置く。View 内に直書きしない
// - **罰・恥系の表現は禁止**(REQUIREMENTS §3.5。「枯れる」「サボり」等のワードを使わない)
//   → LienTests/StringsReviewTests.swift が、このファイルの文字列リテラルを全件拾って禁止ワードを CI で検査する。
//     文言を足したら、同じファイルの StringsCatalog.all にも1行足すこと(足し忘れはテストが教えてくれる)
// - Widget 名前空間は LienWidget ターゲットにもソース共有される(project.yml 参照)。
//   このファイルは Foundation 以外に依存させないこと。

import Foundation

enum Strings {
    /// ウィジェット(LienWidget ターゲットと共有)
    enum Widget {
        static let displayName = "Lien"
        static let description = "ふたりの約束をそっと見守ります"

        /// snapshot がまだ無い(初回起動前・未ログイン)ときの空状態
        static let emptyTitle = "Lien"
        static let emptyMessage = "アプリを開いてはじめよう"

        /// 自分/相手の今日の状態行ラベル(約束タイトル未設定時のフォールバック)
        static let meFallbackLabel = "じぶん"
        static let partnerFallbackLabel = "あいて"

        /// 相手が先に完了しているときの一言(REQUIREMENTS §3.10 表示原則)
        static func partnerWaiting(_ partnerName: String) -> String {
            "\(partnerName)が待ってるよ"
        }

        /// ストリーク日数表示
        static func streakDays(_ days: Int) -> String {
            "\(days)日"
        }

        /// ソロ状態(ペア未成立・タネの子は鉢の土の中で眠っている — REQUIREMENTS §3.9)の一言
        static let soloCaption = "ペアになると、タネの子が目をさますよ"
    }

    /// オンボーディング3画面(REQUIREMENTS §3.1, §6 / T10)
    enum Onboarding {
        // ページ1: コンセプト
        static let conceptTitle = "ふたりで、ひとつの約束"
        static let conceptBody = "大切な人と約束をひとつだけ決めて、\n毎日そっと続けていくアプリです。"
        static let conceptNote = "ひとりで始めて、あとから相手を招待できます"
        static let conceptStart = "はじめる"

        // ページ2: ニックネーム+アイコン(絵文字)
        static let profileTitle = "あなたのことを教えてね"
        static let nicknamePlaceholder = "ニックネーム(8文字まで)"
        static let nicknameEmptyError = "ニックネームを入力してね"
        static let nicknameTooLongError = "ニックネームは8文字までです"
        static let avatarTitle = "アイコンをえらんでね"
        /// 規約への同意ボタンを兼ねる(同意のチェックが入るまで押せない — 下の consent*)
        static let profileSubmit = "同意してはじめる"

        // 規約への明示の同意(写真を共有するアプリは、利用の前に規約への同意を求める — App Store ガイドライン 1.2 / T23 #23)
        static let consentLabel = "利用規約とプライバシーポリシーに同意します"
        static let consentTermsLink = "利用規約を読む"
        static let consentPrivacyLink = "プライバシーポリシーを読む"
        static let consentNote = "不適切な写真や言葉、迷惑行為は禁止されています。気になる内容は、画面を長押しして通報したり、ペアを解消したりできます。"
        /// 同意のチェック(VoiceOver の値)
        static let consentCheckedValue = "同意済み"
        static let consentUncheckedValue = "未同意"

        /// 匿名開始の注意(DESIGN §10: Apple ID 未連携のまま再インストールすると
        /// データを引き継げないことをオンボで明示する義務がある)
        static let anonymousStartNote =
            "登録なしですぐ始められます。機種変更やアプリの入れ直しでは、記録を引き継げない場合があります。"

        // ページ3: 通知プレ許可(OS ダイアログの前にひと言説明 — issue #10)
        static let notificationTitle = "おしらせを受け取る"
        static let notificationBody = "相手がチェックインしたときや、\n約束の時間をそっとお知らせします。"
        static let notificationAllow = "通知を許可する"
        static let notificationLater = "あとで"

        // 送信エラー(リトライ可能。罰・恥系の表現は使わない — REQUIREMENTS §3.5)
        static let submitErrorMessage = "通信がうまくいきませんでした。もう一度お試しください"
        static let retry = "もう一度ためす"

        /// アイコンの絵文字パレット(REQUIREMENTS §3.1: パレットから選択)
        static let avatarPalette: [String] = [
            "🌱", "🌷", "🌻", "🍀", "🐶", "🐱", "🐰", "🐻",
            "🐼", "🦊", "🐧", "🐥", "🍎", "🍓", "🍵", "🌙",
            "⭐️", "🎵", "📚", "🏃", "💪", "🧸", "☕️", "💛",
        ]
    }

    /// 招待・ペアリング画面(REQUIREMENTS §3.2 / DESIGN §6 / T11)
    enum Pairing {
        static let title = "ふたりをつなぐ"
        static let subtitle = "大切な人を招待して、ひとつの約束をはじめよう。"

        // 招待をおくる(発行)
        static let inviteSectionTitle = "招待をおくる"
        static let inviteExplainer = "リンク・QRコード・8文字のコード、どれでも招待できます。"
        static let issueButton = "招待をつくる"
        static let codeCaption = "招待コード"
        static let qrCaption = "QRコードを読み取ってもらってね"
        static let shareButton = "リンクをおくる"
        static let shareMessage = "Lienで、ふたりでひとつの約束をはじめませんか?"
        static func expiresNote(_ formattedDate: String) -> String {
            "\(formattedDate) まで有効・1回かぎりの招待です"
        }

        /// ホームからシートで開いた招待画面を閉じる(招待は任意 — あとからいつでも開ける)
        static let closeButton = "あとで"

        // コードを入力(受諾)
        static let acceptSectionTitle = "コードを入力"
        static let acceptExplainer = "相手から受け取った8文字のコードを入れてね。"
        static let codePlaceholder = "例: AbCd2345"
        static let acceptButton = "ペアになる"

        // エラー文言(InviteClientError → ユーザー向け。
        // 罰・恥系の表現は使わない — REQUIREMENTS §3.5)
        static let errorAlreadyPaired =
            "すでにペアが成立しています"
        static let errorPartnerAlreadyPaired =
            "招待をくれた相手は、すでにべつのペアをはじめているみたい"
        static let errorInviteNotFound =
            "この招待が見つかりませんでした。コードをもう一度確かめてみてね"
        static let errorInviteExpired =
            "この招待は期限が切れています。新しい招待をもらってね"
        static let errorInviteAlreadyUsed =
            "この招待はすでに使われています。新しい招待をもらってね"
        static let errorCannotAcceptOwnInvite =
            "これは自分がつくった招待です。相手に送ってあげてね"
        static let errorInvalidTokenFormat =
            "コードは8文字の英数字です"
        static let errorNetwork =
            "通信がうまくいきませんでした。もう一度お試しください"
    }

    /// 約束設定画面(REQUIREMENTS §3.3 / T12)。罰・恥系の表現は使わない(§3.5)
    enum PromiseSetup {
        static let title = "あなたの約束をきめよう"
        static let subtitle = "毎日続けたいことを、ひとつだけ。\nあとからいつでも変えられます。"

        // タイトル入力
        static let titleSectionTitle = "約束"
        static let titlePlaceholder = "例: まいにち散歩(20文字まで)"
        static let titleEmptyError = "約束を入力してね"
        static let titleTooLongError = "約束は20文字までです"

        // 絵文字選択
        static let emojiSectionTitle = "絵文字をえらんでね"

        // リマインド(任意。ローカル通知のスケジューリングは T16)
        static let remindSectionTitle = "リマインド"
        static let remindToggleLabel = "毎日そっとお知らせ"
        static let remindTimeLabel = "時刻"

        // 保存
        static let saveButton = "この約束にする"
        /// 寛容設計の一言(§3.3: 約束を変えてもストリークは継続)
        static let editKeepsStreakNote = "約束を変えても、ふたりの記録はそのまま続きます"
        // 送信エラー(リトライ可能。責めない文言 — REQUIREMENTS §3.5)
        static let saveErrorMessage = "通信がうまくいきませんでした。もう一度お試しください"

        /// 約束の絵文字パレット(固定候補。サーバー側は長さ上限のみの検査 — issue #12)
        static let emojiPalette: [String] = [
            "💪", "🏃", "🚶", "🧘", "📚", "✍️", "🗣️", "🎹",
            "💧", "🌿", "🍎", "🥗", "🛏️", "🦷", "🧹", "☀️",
            "💊", "🤸", "🚴", "🏊", "🎨", "📷", "💌", "🌙",
        ]
    }

    /// ホーム画面(REQUIREMENTS §3.4, §3.5, §3.9, §3.10 / T13)。
    /// 罰・恥系の表現は使わない(§3.5。リセット時も責めない)
    enum Home {
        // 植物(§3.9。名前未設定のときは名前行を出さない — フォールバック文言は置かない)

        /// ソロ状態(ペア未成立・タネの子は鉢の土の中で眠っている)の一言(ウィジェットと同文言で統一)
        static let soloCaption = Widget.soloCaption
        /// ソロ状態の誘導(招待の動機付け — §3.9)
        static let soloInviteHint = "招待した相手とペアになると、ふたりの約束がはじまります"
        /// ソロ状態のホームから招待画面を開くボタン(§3.2: 招待待ちでも使える。招待は任意)。
        /// 恋人・夫婦・友達・家族のどれにも開く言い方にする(CONCEPT §5-2: カップル限定にしない)
        static let inviteButton = "相手を招待する"

        // ストリーク(§3.5: 最高記録は永続表示。リセット時も「ふたりの財産」として残す)
        static let streakCaption = "ふたりの記録"
        static func streakDays(_ days: Int) -> String {
            "\(days)日"
        }
        static func streakBestNote(_ days: Int) -> String {
            "最高記録 \(days)日"
        }

        // ふたりの今日(§3.10 の表示原則をアプリ内でも踏襲)
        static let todaySectionTitle = "ふたりの今日"
        static let meFallbackLabel = "じぶん"
        static let partnerFallbackLabel = "あいて"
        /// 約束が未設定のチップに出す一言(責めない)
        static let promiseUnsetLabel = "約束はこれから"
        /// 相手が先に完了しているときの一言(REQUIREMENTS §3.10 表示原則)
        static func partnerWaiting(_ partnerName: String) -> String {
            "\(partnerName)が待ってるよ"
        }
        /// 両者完了の演出(REQUIREMENTS §3.4)
        static let bothDoneCelebration = "ふたり達成!"

        // チェックイン(§3.4)
        static let checkinButton = "できた!"
        static let checkinDoneLabel = "今日のぶんは完了"
        static let checkinErrorMessage = "通信がうまくいきませんでした。もう一度お試しください"

        // 空状態(snapshot 未取得。フォアグラウンド復帰時の GET /snapshot で自己修復 — DESIGN §4)
        static let emptyTitle = "Lien"
        static let emptyMessage = "ふたりの今日を準備しています"
    }

    /// チェックインフロー(写真添付+当日取消 — REQUIREMENTS §3.4 / T14)。
    /// 罰・恥系の表現は使わない(§3.5。取消も「誤タップ対応」であって責めない)
    enum Checkin {
        // 写真を添える(完了後・任意・その日1枚 — §3.4)
        static let attachPhotoButton = "写真を添える"
        static let attachPhotoSending = "写真をおくっています…"
        static let attachPhotoDoneNote = "今日の写真を添えました"
        static let attachPhotoErrorMessage = "写真を送れませんでした。もう一度お試しください"

        // 当日取消(誤タップ対応 — §3.4。責めない文言)
        static let cancelButton = "取り消す"
        static let cancelDialogTitle = "今日のチェックインを取り消しますか?"
        static let cancelDialogMessage = "まちがえてタップしたときのために。いつでもまたチェックインできます"
        static let cancelConfirm = "取り消す"
        static let cancelKeep = "そのままにする"
        static let cancelErrorMessage = "通信がうまくいきませんでした。もう一度お試しください"
    }

    /// つつく(ナッジ。REQUIREMENTS §3.7 / T15)。
    /// 自由テキストは入れない — スタンプ6種から選ぶのみ(チャット化を避ける)
    enum Nudge {
        /// ホームのつつくボタン(相手が未完のときだけ表示 — §3.7)
        static let button = "つつく"
        static let sheetTitle = "スタンプでつつく"
        static let sheetSubtitle = "ひとことの代わりに、スタンプを送ってみよう"
        /// 送信済みの一言(セッション内のみ表示。送った/送れたの確認)
        static let sentNote = "つつきました"
        /// 1日3回まで(§3.7)。上限超過はサーバー正本の判定(429) — 責めない文言
        static let limitReachedMessage = "今日はもうたくさんつついたよ。また明日ね"
        static let errorMessage = "通信がうまくいきませんでした。もう一度お試しください"
    }

    /// リアクション(REQUIREMENTS §3.8 / T15)。
    /// 相手の今日のチェックインにスタンプ1つ(❤️🔥👏😂🥹💪)
    enum Reaction {
        /// 相手のチェックインチップに添えるリアクション導線のラベル
        static let button = "リアクション"
        static let sheetTitle = "スタンプでリアクション"
        static let sentNote = "リアクションしました"
        static let errorMessage = "通信がうまくいきませんでした。もう一度お試しください"
    }

    /// 相手の今日の写真(ホームのカードと、タップで開く全画面 — REQUIREMENTS §3.11 / PV #59)。
    /// 読み込みに失敗したとき・写真が無い日には何も出さない(罰なし・責めない — §3.5)ので、その文言は置かない
    enum PartnerPhoto {
        /// カードの下の一言であり、VoiceOver が読む名前
        static func caption(_ partnerName: String) -> String {
            "\(partnerName)の今日の写真"
        }
        /// カード(ボタン)の VoiceOver のヒント
        static let openHint = "タップで大きく見ます"
        /// 読み込み中の枠の VoiceOver 名
        static let loadingLabel = "写真を読み込んでいます"
        /// 全画面の写真の VoiceOver 名
        static func viewerLabel(_ partnerName: String) -> String {
            "\(partnerName)の今日の写真(大きい表示)"
        }
        /// 全画面を閉じるボタンの VoiceOver 名
        static let viewerCloseButton = "とじる"
        /// 全画面の通報・ブロックのメニューボタンの VoiceOver 名(App Store ガイドライン 1.2: 拡大したままでも通報できる)
        static let viewerMenuButton = "通報・ブロック"
    }

    /// 設定画面(REQUIREMENTS §3.15 / T23 #23)。罰・恥系の表現は使わない(§3.5)
    enum Settings {
        static let title = "設定"
        static let closeButton = "閉じる"
        /// ホームの歯車ボタンの VoiceOver 名
        static let openButtonLabel = "設定"

        // プロフィール(ニックネームとアイコンの表示と編集 — REQUIREMENTS §3.15)
        static let profileSection = "プロフィール"
        static let nicknameLabel = "ニックネーム"
        static let loadFailed = "読み込めませんでした"
        static let retry = "もう一度ためす"
        /// プロフィールの編集画面のタイトル
        static let profileEditTitle = "プロフィールを編集"
        static let profileEditFooter = "ニックネームとアイコンは、ペアの相手にも表示されます。"
        static let profileSave = "保存する"
        static let profileSaving = "保存しています…"
        static let profileSavedNote = "プロフィールを保存しました"
        static let profileSaveError = "保存できませんでした。通信状態を確認して、もう一度お試しください"

        // 約束(編集は約束設定の画面を開く)
        static let promiseSection = "約束"
        static let promiseUnset = "まだ決めていません"
        static let promiseEditRow = "約束を変える"
        static let promiseSavedNote = "約束を保存しました"

        // 通知(OS の設定アプリを開く)
        static let notificationSection = "通知"
        static let notificationRow = "通知の設定を開く"
        static let notificationFooter = "通知のオン・オフは、iOS の設定アプリで変えられます。リマインドの時刻は「約束」から変えられます。"

        // ペア
        static let pairSection = "ペア"
        static let partnerLabel = "ペアの相手"
        static let soloNote = "いまはひとりで使っています。相手を招待すると、ここからペアの管理ができます。"
        static let dissolveRow = "ペアを解消する"
        static let dissolveFooter = "ペアを解消すると、相手との共有がすべて止まります。いつでもまた新しい相手を招待できます。"
        static let dissolvedNote = "ペアを解消しました"

        // サポート
        static let supportSection = "サポート"
        static let contactRow = "お問い合わせ"
        static let reportRow = "不適切な内容を通報する"
        static let termsRow = "利用規約"
        static let privacyRow = "プライバシーポリシー"
        static let supportFooter = "相手の写真・ニックネーム・約束の文は、ホームで長押しして通報することもできます。"

        // アカウント
        static let accountSection = "アカウント"
        static let signOutRow = "サインアウト"
        static let deleteRow = "アカウントを削除する"
        static let accountFooter = "登録なしで始めたので、機種変更やアプリの入れ直しで記録を引き継げない場合があります。"

        static let versionLabel = "バージョン"
    }

    /// サインアウトの確認(1段階。端末の記録は消え、登録なしで始めたアカウントには戻れない)
    enum SignOut {
        static let confirmTitle = "サインアウトしますか?"
        static let confirmMessage = "この端末の記録は消えます。登録なしで始めたので、同じ記録には戻れません。ペアの相手とのつながりも、この端末からは戻せなくなります。サーバーに残る記録は、サインアウトしたあとでは削除できません。記録も消したいときは、先に「アカウントを削除する」を選んでください。"
        static let confirmButton = "サインアウト"
        static let cancel = "やめる"
    }

    /// ペアの解消(= ブロック。REQUIREMENTS §3.2・§8)。確認は2段階(説明の画面 → 最後の確認)
    enum Dissolve {
        static let screenTitle = "ペアを解消する"
        static let lead = "ペアを解消すると、相手との共有がすべて止まります。"
        static let effectPhotos = "相手の写真・約束・チェックインは、お互いに見えなくなります"
        static let effectNudges = "つつく・リアクション・通知も、相手とのあいだで届かなくなります"
        static let effectArchive = "植物とストリークの記録はアーカイブされ、同じ相手と組み直しても復活しません"
        static let effectHistory = "あなたのチェックイン履歴は、あなたの記録として残ります"
        static let partnerNote = "相手には通知は届きません。次にアプリを開いたときに、ペアが終わったことがわかります。"
        static let button = "ペアを解消する"
        static let finalTitle = "本当にペアを解消しますか?"
        static let finalMessage = "この操作は取り消せません。"
        static let finalConfirm = "解消する"
        static let cancel = "やめる"
        static let working = "解消しています…"
        static let errorMessage = "うまくいきませんでした。通信状態を確認して、もう一度お試しください"
    }

    /// アカウントの削除(App Store ガイドライン 5.1.1(v) / terms 第8条)。確認は2段階
    enum DeleteAccount {
        static let screenTitle = "アカウントを削除する"
        static let lead = "アカウントを削除すると、次のものがすべて消えます。"
        static let effectProfile = "ニックネーム・約束・チェックインの記録"
        static let effectPhotos = "添えた写真"
        static let effectPair = "ペアの相手との共有(いまのペアは解消されます)"
        static let irreversible = "削除したあとは、元に戻せません。"
        static let button = "アカウントを削除する"
        static let finalTitle = "本当に削除しますか?"
        static let finalMessage = "削除すると元に戻せません。"
        static let finalConfirm = "削除する"
        static let cancel = "やめる"
        static let working = "削除しています…"
        static let errorMessage = "削除できませんでした。通信状態を確認して、もう一度お試しください。もう一度押せば、続きから進みます"
    }

    /// 通報(UGC。App Store ガイドライン 1.2)。ホームで相手の写真・ニックネーム・約束の文・植物の名前を長押し、
    /// または設定から。運営宛のメールの下書きを開く(対象の ID を入れる)
    enum Report {
        // 長押しのメニュー(ホームの相手の写真・ニックネームと約束の文・植物の名前)
        static let menuReportPhoto = "写真を通報する"
        static let menuReportNickname = "ニックネームを通報する"
        static let menuReportPromise = "約束の文を通報する"
        static let menuReportPlantName = "植物の名前を通報する"
        static let menuBlock = "ブロック(ペアを解消)"
        static let confirmTitle = "この内容を通報しますか?"
        static let confirmMessage = "運営に送るメールの下書きが開きます。内容を確認して、そのまま送信してください。"
        static let openMail = "メールを開く"
        static let cancel = "やめる"
        static let mailFailedTitle = "メールを開けませんでした"
        static let mailFailedMessage = "メールアプリの設定を確認してから、もう一度お試しください。"
        /// 運営の連絡先が決まっているとき(SupportLinks.contactEmail)は、メールの設定が無い端末でも通報できるよう宛先を添える
        static func mailFailedMessage(contactAddress: String) -> String {
            "\(mailFailedMessage)\nメールアプリを使わずに、次の宛先へ直接お送りいただいてもかまいません。\n\(contactAddress)"
        }
        static let mailFailedOK = "閉じる"

        // 通報の対象(メールの「種別」)
        static let kindPhoto = "写真"
        static let kindNickname = "ニックネーム"
        static let kindPromise = "約束の文"
        static let kindPlantName = "植物の名前"
        static let kindGeneral = "その他"

        // 通報メール(運営が読む。対象の ID を入れる)
        static func subject(_ kind: String) -> String {
            "【Lien】通報: \(kind)"
        }
        static let bodyIntro = "このまま送信してください。気づいたことがあれば、下に書き足してもかまいません。"
        static let kindLabel = "種別"
        static let pairIdLabel = "ペアID"
        static let dateLabel = "日付"
        static let targetLabel = "対象"
        static let noPair = "(ペアなし)"
        static let appVersionLabel = "アプリのバージョン"
        static let notesLabel = "補足(任意)"
    }

    /// お問い合わせ(設定 → サポート)。運営宛のメールの下書きを開く
    enum Contact {
        static let subject = "【Lien】お問い合わせ"
        static let bodyIntro = "お問い合わせの内容を、下に書いてください。"
        static let bodyPlaceholder = "(お問い合わせの内容)"
    }

    /// ログイン状態が使えなくなったとき(セッション無効。snapshot の取得が 401 / user_not_found で続く)
    enum Session {
        static let lostTitle = "ログイン状態を確認できません"
        static let lostMessage = "この端末のログイン情報が使えなくなっているようです。通信状態が悪いだけのときは「あとで」を選んでください。「はじめからやり直す」を選ぶと、この端末の記録を消して、最初の画面に戻ります。"
        static let restart = "はじめからやり直す"
        static let later = "あとで"
    }
}
