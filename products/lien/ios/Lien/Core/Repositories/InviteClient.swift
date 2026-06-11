// InviteClient.swift — 招待 API(invite-create / invite-accept)のクライアント抽象(T11)
//
// - View から直接呼ばない。ViewModel へは InviteClient プロトコルで注入する
//   (テストは PairingViewModelTests の MockInviteClient — SupabaseService と同じイディオム)
// - 実 HTTP 実装(Edge Functions 呼び出し)は Functions デプロイ(G0)後の後続タスクで追加し、
//   SupabaseService.makeDefault と同様に Config の有無で本実装 / スタブを切り替える。
//   本タスク(issue #11)はプロトコル+スタブまで(UI・エラーマッピングを CI で固定する)
// - エラーコード文字列の正本: invite-create/core.ts / invite-accept/core.ts(下記に出典コメント)

import Foundation

/// 招待の発行・受諾(DESIGN §5.3 / §6)
protocol InviteClient: AnyObject {
    /// POST /invite-create — 招待を発行する(8文字 token / 72h / 1回限り)
    func createInvite() async throws -> InviteCreateResponse

    /// POST /invite-accept — 招待を受諾してペアを作る。成功時は受諾者視点の snapshot を返す
    func acceptInvite(token: String) async throws -> InviteAcceptResponse
}

/// サーバーの error 文字列 → クライアントのエラー型。
/// 文字列はサーバー実装からコピーしたもの(変更時は両方を直すこと — issue #11 契約整合)
enum InviteClientError: Error, Equatable {
    /// "already_paired" — create 409 / accept 409(自分が既にペア)
    case alreadyPaired
    /// "partner_already_paired" — accept 409(発行者側が既にペア)
    case partnerAlreadyPaired
    /// "invite_not_found" — accept 404(存在しない・発行者が削除済み)
    case inviteNotFound
    /// "invite_expired" — accept 410(発行から72時間超過)
    case inviteExpired
    /// "invite_already_used" — accept 410(1回限り。同時受諾の競合負けも含む)
    case inviteAlreadyUsed
    /// "cannot_accept_own_invite" — accept 400(自分の招待は使えない)
    case cannotAcceptOwnInvite
    /// "invalid_token" — accept 400(8文字英数でない)
    case invalidToken
    /// "user_not_found" — create / accept 404(自分の users 行が無い)
    case userNotFound
    /// 上記以外のサーバーエラー("token_generation_failed" / "internal_error" 等)
    case server(code: String)
    /// 通信エラー(オフライン・タイムアウト等)
    case network

    /// サーバー応答 body の error 文字列からマップする(実 HTTP 実装が使う)
    init(serverCode: String) {
        switch serverCode {
        case "already_paired": self = .alreadyPaired
        case "partner_already_paired": self = .partnerAlreadyPaired
        case "invite_not_found": self = .inviteNotFound
        case "invite_expired": self = .inviteExpired
        case "invite_already_used": self = .inviteAlreadyUsed
        case "cannot_accept_own_invite": self = .cannotAcceptOwnInvite
        case "invalid_token": self = .invalidToken
        case "user_not_found": self = .userNotFound
        default: self = .server(code: serverCode)
        }
    }
}

// MARK: - スタブ(実 HTTP 実装が入るまでのアプリ実行用。StubAuthService と同じ役割)

/// メモリ内で成功応答だけ返すスタブ。発行はローカル生成 token、受諾は形式検証のみ行い
/// ダミーのペア snapshot を返す(実サーバー疎通は G0 デプロイ後の後続タスク+T20 実機 E2E)
final class StubInviteClient: InviteClient {
    /// invite-create/core.ts の INVITE_TOKEN_ALPHABET と同一
    /// (8文字英数・紛らわしい 0/O/1/l を除外 — DESIGN §5.1)
    static let tokenAlphabet: [Character] =
        Array("ABCDEFGHIJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789")

    /// invite-create/index.ts の INVITE_WEB_BASE_URL 既定値と同一(G0 で確定 — DESIGN §6)
    static let webBaseURL = "https://ryoki63.github.io/Challenge"

    /// 有効期限 72時間(invite-create/core.ts INVITE_TTL_HOURS / REQUIREMENTS §3.2)
    static let ttlSeconds: TimeInterval = 72 * 60 * 60

    func createInvite() async throws -> InviteCreateResponse {
        let token = String((0..<InviteToken.length).map { _ in
            Self.tokenAlphabet.randomElement() ?? "A"
        })
        return InviteCreateResponse(
            token: token,
            appUrl: "lien://invite/\(token)",
            webUrl: "\(Self.webBaseURL)/lien/i/?t=\(token)",
            expiresAt: Date().addingTimeInterval(Self.ttlSeconds)
        )
    }

    func acceptInvite(token: String) async throws -> InviteAcceptResponse {
        guard InviteToken.isValidFormat(token) else {
            throw InviteClientError.invalidToken
        }
        let pairId = UUID().uuidString.lowercased()
        let snapshot = PairSnapshot(
            schemaVersion: PairSnapshot.currentSchemaVersion,
            pairId: pairId,
            updatedAt: Date(),
            streakCurrent: 0,
            streakBest: 0,
            todayMeDone: false,
            todayPartnerDone: false,
            myPromiseTitle: nil,
            myPromiseEmoji: nil,
            partnerName: nil,
            partnerPromiseTitle: nil,
            partnerPromiseEmoji: nil,
            plantStage: 0,
            plantMood: .normal,
            plantName: nil,
            hasPartnerPhotoToday: false
        )
        return InviteAcceptResponse(pairId: pairId, snapshot: snapshot)
    }
}
