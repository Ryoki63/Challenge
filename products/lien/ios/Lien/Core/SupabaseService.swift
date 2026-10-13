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

    /// ニックネームとアイコンだけの更新ペイロード(設定のプロフィール編集。timezone は書かない)
    private struct NicknameAvatarUpdate: Encodable {
        let nickname: String
        let avatarEmoji: String

        enum CodingKeys: String, CodingKey {
            case nickname
            case avatarEmoji = "avatar_emoji"
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

    /// APNs 登録の取り消しペイロード(push_token / push_env を null にする。nil は明示的に null として書く —
    /// synthesized な Encodable は nil のキーを省くので、自前で encodeNil する)
    private struct PushRegistrationClear: Encodable {
        enum CodingKeys: String, CodingKey {
            case pushToken = "push_token"
            case pushEnv = "push_env"
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encodeNil(forKey: .pushToken)
            try container.encodeNil(forKey: .pushEnv)
        }
    }

    /// 自分の users 行から読むプロフィール(users_select_self により、読めるのは自分の行だけ)
    private struct ProfileRow: Decodable, Sendable {
        let nickname: String?
        let avatarEmoji: String?

        enum CodingKeys: String, CodingKey {
            case nickname
            case avatarEmoji = "avatar_emoji"
        }
    }

    /// 自分の promises 行(promises_select_pair のうち user_id が自分のもの)。archived_at が null が現役
    private struct PromiseRow: Decodable, Sendable {
        let id: String
        let title: String
        let emoji: String
        let remindAt: String?
        let archivedAt: String?

        enum CodingKeys: String, CodingKey {
            case id, title, emoji
            case remindAt = "remind_at"
            case archivedAt = "archived_at"
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

    func updateNicknameAndAvatar(nickname: String, avatarEmoji: String) async throws {
        guard let userID = currentUserID else { throw AuthServiceError.notSignedIn }
        // RLS(users_update_self)と列レベル GRANT により、更新できるのは自分の行のこの列だけ。
        // timezone は書かない(日付の判定に効くので、プロフィールの編集では触らない)
        _ = try await client
            .from("users")
            .update(NicknameAvatarUpdate(nickname: nickname, avatarEmoji: avatarEmoji))
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

    /// サインアウトの前に、この端末への push を止める(users.push_token / push_env を null に)。
    /// RLS(users_update_self)と列レベル GRANT により、更新できるのは自分の行のこの列だけ
    func clearPushRegistration() async throws {
        guard let userID = currentUserID else { throw AuthServiceError.notSignedIn }
        _ = try await client
            .from("users")
            .update(PushRegistrationClear())
            .eq("id", value: userID)
            .execute()
    }

    /// 設定画面のニックネーム表示。行が無い・列が null なら空文字
    func fetchProfile() async throws -> UserProfile {
        guard let userID = currentUserID else { throw AuthServiceError.notSignedIn }
        let rows: [ProfileRow] = try await client
            .from("users")
            .select("nickname, avatar_emoji")
            .eq("id", value: userID)
            .execute()
            .value
        let row = rows.first
        return UserProfile(nickname: row?.nickname ?? "", avatarEmoji: row?.avatarEmoji ?? "")
    }

    /// 設定画面の約束の編集用。自分の約束のうち現役(archived_at が null)の 1 件。無ければ nil。
    /// remind_at は time 型("20:00:00")で来るので、API の表現 "HH:MM" に切る
    func fetchMyPromise() async throws -> Promise? {
        guard let userID = currentUserID else { throw AuthServiceError.notSignedIn }
        let rows: [PromiseRow] = try await client
            .from("promises")
            .select("id, title, emoji, remind_at, archived_at")
            .eq("user_id", value: userID)
            .is("archived_at", value: nil) // 現役だけ。アーカイブ済みの過去の約束は読まない
            .execute()
            .value
        guard let row = rows.first(where: { $0.archivedAt == nil }) else { return nil }
        return Promise(
            id: row.id,
            title: row.title,
            emoji: row.emoji,
            remindAt: row.remindAt.map { String($0.prefix(5)) }
        )
    }

    /// サインアウト。端末のセッション(Keychain)の破棄は端末側で完結する(scope: .local)。
    /// サーバーへのログアウト通信に失敗しても、端末のセッションは消える
    func signOut() async {
        try? await client.auth.signOut(scope: .local)
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
