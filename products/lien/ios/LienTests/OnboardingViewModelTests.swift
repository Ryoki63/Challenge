// OnboardingViewModelTests.swift — オンボ VM の主要パス(T10。モック注入で CI 完結)
//
// 実 Supabase での匿名サインイン・users 行トリガー作成の疎通は T08(G0 後)の E2E で検証する。

import XCTest
@testable import Lien

// MARK: - モック
// トップレベルに置き、テストクラスの @MainActor 隔離を継承させない
// (AuthServicing / PushAuthorizing は非隔離プロトコルのため)

private final class MockAuthService: AuthServicing {
    var signInCallCount = 0
    var updateProfileCallCount = 0
    var signInError: Error?
    var updateProfileError: Error?
    private(set) var signedInUserID: UUID?
    private(set) var lastNickname: String?
    private(set) var lastAvatarEmoji: String?
    private(set) var lastTimezone: String?

    var currentUserID: UUID? { signedInUserID }

    /// サインイン済みセッションが既にある状態を作る
    func presetSignedIn() {
        signedInUserID = UUID()
    }

    @discardableResult
    func signInAnonymously() async throws -> UUID {
        signInCallCount += 1
        if let signInError { throw signInError }
        let id = UUID()
        signedInUserID = id
        return id
    }

    func updateProfile(nickname: String, avatarEmoji: String, timezone: String) async throws {
        updateProfileCallCount += 1
        if let updateProfileError { throw updateProfileError }
        lastNickname = nickname
        lastAvatarEmoji = avatarEmoji
        lastTimezone = timezone
    }

    func updateNicknameAndAvatar(nickname: String, avatarEmoji: String) async throws {
        lastNickname = nickname
        lastAvatarEmoji = avatarEmoji
    }

    func accessToken() async throws -> String {
        guard signedInUserID != nil else { throw AuthServiceError.notSignedIn }
        return "test-access-token"
    }

    func fetchProfile() async throws -> UserProfile {
        guard signedInUserID != nil else { throw AuthServiceError.notSignedIn }
        return UserProfile(nickname: lastNickname ?? "", avatarEmoji: lastAvatarEmoji ?? "")
    }

    func fetchMyPromise() async throws -> Promise? {
        guard signedInUserID != nil else { throw AuthServiceError.notSignedIn }
        return nil
    }

    func signOut() async {
        signedInUserID = nil
    }
}

private final class MockPushAuthorizer: PushAuthorizing {
    var requestCallCount = 0
    var grantResult = true

    @discardableResult
    func requestAuthorization() async -> Bool {
        requestCallCount += 1
        return grantResult
    }
}

private enum TestError: Error {
    case network
}

// MARK: - テスト本体

@MainActor
final class OnboardingViewModelTests: XCTestCase {
    /// 規約に同意済みのオンボ VM(同意の有無を見るテストは agreed: false)
    private func makeViewModel(
        auth: MockAuthService,
        push: MockPushAuthorizer,
        agreed: Bool = true,
        onFinished: @escaping () -> Void = {}
    ) -> OnboardingViewModel {
        let vm = OnboardingViewModel(authService: auth, pushAuthorizer: push, onFinished: onFinished)
        vm.agreedToTerms = agreed
        return vm
    }

    // MARK: ステップ遷移

    func testStepAdvancesFromConceptToNickname() {
        let vm = makeViewModel(auth: MockAuthService(), push: MockPushAuthorizer())
        XCTAssertEqual(vm.step, .concept)
        vm.advanceFromConcept()
        XCTAssertEqual(vm.step, .nickname)
        // 2回呼んでも進みすぎない
        vm.advanceFromConcept()
        XCTAssertEqual(vm.step, .nickname)
    }

    // MARK: ニックネーム検証

    func testNicknameValidationEmptyAndWhitespaceOnly() {
        let vm = makeViewModel(auth: MockAuthService(), push: MockPushAuthorizer())
        vm.nickname = ""
        XCTAssertEqual(vm.nicknameError, .empty)
        vm.nickname = "   \n "
        XCTAssertEqual(vm.nicknameError, .empty)
        XCTAssertFalse(vm.canSubmitProfile)
    }

    func testNicknameValidationBoundaryAt8Characters() {
        let vm = makeViewModel(auth: MockAuthService(), push: MockPushAuthorizer())
        vm.nickname = "あいうえおかきく" // 8字: OK
        XCTAssertNil(vm.nicknameError)
        vm.nickname = "あいうえおかきくけ" // 9字: 超過
        XCTAssertEqual(vm.nicknameError, .tooLong)
        // 前後の空白はトリムしてから数える
        vm.nickname = "  あいうえおかきく  "
        XCTAssertNil(vm.nicknameError)
    }

    func testNicknameCountsUnicodeScalarsLikeDatabase() {
        // DB の check は char_length(コードポイント数)。肌色修飾付き絵文字は
        // 1書記素 = 2スカラーなので、scalar 基準で数えることを固定する
        let vm = makeViewModel(auth: MockAuthService(), push: MockPushAuthorizer())
        vm.nickname = String(repeating: "👍🏻", count: 4) // scalar 8: OK
        XCTAssertNil(vm.nicknameError)
        vm.nickname = String(repeating: "👍🏻", count: 5) // scalar 10: 超過
        XCTAssertEqual(vm.nicknameError, .tooLong)
    }

    // MARK: プロフィール送信

    func testSubmitProfileRejectedWhenNicknameInvalid() async {
        let auth = MockAuthService()
        let vm = makeViewModel(auth: auth, push: MockPushAuthorizer())
        vm.advanceFromConcept()
        vm.nickname = "   "
        await vm.submitProfile()
        XCTAssertEqual(auth.signInCallCount, 0)
        XCTAssertEqual(auth.updateProfileCallCount, 0)
        XCTAssertEqual(vm.step, .nickname)
    }

    func testSubmitProfileSendsTrimmedPayloadAndAdvances() async {
        let auth = MockAuthService()
        let vm = makeViewModel(auth: auth, push: MockPushAuthorizer())
        vm.advanceFromConcept()
        vm.nickname = "  ゆき  "
        vm.avatar = .cactus
        await vm.submitProfile()

        XCTAssertEqual(auth.signInCallCount, 1)
        XCTAssertEqual(auth.lastNickname, "ゆき") // トリム済みで送信
        XCTAssertEqual(auth.lastAvatarEmoji, "cactus", "サーバーには絵文字ではなくアイコンの id を送る")
        XCTAssertEqual(auth.lastTimezone, TimeZone.current.identifier)
        XCTAssertEqual(vm.step, .notification)
        XCTAssertNil(vm.submitErrorMessage)
        XCTAssertFalse(vm.isSubmitting)
    }

    func testSubmitProfileSendsTheDefaultAvatarWhenNothingWasPicked() async {
        // アイコンを選ばずに進んだ人にも、最初から選ばれている「ふたば」の id が保存される(空のまま送らない)
        let auth = MockAuthService()
        let vm = makeViewModel(auth: auth, push: MockPushAuthorizer())
        vm.advanceFromConcept()
        vm.nickname = "ゆき"
        XCTAssertEqual(vm.avatar, .defaultAvatar)
        await vm.submitProfile()

        XCTAssertEqual(auth.lastAvatarEmoji, LienAvatar.defaultAvatar.rawValue)
        XCTAssertEqual(auth.lastAvatarEmoji, "sprout")
    }

    func testSubmitProfileSignsInOnlyOnceAcrossRetries() async {
        let auth = MockAuthService()
        auth.updateProfileError = TestError.network
        let vm = makeViewModel(auth: auth, push: MockPushAuthorizer())
        vm.advanceFromConcept()
        vm.nickname = "ゆき"

        // 1回目: サインインは成功、プロフィール更新で失敗 → エラー表示で留まる
        await vm.submitProfile()
        XCTAssertEqual(auth.signInCallCount, 1)
        XCTAssertEqual(vm.step, .nickname)
        XCTAssertNotNil(vm.submitErrorMessage)

        // リトライ: セッションが残っているので再サインインしない
        auth.updateProfileError = nil
        await vm.submitProfile()
        XCTAssertEqual(auth.signInCallCount, 1)
        XCTAssertEqual(auth.updateProfileCallCount, 2)
        XCTAssertEqual(vm.step, .notification)
        XCTAssertNil(vm.submitErrorMessage)
    }

    func testSignInFailureShowsErrorAndRetryRecovers() async {
        let auth = MockAuthService()
        auth.signInError = TestError.network
        let vm = makeViewModel(auth: auth, push: MockPushAuthorizer())
        vm.advanceFromConcept()
        vm.nickname = "ゆき"

        await vm.submitProfile()
        XCTAssertEqual(vm.submitErrorMessage, Strings.Onboarding.submitErrorMessage)
        XCTAssertEqual(vm.step, .nickname)
        XCTAssertEqual(auth.updateProfileCallCount, 0) // サインイン失敗なら更新は呼ばない

        auth.signInError = nil
        await vm.submitProfile()
        XCTAssertNil(vm.submitErrorMessage)
        XCTAssertEqual(vm.step, .notification)
    }

    func testSubmitProfileSkipsSignInWhenSessionExists() async {
        let auth = MockAuthService()
        auth.presetSignedIn()
        let vm = makeViewModel(auth: auth, push: MockPushAuthorizer())
        vm.advanceFromConcept()
        vm.nickname = "ゆき"
        await vm.submitProfile()
        XCTAssertEqual(auth.signInCallCount, 0)
        XCTAssertEqual(auth.updateProfileCallCount, 1)
        XCTAssertEqual(vm.step, .notification)
    }

    // MARK: プロフィール送信の開始通知(issue #62: ルートが新しいセッションを復元と取り違えないための合図)

    func testSubmitProfileNotifiesRootBeforeSigningIn() async {
        let auth = MockAuthService()
        auth.updateProfileError = TestError.network
        var signInCountAtNotification: [Int] = []
        let vm = OnboardingViewModel(
            authService: auth,
            pushAuthorizer: MockPushAuthorizer(),
            onProfileSubmitStarted: { signInCountAtNotification.append(auth.signInCallCount) },
            onFinished: {}
        )
        vm.agreedToTerms = true
        vm.advanceFromConcept()
        vm.nickname = "ゆき"

        await vm.submitProfile() // サインインのあとでプロフィール更新が失敗
        auth.updateProfileError = nil
        await vm.submitProfile() // リトライ

        XCTAssertEqual(signInCountAtNotification, [0, 1], "送信のたびに、サインインより前に通知する(リトライでも)")
    }

    func testInvalidNicknameDoesNotNotifyRoot() async {
        var notified = 0
        let vm = OnboardingViewModel(
            authService: MockAuthService(),
            pushAuthorizer: MockPushAuthorizer(),
            onProfileSubmitStarted: { notified += 1 },
            onFinished: {}
        )
        vm.agreedToTerms = true
        vm.advanceFromConcept()
        vm.nickname = "   "
        await vm.submitProfile()
        XCTAssertEqual(notified, 0, "送信に進まなかったときは通知しない")
    }

    // MARK: 規約への同意(T23 #23: 同意するまで、アカウントを作る送信ができない)

    func testCannotSubmitProfileWithoutAgreeingToTerms() async {
        let auth = MockAuthService()
        let vm = makeViewModel(auth: auth, push: MockPushAuthorizer(), agreed: false)
        vm.advanceFromConcept()
        vm.nickname = "ゆき"

        XCTAssertNil(vm.nicknameError, "ニックネームは有効")
        XCTAssertFalse(vm.agreedToTerms)
        XCTAssertFalse(vm.canSubmitProfile, "同意のチェックが無ければ送信ボタンは押せない")

        await vm.submitProfile()

        XCTAssertEqual(auth.signInCallCount, 0, "同意が無ければ匿名サインイン(アカウントの作成)をしない")
        XCTAssertEqual(auth.updateProfileCallCount, 0)
        XCTAssertEqual(vm.step, .nickname)
    }

    func testAgreeingToTermsEnablesSubmitAndWithdrawingDisablesAgain() async {
        let auth = MockAuthService()
        let vm = makeViewModel(auth: auth, push: MockPushAuthorizer(), agreed: false)
        vm.advanceFromConcept()
        vm.nickname = "ゆき"

        vm.agreedToTerms = true
        XCTAssertTrue(vm.canSubmitProfile)
        vm.agreedToTerms = false // 外した
        XCTAssertFalse(vm.canSubmitProfile)
        await vm.submitProfile()
        XCTAssertEqual(auth.signInCallCount, 0)

        vm.agreedToTerms = true
        await vm.submitProfile()
        XCTAssertEqual(auth.signInCallCount, 1)
        XCTAssertEqual(vm.step, .notification)
    }

    func testAgreementIsRequiredEvenForInvalidNicknameCombination() {
        let vm = makeViewModel(auth: MockAuthService(), push: MockPushAuthorizer(), agreed: true)
        vm.nickname = "   "
        XCTAssertFalse(vm.canSubmitProfile, "同意していてもニックネームが無効なら送れない")
    }

    // MARK: 通知プレ許可

    func testRequestNotificationsCallsAuthorizerAndFinishes() async {
        let push = MockPushAuthorizer()
        var finishedCount = 0
        let vm = makeViewModel(auth: MockAuthService(), push: push) { finishedCount += 1 }
        await vm.requestNotifications()
        XCTAssertEqual(push.requestCallCount, 1)
        XCTAssertEqual(finishedCount, 1)
    }

    func testRequestNotificationsDeniedStillFinishes() async {
        let push = MockPushAuthorizer()
        push.grantResult = false
        var finishedCount = 0
        let vm = makeViewModel(auth: MockAuthService(), push: push) { finishedCount += 1 }
        await vm.requestNotifications()
        XCTAssertEqual(finishedCount, 1) // 拒否でもオンボは完了(ブロックしない)
    }

    func testSkipNotificationsFinishesWithoutOSDialog() async {
        let push = MockPushAuthorizer()
        var finishedCount = 0
        let vm = makeViewModel(auth: MockAuthService(), push: push) { finishedCount += 1 }
        vm.skipNotifications()
        XCTAssertEqual(push.requestCallCount, 0) // ダイアログは出さない
        XCTAssertEqual(finishedCount, 1)

        // 完了は1回だけ(二重発火しない)
        vm.skipNotifications()
        await vm.requestNotifications()
        XCTAssertEqual(finishedCount, 1)
    }

    // 起動時の初期 phase 導出(旧 LienApp.initialPhase — issue #10 手順7)は
    // 純粋関数 AppRouter.phase(hasSession:snapshot:) に移った(AppRouterTests — issue #55)
}
