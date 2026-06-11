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
}
