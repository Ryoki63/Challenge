// StringsReviewTests.swift — 罰なし文言の lint(issue #62 = T27 の前倒し分)
//
// アプリが画面に出す文言(Strings.swift)に、罰・恥・煽り系の表現が入っていないことを CI で常に検査する。
// 正本: docs/REQUIREMENTS.md §3.5 / docs/DESIGN.md §3.8(罰・恥系の文言は禁止)。
// サーバー側(プッシュ文言)の同じ検査は supabase/functions/_shared/messages_test.ts の BANNED_PATTERN で、
// その語をそのまま Swift に移した(PunishmentFreeLint.bannedWords。ずれは testBannedWordsMatchServerSide が検知する)。
//
// 検査は3層:
//   1. Strings.swift のソース上の文字列リテラルを全件拾って検査する(本線。文言を足した瞬間から対象になる)
//   2. StringsCatalog(静的な文言+関数型文言の代表的な出力)を、実行時の値で検査する(組み立て後の文言)
//   3. 1 で拾った全リテラルが 2 のカタログに載っていることを確かめる(カタログの陳腐化防止)
//      → Strings.swift に文言を足したら、StringsCatalog にも1行足す(忘れるとここが落ちて教えてくれる)
//      載っている = **完全一致**(補間のないリテラルは、カタログの文言のどれかと一字一句同じ。補間のあるリテラルは、
//      固定部分の並びに、文言の全体が一致する — LiteralMatcher)。部分一致にすると、「日」「あり」のような短い断片が
//      どの文言にも含まれてしまい、足し忘れを見逃す(#57 の持ち越し)
//
// 機械チェックは補助にすぎない(責めるニュアンスは語では捕まらない)。
// 全文言の目視レビュー(T27 本体 #27)は docs/STRINGS-REVIEW.md に記録する。StringsCatalog がその一覧の元で、
// testReviewLog* が「全単位がログにあること・文言がずれていないこと」を CI で検査する。

import XCTest
@testable import Lien

// MARK: - 禁止ワード(messages_test.ts の BANNED_PATTERN の移植)

enum PunishmentFreeLint {
    /// supabase/functions/_shared/messages_test.ts の
    ///   const BANNED_PATTERN = /枯れ|サボ|罰|恥|ダメ|怒|遅い|まだやってない/;
    /// と同じ語。サーバー側を拡充したら、ここも同じに直す
    static let bannedWords: [String] = ["枯れ", "サボ", "罰", "恥", "ダメ", "怒", "遅い", "まだやってない"]

    /// text に含まれる禁止ワード(無ければ空)。
    /// サーバー側(JS の RegExp)は書いてある通りの表記にしか反応しないが、こちらは
    /// ひらがな/カタカナの表記ゆれ(だめ / ダメ、さぼ / サボ)も同じ語として扱って、少し厳しめに見る
    static func violations(in text: String) -> [String] {
        let folded = foldKana(text)
        return bannedWords.filter { word in
            text.contains(word) || folded.contains(foldKana(word))
        }
    }

    /// ひらがなをカタカナに寄せる(表記ゆれを同じ語として比べるため)
    static func foldKana(_ text: String) -> String {
        text.applyingTransform(.hiraganaToKatakana, reverse: false) ?? text
    }

    /// ソース上の文字列リテラルに見つかった違反1件
    struct SourceViolation: Equatable {
        let line: Int
        /// 補間の位置を ⟨…⟩ で示した、リテラルの表示
        let literal: String
        let words: [String]

        var message: String { "Strings.swift:\(line) 禁止ワード \(words) を含む文言: \(literal)" }
    }

    /// literals(Strings.swift から拾ったもの)のうち、禁止ワードを含むものを返す。
    /// 補間 `\( … )` で分かれた固定部分ごとに見る(式の中身は文言ではない)
    static func violations(in literals: [StringLiteralScanner.Literal]) -> [SourceViolation] {
        literals.compactMap { literal in
            let words = literal.fragments.flatMap { violations(in: $0) }
            return words.isEmpty
                ? nil
                : SourceViolation(line: literal.line, literal: literal.display, words: Array(Set(words)).sorted())
        }
    }
}

// MARK: - 文言のカタログ(Strings.swift の全文言)

/// 1つの文言(名前は失敗メッセージ用。例: "Home.inviteButton")
struct ReviewedString {
    let name: String
    let text: String
}

enum StringsCatalog {
    /// 関数型文言に渡す代表的な引数(相手の名前・日数・日時の表記)。
    /// 名前は日本語・英字・絵文字入り、日数は 0 と大きい値を含める
    static let representativeNames = ["ゆうき", "Aki", "🌱はな"]
    static let representativeDays = [0, 1, 23, 365]
    /// お休みチケットの残数の代表(0枚でもバッジを出す — REQUIREMENTS §3.5)
    static let representativeTicketBalances = [0, 1, 2, 5]
    static let representativeDates = ["2026年10月20日 21:00", "Oct 20, 2026 at 9:00 PM"]
    /// 運営の連絡先として文言に入るメールアドレスの代表(メールを開けなかったときの案内)
    static let representativeAddresses = ["support@example.com"]
    /// ゲージの文に入る段階名の代表(最初・途中・最後 — Strings.Plant.stageNames)
    static let representativeStageNames = ["めばえ", "わかば", "みのり"]
    /// リマインドの文言に入る約束の名前の代表(約束の絵文字は 2026-10-26 に UI から廃止したので、文言に入れない)
    static let representativePromiseTitles = ["筋トレ", "まいにち散歩"]
    /// 設定画面の行に出すリマインドの時刻の代表
    static let representativeTimes = ["20:00", "07:30"]
    /// 通報メールの件名に入る「種別」(Strings.Report.kind*)
    static let representativeKinds = [
        Strings.Report.kindPhoto, Strings.Report.kindNickname, Strings.Report.kindPromise,
        Strings.Report.kindPlantName, Strings.Report.kindGeneral,
    ]

    /// Strings.swift の全文言。静的な文言は値そのもの、関数型の文言は代表的な引数で組み立てた出力。
    /// ※ Strings.swift に文言を足したら、ここにも足すこと
    static var all: [ReviewedString] {
        var items: [ReviewedString] = []
        func add(_ name: String, _ text: String) {
            items.append(ReviewedString(name: name, text: text))
        }
        func addPalette(_ name: String, _ palette: [String]) {
            for (i, emoji) in palette.enumerated() { add("\(name)[\(i)]", emoji) }
        }

        // Widget(LienWidget ターゲットと共有する名前空間)
        add("Widget.displayName", Strings.Widget.displayName)
        add("Widget.description", Strings.Widget.description)
        add("Widget.emptyTitle", Strings.Widget.emptyTitle)
        add("Widget.emptyMessage", Strings.Widget.emptyMessage)
        add("Widget.meFallbackLabel", Strings.Widget.meFallbackLabel)
        add("Widget.partnerFallbackLabel", Strings.Widget.partnerFallbackLabel)
        add("Widget.soloCaption", Strings.Widget.soloCaption)
        for name in representativeNames {
            add("Widget.partnerWaiting(\(name))", Strings.Widget.partnerWaiting(name))
            add("Widget.partnerStatus(\(name), done)", Strings.Widget.partnerStatus(name, done: true))
            add("Widget.partnerStatus(\(name), pending)", Strings.Widget.partnerStatus(name, done: false))
        }
        for days in representativeDays {
            add("Widget.streakDays(\(days))", Strings.Widget.streakDays(days))
            add("Widget.streakSpoken(\(days))", Strings.Widget.streakSpoken(days))
        }

        // Onboarding
        add("Onboarding.stepIndicator", Strings.Onboarding.stepIndicator(1))
        add("Onboarding.conceptTitle", Strings.Onboarding.conceptTitle)
        add("Onboarding.conceptBody", Strings.Onboarding.conceptBody)
        add("Onboarding.conceptNote", Strings.Onboarding.conceptNote)
        add("Onboarding.conceptStart", Strings.Onboarding.conceptStart)
        add("Onboarding.profileTitle", Strings.Onboarding.profileTitle)
        add("Onboarding.nicknamePlaceholder", Strings.Onboarding.nicknamePlaceholder)
        add("Onboarding.nicknameEmptyError", Strings.Onboarding.nicknameEmptyError)
        add("Onboarding.nicknameTooLongError", Strings.Onboarding.nicknameTooLongError)
        add("Onboarding.nicknameRequiredHint", Strings.Onboarding.nicknameRequiredHint)
        add("Onboarding.consentRequiredHint", Strings.Onboarding.consentRequiredHint)
        add("Onboarding.avatarTitle", Strings.Onboarding.avatarTitle)
        add("Onboarding.profileSubmit", Strings.Onboarding.profileSubmit)
        add("Onboarding.anonymousStartNote", Strings.Onboarding.anonymousStartNote)
        add("Onboarding.notificationTitle", Strings.Onboarding.notificationTitle)
        add("Onboarding.notificationBody", Strings.Onboarding.notificationBody)
        add("Onboarding.notificationAllow", Strings.Onboarding.notificationAllow)
        add("Onboarding.notificationLater", Strings.Onboarding.notificationLater)
        add("Onboarding.submitErrorMessage", Strings.Onboarding.submitErrorMessage)
        add("Onboarding.retry", Strings.Onboarding.retry)

        // Avatar(プロフィールのアイコン = タネの子のイラスト12種の名前。VoiceOver の読み上げ)
        add("Avatar.sprout", Strings.Avatar.sprout)
        add("Avatar.cactus", Strings.Avatar.cactus)
        add("Avatar.star", Strings.Avatar.star)
        add("Avatar.mushroom", Strings.Avatar.mushroom)
        add("Avatar.clover", Strings.Avatar.clover)
        add("Avatar.moon", Strings.Avatar.moon)
        add("Avatar.tulip", Strings.Avatar.tulip)
        add("Avatar.sunflower", Strings.Avatar.sunflower)
        add("Avatar.acorn", Strings.Avatar.acorn)
        add("Avatar.sakura", Strings.Avatar.sakura)
        add("Avatar.strawberry", Strings.Avatar.strawberry)
        add("Avatar.drop", Strings.Avatar.drop)
        add("Avatar.label", Strings.Avatar.label(Strings.Avatar.sprout))

        // Pairing
        add("Pairing.title", Strings.Pairing.title)
        add("Pairing.subtitle", Strings.Pairing.subtitle)
        add("Pairing.inviteSectionTitle", Strings.Pairing.inviteSectionTitle)
        add("Pairing.inviteExplainer", Strings.Pairing.inviteExplainer)
        add("Pairing.issueButton", Strings.Pairing.issueButton)
        add("Pairing.codeCaption", Strings.Pairing.codeCaption)
        add("Pairing.qrCaption", Strings.Pairing.qrCaption)
        add("Pairing.shareButton", Strings.Pairing.shareButton)
        add("Pairing.shareMessage", Strings.Pairing.shareMessage)
        add("Pairing.closeButton", Strings.Pairing.closeButton)
        add("Pairing.acceptSectionTitle", Strings.Pairing.acceptSectionTitle)
        add("Pairing.acceptExplainer", Strings.Pairing.acceptExplainer)
        add("Pairing.codePlaceholder", Strings.Pairing.codePlaceholder)
        add("Pairing.acceptButton", Strings.Pairing.acceptButton)
        add("Pairing.errorAlreadyPaired", Strings.Pairing.errorAlreadyPaired)
        add("Pairing.errorPartnerAlreadyPaired", Strings.Pairing.errorPartnerAlreadyPaired)
        add("Pairing.errorInviteNotFound", Strings.Pairing.errorInviteNotFound)
        add("Pairing.errorInviteExpired", Strings.Pairing.errorInviteExpired)
        add("Pairing.errorInviteAlreadyUsed", Strings.Pairing.errorInviteAlreadyUsed)
        add("Pairing.errorCannotAcceptOwnInvite", Strings.Pairing.errorCannotAcceptOwnInvite)
        add("Pairing.errorInvalidTokenFormat", Strings.Pairing.errorInvalidTokenFormat)
        add("Pairing.errorNetwork", Strings.Pairing.errorNetwork)
        for date in representativeDates {
            add("Pairing.expiresNote(\(date))", Strings.Pairing.expiresNote(date))
        }

        // PromiseSetup
        add("PromiseSetup.title", Strings.PromiseSetup.title)
        add("PromiseSetup.subtitle", Strings.PromiseSetup.subtitle)
        add("PromiseSetup.titleSectionTitle", Strings.PromiseSetup.titleSectionTitle)
        add("PromiseSetup.titlePlaceholder", Strings.PromiseSetup.titlePlaceholder)
        add("PromiseSetup.titleEmptyError", Strings.PromiseSetup.titleEmptyError)
        add("PromiseSetup.titleTooLongError", Strings.PromiseSetup.titleTooLongError)
        add("PromiseSetup.remindSectionTitle", Strings.PromiseSetup.remindSectionTitle)
        add("PromiseSetup.remindToggleLabel", Strings.PromiseSetup.remindToggleLabel)
        add("PromiseSetup.remindTimeLabel", Strings.PromiseSetup.remindTimeLabel)
        add("PromiseSetup.saveButton", Strings.PromiseSetup.saveButton)
        add("PromiseSetup.editKeepsStreakNote", Strings.PromiseSetup.editKeepsStreakNote)
        add("PromiseSetup.saveErrorMessage", Strings.PromiseSetup.saveErrorMessage)

        // Home
        add("Home.soloCaption", Strings.Home.soloCaption)
        add("Home.soloInviteHint", Strings.Home.soloInviteHint)
        add("Home.inviteButton", Strings.Home.inviteButton)
        add("Home.streakCaption", Strings.Home.streakCaption)
        add("Home.todaySectionTitle", Strings.Home.todaySectionTitle)
        add("Home.meFallbackLabel", Strings.Home.meFallbackLabel)
        add("Home.partnerFallbackLabel", Strings.Home.partnerFallbackLabel)
        add("Home.promiseUnsetLabel", Strings.Home.promiseUnsetLabel)
        add("Home.bothDoneCelebration", Strings.Home.bothDoneCelebration)
        add("Home.checkinButton", Strings.Home.checkinButton)
        add("Home.checkinDoneLabel", Strings.Home.checkinDoneLabel)
        add("Home.checkinErrorMessage", Strings.Home.checkinErrorMessage)
        add("Home.emptyTitle", Strings.Home.emptyTitle)
        add("Home.emptyMessage", Strings.Home.emptyMessage)
        for days in representativeDays {
            add("Home.streakDays(\(days))", Strings.Home.streakDays(days))
            add("Home.streakBestNote(\(days))", Strings.Home.streakBestNote(days))
        }
        for name in representativeNames {
            add("Home.partnerWaiting(\(name))", Strings.Home.partnerWaiting(name))
        }

        // Tickets(お休みチケットの残数バッジ — T19a #19)
        for count in representativeTicketBalances {
            add("Tickets.balance(\(count))", Strings.Tickets.balance(count))
        }

        // Paywall(プレミアムのペイウォール — T33 / REQUIREMENTS §3.14)
        add("Paywall.title", Strings.Paywall.title)
        add("Paywall.closeButton", Strings.Paywall.closeButton)
        add("Paywall.benefitsTitle", Strings.Paywall.benefitsTitle)
        for (index, benefit) in Strings.Paywall.benefits.enumerated() {
            add("Paywall.benefits[\(index)]", benefit)
        }
        add("Paywall.monthlyPrefix", Strings.Paywall.monthlyPrefix)
        add("Paywall.yearlyPrefix", Strings.Paywall.yearlyPrefix)
        add("Paywall.recommended", Strings.Paywall.recommended)
        add("Paywall.trialNote(17)", Strings.Paywall.trialNote(17))
        add("Paywall.purchaseButton", Strings.Paywall.purchaseButton)
        add("Paywall.purchasing", Strings.Paywall.purchasing)
        add("Paywall.restoreButton", Strings.Paywall.restoreButton)
        add("Paywall.restoring", Strings.Paywall.restoring)
        add("Paywall.appliedByPartner", Strings.Paywall.appliedByPartner)
        add("Paywall.purchaseDone", Strings.Paywall.purchaseDone)
        add("Paywall.restoreDone", Strings.Paywall.restoreDone)
        add("Paywall.restoreNotFound", Strings.Paywall.restoreNotFound)
        add("Paywall.unavailable", Strings.Paywall.unavailable)
        add("Paywall.errorMessage", Strings.Paywall.errorMessage)
        add("Paywall.cancelled", Strings.Paywall.cancelled)
        add("Paywall.pending", Strings.Paywall.pending)
        add("Paywall.legalNote", Strings.Paywall.legalNote)
        add("Paywall.terms", Strings.Paywall.terms)
        add("Paywall.privacy", Strings.Paywall.privacy)
        add("Paywall.milestoneHeadline(30)", Strings.Paywall.milestoneHeadline(30))
        add("Paywall.milestoneMessage", Strings.Paywall.milestoneMessage)
        add("Paywall.albumHeadline", Strings.Paywall.albumHeadline)
        add("Paywall.albumMessage", Strings.Paywall.albumMessage)
        add("Paywall.ticketEmptyHeadline", Strings.Paywall.ticketEmptyHeadline)
        add("Paywall.ticketEmptyMessage", Strings.Paywall.ticketEmptyMessage)

        // Checkin
        add("Checkin.attachPhotoButton", Strings.Checkin.attachPhotoButton)
        add("Checkin.attachPhotoSending", Strings.Checkin.attachPhotoSending)
        add("Checkin.attachPhotoDoneNote", Strings.Checkin.attachPhotoDoneNote)
        add("Checkin.attachPhotoErrorMessage", Strings.Checkin.attachPhotoErrorMessage)
        add("Checkin.cancelButton", Strings.Checkin.cancelButton)
        add("Checkin.cancelDialogTitle", Strings.Checkin.cancelDialogTitle)
        add("Checkin.cancelDialogMessage", Strings.Checkin.cancelDialogMessage)
        add("Checkin.cancelConfirm", Strings.Checkin.cancelConfirm)
        add("Checkin.cancelKeep", Strings.Checkin.cancelKeep)
        add("Checkin.cancelErrorMessage", Strings.Checkin.cancelErrorMessage)

        // Nudge
        add("Nudge.button", Strings.Nudge.button)
        add("Nudge.sheetTitle", Strings.Nudge.sheetTitle)
        add("Nudge.sheetSubtitle", Strings.Nudge.sheetSubtitle)
        add("Nudge.sentNote", Strings.Nudge.sentNote)
        add("Nudge.limitReachedMessage", Strings.Nudge.limitReachedMessage)
        add("Nudge.errorMessage", Strings.Nudge.errorMessage)

        // Reaction
        add("Reaction.button", Strings.Reaction.button)
        add("Reaction.sheetTitle", Strings.Reaction.sheetTitle)
        add("Reaction.sentNote", Strings.Reaction.sentNote)
        add("Reaction.errorMessage", Strings.Reaction.errorMessage)

        // PartnerPhoto(相手の今日の写真 — PV #59)
        add("PartnerPhoto.openHint", Strings.PartnerPhoto.openHint)
        add("PartnerPhoto.loadingLabel", Strings.PartnerPhoto.loadingLabel)
        add("PartnerPhoto.viewerCloseButton", Strings.PartnerPhoto.viewerCloseButton)
        add("PartnerPhoto.viewerMenuButton", Strings.PartnerPhoto.viewerMenuButton)
        for name in representativeNames {
            add("PartnerPhoto.caption(\(name))", Strings.PartnerPhoto.caption(name))
            add("PartnerPhoto.viewerLabel(\(name))", Strings.PartnerPhoto.viewerLabel(name))
        }

        // Share(シェア画像 — REQUIREMENTS §3.13 / T22)
        add("Share.title", Strings.Share.title)
        add("Share.createButton", Strings.Share.createButton)
        add("Share.shortButton", Strings.Share.shortButton)
        add("Share.subtitle", Strings.Share.subtitle)
        add("Share.formatPickerLabel", Strings.Share.formatPickerLabel)
        add("Share.formatStory", Strings.Share.formatStory)
        add("Share.formatSquare", Strings.Share.formatSquare)
        add("Share.loading", Strings.Share.loading)
        add("Share.shareButton", Strings.Share.shareButton)
        add("Share.closeButton", Strings.Share.closeButton)
        add("Share.retry", Strings.Share.retry)
        add("Share.unavailableMessage", Strings.Share.unavailableMessage)
        add("Share.errorMessage", Strings.Share.errorMessage)
        add("Share.privacyNote", Strings.Share.privacyNote)
        add("Share.streakCaption", Strings.Share.streakCaption)
        add("Share.dayUnit", Strings.Share.dayUnit)
        add("Share.meFallbackName", Strings.Share.meFallbackName)
        add("Share.partnerFallbackName", Strings.Share.partnerFallbackName)
        add("Share.milestoneBody", Strings.Share.milestoneBody)
        for name in representativeNames {
            add("Share.names(\(name), \(name))", Strings.Share.names(name, name))
            add("Share.previewLabel(\(name), \(name), 30)", Strings.Share.previewLabel(name, name, 30))
        }
        for date in representativeDates {
            add("Share.startedOn(\(date))", Strings.Share.startedOn(date))
        }
        for days in representativeDays {
            add("Share.milestoneTitle(\(days))", Strings.Share.milestoneTitle(days))
            add("Share.sharePreviewTitle(\(days))", Strings.Share.sharePreviewTitle(days))
        }

        // Onboarding(規約への同意 — T23 #23)
        add("Onboarding.consentLabel", Strings.Onboarding.consentLabel)
        add("Onboarding.consentTermsLink", Strings.Onboarding.consentTermsLink)
        add("Onboarding.consentPrivacyLink", Strings.Onboarding.consentPrivacyLink)
        add("Onboarding.consentNote", Strings.Onboarding.consentNote)
        add("Onboarding.consentCheckedValue", Strings.Onboarding.consentCheckedValue)
        add("Onboarding.consentUncheckedValue", Strings.Onboarding.consentUncheckedValue)

        // Settings
        add("Settings.title", Strings.Settings.title)
        add("Settings.closeButton", Strings.Settings.closeButton)
        add("Settings.openButtonLabel", Strings.Settings.openButtonLabel)
        add("Settings.profileSection", Strings.Settings.profileSection)
        add("Settings.nicknameLabel", Strings.Settings.nicknameLabel)
        add("Settings.loadFailed", Strings.Settings.loadFailed)
        add("Settings.retry", Strings.Settings.retry)
        add("Settings.profileEditTitle", Strings.Settings.profileEditTitle)
        add("Settings.profileEditFooter", Strings.Settings.profileEditFooter)
        add("Settings.profileSave", Strings.Settings.profileSave)
        add("Settings.profileSaving", Strings.Settings.profileSaving)
        add("Settings.profileSavedNote", Strings.Settings.profileSavedNote)
        add("Settings.profileSaveError", Strings.Settings.profileSaveError)
        add("Settings.promiseSection", Strings.Settings.promiseSection)
        add("Settings.promiseUnset", Strings.Settings.promiseUnset)
        add("Settings.promiseEditRow", Strings.Settings.promiseEditRow)
        add("Settings.promiseSavedNote", Strings.Settings.promiseSavedNote)
        add("Settings.notificationSection", Strings.Settings.notificationSection)
        add("Settings.notificationRow", Strings.Settings.notificationRow)
        add("Settings.notificationFooter", Strings.Settings.notificationFooter)
        add("Settings.pairSection", Strings.Settings.pairSection)
        add("Settings.partnerLabel", Strings.Settings.partnerLabel)
        add("Settings.soloNote", Strings.Settings.soloNote)
        add("Settings.dissolveRow", Strings.Settings.dissolveRow)
        add("Settings.dissolveFooter", Strings.Settings.dissolveFooter)
        add("Settings.dissolvedNote", Strings.Settings.dissolvedNote)
        add("Settings.supportSection", Strings.Settings.supportSection)
        add("Settings.contactRow", Strings.Settings.contactRow)
        add("Settings.reportRow", Strings.Settings.reportRow)
        add("Settings.termsRow", Strings.Settings.termsRow)
        add("Settings.privacyRow", Strings.Settings.privacyRow)
        add("Settings.supportFooter", Strings.Settings.supportFooter)
        add("Settings.accountSection", Strings.Settings.accountSection)
        add("Settings.signOutRow", Strings.Settings.signOutRow)
        add("Settings.deleteRow", Strings.Settings.deleteRow)
        add("Settings.accountFooter", Strings.Settings.accountFooter)
        add("Settings.versionLabel", Strings.Settings.versionLabel)

        // SignOut
        add("SignOut.confirmTitle", Strings.SignOut.confirmTitle)
        add("SignOut.confirmMessage", Strings.SignOut.confirmMessage)
        add("SignOut.confirmButton", Strings.SignOut.confirmButton)
        add("SignOut.cancel", Strings.SignOut.cancel)

        // Dissolve
        add("Dissolve.screenTitle", Strings.Dissolve.screenTitle)
        add("Dissolve.lead", Strings.Dissolve.lead)
        add("Dissolve.effectPhotos", Strings.Dissolve.effectPhotos)
        add("Dissolve.effectNudges", Strings.Dissolve.effectNudges)
        add("Dissolve.effectArchive", Strings.Dissolve.effectArchive)
        add("Dissolve.effectHistory", Strings.Dissolve.effectHistory)
        add("Dissolve.partnerNote", Strings.Dissolve.partnerNote)
        add("Dissolve.button", Strings.Dissolve.button)
        add("Dissolve.finalTitle", Strings.Dissolve.finalTitle)
        add("Dissolve.finalMessage", Strings.Dissolve.finalMessage)
        add("Dissolve.finalConfirm", Strings.Dissolve.finalConfirm)
        add("Dissolve.cancel", Strings.Dissolve.cancel)
        add("Dissolve.working", Strings.Dissolve.working)
        add("Dissolve.errorMessage", Strings.Dissolve.errorMessage)

        // DeleteAccount
        add("DeleteAccount.screenTitle", Strings.DeleteAccount.screenTitle)
        add("DeleteAccount.lead", Strings.DeleteAccount.lead)
        add("DeleteAccount.effectProfile", Strings.DeleteAccount.effectProfile)
        add("DeleteAccount.effectPhotos", Strings.DeleteAccount.effectPhotos)
        add("DeleteAccount.effectPair", Strings.DeleteAccount.effectPair)
        add("DeleteAccount.irreversible", Strings.DeleteAccount.irreversible)
        add("DeleteAccount.button", Strings.DeleteAccount.button)
        add("DeleteAccount.finalTitle", Strings.DeleteAccount.finalTitle)
        add("DeleteAccount.finalMessage", Strings.DeleteAccount.finalMessage)
        add("DeleteAccount.finalConfirm", Strings.DeleteAccount.finalConfirm)
        add("DeleteAccount.cancel", Strings.DeleteAccount.cancel)
        add("DeleteAccount.working", Strings.DeleteAccount.working)
        add("DeleteAccount.errorMessage", Strings.DeleteAccount.errorMessage)

        // Report
        add("Report.menuReportPhoto", Strings.Report.menuReportPhoto)
        add("Report.menuReportNickname", Strings.Report.menuReportNickname)
        add("Report.menuReportPromise", Strings.Report.menuReportPromise)
        add("Report.menuReportPlantName", Strings.Report.menuReportPlantName)
        add("Report.menuBlock", Strings.Report.menuBlock)
        add("Report.confirmTitle", Strings.Report.confirmTitle)
        add("Report.confirmMessage", Strings.Report.confirmMessage)
        add("Report.openMail", Strings.Report.openMail)
        add("Report.cancel", Strings.Report.cancel)
        add("Report.mailFailedTitle", Strings.Report.mailFailedTitle)
        add("Report.mailFailedMessage", Strings.Report.mailFailedMessage)
        for address in representativeAddresses {
            add("Report.mailFailedMessage(\(address))", Strings.Report.mailFailedMessage(contactAddress: address))
        }
        add("Report.mailFailedOK", Strings.Report.mailFailedOK)
        add("Report.kindPhoto", Strings.Report.kindPhoto)
        add("Report.kindNickname", Strings.Report.kindNickname)
        add("Report.kindPromise", Strings.Report.kindPromise)
        add("Report.kindPlantName", Strings.Report.kindPlantName)
        add("Report.kindGeneral", Strings.Report.kindGeneral)
        add("Report.bodyIntro", Strings.Report.bodyIntro)
        add("Report.kindLabel", Strings.Report.kindLabel)
        add("Report.pairIdLabel", Strings.Report.pairIdLabel)
        add("Report.dateLabel", Strings.Report.dateLabel)
        add("Report.targetLabel", Strings.Report.targetLabel)
        add("Report.noPair", Strings.Report.noPair)
        add("Report.appVersionLabel", Strings.Report.appVersionLabel)
        add("Report.notesLabel", Strings.Report.notesLabel)
        for kind in representativeKinds {
            add("Report.subject(\(kind))", Strings.Report.subject(kind))
        }

        // Contact
        add("Contact.subject", Strings.Contact.subject)
        add("Contact.bodyIntro", Strings.Contact.bodyIntro)
        add("Contact.bodyPlaceholder", Strings.Contact.bodyPlaceholder)

        // Session
        add("Session.lostTitle", Strings.Session.lostTitle)
        add("Session.lostMessage", Strings.Session.lostMessage)
        add("Session.restart", Strings.Session.restart)
        add("Session.later", Strings.Session.later)

        // LocalNotification(端末のローカル通知 — T16 #16)
        add("LocalNotification.title", Strings.LocalNotification.title)
        for promiseTitle in representativePromiseTitles {
            for (index, line) in Strings.LocalNotification.reminderBodies(promiseTitle).enumerated() {
                add("LocalNotification.reminderBodies(\(promiseTitle))[\(index)]", line)
            }
        }
        for days in representativeDays {
            add("LocalNotification.streakRiskNeither(\(days))", Strings.LocalNotification.streakRiskNeither(days: days))
            for name in representativeNames {
                add(
                    "LocalNotification.streakRiskPartnerDone(\(name), \(days))",
                    Strings.LocalNotification.streakRiskPartnerDone(partnerName: name, days: days)
                )
                add(
                    "LocalNotification.streakRiskMeDone(\(name), \(days))",
                    Strings.LocalNotification.streakRiskMeDone(partnerName: name, days: days)
                )
            }
        }

        // NotificationSettings(通知の設定画面 — T16 #16)
        add("NotificationSettings.title", Strings.NotificationSettings.title)
        add("NotificationSettings.deniedNotice", Strings.NotificationSettings.deniedNotice)
        add("NotificationSettings.reminderSection", Strings.NotificationSettings.reminderSection)
        add("NotificationSettings.reminderToggle", Strings.NotificationSettings.reminderToggle)
        add("NotificationSettings.reminderTime", Strings.NotificationSettings.reminderTime)
        add("NotificationSettings.reminderFooter", Strings.NotificationSettings.reminderFooter)
        add("NotificationSettings.reminderNoPromise", Strings.NotificationSettings.reminderNoPromise)
        add("NotificationSettings.reminderSave", Strings.NotificationSettings.reminderSave)
        add("NotificationSettings.reminderSaving", Strings.NotificationSettings.reminderSaving)
        add("NotificationSettings.reminderSaved", Strings.NotificationSettings.reminderSaved)
        add("NotificationSettings.reminderSaveError", Strings.NotificationSettings.reminderSaveError)
        add("NotificationSettings.loadFailed", Strings.NotificationSettings.loadFailed)
        add("NotificationSettings.retry", Strings.NotificationSettings.retry)
        add("NotificationSettings.streakSection", Strings.NotificationSettings.streakSection)
        add("NotificationSettings.streakToggle", Strings.NotificationSettings.streakToggle)
        add("NotificationSettings.streakFooter", Strings.NotificationSettings.streakFooter)
        add("NotificationSettings.partnerSection", Strings.NotificationSettings.partnerSection)
        add("NotificationSettings.partnerFooter", Strings.NotificationSettings.partnerFooter)
        add("NotificationSettings.openSystemSettings", Strings.NotificationSettings.openSystemSettings)
        add("NotificationSettings.summaryOff", Strings.NotificationSettings.summaryOff)
        for time in representativeTimes {
            add("NotificationSettings.summaryDaily(\(time))", Strings.NotificationSettings.summaryDaily(time))
        }

        // Plant(植物 — PB #57)
        addPalette("Plant.stageNames", Strings.Plant.stageNames)
        for stage in -1...11 {
            add("Plant.stageName(\(stage))", Strings.Plant.stageName(stage))
        }
        for days in representativeDays {
            for stageName in representativeStageNames {
                add("Plant.gaugeRemaining(\(days), \(stageName))", Strings.Plant.gaugeRemaining(days, nextStageName: stageName))
                add("Plant.gaugeSinceStage(\(stageName), \(days))", Strings.Plant.gaugeSinceStage(stageName, count: days))
            }
            add("Plant.gaugeLast(\(days))", Strings.Plant.gaugeLast(days))
            add("Plant.gaugeUnknownNext(\(days))", Strings.Plant.gaugeUnknownNext(days))
            add("Plant.stageUpBody(\(days))", Strings.Plant.stageUpBody(days))
        }
        for stageName in Strings.Plant.stageNames {
            add("Plant.stageUpHeadline(\(stageName))", Strings.Plant.stageUpHeadline(stageName))
            add("Plant.celebrationBefore(\(stageName))", Strings.Plant.celebrationBefore(stageName))
            add("Plant.celebrationAfter(\(stageName))", Strings.Plant.celebrationAfter(stageName))
            add("Plant.voiceHeader(みどり, \(stageName))", Strings.Plant.voiceHeader(name: "みどり", stageName: stageName))
            add("Plant.voiceHeader(nil, \(stageName))", Strings.Plant.voiceHeader(name: nil, stageName: stageName))
        }
        for name in representativeNames {
            for (meDone, partnerDone) in [(false, false), (true, false), (false, true), (true, true)] {
                add(
                    "Plant.voiceStatus(\(meDone), \(name), \(partnerDone))",
                    Strings.Plant.voiceStatus(meDone: meDone, partnerName: name, partnerDone: partnerDone)
                )
            }
            add("Plant.celebrationHeart(\(name))", Strings.Plant.celebrationHeart(name))
            add("Plant.nameSavedNote(\(name))", Strings.Plant.nameSavedNote(name))
            add("Plant.nameAdoptedNote(\(name))", Strings.Plant.nameAdoptedNote(name))
            add("Plant.nameFirstNotice(\(name))", Strings.Plant.nameFirstNotice(name))
            add("Plant.nameChangedNotice(\(name))", Strings.Plant.nameChangedNotice(name))
            for (index, line) in Strings.Plant.Whisper.bothDone(name).enumerated() {
                add("Plant.Whisper.bothDone(\(name))[\(index)]", line)
            }
            for (index, line) in Strings.Plant.Whisper.partnerDone(name).enumerated() {
                add("Plant.Whisper.partnerDone(\(name))[\(index)]", line)
            }
            for (index, line) in Strings.Plant.Whisper.meDone(name).enumerated() {
                add("Plant.Whisper.meDone(\(name))[\(index)]", line)
            }
        }
        add("Plant.voiceDone", Strings.Plant.voiceDone)
        add("Plant.voicePending", Strings.Plant.voicePending)
        add("Plant.voiceSolo", Strings.Plant.voiceSolo)
        add("Plant.renameHint", Strings.Plant.renameHint)
        add("Plant.whisperAction", Strings.Plant.whisperAction)
        add("Plant.meetingHeadline", Strings.Plant.meetingHeadline)
        add("Plant.meetingBody", Strings.Plant.meetingBody)
        add("Plant.celebrationClose", Strings.Plant.celebrationClose)
        add("Plant.celebrationHeartSending", Strings.Plant.celebrationHeartSending)
        add("Plant.celebrationHeartSent", Strings.Plant.celebrationHeartSent)
        add("Plant.celebrationHeartError", Strings.Plant.celebrationHeartError)
        add("Plant.welcomeBackHeadline", Strings.Plant.welcomeBackHeadline)
        add("Plant.welcomeBackBody", Strings.Plant.welcomeBackBody)
        add("Plant.nameTitle", Strings.Plant.nameTitle)
        add("Plant.renameTitle", Strings.Plant.renameTitle)
        add("Plant.namePlaceholder", Strings.Plant.namePlaceholder)
        add("Plant.nameNote", Strings.Plant.nameNote)
        add("Plant.nameSubmit", Strings.Plant.nameSubmit)
        add("Plant.renameSubmit", Strings.Plant.renameSubmit)
        add("Plant.nameSaving", Strings.Plant.nameSaving)
        add("Plant.nameLater", Strings.Plant.nameLater)
        add("Plant.nameCancel", Strings.Plant.nameCancel)
        add("Plant.nameButton", Strings.Plant.nameButton)
        add("Plant.nameEmptyError", Strings.Plant.nameEmptyError)
        add("Plant.nameTooLongError", Strings.Plant.nameTooLongError)
        add("Plant.nameInvalidError", Strings.Plant.nameInvalidError)
        add("Plant.nameSaveError", Strings.Plant.nameSaveError)
        add("Plant.nameNoPairError", Strings.Plant.nameNoPairError)
        add("Plant.nameNoticeClose", Strings.Plant.nameNoticeClose)
        for (index, line) in Strings.Plant.Whisper.sleepy.enumerated() { add("Plant.Whisper.sleepy[\(index)]", line) }
        for (index, line) in Strings.Plant.Whisper.morning.enumerated() { add("Plant.Whisper.morning[\(index)]", line) }
        for (index, line) in Strings.Plant.Whisper.daytime.enumerated() { add("Plant.Whisper.daytime[\(index)]", line) }
        for (index, line) in Strings.Plant.Whisper.evening.enumerated() { add("Plant.Whisper.evening[\(index)]", line) }
        for (index, line) in Strings.Plant.Whisper.night.enumerated() { add("Plant.Whisper.night[\(index)]", line) }
        for stage in 0...9 {
            for (index, line) in Strings.Plant.Whisper.stage(stage).enumerated() {
                add("Plant.Whisper.stage(\(stage))[\(index)]", line)
            }
        }

        // History(T18 #18)
        add("History.title", Strings.History.title)
        add("History.openButtonLabel", Strings.History.openButtonLabel)
        add("History.previousMonth", Strings.History.previousMonth)
        add("History.nextMonth", Strings.History.nextMonth)
        for (index, symbol) in Strings.History.weekdaySymbols.enumerated() {
            add("History.weekdaySymbols[\(index)]", symbol)
        }
        add("History.bothDone", Strings.History.bothDone)
        add("History.meOnly", Strings.History.meOnly)
        add("History.partnerOnly", Strings.History.partnerOnly)
        add("History.restTicket", Strings.History.restTicket)
        add("History.noRecord", Strings.History.noRecord)
        add("History.beforePair", Strings.History.beforePair)
        add("History.future", Strings.History.future)
        add("History.todayPending", Strings.History.todayPending)
        add("History.loadFailed", Strings.History.loadFailed)
        add("History.retry", Strings.History.retry)
        add("History.empty", Strings.History.empty)
        for year in [2025, 2026] {
            for month in [1, 10, 12] {
                add("History.monthTitle(\(year), \(month))", Strings.History.monthTitle(year: year, month: month))
            }
        }
        for day in [1, 5, 31] {
            add("History.dayTitle(\(day))", Strings.History.dayTitle(month: 10, day: day))
        }
        for mark in [
            Strings.History.bothDone, Strings.History.meOnly, Strings.History.partnerOnly,
            Strings.History.restTicket, Strings.History.noRecord, Strings.History.beforePair,
            Strings.History.future, Strings.History.todayPending,
        ] {
            add(
                "History.dayAccessibility(\(mark))",
                Strings.History.dayAccessibility(Strings.History.dayTitle(month: 10, day: 5), mark)
            )
        }

        return items
    }
}

// MARK: - リテラルとカタログの照合(完全一致)

enum LiteralMatcher {
    /// Strings.swift のリテラル(補間で区切られた固定部分 `fragments`)が、`text`(カタログの文言)と一致するか。
    ///   - 断片が1つ(補間なし): `text` と完全に同じ
    ///   - 断片が2つ以上(補間あり): `text` が最初の断片で始まり、最後の断片で終わり、間の断片がこの順に(重ならずに)現れる。
    ///     補間の位置には任意の文字列が入る
    /// 比べるのは UTF-8 のバイト列(正規化・書記素の扱いに左右されない。「見た目が同じ別の表記」は別の文字列)
    static func matches(fragments: [String], text: String) -> Bool {
        let bytes = Array(text.utf8)
        let parts = fragments.map { Array($0.utf8) }
        guard let first = parts.first, let last = parts.last else { return false }
        if parts.count == 1 {
            return !first.isEmpty && bytes == first
        }
        guard
            bytes.count >= first.count + last.count,
            bytes.starts(with: first),
            bytes.suffix(last.count).elementsEqual(last)
        else { return false }
        var cursor = first.count
        let end = bytes.count - last.count
        for middle in parts.dropFirst().dropLast() {
            guard let found = firstIndex(of: middle, in: bytes, from: cursor, to: end) else { return false }
            cursor = found + middle.count
        }
        return true
    }

    /// bytes[from..<to] の中で、pattern が最初に現れる位置(無ければ nil。空のパターンは from)
    private static func firstIndex(of pattern: [UInt8], in bytes: [UInt8], from: Int, to: Int) -> Int? {
        if pattern.isEmpty { return from }
        guard to - from >= pattern.count else { return nil }
        var start = from
        while start + pattern.count <= to {
            if bytes[start..<(start + pattern.count)].elementsEqual(pattern) { return start }
            start += 1
        }
        return nil
    }
}

// MARK: - リポジトリ内のファイルの場所

private enum LienSourceFiles {
    /// products/lien/(このテストファイルは products/lien/ios/LienTests/ にある。
    /// シミュレータはホストのファイルを読めるので、CI でもソースの場所をそのまま辿れる — ContractFixtures と同じ方式)
    static func lienRoot(from file: StaticString = #filePath) -> URL {
        URL(fileURLWithPath: "\(file)")
            .deletingLastPathComponent() // LienTests
            .deletingLastPathComponent() // ios
            .deletingLastPathComponent() // lien
    }

    static func read(_ relativePath: String, file: StaticString = #filePath) throws -> String {
        let url = lienRoot(from: file).appendingPathComponent(relativePath)
        do {
            return try String(contentsOf: url, encoding: .utf8)
        } catch {
            throw NSError(
                domain: "StringsReviewTests",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "\(relativePath) が読めません(\(url.path)): \(error)"]
            )
        }
    }

    /// リポジトリ直下からの相対パス(docs/STRINGS-REVIEW.md など)を読む。
    /// products/lien/ の2つ上 = リポジトリのルート
    static func repoRead(_ relativePath: String, file: StaticString = #filePath) throws -> String {
        let url = lienRoot(from: file)
            .deletingLastPathComponent() // products
            .deletingLastPathComponent() // リポジトリのルート
            .appendingPathComponent(relativePath)
        do {
            return try String(contentsOf: url, encoding: .utf8)
        } catch {
            throw NSError(
                domain: "StringsReviewTests",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "\(relativePath) が読めません(\(url.path)): \(error)"]
            )
        }
    }
}

// MARK: - レビューログ(docs/STRINGS-REVIEW.md)の読み取り

/// T27 本体の目視レビューの記録。`StringsCatalog` の名前から引数部・添字を落とした「単位」と、
/// ログの表の1行を対応させる。文言を足したら、ログにも1行足す(忘れると CI が落ちる)。
enum StringsReviewLog {
    static let path = "docs/STRINGS-REVIEW.md"
    /// ログの表では改行を ⏎ で表す(1行の表に収めるため)
    static let newlineMark = "⏎"

    struct Row {
        let name: String
        let text: String
        let verdict: String
        let note: String
    }

    /// 表の行(`| `名前` | 文言 | 判定 | メモ |`)を読む。見出し・説明の表は名前が backtick で始まらないので拾わない
    static func rows() throws -> [Row] {
        let source = try LienSourceFiles.repoRead(path)
        return source.split(separator: "\n", omittingEmptySubsequences: false).compactMap { line in
            guard line.hasPrefix("| `") else { return nil }
            let cells = line.split(separator: "|", omittingEmptySubsequences: false)
                .map { String($0).trimmingCharacters(in: .whitespaces) }
            // 先頭と末尾の空セルを含めて 6 個。文言・メモに `|` は使わない(使うときは ｜ にする)
            guard
                cells.count == 6,
                cells[1].hasPrefix("`"),
                cells[1].hasSuffix("`"),
                // 判定の列がある表だけを読む(§3 の「変更前 → 変更後」の表も backtick で始まるため)
                ["OK", "修正", "保留"].contains(cells[3])
            else { return nil }
            return Row(
                name: String(cells[1].dropFirst().dropLast()),
                text: cells[2],
                verdict: cells[3],
                note: cells[4]
            )
        }
    }

    /// レビューの単位。`StringsCatalog` の名前から、関数の引数部 `(…)` と配列の添字 `[n]` を落とす。
    /// 例: `Plant.voiceHeader(みどり, たね)` → `Plant.voiceHeader` / `Plant.stageNames[0]` → `Plant.stageNames`
    static func units() -> [(name: String, texts: [String])] {
        var order: [String] = []
        var texts: [String: [String]] = [:]
        for item in StringsCatalog.all {
            let base = baseName(item.name)
            if texts[base] == nil { order.append(base) }
            texts[base, default: []].append(item.text)
        }
        return order.map { (name: $0, texts: texts[$0] ?? []) }
    }

    static func baseName(_ name: String) -> String {
        var base = name
        if let paren = base.firstIndex(of: "(") {
            base = String(base[..<paren])
        }
        if let bracket = base.lastIndex(of: "[") {
            base = String(base[..<bracket])
        }
        return base
    }
}

// MARK: - lint 本体

final class StringsReviewTests: XCTestCase {
    private func stringsSwiftLiterals() throws -> [StringLiteralScanner.Literal] {
        let source = try LienSourceFiles.read("ios/Lien/Core/Strings.swift")
        return try StringLiteralScanner.literals(in: source)
    }

    // MARK: 1. Strings.swift のソース上の全リテラル(本線)

    func testEveryStringLiteralInStringsSwiftIsFreeOfPunitiveWords() throws {
        let literals = try stringsSwiftLiterals()

        // 読めている確認: 実在する文言が拾えていること(拾えていないのに「違反なし」で通るのを防ぐ)
        let allFragments = Set(literals.flatMap(\.fragments))
        XCTAssertTrue(allFragments.contains(Strings.Onboarding.conceptTitle), "Strings.swift の文言を拾えていない")
        XCTAssertTrue(allFragments.contains(Strings.Home.checkinButton), "Strings.swift の文言を拾えていない")

        let found = PunishmentFreeLint.violations(in: literals)
        XCTAssertTrue(found.isEmpty, "罰・恥系の禁止ワードを含む文言:\n" + found.map(\.message).joined(separator: "\n"))
    }

    func testLintFindsPunitiveWordsInSourceLiterals() throws {
        // lint 自体が働くことの確認(文言の一覧が空振りで「違反なし」にならないように)
        let source = """
        enum Strings {
            // 「枯れる」「サボり」のようなワードを使わない(コメントの中は文言ではないので対象外)
            static let ok = "ふたりのペースでいこう"
            static let bad = "あと3日で枯れちゃうよ"
            static func template(_ name: String) -> String { "\\(name)はサボってる?" }
            static let hiragana = "だめだよ"
        }
        """
        let found = PunishmentFreeLint.violations(in: try StringLiteralScanner.literals(in: source))
        XCTAssertEqual(found.map(\.line), [4, 5, 6])
        XCTAssertEqual(found.map(\.words), [["枯れ"], ["サボ"], ["ダメ"]])
        XCTAssertEqual(found[1].literal, "⟨…⟩はサボってる?")

        // 責めない文言と、コメントだけの禁止ワードは違反にしない
        let clean = """
        // サボらせない、のような説明のコメント
        static let a = "また明日ね"
        """
        XCTAssertEqual(PunishmentFreeLint.violations(in: try StringLiteralScanner.literals(in: clean)), [])
    }

    func testNoEmptyStringLiteralInStringsSwift() throws {
        for literal in try stringsSwiftLiterals() {
            let isBlank = literal.fragments.allSatisfy {
                $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
            // 補間だけのリテラル("\(x)")も、見える文言が空になりうるので同じく不可
            XCTAssertFalse(isBlank, "Strings.swift:\(literal.line) 空(または空白だけ)の文言: \(literal.display)")
        }
    }

    // MARK: 2. カタログ(実行時の値。関数型の文言は代表的な引数で組み立てた出力)

    func testCatalogStringsAreFreeOfPunitiveWordsAndWellFormed() {
        let catalog = StringsCatalog.all
        XCTAssertGreaterThan(catalog.count, 100)

        for item in catalog {
            XCTAssertEqual(
                PunishmentFreeLint.violations(in: item.text),
                [],
                "Strings.\(item.name) が罰・恥系の禁止ワードを含む: \(item.text)"
            )
            XCTAssertFalse(
                item.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                "Strings.\(item.name) が空文言"
            )
            // 組み立て損ない(補間の取りこぼし・書式指定子の混入)
            XCTAssertFalse(item.text.contains("\\("), "Strings.\(item.name) に補間の記法が残っている: \(item.text)")
            XCTAssertFalse(item.text.contains("%@"), "Strings.\(item.name) に書式指定子が残っている: \(item.text)")
            XCTAssertFalse(item.text.contains("%d"), "Strings.\(item.name) に書式指定子が残っている: \(item.text)")
        }
    }

    func testCatalogNamesAreUnique() {
        var seen = Set<String>()
        for item in StringsCatalog.all {
            XCTAssertTrue(seen.insert(item.name).inserted, "カタログの名前が重複: \(item.name)")
        }
    }

    func testFunctionStringsEmbedTheirArguments() {
        // 代表的な引数が文言に反映されている(引数を無視した固定文言になっていない)
        for name in StringsCatalog.representativeNames {
            XCTAssertTrue(Strings.Widget.partnerWaiting(name).contains(name))
            // ロック画面・円形の読み上げ(T17a #17): 名前と、完了 / まだ
            XCTAssertEqual(Strings.Widget.partnerStatus(name, done: true), "\(name): \(Strings.Plant.voiceDone)")
            XCTAssertEqual(Strings.Widget.partnerStatus(name, done: false), "\(name): \(Strings.Plant.voicePending)")
            XCTAssertTrue(Strings.Home.partnerWaiting(name).contains(name))
            XCTAssertTrue(Strings.PartnerPhoto.caption(name).contains(name))
            XCTAssertTrue(Strings.PartnerPhoto.viewerLabel(name).contains(name))
        }
        for days in StringsCatalog.representativeDays {
            XCTAssertTrue(Strings.Widget.streakDays(days).contains("\(days)"))
            XCTAssertEqual(Strings.Widget.streakSpoken(days), "\(Strings.Home.streakCaption): \(days)日")
            XCTAssertTrue(Strings.Home.streakDays(days).contains("\(days)"))
            XCTAssertTrue(Strings.Home.streakBestNote(days).contains("\(days)"))
        }
        for date in StringsCatalog.representativeDates {
            XCTAssertTrue(Strings.Pairing.expiresNote(date).contains(date))
        }
        for kind in StringsCatalog.representativeKinds {
            XCTAssertTrue(Strings.Report.subject(kind).contains(kind))
        }
        // ローカル通知(T16 #16): 約束の名前・相手の名前・続いている日数が文言に入る(約束の絵文字は入れない — 2026-10-26 に UI から廃止)
        for promiseTitle in StringsCatalog.representativePromiseTitles {
            let bodies = Strings.LocalNotification.reminderBodies(promiseTitle)
            XCTAssertEqual(bodies.count, 3)
            for body in bodies {
                XCTAssertTrue(body.contains("『\(promiseTitle)』"), body)
                XCTAssertFalse(
                    body.unicodeScalars.contains { $0.properties.isEmojiPresentation },
                    "約束の絵文字は文言に付けない: \(body)"
                )
            }
        }
        for days in StringsCatalog.representativeDays {
            XCTAssertTrue(Strings.LocalNotification.streakRiskNeither(days: days).contains("\(days)日"))
            for name in StringsCatalog.representativeNames {
                XCTAssertTrue(Strings.LocalNotification.streakRiskPartnerDone(partnerName: name, days: days).contains(name))
                XCTAssertTrue(Strings.LocalNotification.streakRiskPartnerDone(partnerName: name, days: days).contains("\(days)日"))
                XCTAssertTrue(Strings.LocalNotification.streakRiskMeDone(partnerName: name, days: days).contains(name))
                XCTAssertTrue(Strings.LocalNotification.streakRiskMeDone(partnerName: name, days: days).contains("\(days)日"))
            }
        }
        for time in StringsCatalog.representativeTimes {
            XCTAssertTrue(Strings.NotificationSettings.summaryDaily(time).contains(time))
        }
    }

    func testPartnerNotificationFooterSaysAllOfLiensNotificationsStopInTheSystemSettings() {
        // iOS の設定アプリで通知をオフにすると、相手の通知だけでなく、Lien の通知がすべて(リマインドと夜 9 時のお知らせも)止まる。
        // 「相手の通知だけを切れる」と読める文言にしない(T16 #16 の Opus レビュー)
        let footer = Strings.NotificationSettings.partnerFooter
        XCTAssertTrue(footer.contains("すべて止まります"), footer)
        XCTAssertTrue(footer.contains("リマインド"), footer)
        XCTAssertTrue(footer.contains("夜9時"), footer)
        XCTAssertFalse(footer.contains("オン・オフを変えられます"), "相手の通知だけをオン・オフできるようには読ませない: \(footer)")
    }

    // MARK: 3. ソースの全リテラルがカタログに載っている(カタログの陳腐化防止)

    func testCatalogCoversEveryStringLiteralInStringsSwift() throws {
        let catalogTexts = StringsCatalog.all.map(\.text)

        for literal in try stringsSwiftLiterals() {
            // 完全一致: 補間のないリテラルは、カタログの文言のどれかと一字一句同じ。補間のあるリテラルは、
            // 固定部分の並びに、カタログの文言のどれかの全体が一致する(部分一致にしない — LiteralMatcher)
            XCTAssertTrue(
                catalogTexts.contains { LiteralMatcher.matches(fragments: literal.fragments, text: $0) },
                "Strings.swift:\(literal.line) の文言がカタログに無い: \(literal.display) — StringsReviewTests の StringsCatalog.all に足してください"
            )
        }
    }

    func testLiteralMatcherRequiresTheWholeText() {
        // 補間のないリテラル(断片が1つ): 完全一致だけ。部分一致では通さない
        XCTAssertTrue(LiteralMatcher.matches(fragments: ["ふたり達成!"], text: "ふたり達成!"))
        XCTAssertFalse(LiteralMatcher.matches(fragments: ["ふたり達成"], text: "ふたり達成!"), "前方一致だけでは通らない")
        XCTAssertFalse(LiteralMatcher.matches(fragments: ["達成!"], text: "ふたり達成!"), "後方一致だけでは通らない")
        XCTAssertFalse(LiteralMatcher.matches(fragments: ["日"], text: "最高記録 40日"), "短い断片が、どの文言にも含まれて通ってしまわない")
        XCTAssertFalse(LiteralMatcher.matches(fragments: [""], text: "なにか"), "空のリテラルは、文言と一致しない")

        // 補間のあるリテラル: 固定部分の並びに、文言の全体が一致する(補間の位置には任意の文字列が入る)
        XCTAssertTrue(LiteralMatcher.matches(fragments: ["", "が待ってるよ"], text: "ゆうきが待ってるよ"))
        XCTAssertTrue(LiteralMatcher.matches(fragments: ["最高記録 ", "日"], text: "最高記録 40日"))
        XCTAssertFalse(LiteralMatcher.matches(fragments: ["最高記録 ", "日"], text: "最高記録 40日です"), "末尾が違う")
        XCTAssertFalse(LiteralMatcher.matches(fragments: ["最高記録 ", "日"], text: "いまの最高記録 40日"), "先頭が違う")
        XCTAssertTrue(LiteralMatcher.matches(fragments: ["あなた: ", "、", ": ", ""], text: "あなた: 完了、ゆうき: まだ"))
        XCTAssertFalse(
            LiteralMatcher.matches(fragments: ["あなた: ", "、", ": ", ""], text: "あなた: 完了。ゆうき: まだ"),
            "途中の固定部分が、この順に並んでいない"
        )
        // 断片が重ならない: 「ab」+ 補間 + 「bc」は「abc」には一致しない(b が2回要る)
        XCTAssertFalse(LiteralMatcher.matches(fragments: ["ab", "bc"], text: "abc"))
        XCTAssertTrue(LiteralMatcher.matches(fragments: ["ab", "bc"], text: "abbc"))
        // 文字の同一性はバイト列で比べる(見た目が同じ別の表記を同じとは見ない)
        XCTAssertFalse(LiteralMatcher.matches(fragments: ["が"], text: "か\u{3099}"), "濁点の分解形は別の文字列")
    }

    // MARK: 禁止ワード自体の確認

    func testBannedWordsMatchServerSide() throws {
        let source = try LienSourceFiles.read("supabase/functions/_shared/messages_test.ts")
        // const BANNED_PATTERN = /枯れ|サボ|罰|恥|ダメ|怒|遅い|まだやってない/;
        let regex = try NSRegularExpression(pattern: #"const\s+BANNED_PATTERN\s*=\s*/([^/\n]+)/[a-z]*\s*;"#)
        let range = NSRange(source.startIndex..., in: source)
        guard
            let match = regex.firstMatch(in: source, range: range),
            let patternRange = Range(match.range(at: 1), in: source)
        else {
            XCTFail("messages_test.ts に BANNED_PATTERN の定義が見つからない(書き方が変わった?)。この lint の移植元を確かめてください")
            return
        }
        let pattern = String(source[patternRange])

        // 単純な語の並び(a|b|c)だけを受け付ける。正規表現の記号が入ったら、移植のしかたを見直す
        let metacharacters = CharacterSet(charactersIn: "\\^$.?*+()[]{}")
        XCTAssertTrue(
            pattern.unicodeScalars.allSatisfy { !metacharacters.contains($0) },
            "サーバー側の BANNED_PATTERN が単純な語の並びではなくなった。PunishmentFreeLint の移植を見直してください: \(pattern)"
        )

        let serverWords = Set(pattern.split(separator: "|").map(String.init))
        let swiftWords = Set(PunishmentFreeLint.bannedWords)
        XCTAssertEqual(
            swiftWords.subtracting(serverWords),
            [],
            "Swift 版にだけある禁止ワード(サーバー側へも足すか、Swift 側から外すか決める)"
        )
        XCTAssertEqual(
            serverWords.subtracting(swiftWords),
            [],
            "サーバー側(messages_test.ts)に足された禁止ワードが Swift 版に無い — PunishmentFreeLint.bannedWords に足してください"
        )
    }

    func testLintDetectsPunitiveExpressions() {
        // 禁止ワード8語それぞれを含む文を、ひとつずつ検出できること
        let bad: [(text: String, word: String)] = [
            ("あと3日で枯れちゃうよ", "枯れ"),
            ("サボってない?", "サボ"),
            ("ゲームに負けたら罰ゲーム", "罰"),
            ("恥ずかしくないの", "恥"),
            ("ダメだよ、続けなきゃ", "ダメ"),
            ("まだ怒ってるよ", "怒"),
            ("今日も遅いなあ", "遅い"),
            ("まだやってないの?", "まだやってない"),
        ]
        for (text, word) in bad {
            XCTAssertEqual(PunishmentFreeLint.violations(in: text), [word], text)
        }
    }

    func testLintTreatsHiraganaAndKatakanaSpellingsAlike() {
        XCTAssertEqual(PunishmentFreeLint.violations(in: "だめだよ"), ["ダメ"])
        XCTAssertEqual(PunishmentFreeLint.violations(in: "さぼってる"), ["サボ"])
        XCTAssertEqual(PunishmentFreeLint.violations(in: "マダヤッテナイ"), ["まだやってない"])
    }

    func testLintAcceptsGentleExpressions() {
        // 実際に使っている、責めない言い回し
        let gentle = [
            "ゆうきが待ってるよ",
            "今日はもうたくさんつついたよ。また明日ね",
            "また今日から。最高記録 40日 はふたりの財産だよ🌱",
            "通信がうまくいきませんでした。もう一度お試しください",
            "まちがえてタップしたときのために。いつでもまたチェックインできます",
            "約束を変えても、ふたりの記録はそのまま続きます",
        ]
        for text in gentle {
            XCTAssertEqual(PunishmentFreeLint.violations(in: text), [], text)
        }
    }

    // MARK: 4. T27 本体のレビューログ(docs/STRINGS-REVIEW.md)

    func testReviewLogCoversEveryStringsCatalogEntry() throws {
        let units = StringsReviewLog.units()
        let rows = try StringsReviewLog.rows()
        XCTAssertGreaterThan(units.count, 250, "レビューの単位が少なすぎる(StringsCatalog を読めていない?)")

        let rowNames = rows.map(\.name)
        XCTAssertEqual(Set(rowNames).count, rowNames.count, "レビューログに同じ名前が2回出ている")
        let unitNames = Set(units.map(\.name))
        let missing = unitNames.subtracting(rowNames)
        let extra = Set(rowNames).subtracting(unitNames)
        XCTAssertTrue(missing.isEmpty, "レビューログに無い文言: \(missing.sorted())")
        XCTAssertTrue(extra.isEmpty, "レビューログにだけある文言: \(extra.sorted())")
    }

    func testReviewLogTextsMatchStringsCatalog() throws {
        let rows = Dictionary(try StringsReviewLog.rows().map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        for unit in StringsReviewLog.units() {
            guard let row = rows[unit.name] else {
                XCTFail("レビューログに \(unit.name) が無い")
                continue
            }
            if unit.texts.count == 1 {
                XCTAssertEqual(
                    row.text,
                    unit.texts[0].replacingOccurrences(of: "\n", with: StringsReviewLog.newlineMark),
                    "\(unit.name) の文言がログと違う(文言を変えたらログも直す)"
                )
            } else {
                // 関数型・配列は代表を1行だけ載せる。全通りは StringsReviewTests の lint が検査する
                XCTAssertTrue(
                    row.text.contains(unit.texts[0].replacingOccurrences(of: "\n", with: StringsReviewLog.newlineMark)),
                    "\(unit.name) の代表文言がログに無い: \(row.text)"
                )
            }
        }
    }

    func testReviewLogSummaryMatchesVerdicts() throws {
        let source = try LienSourceFiles.repoRead(StringsReviewLog.path)
        let rows = try StringsReviewLog.rows()
        let verdicts = Dictionary(grouping: rows, by: \.verdict).mapValues { $0.count }
        let expected = "- 対象: \(rows.count) 件（OK \(verdicts["OK"] ?? 0) / 修正 \(verdicts["修正"] ?? 0) / 保留 \(verdicts["保留"] ?? 0)）"
        XCTAssertTrue(source.contains(expected), "レビューログの集計が表と違う。期待する行: \(expected)")

        XCTAssertTrue(
            rows.allSatisfy { ["OK", "修正", "保留"].contains($0.verdict) },
            "判定は OK / 修正 / 保留 のいずれか"
        )
        for row in rows where row.verdict == "修正" {
            XCTAssertFalse(row.note.isEmpty, "修正した \(row.name) に理由が無い")
        }
    }

    func testUserFacingStringsAvoidDeveloperJargon() {
        // 画面に出さない開発者ことば(T27 のレビューで「ストリーク」「アーカイブ」を除去した)
        let jargon = ["ストリーク", "アーカイブ", "セッション", "snapshot", "ペイロード", "RLS", "API"]
        for item in StringsCatalog.all {
            for word in jargon {
                XCTAssertFalse(
                    item.text.contains(word),
                    "Strings.\(item.name) に開発者ことば「\(word)」: \(item.text)"
                )
            }
        }
    }

    func testCloseLabelsAreConsistent() {
        let labels = [
            Strings.Settings.closeButton,
            Strings.Report.mailFailedOK,
            Strings.Plant.nameNoticeClose,
            Strings.Plant.celebrationClose,
            Strings.PartnerPhoto.viewerCloseButton,
        ]
        XCTAssertEqual(Set(labels), ["閉じる"], "閉じるボタンの文言を「閉じる」に統一する")
    }

    func testNetworkErrorMessagesAreIdentical() {
        let messages = [
            Strings.Onboarding.submitErrorMessage,
            Strings.Pairing.errorNetwork,
            Strings.PromiseSetup.saveErrorMessage,
            Strings.Home.checkinErrorMessage,
            Strings.Checkin.cancelErrorMessage,
            Strings.Nudge.errorMessage,
            Strings.Reaction.errorMessage,
        ]
        XCTAssertEqual(
            Set(messages),
            ["通信がうまくいきませんでした。もう一度お試しください"],
            "同じ状況の通信エラーは、同じ言い方にする"
        )
    }
}

// MARK: - 字句解析器そのものの確認(lint の「全件拾える」が土台なので、解析器を信頼できる状態にしておく)

final class StringLiteralScannerTests: XCTestCase {
    private func fragments(_ source: String) throws -> [[String]] {
        try StringLiteralScanner.literals(in: source).map(\.fragments)
    }

    func testPlainLiteralsAndLineNumbers() throws {
        let source = "let a = \"こんにちは\"\n\nlet b = \"さようなら\"\n"
        let literals = try StringLiteralScanner.literals(in: source)
        XCTAssertEqual(literals.map(\.fragments), [["こんにちは"], ["さようなら"]])
        XCTAssertEqual(literals.map(\.line), [1, 3])
    }

    func testCommentsAreSkipped() throws {
        let source = """
        // "行コメントの中の文言"
        /// "ドキュメントコメントの中の文言"
        let a = "拾う" // "行末コメントの中の文言"
        /* "ブロックコメント"
           /* "ネストしたブロックコメント" */
           "まだブロックコメントの中" */
        let b = "これも拾う"
        """
        XCTAssertEqual(try fragments(source), [["拾う"], ["これも拾う"]])
    }

    func testDoubleSlashInsideLiteralIsNotAComment() throws {
        XCTAssertEqual(try fragments("let url = \"https://example.com/a\""), [["https://example.com/a"]])
    }

    func testEscapesAreResolved() throws {
        // \n \t \" \\ \u{…}
        let source = #"let a = "行1\n行2\t\"引用\"\\\u{3042}""#
        XCTAssertEqual(try fragments(source), [["行1\n行2\t\"引用\"\\あ"]])
    }

    func testInterpolationSplitsFragmentsAndSkipsTheExpression() throws {
        XCTAssertEqual(try fragments(#"let a = "\(partnerName)が待ってるよ""#), [["", "が待ってるよ"]])
        XCTAssertEqual(try fragments(#"let a = "\(days)日""#), [["", "日"]])
        XCTAssertEqual(try fragments(#"let a = "最高記録 \(days)日""#), [["最高記録 ", "日"]])
        // 式の中の括弧と、式の中の文字列リテラル(これも文言になり得るので別に拾う)
        let nested = try StringLiteralScanner.literals(in: #"let a = "\(f(g(1), flag ? "あり" : "なし"))です""#)
        XCTAssertEqual(Set(nested.map(\.fragments)), [["", "です"], ["あり"], ["なし"]])
    }

    func testEmojiWithVariationSelectorsSurvive() throws {
        XCTAssertEqual(try fragments(#"let p = ["⭐️", "☕️", "✍️", "🗣️"]"#), [["⭐️"], ["☕️"], ["✍️"], ["🗣️"]])
    }

    func testEmptyLiteralIsReported() throws {
        XCTAssertEqual(try fragments("let a = \"\""), [[""]])
    }

    func testUnsupportedSyntaxThrowsInsteadOfSilentlySkipping() {
        XCTAssertThrowsError(try StringLiteralScanner.literals(in: "let a = \"\"\"\nline\n\"\"\"")) { error in
            XCTAssertTrue("\(error)".contains("複数行"), "\(error)")
        }
        XCTAssertThrowsError(try StringLiteralScanner.literals(in: ##"let a = #"raw"#"##)) { error in
            XCTAssertTrue("\(error)".contains("生文字列"), "\(error)")
        }
        XCTAssertThrowsError(try StringLiteralScanner.literals(in: "let a = \"閉じていない\nlet b = 1"))
        XCTAssertThrowsError(try StringLiteralScanner.literals(in: #"let a = "未知のエスケープ\q""#))
    }

    func testHashDirectivesAreNotRawStrings() throws {
        // #if / #Preview("…") / #filePath は生文字列ではない
        let source = """
        #if DEBUG
        let a = "デバッグ"
        #endif
        #Preview("プレビュー") { }
        """
        XCTAssertEqual(try fragments(source), [["デバッグ"], ["プレビュー"]])
    }
}
