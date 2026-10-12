// AuthServicing.swift — 認証サービスの抽象+スタブ(DESIGN §3.3 / T10 / issue #55)
//
// - View / ViewModel へは AuthServicing プロトコルで注入する(テストはモック)
// - 本実装 SupabaseService は supabase-swift に依存するため SupabaseService.swift に分離している。
//   本ファイルは Foundation のみに依存し、Config 未設定(CI など Secrets.xcconfig が無い環境)では
//   StubAuthService に差し替えて、ネットワークを一切使わずにビルド・テストが通る
// - 実 Supabase 疎通は T08 の E2E で検証する

import Foundation

/// 認証+プロフィール更新の抽象。Edge Functions への Bearer トークン供給(accessToken)も担う
protocol AuthServicing: AnyObject {
    /// 現在のセッションのユーザー ID(未サインインなら nil)
    var currentUserID: UUID? { get }

    /// 匿名サインイン(Supabase anonymous sign-in — DESIGN §10)。
    /// auth.users への INSERT 時に public.users の骨組み行がトリガーで自動作成される
    /// (0001_init.sql の handle_new_user。クライアントは users に INSERT しない)
    @discardableResult
    func signInAnonymously() async throws -> UUID

    /// 自分の users 行のプロフィール列を更新する。
    /// 更新できる列は列レベル GRANT(nickname / avatar_emoji / timezone / remind_at /
    /// push_token / push_env — 0001_init.sql, 0005)に限られる
    func updateProfile(nickname: String, avatarEmoji: String, timezone: String) async throws

    /// 現在のユーザー JWT(Edge Functions の `Authorization: Bearer` に載せる)。
    /// 期限切れの場合は提供側(supabase-swift のセッション)が自動更新してから返す。
    /// 未サインインなら AuthServiceError.notSignedIn
    func accessToken() async throws -> String
}

enum AuthServiceError: Error, Equatable {
    /// サインイン前にプロフィール更新・トークン取得を呼んだ
    case notSignedIn
}

// MARK: - スタブ(Config 未設定環境用)

/// メモリ内で成功応答だけ返すスタブ。永続しないため、未設定ビルドでは起動のたびに
/// オンボーディングから始まる(実値設定後は SupabaseService がセッションを keychain 永続する)
final class StubAuthService: AuthServicing, PushRegistrationUpdating {
    private(set) var signedInUserID: UUID?
    /// サーバーの users 行の代わり(updatePushRegistration で書き、fetchPushRegistration で読む)
    private var storedPushRegistration = ServerPushRegistration(token: nil, environment: nil)

    var currentUserID: UUID? { signedInUserID }

    @discardableResult
    func signInAnonymously() async throws -> UUID {
        if let existing = signedInUserID { return existing }
        let id = UUID()
        signedInUserID = id
        return id
    }

    func updateProfile(nickname: String, avatarEmoji: String, timezone: String) async throws {
        guard signedInUserID != nil else { throw AuthServiceError.notSignedIn }
        // メモリ内スタブ: 何も送信しない
    }

    func accessToken() async throws -> String {
        guard signedInUserID != nil else { throw AuthServiceError.notSignedIn }
        return "stub-access-token"
    }

    func updatePushRegistration(token: String, environment: PushEnvironment) async throws {
        guard signedInUserID != nil else { throw AuthServiceError.notSignedIn }
        // メモリ内スタブ: 何も送信しない(読み戻し用に覚えるだけ)
        storedPushRegistration = ServerPushRegistration(token: token, environment: environment)
    }

    func fetchPushRegistration() async throws -> ServerPushRegistration {
        guard signedInUserID != nil else { throw AuthServiceError.notSignedIn }
        return storedPushRegistration
    }
}
