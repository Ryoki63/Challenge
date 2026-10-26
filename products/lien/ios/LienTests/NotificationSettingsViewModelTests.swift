// NotificationSettingsViewModelTests.swift — 通知の設定画面の状態管理(T16 #16 / REQUIREMENTS §3.12・§3.15)
//
// 検証対象(NotificationSettingsViewModel.swift):
//   - リマインド(約束の remind_at): サーバーの約束を読んで草稿にする / 「保存する」で約束を更新して端末の予約に反映 /
//     失敗してもやり直せる / 約束が読めない間・約束が無い間は変えられない
//   - ストリーク危機(端末ローカル): すぐ保存して予約を合わせる(通信しない)/ 約束が読めなくても変えられる /
//     スイッチの値は操作したその場で変わる(いったん元に戻って見えない)
//   - OS の通知許可: 拒否の案内 / まだのときだけ、ON にしたときに許可を求める / 許可されたら予約を合わせ直す
//   - 設定画面の行の右側の要約

import XCTest
@testable import Lien

// MARK: - モック(トップレベル: テストクラスの隔離を継承させない)

private final class NotificationMockAuth: AuthServicing {
    var promiseResult: Result<Promise?, Error> = .success(nil)
    private(set) var promiseFetches = 0

    var currentUserID: UUID? { UUID() }

    @discardableResult
    func signInAnonymously() async throws -> UUID { UUID() }
    func updateProfile(nickname: String, avatarEmoji: String, timezone: String) async throws {}
    func updateNicknameAndAvatar(nickname: String, avatarEmoji: String) async throws {}
    func accessToken() async throws -> String { "token" }
    func fetchProfile() async throws -> UserProfile { UserProfile(nickname: "あきら", avatarEmoji: "🌱") }
    func fetchMyPromise() async throws -> Promise? {
        promiseFetches += 1
        return try promiseResult.get()
    }
    func signOut() async {}
}

private final class RecordingPromiseClient: PromiseAPIClient {
    struct Call: Equatable {
        let title: String
        let emoji: String
        let remindAt: String?
    }

    private(set) var calls: [Call] = []
    var error: Error?
    /// 送信の途中で止めるための門(保存中の状態を観測する)
    var gate: AsyncGate?

    func setPromise(title: String, emoji: String, remindAt: String?) async throws -> Promise {
        calls.append(Call(title: title, emoji: emoji, remindAt: remindAt))
        if let gate { await gate.wait() }
        if let error { throw error }
        return Promise(id: "p-1", title: title, emoji: emoji, remindAt: remindAt)
    }
}

/// 許可を求められた回数を数え、求められたら通知センターの許可を「許可」に変える(OS のダイアログで許可した想定)
private final class CountingAuthorizer: PushAuthorizing {
    private(set) var requestCount = 0
    let center: FakeNotificationCenter
    var grants = true

    init(center: FakeNotificationCenter) {
        self.center = center
    }

    @discardableResult
    func requestAuthorization() async -> Bool {
        requestCount += 1
        center.authorization = grants ? .authorized : .denied
        return grants
    }
}

private struct Offline: Error {}

@MainActor
final class NotificationSettingsViewModelTests: XCTestCase {
    private typealias Clock = NotificationClock

    private struct Rig {
        let vm: NotificationSettingsViewModel
        let auth: NotificationMockAuth
        let client: RecordingPromiseClient
        let center: FakeNotificationCenter
        let scheduler: ReminderScheduler
        let store: InMemoryNotificationPreferencesStore
        let authorizer: CountingAuthorizer
        let saved: SavedBox
    }

    /// onReminderSaved に渡された約束を受け取る箱
    private final class SavedBox {
        var promises: [Promise] = []
    }

    private let now = NotificationClock.date(2026, 10, 14, 12, 0)
    private let calendar = NotificationClock.calendar()

    private func makeRig(
        promise: Promise? = Promise(id: "p-1", title: "筋トレ", emoji: "💪", remindAt: "20:30"),
        prefs: NotificationPreferences = NotificationPreferences(reminder: .daily(hour: 20, minute: 30)),
        authorization: NotificationAuthorization = .authorized
    ) -> Rig {
        let auth = NotificationMockAuth()
        auth.promiseResult = .success(promise)
        let client = RecordingPromiseClient()
        let center = FakeNotificationCenter()
        center.authorization = authorization
        let store = InMemoryNotificationPreferencesStore(prefs)
        let snapshot = NotificationSnapshots.paired(updatedAt: now)
        let current = now
        let zone = calendar
        let scheduler = ReminderScheduler(
            center: center,
            preferences: store,
            snapshotSource: { snapshot },
            now: { current },
            calendar: { zone }
        )
        let authorizer = CountingAuthorizer(center: center)
        let saved = SavedBox()
        let vm = NotificationSettingsViewModel(
            auth: auth,
            promiseClient: client,
            reminders: scheduler,
            authorizer: authorizer,
            calendar: calendar,
            onReminderSaved: { saved.promises.append($0) }
        )
        return Rig(vm: vm, auth: auth, client: client, center: center, scheduler: scheduler, store: store,
                   authorizer: authorizer, saved: saved)
    }

    private func time(_ hour: Int, _ minute: Int) -> Date {
        calendar.date(bySettingHour: hour, minute: minute, second: 0, of: now)!
    }

    // MARK: 読み込み

    func testLoadFillsTheDraftFromTheServerPromise() async {
        let rig = makeRig()
        XCTAssertEqual(rig.vm.loadState, .loading)

        await rig.vm.load()

        XCTAssertEqual(rig.vm.loadState, .loaded)
        XCTAssertTrue(rig.vm.canEditReminder)
        XCTAssertTrue(rig.vm.reminderEnabled)
        XCTAssertEqual(calendar.dateComponents([.hour, .minute], from: rig.vm.reminderTime).hour, 20)
        XCTAssertEqual(calendar.dateComponents([.hour, .minute], from: rig.vm.reminderTime).minute, 30)
        XCTAssertFalse(rig.vm.isReminderDirty, "読んだだけでは、変更なし")
        XCTAssertFalse(rig.vm.canSaveReminder)
        XCTAssertTrue(rig.vm.streakRiskEnabled)
    }

    func testPromiseWithoutRemindAtLoadsAsOffWithTheDefaultTime() async {
        let rig = makeRig(promise: Promise(id: "p-1", title: "筋トレ", emoji: "💪", remindAt: nil))
        await rig.vm.load()
        XCTAssertFalse(rig.vm.reminderEnabled)
        XCTAssertEqual(calendar.dateComponents([.hour, .minute], from: rig.vm.reminderTime).hour, 20, "オンにしたときの既定は 20:00")
        XCTAssertEqual(calendar.dateComponents([.hour, .minute], from: rig.vm.reminderTime).minute, 0)
        XCTAssertFalse(rig.vm.isReminderDirty)
    }

    func testLoadFailureBlocksReminderEditingButNotTheStreakToggle() async {
        let rig = makeRig()
        rig.auth.promiseResult = .failure(Offline())

        await rig.vm.load()

        XCTAssertEqual(rig.vm.loadState, .failed)
        XCTAssertFalse(rig.vm.canEditReminder, "元の値が分からないまま保存すると、約束のリマインドを書き換えてしまう")
        await rig.vm.saveReminder()
        XCTAssertEqual(rig.client.calls, [])

        await rig.vm.setStreakRiskEnabled(false)
        XCTAssertFalse(rig.store.load().streakRiskEnabled, "端末ローカルの設定は、通信できなくても変えられる")

        rig.auth.promiseResult = .success(Promise(id: "p-1", title: "筋トレ", emoji: "💪", remindAt: "20:30"))
        await rig.vm.load() // 「もう一度ためす」
        XCTAssertEqual(rig.vm.loadState, .loaded)
        XCTAssertTrue(rig.vm.canEditReminder)
    }

    func testNoPromiseYetMeansNothingToEdit() async {
        let rig = makeRig(promise: nil)
        await rig.vm.load()
        XCTAssertEqual(rig.vm.loadState, .loaded)
        XCTAssertTrue(rig.vm.hasNoPromise)
        XCTAssertFalse(rig.vm.canEditReminder)
        await rig.vm.saveReminder()
        XCTAssertEqual(rig.client.calls, [])
    }

    // MARK: リマインドの保存

    func testChangingTheTimeMakesTheDraftDirtyAndSavingUpdatesThePromise() async {
        let rig = makeRig()
        await rig.vm.load()

        rig.vm.reminderTime = time(21, 15)
        XCTAssertTrue(rig.vm.isReminderDirty)
        XCTAssertTrue(rig.vm.canSaveReminder)
        XCTAssertEqual(rig.vm.reminderAtToSend, "21:15")

        await rig.vm.saveReminder()

        XCTAssertEqual(
            rig.client.calls, [.init(title: "筋トレ", emoji: "💪", remindAt: "21:15")],
            "タイトルと絵文字は読んだままを送る(約束のほかの項目を変えない)"
        )
        XCTAssertEqual(rig.vm.promise?.remindAt, "21:15")
        XCTAssertFalse(rig.vm.isReminderDirty, "保存したので、変更なし")
        XCTAssertTrue(rig.vm.showsSavedNote)
        XCTAssertNil(rig.vm.saveErrorMessage)
        XCTAssertEqual(rig.saved.promises.map(\.remindAt), ["21:15"], "画面と AppModel に、保存した約束が渡る")
    }

    func testSavingFallsBackToThePlaceholderEmojiWhenThePromiseHasNone() async {
        // 約束の絵文字は UI から廃止した(2026-10-26)。サーバーの promise-set は emoji 必須(空は invalid_emoji)なので、
        // 読んだ約束の絵文字が空なら固定値を送る(空のまま送ると、リマインドの保存が必ず失敗する)
        let rig = makeRig(promise: Promise(id: "p-1", title: "筋トレ", emoji: "", remindAt: "20:30"))
        await rig.vm.load()

        rig.vm.reminderTime = time(21, 0)
        await rig.vm.saveReminder()

        XCTAssertEqual(
            rig.client.calls,
            [.init(title: "筋トレ", emoji: PromiseSetupViewModel.placeholderEmoji, remindAt: "21:00")]
        )
        XCTAssertNil(rig.vm.saveErrorMessage)
    }

    func testTurningTheReminderOffSavesANilRemindAt() async {
        let rig = makeRig()
        await rig.vm.load()

        rig.vm.reminderEnabled = false
        XCTAssertTrue(rig.vm.isReminderDirty)
        XCTAssertNil(rig.vm.reminderAtToSend)
        await rig.vm.saveReminder()

        XCTAssertEqual(rig.client.calls, [.init(title: "筋トレ", emoji: "💪", remindAt: nil)])
        XCTAssertNil(rig.vm.promise?.remindAt)
        XCTAssertFalse(rig.vm.reminderEnabled)
        XCTAssertFalse(rig.vm.isReminderDirty)
    }

    func testTurningTheReminderOnUsesTheDraftTime() async {
        let rig = makeRig(promise: Promise(id: "p-1", title: "筋トレ", emoji: "💪", remindAt: nil))
        await rig.vm.load()
        XCTAssertFalse(rig.vm.isReminderDirty)

        rig.vm.reminderEnabled = true
        XCTAssertTrue(rig.vm.isReminderDirty)
        await rig.vm.saveReminder()

        XCTAssertEqual(rig.client.calls, [.init(title: "筋トレ", emoji: "💪", remindAt: "20:00")])
        XCTAssertTrue(rig.vm.reminderEnabled)
    }

    func testChangingTheTimeWhileOffIsNotAChange() async {
        // オフのまま時刻の欄をいじっても(欄は出ないが、草稿の値が動いても)保存する変更ではない
        let rig = makeRig(promise: Promise(id: "p-1", title: "筋トレ", emoji: "💪", remindAt: nil))
        await rig.vm.load()
        rig.vm.reminderTime = time(6, 0)
        XCTAssertFalse(rig.vm.isReminderDirty)
    }

    func testRestoringTheSavedValueClearsTheDirtyFlag() async {
        let rig = makeRig()
        await rig.vm.load()
        rig.vm.reminderTime = time(22, 0)
        XCTAssertTrue(rig.vm.isReminderDirty)
        rig.vm.reminderTime = time(20, 30)
        XCTAssertFalse(rig.vm.isReminderDirty, "元に戻したら、変更なし")
    }

    func testSavingWithoutAChangeDoesNothing() async {
        let rig = makeRig()
        await rig.vm.load()
        await rig.vm.saveReminder()
        XCTAssertEqual(rig.client.calls, [])
        XCTAssertEqual(rig.saved.promises, [])
    }

    func testSaveFailureKeepsTheDraftAndAllowsRetry() async {
        let rig = makeRig()
        await rig.vm.load()
        rig.vm.reminderTime = time(21, 0)
        rig.client.error = Offline()

        await rig.vm.saveReminder()

        XCTAssertEqual(rig.vm.saveErrorMessage, Strings.NotificationSettings.reminderSaveError)
        XCTAssertTrue(rig.vm.isReminderDirty, "草稿は残る")
        XCTAssertEqual(rig.vm.promise?.remindAt, "20:30", "保存できていないので、約束は元のまま")
        XCTAssertEqual(rig.saved.promises, [], "端末の予約は変えない")
        XCTAssertFalse(rig.vm.showsSavedNote)
        XCTAssertFalse(rig.vm.isSaving)

        rig.client.error = nil
        await rig.vm.saveReminder()
        XCTAssertNil(rig.vm.saveErrorMessage, "やり直して成功したらメッセージは消える")
        XCTAssertEqual(rig.saved.promises.map(\.remindAt), ["21:00"])
    }

    func testWhileSavingAnotherSaveIsNotAccepted() async {
        let rig = makeRig()
        await rig.vm.load()
        rig.vm.reminderTime = time(21, 0)
        let gate = AsyncGate()
        rig.client.gate = gate

        let saving = Task { @MainActor in await rig.vm.saveReminder() }
        await waitUntil { rig.client.calls.count == 1 }
        XCTAssertTrue(rig.vm.isSaving)
        XCTAssertFalse(rig.vm.canSaveReminder, "保存中は、もう一度押せない")
        await rig.vm.saveReminder()
        XCTAssertEqual(rig.client.calls.count, 1)

        gate.open()
        await saving.value
        XCTAssertFalse(rig.vm.isSaving)
        XCTAssertEqual(rig.client.calls.count, 1)
    }

    func testReminderSavedHookFeedsTheLocalNotificationSchedule() async {
        // 画面 → AppModel.reminderSaved と同じ手順(recordReminder → sync)で、端末の予約が保存した時刻になる
        let rig = makeRig()
        await rig.vm.load()
        rig.vm.reminderTime = time(21, 15)
        await rig.vm.saveReminder()
        let promise = try? XCTUnwrap(rig.saved.promises.first)
        if let promise { rig.scheduler.recordReminder(from: promise) }
        await rig.scheduler.sync()

        XCTAssertEqual(rig.store.load().reminder, .daily(hour: 21, minute: 15))
        let reminders = rig.center.ourPending.filter(\.isReminder)
        XCTAssertFalse(reminders.isEmpty)
        XCTAssertTrue(reminders.allSatisfy { $0.fireAt.hour == 21 && $0.fireAt.minute == 15 })
    }

    // MARK: ストリーク危機(端末ローカル)

    func testStreakToggleIsSavedImmediatelyWithoutTalkingToTheServer() async {
        let rig = makeRig()
        await rig.vm.load()
        await rig.scheduler.sync()
        XCTAssertEqual(rig.center.ourPending.filter(\.isStreakRisk).count, 1)

        await rig.vm.setStreakRiskEnabled(false)

        XCTAssertFalse(rig.vm.streakRiskEnabled)
        XCTAssertFalse(rig.store.load().streakRiskEnabled)
        XCTAssertEqual(rig.center.ourPending.filter(\.isStreakRisk).count, 0, "予約も取り消される")
        XCTAssertEqual(rig.client.calls, [], "約束(サーバー)には触れない")

        await rig.vm.setStreakRiskEnabled(true)
        XCTAssertTrue(rig.store.load().streakRiskEnabled)
        XCTAssertEqual(rig.center.ourPending.filter(\.isStreakRisk).count, 1)
    }

    func testTheSwitchShowsTheNewValueAtOnceAndSavesRightAfter() async {
        // SwiftUI の Toggle の Binding は、set の中で値が変わらないと、いったん元の値に戻って見える。
        // set からは、画面の値を変える同期の関数を呼び、保存と予約はその Task が続ける
        let rig = makeRig()
        await rig.vm.load()
        await rig.scheduler.sync()
        XCTAssertTrue(rig.vm.streakRiskEnabled)

        let saving = rig.vm.streakRiskToggled(to: false)
        XCTAssertFalse(rig.vm.streakRiskEnabled, "呼び出しが返った時点で、もう画面の値が変わっている")

        await saving.value
        XCTAssertFalse(rig.store.load().streakRiskEnabled)
        XCTAssertEqual(rig.center.ourPending.filter(\.isStreakRisk).count, 0, "保存と予約は、そのあとに済む")
    }

    func testStreakToggleStartsFromTheSavedSetting() async {
        let rig = makeRig(prefs: NotificationPreferences(reminder: .daily(hour: 20, minute: 30), streakRiskEnabled: false))
        XCTAssertFalse(rig.vm.streakRiskEnabled)
        await rig.vm.load()
        XCTAssertFalse(rig.vm.streakRiskEnabled)
    }

    // MARK: OS の通知許可

    func testDeniedAuthorizationIsShownAndRefreshedWhenComingBackFromSettings() async {
        let rig = makeRig(authorization: .denied)
        XCTAssertEqual(rig.vm.authorization, .authorized, "読むまでは案内を出さない")

        await rig.vm.load()
        XCTAssertEqual(rig.vm.authorization, .denied)

        rig.center.authorization = .authorized // iOS の設定アプリで許可して戻ってきた
        await rig.vm.refreshAuthorization()
        XCTAssertEqual(rig.vm.authorization, .authorized)
    }

    func testEnablingTheStreakToggleAsksForPermissionOnlyWhenNotYetAsked() async {
        let rig = makeRig(authorization: .notDetermined)
        await rig.vm.load()

        await rig.vm.setStreakRiskEnabled(true)

        XCTAssertEqual(rig.authorizer.requestCount, 1, "オンボーディングで「あとで」を選んだ人が、あとから許可できる")
        XCTAssertEqual(rig.vm.authorization, .authorized)

        await rig.vm.setStreakRiskEnabled(false)
        await rig.vm.setStreakRiskEnabled(true)
        XCTAssertEqual(rig.authorizer.requestCount, 1, "許可済みなら、もう聞かない")
    }

    func testGrantingPermissionSyncsTheScheduleAgain() async {
        // 許可が出る前に合わせた予約は、OS に断られて残っていないかもしれない。許可されたら、もう一度合わせる
        let rig = makeRig(authorization: .notDetermined)
        await rig.vm.load()
        XCTAssertEqual(rig.center.ourPending.count, 0)

        await rig.vm.setStreakRiskEnabled(true)

        XCTAssertEqual(rig.authorizer.requestCount, 1)
        XCTAssertGreaterThan(rig.center.pendingReads, 1, "許可のあとの同期が走った(設定の保存の同期とは別に、もう一度)")
        XCTAssertEqual(rig.center.ourPending.filter(\.isStreakRisk).count, 1)
        XCTAssertEqual(rig.center.ourPending.filter(\.isReminder).count, 14, "リマインドも、許可されたあとに合わせ直される")
    }

    func testRefusingPermissionDoesNotSyncAgain() async {
        let rig = makeRig(authorization: .notDetermined)
        rig.authorizer.grants = false
        await rig.vm.load()

        await rig.vm.setStreakRiskEnabled(true)

        XCTAssertEqual(rig.authorizer.requestCount, 1)
        XCTAssertEqual(rig.vm.authorization, .denied, "拒否されたら、画面に案内を出す")
        XCTAssertEqual(rig.center.pendingReads, 1, "設定の保存の同期だけ(許可のあとの同期は走らない)")
    }

    func testSavingAnEnabledReminderAsksForPermissionOnlyWhenNotYetAsked() async {
        let rig = makeRig(authorization: .notDetermined)
        await rig.vm.load()
        rig.vm.reminderTime = time(21, 0)
        await rig.vm.saveReminder()
        XCTAssertEqual(rig.authorizer.requestCount, 1)

        // オフにして保存するときは聞かない
        let off = makeRig(authorization: .notDetermined)
        await off.vm.load()
        off.vm.reminderEnabled = false
        await off.vm.saveReminder()
        XCTAssertEqual(off.authorizer.requestCount, 0)
    }

    func testDeniedAuthorizationIsNeverAskedAgain() async {
        // 拒否されているとき、アプリからは出せない(画面の案内で iOS の設定アプリへ)
        let rig = makeRig(authorization: .denied)
        await rig.vm.load()
        await rig.vm.setStreakRiskEnabled(true)
        rig.vm.reminderTime = time(21, 0)
        await rig.vm.saveReminder()
        XCTAssertEqual(rig.authorizer.requestCount, 0)
        XCTAssertEqual(rig.vm.authorization, .denied)
    }

    // MARK: 要約(設定画面の行の右側)

    func testSummaryTextShowsTheCurrentReminderState() {
        XCTAssertEqual(ReminderPreference.daily(hour: 20, minute: 0).summaryText, "毎日 20:00")
        XCTAssertEqual(ReminderPreference.daily(hour: 7, minute: 5).summaryText, "毎日 07:05")
        XCTAssertEqual(ReminderPreference.off.summaryText, "オフ")
        XCTAssertNil(ReminderPreference.unknown.summaryText, "まだ知らないときは、何も出さない")
    }
}
