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
    private func makeViewModel(
        auth: MockAuthService,
        push: MockPushAuthorizer,
        onFinished: @escaping () -> Void = {}
    ) -> OnboardingViewModel {
        OnboardingViewModel(authService: auth, pushAuthorizer: push, onFinished: onFinished)
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
        vm.avatarEmoji = "🐰"
        await vm.submitProfile()

        XCTAssertEqual(auth.signInCallCount, 1)
        XCTAssertEqual(auth.lastNickname, "ゆき") // トリム済みで送信
        XCTAssertEqual(auth.lastAvatarEmoji, "🐰")
        XCTAssertEqual(auth.lastTimezone, TimeZone.current.identifier)
        XCTAssertEqual(vm.step, .notification)
        XCTAssertNil(vm.submitErrorMessage)
        XCTAssertFalse(vm.isSubmitting)
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

    // MARK: 起動時の初期 phase 導出(LienApp.initialPhase — issue #10 手順7)

    func testInitialPhaseDerivation() throws {
        let auth = MockAuthService()
        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("OnboardingVMTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let store = AppGroupStore(containerURL: tempDir)

        // セッション無し → onboarding(store の有無は関係ない)
        XCTAssertEqual(LienApp.initialPhase(authService: auth, store: store), .onboarding)
        XCTAssertEqual(LienApp.initialPhase(authService: auth, store: nil), .onboarding)

        // セッション有り+snapshot 無し → solo
        auth.presetSignedIn()
        XCTAssertEqual(LienApp.initialPhase(authService: auth, store: store), .solo)

        // snapshot はあるが pairId == null(ソロ状態)→ solo のまま
        try store.saveSnapshot(makeSnapshot(pairId: nil))
        XCTAssertEqual(LienApp.initialPhase(authService: auth, store: store), .solo)

        // pairId 有り → paired
        try store.saveSnapshot(makeSnapshot(pairId: "1f0c5a4e-9d3b-4c1a-8f2e-7b6d5a4c3b2a"))
        XCTAssertEqual(LienApp.initialPhase(authService: auth, store: store), .paired)
    }

    private func makeSnapshot(pairId: String?) -> PairSnapshot {
        PairSnapshot(
            schemaVersion: PairSnapshot.currentSchemaVersion,
            pairId: pairId,
            updatedAt: Date(timeIntervalSince1970: 1_781_166_600), // 2026-06-11T08:30:00Z
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
    }
}
