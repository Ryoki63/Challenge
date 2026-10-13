// SupportLinks.swift — 規約・プライバシーポリシー・運営者への連絡先(T23 #23)
//
// 設定画面・オンボーディングの規約同意・通報とお問い合わせのメールが使う、外へ出る先の一覧。
// **G4(#42)で確定する値**はこのファイルだけに置く(確定したら、ここの 2 行を直すだけで全画面に反映される):
//   - 運営者の連絡先メールアドレス(`contactEmail`)。確定するまで空
//   - 法務ページの公開先(`webBaseURL` の下の /lien/legal/)。Pages への公開は TASKPLAN §9.2 の「Pages 公開」
//     (invite と legal を同じ土台に載せる)。公開して実在を確かめるまで、リンクの先は未公開のことがある
// 文言は Strings、メールの組み立ては ReportComposer。

import Foundation

enum SupportLinks {
    /// Pages の土台(招待ページと同じ。invite-create の INVITE_WEB_BASE_URL の既定値・StubInviteClient.webBaseURL と同じ)
    static let webBaseURL = "https://ryoki63.github.io/Challenge"

    /// 利用規約(marketing/legal/terms.html の公開先 — marketing/legal/CHECKLIST-G4.md §3)
    static let termsURL: URL = url("\(webBaseURL)/lien/legal/terms.html")

    /// プライバシーポリシー(marketing/legal/privacy.html の公開先)
    static let privacyURL: URL = url("\(webBaseURL)/lien/legal/privacy.html")

    /// 運営者への連絡先メールアドレス。**G4 で確定するまで空**。
    /// 空のあいだ、通報・お問い合わせのメールは宛先なしの下書きとして開く(宛先は利用者が入れる)。
    /// 確定したら、marketing/terms.md・privacy-policy.md の連絡先欄と同じアドレスにする
    static let contactEmail = ""

    /// 連絡先が確定しているか(確定前は、リリース前の確認事項として followups に挙がっている)
    static var hasContactEmail: Bool {
        !contactEmail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// iOS の設定アプリで、このアプリの設定(通知を含む)を開く URL(UIApplication.openSettingsURLString と同じ値)
    static let appSettingsURL: URL = url("app-settings:")

    private static func url(_ string: String) -> URL {
        // 定数の文字列から作る。壊れていれば SupportLinksTests が落ちる
        URL(string: string) ?? URL(fileURLWithPath: "/")
    }
}
