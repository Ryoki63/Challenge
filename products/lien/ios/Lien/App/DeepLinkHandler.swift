// DeepLinkHandler.swift — 招待ディープリンクのパース(T11 / DESIGN §3.6)
//
// 受け付ける形式(どちらも token は8文字英数 — invite-accept/core.ts TOKEN_FORMAT と同一):
//   1. lien://invite/<token>            … カスタムスキーム(v1.0 の正式経路)
//   2. https://<GH_PAGES>/lien/i/?t=<token> … 招待静的ページの URL を貼り付けた場合の救済
//      (ユニバーサルリンクは独自ドメイン取得後の v1.1 — DESIGN §3.6。OS からは飛んでこないが、
//       共有テキストごとペーストされたときに同じ関数で拾えるようにしておく)
// 不正な URL は nil(呼び出し側は何もしない)。

import Foundation

enum DeepLinkHandler {
    /// URL から招待 token を取り出す。招待リンクでない・形式不正なら nil
    static func inviteToken(from url: URL) -> String? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return nil
        }
        switch components.scheme?.lowercased() {
        case "lien":
            // lien://invite/<token> → host = "invite", path = "/<token>"
            guard components.host?.lowercased() == "invite" else { return nil }
            let segments = components.path.split(separator: "/")
            guard segments.count == 1 else { return nil }
            let token = String(segments[0])
            return InviteToken.isValidFormat(token) ? token : nil
        case "https", "http":
            // 静的ページ形式: クエリ t=<token>(DESIGN §6)
            guard
                let token = components.queryItems?.first(where: { $0.name == "t" })?.value,
                InviteToken.isValidFormat(token)
            else { return nil }
            return token
        default:
            return nil
        }
    }
}
