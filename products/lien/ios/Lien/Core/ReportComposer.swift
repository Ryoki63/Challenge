// ReportComposer.swift — 通報・お問い合わせのメール(mailto)の組み立て(T23 #23)
//
// 通報の仕組み(App Store ガイドライン 1.2 / REQUIREMENTS §8): 写真・ニックネーム・約束の文・植物の名前を
// ホームで長押しするか、設定の「不適切な内容を通報する」から、運営宛のメールの下書きを開く。
// 運営が内容を特定できるよう、対象の ID(ペア ID・写真のパス)と内容そのもの(ニックネームなど)を
// 本文に入れる。下書きは利用者が確かめてから送る(自動では送らない)。
//
// - 宛先は SupportLinks.contactEmail(G4 で確定。空のあいだは宛先なしの下書き)
// - 組み立ては純粋関数(Foundation だけ)。メールを開く操作そのものは View が openURL で行う
// - 文言は Strings.Report / Strings.Contact

import Foundation

/// 通報の対象(メールの「種別」と「対象」になる)
enum ReportTarget: Equatable, Sendable {
    /// 相手の今日の写真(長押しした写真の指し先。パスに写真の持ち主の user_id が入っている)
    case photo(PartnerPhotoReference)
    /// 相手のニックネーム
    case nickname(String)
    /// 相手の約束の文(絵文字+タイトル)
    case promise(emoji: String?, title: String?)
    /// 植物の名前(どちらのペアも付けられるので、誰が付けたかは区別しない)
    case plantName(String)
    /// 特定の対象を持たない通報(設定の「不適切な内容を通報する」)
    case general

    /// メールの「種別」
    var kindLabel: String {
        switch self {
        case .photo: return Strings.Report.kindPhoto
        case .nickname: return Strings.Report.kindNickname
        case .promise: return Strings.Report.kindPromise
        case .plantName: return Strings.Report.kindPlantName
        case .general: return Strings.Report.kindGeneral
        }
    }

    /// メールの「対象」(運営が内容を特定するための値)。無ければ nil(行を出さない)
    var detail: String? {
        switch self {
        case .photo(let reference):
            return reference.photoPath
        case .nickname(let name):
            return Self.nonEmpty(name)
        case .promise(let emoji, let title):
            let text = [emoji, title].compactMap { $0 }.joined(separator: " ")
            return Self.nonEmpty(text)
        case .plantName(let name):
            return Self.nonEmpty(name)
        case .general:
            return nil
        }
    }

    private static func nonEmpty(_ text: String) -> String? {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : text
    }
}

/// 通報・お問い合わせのメールに添える、いまの状況
struct ReportContext: Equatable, Sendable {
    /// ペア ID(ソロなら nil)
    var pairId: String?
    /// 通報した日(date_local "YYYY-MM-DD")
    var dateLocal: String
    /// アプリのバージョン表記("1.0.0 (45)")
    var appVersion: String

    /// いまの状況から作る。ペア ID は snapshot から、バージョンはバンドルから
    static func current(
        pairId: String?,
        now: Date = Date(),
        calendar: Calendar = .current,
        appVersion: String = ReportContext.appVersionText()
    ) -> ReportContext {
        ReportContext(
            pairId: pairId,
            dateLocal: DayBoundary.dateLocalString(for: now, calendar: calendar),
            appVersion: appVersion
        )
    }

    /// "1.0.0 (45)"。バンドルの Info.plist から
    static func appVersionText(bundle: Bundle = .main) -> String {
        appVersionText(info: bundle.infoDictionary)
    }

    /// Info.plist の辞書から "1.0.0 (45)"。どちらかが読めなければ読めた方だけ。両方読めなければ空文字
    static func appVersionText(info: [String: Any]?) -> String {
        let short = info?["CFBundleShortVersionString"] as? String
        let build = info?["CFBundleVersion"] as? String
        switch (short, build) {
        case let (short?, build?) where !short.isEmpty && !build.isEmpty: return "\(short) (\(build))"
        case let (short?, _) where !short.isEmpty: return short
        case let (_, build?) where !build.isEmpty: return build
        default: return ""
        }
    }
}

enum ReportComposer {
    /// 通報メールの下書きを開く mailto。組み立てに失敗したら nil
    static func reportURL(
        target: ReportTarget,
        context: ReportContext,
        email: String = SupportLinks.contactEmail
    ) -> URL? {
        mailtoURL(
            address: email,
            subject: Strings.Report.subject(target.kindLabel),
            body: reportBody(target: target, context: context)
        )
    }

    /// お問い合わせメールの下書きを開く mailto
    static func contactURL(
        context: ReportContext,
        email: String = SupportLinks.contactEmail
    ) -> URL? {
        mailtoURL(
            address: email,
            subject: Strings.Contact.subject,
            body: contactBody(context: context)
        )
    }

    /// 通報メールの本文(運営が読む。対象の ID・内容・日付・アプリの版)
    static func reportBody(target: ReportTarget, context: ReportContext) -> String {
        var lines = [
            Strings.Report.bodyIntro,
            "",
            "\(Strings.Report.kindLabel): \(target.kindLabel)",
            "\(Strings.Report.pairIdLabel): \(context.pairId ?? Strings.Report.noPair)",
            "\(Strings.Report.dateLabel): \(context.dateLocal)",
        ]
        if let detail = target.detail {
            lines.append("\(Strings.Report.targetLabel): \(detail)")
        }
        if !context.appVersion.isEmpty {
            lines.append("\(Strings.Report.appVersionLabel): \(context.appVersion)")
        }
        lines.append("")
        lines.append("\(Strings.Report.notesLabel):")
        lines.append("")
        return lines.joined(separator: "\n")
    }

    /// お問い合わせメールの本文
    static func contactBody(context: ReportContext) -> String {
        var lines = [Strings.Contact.bodyIntro, "", Strings.Contact.bodyPlaceholder, ""]
        if !context.appVersion.isEmpty {
            lines.append("\(Strings.Report.appVersionLabel): \(context.appVersion)")
        }
        return lines.joined(separator: "\n")
    }

    /// メールを開けなかったとき(メールアプリが無い・設定が無い端末)のアラートの本文。
    /// 運営の連絡先が決まっていれば、メールアプリを使わずに直接送れるよう宛先を添える(決まるまでは添えない)
    static func mailFailureMessage(email: String = SupportLinks.contactEmail) -> String {
        let address = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !address.isEmpty else { return Strings.Report.mailFailedMessage }
        return Strings.Report.mailFailedMessage(contactAddress: address)
    }

    /// `mailto:<address>?subject=…&body=…`。件名と本文は RFC 3986 の非予約文字以外をすべて % エンコードする
    /// (`&`・`=`・`+`・改行・日本語が、別の意味に読まれたり欠けたりしない)。
    /// 宛先が空なら `mailto:?subject=…`(宛先なしの下書き)。宛先に使えない文字が入っていれば nil
    static func mailtoURL(address: String, subject: String, body: String) -> URL? {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.unicodeScalars.allSatisfy({ allowedAddressScalars.contains($0) }) else { return nil }
        let query = "subject=\(encode(subject))&body=\(encode(body))"
        return URL(string: "mailto:\(trimmed)?\(query)")
    }

    /// 宛先に許す文字(メールアドレスの一般的な範囲。% エンコードはしない)
    private static let allowedAddressScalars: CharacterSet = {
        var set = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789")
        set.insert(charactersIn: "@.-_+")
        return set
    }()

    private static let unreserved = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
    )

    private static func encode(_ text: String) -> String {
        text.addingPercentEncoding(withAllowedCharacters: unreserved) ?? ""
    }
}
