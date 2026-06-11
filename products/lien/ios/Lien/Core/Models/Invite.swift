// Invite.swift — 招待 API のレスポンスモデル(T11)
//
// 契約の正本はサーバー実装:
//   - invite-create/core.ts の InviteCreateResult(token / appUrl / webUrl / expiresAt)
//   - invite-accept/core.ts の InviteAcceptResult(pairId / snapshot)
// JSON デコードは PairSnapshot.makeJSONDecoder() を使うこと
// (expiresAt / snapshot.updatedAt は ISO8601 小数秒あり・なし両対応が必要なため)。

import Foundation

/// 招待トークンの形式(8文字英数)。
/// invite-accept/core.ts の TOKEN_FORMAT(/^[A-Za-z0-9]{8}$/)および
/// migration 0001 の invites.token CHECK と同一判定。
enum InviteToken {
    static let length = 8

    static func isValidFormat(_ token: String) -> Bool {
        token.count == length && token.allSatisfy { ch in
            ch.isASCII && (ch.isLetter || ch.isNumber)
        }
    }
}

/// POST /invite-create の 200 応答(invite-create/core.ts InviteCreateResult.body)
struct InviteCreateResponse: Equatable, Sendable, Codable {
    /// 8文字英数(紛らわしい 0/O/1/l を除いた58文字 — DESIGN §5.1)
    let token: String
    /// カスタムスキーム形式: lien://invite/<token>(DESIGN §3.6 / §6)
    let appUrl: String
    /// 静的ページ形式: https://<GH_PAGES>/lien/i/?t=<token>(DESIGN §6)
    let webUrl: String
    /// 発行時刻 + 72h(REQUIREMENTS §3.2)
    let expiresAt: Date

    var appURL: URL? { URL(string: appUrl) }
    var webURL: URL? { URL(string: webUrl) }
}

/// POST /invite-accept の 200 応答(invite-accept/core.ts InviteAcceptResult.body)。
/// snapshot は受諾者視点でサーバーが組み立てる(DESIGN §3.4)
struct InviteAcceptResponse: Equatable, Sendable, Codable {
    let pairId: String
    let snapshot: PairSnapshot
}
