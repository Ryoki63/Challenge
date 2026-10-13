// OnboardingViewModel.swift — オンボーディング3画面の状態管理(T10 / REQUIREMENTS §3.1, §6)
//
// - 遷移: concept → nickname → notification(完了で onFinished → ルートが約束設定(.promiseSetup)へ。
//   約束を決めてから、ソロのホーム(.solo)に着く — AppRouter / DESIGN §3.3)
// - 認証は AuthServicing 経由(実体は SupabaseService / Config 未設定時 StubAuthService /
//   テストはモック)。通知許可は PushAuthorizing 経由
// - ニックネーム検証は DB の check 制約 char_length(Unicode コードポイント数)に合わせて
//   unicodeScalars.count で数える(絵文字込みでも DB とズレない — issue #10)。規則は NicknameRules
//   (設定のプロフィール編集と共通 — issue #23)
// - 利用規約・プライバシーポリシーへの明示の同意(チェック)が入るまで、プロフィールを送信できない。
//   送信が匿名サインイン(= アカウントの作成)を兼ねるので、同意のないままアカウントを作らない
//   (写真を共有するアプリの審査要件 — App Store ガイドライン 1.2 / issue #23)

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

    // MARK: - 入力状態(View からバインド)

    var nickname = ""
    var avatarEmoji = Strings.Onboarding.avatarPalette.first ?? "🌱"
    /// 利用規約とプライバシーポリシーに同意したか(チェック)。入るまで送信できない
    var agreedToTerms = false

    // MARK: - 画面状態

    private(set) var step: Step = .concept
    private(set) var isSubmitting = false
    private(set) var isRequestingNotifications = false
    /// 送信失敗時のユーザー向けメッセージ(同じ画面に留まり、リトライで再送信できる)
    private(set) var submitErrorMessage: String?

    // MARK: - 依存(モック注入可能)

    private let authService: AuthServicing
    private let pushAuthorizer: PushAuthorizing
    private let onProfileSubmitStarted: (() -> Void)?
    private let onFinished: () -> Void
    private var hasFinished = false

    /// - onProfileSubmitStarted: プロフィール送信(匿名サインインを含む)を始めるたびに呼ぶ。
    ///   ルート(AppModel)が、ここで作るセッションを「起動時に読めなかったセッションの復元」と取り違えて
    ///   オンボーディングの途中で画面を飛ばさないようにするための合図(issue #62)
    init(
        authService: AuthServicing,
        pushAuthorizer: PushAuthorizing,
        onProfileSubmitStarted: (() -> Void)? = nil,
        onFinished: @escaping () -> Void
    ) {
        self.authService = authService
        self.pushAuthorizer = pushAuthorizer
        self.onProfileSubmitStarted = onProfileSubmitStarted
        self.onFinished = onFinished
    }

    // MARK: - ニックネーム検証

    /// 前後の空白・改行を除いた送信用ニックネーム
    var trimmedNickname: String {
        NicknameRules.trimmed(nickname)
    }

    /// nil なら送信可。DB の check(char_length <= 8)と同じ数え方で検証する。
    /// 設定のプロフィール編集と同じ規則(NicknameRules)
    var nicknameError: NicknameError? {
        NicknameRules.validate(nickname)
    }

    var canSubmitProfile: Bool {
        nicknameError == nil && agreedToTerms && !isSubmitting
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
        onProfileSubmitStarted?()
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
