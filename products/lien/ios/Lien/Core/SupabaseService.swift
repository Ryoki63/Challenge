// SupabaseService.swift — Supabase 認証+users プロフィール更新(DESIGN §3.3 / T10)
//
// - View から直接呼ばない。ViewModel へは AuthServicing プロトコルで注入する(テストはモック)
// - Config 未設定(CI など Secrets.xcconfig が無い環境)では StubAuthService に差し替え、
//   ネットワークを一切使わずにビルド・テストが通る。実 Supabase 疎通は T08 の E2E で検証
// - supabase-swift をリンクするのは Lien ターゲットのみ(LienWidget / LienNSE には入れない)

import Foundation
import Supabase

/// 認証+プロフィール更新の抽象(T10 時点)。Functions 呼び出し等は後続タスクで拡張する
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
    /// push_token — 0001_init.sql)に限られる
    func updateProfile(nickname: String, avatarEmoji: String, timezone: String) async throws
}

enum AuthServiceError: Error, Equatable {
    /// サインイン前にプロフィール更新を呼んだ
    case notSignedIn
}

// MARK: - 本実装(supabase-swift)

final class SupabaseService: AuthServicing {
    /// users 行の更新ペイロード(キー名は DB 列名と一致させる)
    private struct ProfileUpdate: Encodable {
        let nickname: String
        let avatarEmoji: String
        let timezone: String

        enum CodingKeys: String, CodingKey {
            case nickname
            case avatarEmoji = "avatar_emoji"
            case timezone
        }
    }

    private let client: SupabaseClient

    init(config: Config) {
        client = SupabaseClient(
            supabaseURL: config.supabaseURL,
            supabaseKey: config.supabaseAnonKey
        )
    }

    var currentUserID: UUID? {
        client.auth.currentUser?.id
    }

    @discardableResult
    func signInAnonymously() async throws -> UUID {
        // 既存セッションがあれば再利用する(匿名ユーザーの二重作成防止)
        if let existing = currentUserID { return existing }
        let session = try await client.auth.signInAnonymously()
        return session.user.id
    }

    func updateProfile(nickname: String, avatarEmoji: String, timezone: String) async throws {
        guard let userID = currentUserID else { throw AuthServiceError.notSignedIn }
        _ = try await client
            .from("users")
            .update(ProfileUpdate(nickname: nickname, avatarEmoji: avatarEmoji, timezone: timezone))
            .eq("id", value: userID)
            .execute()
    }

    /// 標準構成: Secrets 設定済みなら本実装、未設定(CI 等)なら StubAuthService
    static func makeDefault(bundle: Bundle = .main) -> AuthServicing {
        if let config = Config.load(bundle: bundle) {
            return SupabaseService(config: config)
        }
        return StubAuthService()
    }
}

// MARK: - スタブ(Config 未設定環境用)

/// メモリ内で成功応答だけ返すスタブ。永続しないため、未設定ビルドでは起動のたびに
/// オンボーディングから始まる(実値設定後は SupabaseService がセッションを keychain 永続する)
final class StubAuthService: AuthServicing {
    private(set) var signedInUserID: UUID?

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
}
