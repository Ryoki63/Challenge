// SupabaseService.swift — Supabase 認証+users プロフィール更新の本実装(DESIGN §3.3 / T10 / issue #55)
//
// - 抽象(AuthServicing)・エラー・スタブ(StubAuthService)は AuthServicing.swift。
//   View から直接呼ばない。ViewModel へは AuthServicing プロトコルで注入する(テストはモック)
// - Config 未設定(CI など Secrets.xcconfig が無い環境)では AppServices が StubAuthService に
//   差し替え、ネットワークを一切使わずにビルド・テストが通る。実 Supabase 疎通は T08 の E2E で検証
// - supabase-swift をリンクするのは Lien ターゲットのみ(LienWidget / LienNSE には入れない)

import Foundation
import Supabase

final class SupabaseService: AuthServicing, PushRegistrationUpdating {
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

    /// APNs 登録の更新ペイロード(push_token / push_env は本人が更新できる列 — 0001 + 0005)
    private struct PushRegistrationUpdate: Encodable {
        let pushToken: String
        let pushEnv: String

        enum CodingKeys: String, CodingKey {
            case pushToken = "push_token"
            case pushEnv = "push_env"
        }
    }

    /// 自分の users 行から読む APNs 登録(users_select_self により、読めるのは自分の行だけ)
    private struct PushRegistrationRow: Decodable, Sendable {
        let pushToken: String?
        let pushEnv: String?

        enum CodingKeys: String, CodingKey {
            case pushToken = "push_token"
            case pushEnv = "push_env"
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

    func accessToken() async throws -> String {
        guard currentUserID != nil else { throw AuthServiceError.notSignedIn }
        // auth.session は期限切れなら refresh token で自動更新してから返す
        return try await client.auth.session.accessToken
    }

    /// users.push_token と users.push_env を更新する(PushTokenSync から呼ばれる)。
    /// RLS(users_update_self)と列レベル GRANT により、更新できるのは自分の行のこの列だけ
    func updatePushRegistration(token: String, environment: PushEnvironment) async throws {
        guard let userID = currentUserID else { throw AuthServiceError.notSignedIn }
        _ = try await client
            .from("users")
            .update(PushRegistrationUpdate(pushToken: token, pushEnv: environment.rawValue))
            .eq("id", value: userID)
            .execute()
    }

    /// users.push_token と users.push_env を読む(PushTokenSync が、サーバー側で APNs 登録が
    /// 無効にされていない(410 / BadDeviceToken で push_token が null にされていない)かを確かめるのに使う)。
    /// 行が無い・列が null なら、その項目は nil(= 登録なし)
    func fetchPushRegistration() async throws -> ServerPushRegistration {
        guard let userID = currentUserID else { throw AuthServiceError.notSignedIn }
        let rows: [PushRegistrationRow] = try await client
            .from("users")
            .select("push_token, push_env")
            .eq("id", value: userID)
            .execute()
            .value
        let row = rows.first
        return ServerPushRegistration(
            token: row?.pushToken,
            environment: row?.pushEnv.flatMap(PushEnvironment.init(rawValue:))
        )
    }
}
