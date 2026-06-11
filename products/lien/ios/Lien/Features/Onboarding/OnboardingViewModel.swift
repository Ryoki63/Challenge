// OnboardingViewModel.swift — オンボーディング3画面の状態管理(T10 / REQUIREMENTS §3.1, §6)
//
// - 遷移: concept → nickname → notification(完了で onFinished → ルートが .solo へ)
// - 認証は AuthServicing 経由(実体は SupabaseService / Config 未設定時 StubAuthService /
//   テストはモック)。通知許可は PushAuthorizing 経由
// - ニックネーム検証は DB の check 制約 char_length(Unicode コードポイント数)に合わせて
//   unicodeScalars.count で数える(絵文字込みでも DB とズレない — issue #10)

import Foundation
import Observation

@MainActor
@Observable
final class OnboardingViewModel {
    /// オンボーディングの3ステップ(REQUIREMENTS §6: コンセプト → ニックネーム/アイコン → 通知)
    enum Step {
        case concept
        case nickname
        case notification
    }

    /// ニックネーム検証エラー(REQUIREMENTS §3.1: 8字まで)
    enum NicknameError {
        case empty
        case tooLong
    }

    static let nicknameMaxLength = 8

    // MARK: - 入力状態(View からバインド)

    var nickname = ""
    var avatarEmoji = Strings.Onboarding.avatarPalette.first ?? "🌱"

    // MARK: - 画面状態

    private(set) var step: Step = .concept
    private(set) var isSubmitting = false
    private(set) var isRequestingNotifications = false
    /// 送信失敗時のユーザー向けメッセージ(同じ画面に留まり、リトライで再送信できる)
    private(set) var submitErrorMessage: String?

    // MARK: - 依存(モック注入可能)

    private let authService: AuthServicing
    private let pushAuthorizer: PushAuthorizing
    private let onFinished: () -> Void
    private var hasFinished = false

    init(
        authService: AuthServicing,
        pushAuthorizer: PushAuthorizing,
        onFinished: @escaping () -> Void
    ) {
        self.authService = authService
        self.pushAuthorizer = pushAuthorizer
        self.onFinished = onFinished
    }

    // MARK: - ニックネーム検証

    /// 前後の空白・改行を除いた送信用ニックネーム
    var trimmedNickname: String {
        nickname.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// nil なら送信可。DB の check(char_length <= 8)と同じ数え方で検証する
    var nicknameError: NicknameError? {
        let trimmed = trimmedNickname
        if trimmed.isEmpty { return .empty }
        if trimmed.unicodeScalars.count > Self.nicknameMaxLength { return .tooLong }
        return nil
    }

    var canSubmitProfile: Bool {
        nicknameError == nil && !isSubmitting
    }

    // MARK: - 遷移・送信

    /// ページ1(コンセプト)→ ページ2(ニックネーム)
    func advanceFromConcept() {
        guard step == .concept else { return }
        step = .nickname
    }

    /// ページ2: 匿名サインイン → users プロフィール更新 → ページ3へ。
    /// 失敗時(ネットワーク・DB check エラー等)はエラーメッセージを立てて留まる(リトライ可能)
    func submitProfile() async {
        guard canSubmitProfile else { return }
        isSubmitting = true
        submitErrorMessage = nil
        defer { isSubmitting = false }
        do {
            // 既にセッションがあれば再サインインしない(匿名ユーザーの二重作成防止)
            if authService.currentUserID == nil {
                try await authService.signInAnonymously()
            }
            try await authService.updateProfile(
                nickname: trimmedNickname,
                avatarEmoji: avatarEmoji,
                timezone: TimeZone.current.identifier
            )
            step = .notification
        } catch {
            submitErrorMessage = Strings.Onboarding.submitErrorMessage
        }
    }

    /// ページ3: OS の通知許可ダイアログを1回だけ出して完了する。
    /// 拒否されてもオンボーディングは完了する(ブロックしない — issue #10)
    func requestNotifications() async {
        guard !isRequestingNotifications else { return }
        isRequestingNotifications = true
        _ = await pushAuthorizer.requestAuthorization()
        isRequestingNotifications = false
        finish()
    }

    /// ページ3「あとで」: 許可ダイアログを出さずに完了する
    func skipNotifications() {
        finish()
    }

    private func finish() {
        guard !hasFinished else { return }
        hasFinished = true
        onFinished()
    }
}
