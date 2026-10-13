// ReportComposerTests.swift — 通報・お問い合わせのメール(mailto)の組み立て(T23 #23)
//
// 検証対象(ReportComposer.swift / SupportLinks.swift):
//   - 通報メールの宛先・件名・本文(対象の ID・内容・日付・アプリの版)と、特殊文字を含む内容の往復
//   - 宛先が未確定(G4 前)のときは宛先なしの下書き / 宛先に使えない文字が入っていれば作らない
//   - 規約・プライバシーポリシー・設定アプリへのリンクの形

import XCTest
@testable import Lien

final class ReportComposerTests: XCTestCase {
    private let pairID = "1f0c5a4e-9d3b-4c1a-8f2e-7b6d5a4c3b2a"
    private lazy var context = ReportContext(pairId: pairID, dateLocal: "2026-10-13", appVersion: "1.0.0 (45)")
    private let photoReference = PartnerPhotoReference(
        pairID: "1f0c5a4e-9d3b-4c1a-8f2e-7b6d5a4c3b2a",
        dateLocal: "2026-10-13",
        photoPath: "pairs/1f0c5a4e-9d3b-4c1a-8f2e-7b6d5a4c3b2a/2026-10-13/b2222222-2222-4222-8222-222222222222/photo.jpg"
    )

    /// mailto の件名・本文を、URL のエンコードを外した値で読む
    private func decode(_ url: URL?) throws -> (address: String, subject: String, body: String) {
        let url = try XCTUnwrap(url)
        XCTAssertEqual(url.scheme, "mailto")
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        var items: [String: String] = [:]
        for item in components.queryItems ?? [] { items[item.name] = item.value ?? "" }
        return (components.path, try XCTUnwrap(items["subject"]), try XCTUnwrap(items["body"]))
    }

    // MARK: 通報メール

    func testPhotoReportCarriesTheIdsNeededToFindTheContent() throws {
        let url = ReportComposer.reportURL(
            target: .photo(photoReference),
            context: context,
            email: "support@example.com"
        )
        let mail = try decode(url)

        XCTAssertEqual(mail.address, "support@example.com")
        XCTAssertEqual(mail.subject, "【Lien】通報: 写真")
        XCTAssertTrue(mail.body.contains("\(Strings.Report.kindLabel): \(Strings.Report.kindPhoto)"))
        XCTAssertTrue(mail.body.contains("\(Strings.Report.pairIdLabel): \(pairID)"), "ペア ID")
        XCTAssertTrue(mail.body.contains("\(Strings.Report.dateLabel): 2026-10-13"))
        XCTAssertTrue(
            mail.body.contains("\(Strings.Report.targetLabel): \(photoReference.photoPath)"),
            "写真のパス(持ち主の user_id が入っている)"
        )
        XCTAssertTrue(mail.body.contains("\(Strings.Report.appVersionLabel): 1.0.0 (45)"))
        XCTAssertTrue(mail.body.contains(Strings.Report.bodyIntro))
        XCTAssertTrue(mail.body.contains("\(Strings.Report.notesLabel):"), "補足を書き足す欄")
    }

    func testNicknamePromiseAndPlantNameReportsCarryTheContent() throws {
        let nickname = try decode(ReportComposer.reportURL(target: .nickname("ゆうき"), context: context, email: ""))
        XCTAssertEqual(nickname.subject, "【Lien】通報: ニックネーム")
        XCTAssertTrue(nickname.body.contains("\(Strings.Report.targetLabel): ゆうき"))

        let promise = try decode(ReportComposer.reportURL(
            target: .promise(emoji: "🏃", title: "ランニング"),
            context: context,
            email: ""
        ))
        XCTAssertEqual(promise.subject, "【Lien】通報: 約束の文")
        XCTAssertTrue(promise.body.contains("\(Strings.Report.targetLabel): 🏃 ランニング"))

        let plant = try decode(ReportComposer.reportURL(target: .plantName("みどり"), context: context, email: ""))
        XCTAssertEqual(plant.subject, "【Lien】通報: 植物の名前")
        XCTAssertTrue(plant.body.contains("\(Strings.Report.targetLabel): みどり"))
    }

    func testGeneralReportHasNoTargetLine() throws {
        let mail = try decode(ReportComposer.reportURL(target: .general, context: context, email: ""))
        XCTAssertEqual(mail.subject, "【Lien】通報: その他")
        XCTAssertFalse(mail.body.contains("\(Strings.Report.targetLabel):"), "対象を持たない通報には「対象」の行を出さない")
    }

    func testSoloReportSaysThereIsNoPair() throws {
        let solo = ReportContext(pairId: nil, dateLocal: "2026-10-13", appVersion: "")
        let mail = try decode(ReportComposer.reportURL(target: .general, context: solo, email: ""))
        XCTAssertTrue(mail.body.contains("\(Strings.Report.pairIdLabel): \(Strings.Report.noPair)"))
        XCTAssertFalse(mail.body.contains(Strings.Report.appVersionLabel), "版が読めなければその行は出さない")
    }

    func testSpecialCharactersInTheReportedContentSurviveTheRoundTrip() throws {
        // 相手が付けた文字列が、& = + % 改行 日本語・絵文字を含んでいても、欠けたり別の意味に読まれたりしない
        let nasty = "a&b=c+d%20e\n日本語🌱 #?;/"
        let mail = try decode(ReportComposer.reportURL(target: .nickname(nasty), context: context, email: "a.b+c@example.com"))

        XCTAssertEqual(mail.address, "a.b+c@example.com")
        XCTAssertTrue(mail.body.contains("\(Strings.Report.targetLabel): \(nasty)"))
    }

    func testBodyIsMultilineAndUsesNewlines() {
        let body = ReportComposer.reportBody(target: .nickname("ゆうき"), context: context)
        let lines = body.split(separator: "\n", omittingEmptySubsequences: false)
        XCTAssertGreaterThan(lines.count, 6)
        XCTAssertEqual(String(lines.first ?? ""), Strings.Report.bodyIntro)
    }

    // MARK: 宛先

    func testEmptyContactEmailMakesADraftWithoutARecipient() throws {
        // G4 で連絡先が確定するまで: 下書きは開くが、宛先は利用者が入れる
        let url = try XCTUnwrap(ReportComposer.reportURL(target: .general, context: context, email: ""))
        XCTAssertTrue(url.absoluteString.hasPrefix("mailto:?subject="), url.absoluteString)
        XCTAssertEqual(try decode(url).address, "")
    }

    func testInvalidRecipientCharactersProduceNoURL() {
        for bad in ["a b@example.com", "a@example.com\nBcc: x@example.com", "a@example.com?cc=x@example.com", "<a@example.com>"] {
            XCTAssertNil(
                ReportComposer.reportURL(target: .general, context: context, email: bad),
                "宛先に使えない文字: \(bad)"
            )
        }
    }

    func testDefaultRecipientIsTheConfiguredContactEmail() throws {
        let mail = try decode(ReportComposer.reportURL(target: .general, context: context))
        XCTAssertEqual(mail.address, SupportLinks.contactEmail)
    }

    // MARK: お問い合わせ

    func testContactMailHasTheContactSubjectAndAPlaceholder() throws {
        let mail = try decode(ReportComposer.contactURL(context: context, email: "support@example.com"))
        XCTAssertEqual(mail.address, "support@example.com")
        XCTAssertEqual(mail.subject, Strings.Contact.subject)
        XCTAssertTrue(mail.body.contains(Strings.Contact.bodyIntro))
        XCTAssertTrue(mail.body.contains(Strings.Contact.bodyPlaceholder))
        XCTAssertTrue(mail.body.contains("\(Strings.Report.appVersionLabel): 1.0.0 (45)"))
    }

    // MARK: 通報の対象

    func testReportTargetDetails() {
        XCTAssertEqual(ReportTarget.photo(photoReference).detail, photoReference.photoPath)
        XCTAssertEqual(ReportTarget.nickname("ゆうき").detail, "ゆうき")
        XCTAssertNil(ReportTarget.nickname("  ").detail, "空のニックネームは対象の行を出さない")
        XCTAssertEqual(ReportTarget.promise(emoji: "🏃", title: "ランニング").detail, "🏃 ランニング")
        XCTAssertEqual(ReportTarget.promise(emoji: nil, title: "ランニング").detail, "ランニング")
        XCTAssertNil(ReportTarget.promise(emoji: nil, title: nil).detail)
        XCTAssertEqual(ReportTarget.plantName("みどり").detail, "みどり")
        XCTAssertNil(ReportTarget.general.detail)
    }

    // MARK: 状況(ReportContext)

    func testAppVersionTextCombinesShortVersionAndBuild() {
        XCTAssertEqual(
            ReportContext.appVersionText(info: ["CFBundleShortVersionString": "1.0.0", "CFBundleVersion": "45"]),
            "1.0.0 (45)"
        )
        XCTAssertEqual(ReportContext.appVersionText(info: ["CFBundleShortVersionString": "1.0.0"]), "1.0.0")
        XCTAssertEqual(ReportContext.appVersionText(info: ["CFBundleVersion": "45"]), "45")
        XCTAssertEqual(ReportContext.appVersionText(info: ["CFBundleShortVersionString": ""]), "")
        XCTAssertEqual(ReportContext.appVersionText(info: [:]), "")
        XCTAssertEqual(ReportContext.appVersionText(info: nil), "")
    }

    func testCurrentContextUsesTheLocalDate() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Tokyo") ?? .current
        // 2026-06-11T16:00:00Z は JST では 6/12 の 01:00
        let now = Date(timeIntervalSince1970: 1_781_193_600)
        let current = ReportContext.current(pairId: "p", now: now, calendar: calendar, appVersion: "1.0.0 (3)")
        XCTAssertEqual(current.dateLocal, "2026-06-12")
        XCTAssertEqual(current.pairId, "p")
        XCTAssertEqual(current.appVersion, "1.0.0 (3)")
    }

    // MARK: リンク

    func testLegalLinksAreHTTPSPagesURLs() {
        for url in [SupportLinks.termsURL, SupportLinks.privacyURL] {
            XCTAssertEqual(url.scheme, "https")
            XCTAssertFalse((url.host ?? "").isEmpty)
            XCTAssertTrue(url.absoluteString.hasPrefix(SupportLinks.webBaseURL + "/lien/legal/"), url.absoluteString)
        }
        XCTAssertTrue(SupportLinks.termsURL.absoluteString.hasSuffix("terms.html"))
        XCTAssertTrue(SupportLinks.privacyURL.absoluteString.hasSuffix("privacy.html"))
    }

    func testAppSettingsURLOpensTheSystemSettings() {
        XCTAssertEqual(SupportLinks.appSettingsURL.scheme, "app-settings")
    }
}
