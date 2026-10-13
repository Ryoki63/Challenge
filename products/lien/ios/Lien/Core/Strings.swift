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

        // VoiceOver(ロック画面の2種。ホーム S / M は植物の読み上げ文 PlantVoiceOver を使う — GROWTH §5.4)

        /// ロック画面・円形(相手の葉の開閉): 「ゆうき: 完了」/「ゆうき: まだ」
        static func partnerStatus(_ partnerName: String, done: Bool) -> String {
            "\(partnerName): \(done ? Plant.voiceDone : Plant.voicePending)"
        }

        /// ロック画面・インライン(ストリーク): 「ふたりの記録: 23日」(植物の読み上げ文 Plant.voiceStatus と同じ「名前: 値」の形)
        static func streakSpoken(_ days: Int) -> String {
            "\(Home.streakCaption): \(streakDays(days))"
        }
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

        /// 匿名開始の注意。v1.0 は Sign in with Apple(Apple ID への連携)を入れない(D3・REVIEW-2026-10-12 §1。1.0.1 で対応)ので、
        /// 機種変更やアプリの入れ直しで記録を引き継げない場合があることを、オンボ(ここ)と設定(Settings.accountFooter)に明示する
        /// (DESIGN §10: 再インストール時、匿名のままのユーザーは救済できない — オンボで明示する)
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

        // リマインド(任意。約束の remind_at が毎日のローカル通知の時刻になる — ReminderScheduler / T16 #16)
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

    /// 植物(タネの子)— 段階名・ゲージ・段階アップの演出・名前付け・読み上げ・ひとこと(GROWTH §3.3・§4.5・§5 / PB #57)。
    /// 罰・恥系の表現は使わない(§3.5。休んだ日・減ることには触れない)。主語は名前にする(左右は使わない — GROWTH §4.5)
    enum Plant {
        // MARK: 段階名(GROWTH §3.3。仮の名前)

        /// 添字 = 段階 0〜9。アプリが知らない大きい段階は stageName が最大(みのり)に丸める
        static let stageNames = [
            "たね", "ふたば", "めばえ", "わかば", "よりそい", "つぼみ", "いろづき", "ほころび", "ふたりざき", "みのり",
        ]

        /// 段階の名前。範囲外は 0〜9 に丸める(知らない段階はみのりとして描く — PlantLayers.clampedStage)
        static func stageName(_ stage: Int) -> String {
            stageNames[min(max(stage, 0), stageNames.count - 1)]
        }

        // MARK: ゲージの文(GROWTH §5.1。ホームの植物の下に1行。単位は「回」)

        /// 次の段階まで(区間が短いとき・長い区間の後半): 「ふたりそろって あと2回で めばえ」
        static func gaugeRemaining(_ remaining: Int, nextStageName: String) -> String {
            "ふたりそろって あと\(remaining)回で \(nextStageName)"
        }
        /// 長い区間の前半: 「わかばになってから 3回そろったよ」
        static func gaugeSinceStage(_ stageName: String, count: Int) -> String {
            "\(stageName)になってから \(count)回そろったよ"
        }
        /// 次の段階が無いとき(みのり以降): 「ふたりで 128回 そろったよ」
        static func gaugeLast(_ grownDays: Int) -> String {
            "ふたりで \(grownDays)回 そろったよ"
        }
        /// アプリが知らない段階をサーバーが返したとき(1.0.1 の花壇など): 「あと25回で つぎの おたのしみ」
        static func gaugeUnknownNext(_ remaining: Int) -> String {
            "あと\(remaining)回で つぎの おたのしみ"
        }

        // MARK: VoiceOver(GROWTH §5.4: 「みどり、わかば。あなた: 完了、ゆうき: まだ。ふたりそろって あと3回で よりそい」)

        /// 名前があれば「名前、段階名」、無ければ段階名だけ
        static func voiceHeader(name: String?, stageName: String) -> String {
            guard let name, !name.isEmpty else { return stageName }
            return "\(name)、\(stageName)"
        }
        /// 「あなた: 完了、ゆうき: まだ」
        static func voiceStatus(meDone: Bool, partnerName: String, partnerDone: Bool) -> String {
            "あなた: \(meDone ? voiceDone : voicePending)、\(partnerName): \(partnerDone ? voiceDone : voicePending)"
        }
        static let voiceDone = "完了"
        static let voicePending = "まだ"
        /// ソロ(ペア未成立): 植物は土の中で眠っている
        static let voiceSolo = "土の中で眠るタネの子"
        /// 名前を変えるボタンのヒント
        static let renameHint = "ダブルタップで、名前を変えます"
        /// 植物をタップするとひとことをもう一度出す(VoiceOver のアクション名)
        static let whisperAction = "タネの子のひとこと"

        // MARK: 段階アップの演出(GROWTH §5.2。各段階1回だけ全画面で)

        /// 段階0(ペア成立): はじめまして
        static let meetingHeadline = "はじめまして!"
        static let meetingBody = "タネの子が、目をさましたよ"
        /// 段階1以降: 「わかばになった!」/「ふたりで 7回 そろったよ」
        static func stageUpHeadline(_ stageName: String) -> String {
            "\(stageName)になった!"
        }
        static func stageUpBody(_ grownDays: Int) -> String {
            "ふたりで \(grownDays)回 そろったよ"
        }
        static let celebrationClose = "とじる"
        /// 変わる前 / 後の植物(VoiceOver)
        static func celebrationBefore(_ stageName: String) -> String {
            "さっきまで: \(stageName)"
        }
        static func celebrationAfter(_ stageName: String) -> String {
            "いま: \(stageName)"
        }
        /// ボタン「(相手)にハートを送る」(リアクションのスタンプ ❤️ を使い回す — T15)
        static func celebrationHeart(_ partnerName: String) -> String {
            "\(partnerName)にハートを送る"
        }
        static let celebrationHeartSending = "送っています…"
        static let celebrationHeartSent = "ハートを送ったよ"
        static let celebrationHeartError = "送れませんでした。あとでもう一度お試しください"

        // MARK: おかえり(GROWTH §4.4。2日以上あいたあと、自分がチェックインした瞬間だけ。空いた日数は出さない)

        static let welcomeBackHeadline = "おかえり"
        static let welcomeBackBody = "また いっしょに"

        // MARK: 名前付け(GROWTH §5.3。最初の「ふたば」の演出の中で付ける。先に付けた人の名前に決まる)

        static let nameTitle = "名前をつけてあげよう"
        static let renameTitle = "名前をかえる"
        static let namePlaceholder = "なまえ(8文字まで)"
        static let nameNote = "どちらかが先につけると、その名前に決まります。あとからいつでも変えられます。"
        static let nameSubmit = "名前をつける"
        static let renameSubmit = "この名前にする"
        static let nameSaving = "保存しています…"
        static let nameLater = "あとで"
        static let nameCancel = "やめる"
        /// ホームで、まだ名前が無いときのボタン(演出を閉じたあとも残る)
        static let nameButton = "名前をつける"
        static let nameEmptyError = "名前を入力してね"
        static let nameTooLongError = "名前は8文字までです"
        /// 改行・見えない文字・向きを変える制御文字など(サーバーの invalid_name と同じ規則)
        static let nameInvalidError = "使えない文字が入っています"
        static let nameSaveError = "保存できませんでした。通信状態を確認して、もう一度お試しください"
        static let nameNoPairError = "いまはペアがいないので、名前をつけられません"
        /// 自分が付けた: 「『みどり』と名づけたよ」
        static func nameSavedNote(_ name: String) -> String {
            "『\(name)』と名づけたよ"
        }
        /// 相手が先に付けていた(409): 「名前は『みどり』になったよ」
        static func nameAdoptedNote(_ name: String) -> String {
            "名前は『\(name)』になったよ"
        }
        /// 相手が初めて付けた(次に開いたとき): 「名前が『みどり』になったよ」。変えたときの「かわったよ」とは分ける
        static func nameFirstNotice(_ name: String) -> String {
            "名前が『\(name)』になったよ"
        }
        /// 相手が変えた(次に開いたとき): 「名前が『みどり』にかわったよ」
        static func nameChangedNotice(_ name: String) -> String {
            "名前が『\(name)』にかわったよ"
        }
        static let nameNoticeClose = "閉じる"

        // MARK: 今日のひとこと(GROWTH §5.5。その日はじめてホームを開いたとき、吹き出しで短く。同じ日は同じ言葉)
        // 主語は名前にする。絵は使わない。罰なし文言の lint の対象(Strings.swift の全リテラル)

        enum Whisper {
            /// ふたりそろった日
            static func bothDone(_ partnerName: String) -> [String] {
                [
                    "ふたりの葉、そろってひらいたね",
                    "きょうも ふたりで できたね",
                    "ぽかぽか。いい日だなあ",
                    "\(partnerName)と いっしょで うれしいな",
                ]
            }
            /// 相手だけ完了
            static func partnerDone(_ partnerName: String) -> [String] {
                [
                    "\(partnerName)の葉、ひらいたよ",
                    "\(partnerName)が ひらいてくれた。うれしいね",
                    "\(partnerName)の葉が きらきらしてる",
                    "あなたの葉が ひらくのも、たのしみにしてるよ",
                ]
            }
            /// 自分だけ完了
            static func meDone(_ partnerName: String) -> [String] {
                [
                    "ひらいたよ。\(partnerName)の葉は ねんね中",
                    "\(partnerName)の葉も、そのうち ひらくよ",
                    "ひとりぶん できたね。ゆっくり待とうね",
                ]
            }
            /// すやすや(ふたり達成もお休みチケットもない日が続いたあと)
            static let sleepy = [
                "すやすや…ふたりのペースで いいよ",
                "ぐっすり ねてたよ。おはよう",
                "のんびり いこうね",
            ]
            /// まだ誰もチェックインしていない日(時間帯ごと)
            static let morning = [
                "おはよう。きょうも ふたりのペースでね",
                "いい朝だね。きょうは なにする?",
                "ふわぁ…おはよう",
                "あさの ひかりが きもちいいね",
            ]
            static let daytime = [
                "おひるだね。ひとやすみも いいね",
                "きょうも ふたりの葉っぱが そよそよ",
                "ゆっくり いこうね",
            ]
            static let evening = [
                "夕方だね。きょうも おつかれさま",
                "ゆっくりで だいじょうぶ",
                "ひがくれてきたね",
            ]
            static let night = [
                "もう夜だね。おやすみの じゅんび?",
                "ふぁ…ねむくなってきた",
                "あしたも ふたりのペースでね",
            ]
            /// 段階ごとの一言(ふたば・わかば・つぼみ・ふたりざき・みのり)。ほかの段階は無い
            static func stage(_ stage: Int) -> [String] {
                switch stage {
                case 1: return ["ふたば、にあう?", "ふたばって かわいいでしょ"]
                case 3: return ["わかばに なれたよ。ぐんぐん のびるよ", "ふたりの わかば、いいかんじ"]
                case 5: return ["つぼみが ふくらんできたよ", "なにが さくんだろう?"]
                case 8: return ["ふたりで さいたね", "いっしょに さくと うれしいね"]
                case 9: return ["みのりの おいわい。ありがとう", "ふたりの タネが ひかってるよ"]
                default: return []
                }
            }
        }
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

        // 通知(通知の設定画面へ — NotificationSettings。相手からの通知は v1.0 ではアプリの中で切り替えられない)
        static let notificationSection = "通知"
        static let notificationRow = "リマインドとお知らせ"
        static let notificationFooter = "リマインドの時刻や、ふたりの記録のお知らせを変えられます。"

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

    /// 端末のローカル通知の文言(リマインド・ストリーク危機 — REQUIREMENTS §3.12 / T16 #16)。
    /// 通知の名義はアプリ(title は常に「Lien」)。**罰・恥系の表現は使わない**(§3.5。責めない・脅さない・相手を責めない)。
    /// 文言は予約するときに組み立てて OS に渡す(ReminderScheduler と、相手の push を受けた NSE — LocalNotificationPushSync)ので、
    /// 予約したあとで約束の名前や状態が変わったら、次の同期(または次の push)で付け替わる。ふたりそろったあとに NSE が
    /// 取り消せなかったとき(ReminderScheduler のコメント)に届いても、読んで困らない言い方にしてある
    enum LocalNotification {
        static let title = "Lien"

        /// リマインド(約束の remind_at)。日付で 1 つ選ぶ(同じ日は同じ言葉)。emoji は約束の絵文字(無ければ空)を末尾に付ける。
        /// 1 つ目は REQUIREMENTS §3.12 の例
        static func reminderBodies(_ promiseTitle: String, emoji: String) -> [String] {
            [
                "今日の『\(promiseTitle)』、まだ間に合うよ\(emoji)",
                "『\(promiseTitle)』の時間だよ。ゆっくりでだいじょうぶ\(emoji)",
                "今日もひとつだけ。『\(promiseTitle)』、できそう?\(emoji)",
            ]
        }

        // ストリーク危機(夜 9 時 = ReminderScheduler.streakRiskHour。「あと3時間」は 21:00 から日付が変わるまで)。
        // ふたりの記録が続いていて、その日まだふたりそろっていないとき。days は続いている日数(ふたりの記録)。
        // 文言の決め方(GROWTH §6.6 の表。REQUIREMENTS §10): 案 A「…ふたりの23日が懸かってる」は損失をちらつかせる強さがあり、
        // 案 B「あと3時間。そろうと24日目」は罰なしの原則に近いがストリーク保険(課金の柱)の訴えが弱まる。そこで、
        // 「ふたりの記録の日数」と「あと3時間」(保険の訴えの核)は残し、「守ろう」という前向きな呼びかけにした
        // (お休みチケットが「守る」ものなのと同じ言葉。責めない・脅さない・相手を責めない)

        /// どちらも、またはわからない
        static func streakRiskNeither(days: Int) -> String {
            "あと3時間。ふたりの\(days)日を、いっしょに守ろう🌱"
        }
        /// 相手は済んでいて、自分がまだ(ウィジェットの「(相手)が待ってるよ」と同じ言い方 — REQUIREMENTS §3.10)
        static func streakRiskPartnerDone(partnerName: String, days: Int) -> String {
            "\(partnerName)が待ってるよ。あと3時間、ふたりの\(days)日を守ろう🌱"
        }
        /// 自分は済んでいて、相手がまだ(アプリの「つつく」を案内する)。「まだなら」と条件で言う: 予約したあとで相手が済ませて、
        /// NSE が取り消せなかったとき(ReminderScheduler のコメント)に届いても、事実と食い違わない
        static func streakRiskMeDone(partnerName: String, days: Int) -> String {
            "あと3時間。\(partnerName)がまだなら、「つつく」で声をかけてみよう。ふたりの\(days)日を守れるよ"
        }
    }

    /// 通知の設定画面(設定 → 通知。REQUIREMENTS §3.12・§3.15 / T16 #16)。罰・恥系の表現は使わない(§3.5)
    enum NotificationSettings {
        static let title = "通知"
        /// OS の通知が許可されていないとき(iOS の設定アプリでしか変えられない)
        static let deniedNotice = "通知が許可されていません。iOS の設定アプリで許可すると、お知らせが届きます。"

        // リマインド(約束の remind_at。約束設定の画面と同じ値 — 保存すると約束も更新される)
        static let reminderSection = "リマインド"
        static let reminderToggle = PromiseSetup.remindToggleLabel
        static let reminderTime = PromiseSetup.remindTimeLabel
        static let reminderFooter = "決めた時刻に、約束をそっとお知らせします。その日の分ができていたら、お知らせしません。"
        static let reminderNoPromise = "約束を決めると、リマインドを設定できます。"
        static let reminderSave = "保存する"
        static let reminderSaving = "保存しています…"
        static let reminderSaved = "リマインドを保存しました"
        static let reminderSaveError = "保存できませんでした。通信状態を確認して、もう一度お試しください"
        static let loadFailed = Settings.loadFailed
        static let retry = Settings.retry

        // ふたりの記録(ストリーク危機。端末ローカルの設定)
        static let streakSection = "ふたりの記録"
        static let streakToggle = "夜9時のお知らせ"
        static let streakFooter = "ふたりの記録が続いていて、その日まだふたりそろっていないときだけ、夜9時に一度お知らせします。ふたりそろったら、お知らせしません。"

        // 相手からの通知(v1.0 はアプリの中では切り替えられない。種別ごとのオン・オフは v1.1)。iOS の設定アプリで通知を
        // オフにすると、相手の通知だけでなく Lien の通知がすべて(リマインドと夜 9 時のお知らせも)止まるので、そう書く
        static let partnerSection = "相手からの通知"
        static let partnerFooter = "相手のチェックイン・つつく・リアクションの通知は、アプリの中では切り替えられません。iOS の設定アプリで通知をオフにすると、リマインドや夜9時のお知らせを含め、Lien の通知がすべて止まります。"
        static let openSystemSettings = "iOS の通知設定を開く"

        // 設定画面の行の右側(いまの状態)
        static func summaryDaily(_ time: String) -> String {
            "毎日 \(time)"
        }
        static let summaryOff = "オフ"
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
