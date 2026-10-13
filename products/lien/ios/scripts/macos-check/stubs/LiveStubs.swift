// LiveStubs.swift — AppServices+Live.swift を型検査するための代替(supabase-swift / UIKit に依存する実体の代わり)。
// SupabaseService.swift が準拠するプロトコル(AuthServicing / PushRegistrationUpdating)や、AppServices+Live.swift が
// 呼ぶ初期化子を変えたら、ここも同じに直す。
import Foundation

final class SupabaseService: AuthServicing, PushRegistrationUpdating {
    init(config: Config) {}
    var currentUserID: UUID? { nil }
    func signInAnonymously() async throws -> UUID { UUID() }
    func updateProfile(nickname: String, avatarEmoji: String, timezone: String) async throws {}
    func updateNicknameAndAvatar(nickname: String, avatarEmoji: String) async throws {}
    func accessToken() async throws -> String { "" }
    func updatePushRegistration(token: String, environment: PushEnvironment) async throws {}
    func fetchPushRegistration() async throws -> ServerPushRegistration {
        ServerPushRegistration(token: nil, environment: nil)
    }
    func clearPushRegistration() async throws {}
    func fetchProfile() async throws -> UserProfile { UserProfile(nickname: "", avatarEmoji: "") }
    func fetchMyPromise() async throws -> Promise? { nil }
    func signOut() async {}
}

final class PushManager: PushAuthorizing {
    @discardableResult
    func requestAuthorization() async -> Bool { true }
}
