// Strings.swift — ユーザー向け文言の集約(DESIGN §3.8)
//
// - ユーザーの目に触れる文言は必ずここに置く。View 内に直書きしない
// - **罰・恥系の表現は禁止**(REQUIREMENTS §3.5。「枯れる」「サボり」等のワードを使わない)
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

        /// ソロ状態(ペア未成立・鉢は土だけ — REQUIREMENTS §3.9)の一言
        static let soloCaption = "ペアになると種がまかれるよ"
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
        static let profileSubmit = "これではじめる"

        /// 匿名開始の注意(DESIGN §10: Apple ID 未連携のまま再インストールすると
        /// データを引き継げないことをオンボで明示する義務がある)
        static let anonymousStartNote =
            "登録なしですぐ始められます。機種変更やアプリの入れ直しで続きを引き継ぐには、あとから Apple ID 連携(設定画面)が必要です。"

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

        /// ソロ状態(ペア未成立・鉢は土だけ)の一言(ウィジェットと同文言で統一)
        static let soloCaption = Widget.soloCaption
        /// ソロ状態の誘導(招待の動機付け — §3.9)
        static let soloInviteHint = "招待した相手とペアになると、ふたりの約束がはじまります"

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
}
