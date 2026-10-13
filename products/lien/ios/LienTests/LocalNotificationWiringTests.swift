// LocalNotificationWiringTests.swift — ローカル通知(T16 #16)を、アプリの各所からいつ呼ぶか(結線)
//
// 検証対象:
//   - AppModel: snapshot を読み直すたび(起動・前面復帰・同期・約束の保存)に予約を合わせる / 約束を保存したら、
//     その remind_at を先に覚えてから合わせる / 通知の設定画面の保存 / ホームの操作 / サインアウトで設定と予約を消す
//   - HomeViewModel: チェックイン・取り消しで端末の snapshot が変わったら知らせる(読み直しだけでは知らせない)
//   - 本物の ReminderScheduler と組み合わせて、自分のチェックインで今日のリマインドが取り消され、取り消しで戻る
//   - 通知を扱わない構成(store が無い)では何もしない

import XCTest
@testable import Lien

// MARK: - モック(トップレベル)

/// 呼び出しを順に記録する ReminderManaging
@MainActor
private final class RecordingReminders: ReminderManaging {
    private(set) var log: [String] = []
    var preferences = NotificationPreferences()

    var syncCount: Int { log.filter { $0 == "sync" }.count }
    var resetCount: Int { log.filter { $0 == "reset" }.count }

    func sync() async { log.append("sync") }

    func recordReminder(from promise: Promise) {
        log.append("record:\(promise.remindAt ?? "off")")
    }

    func setStreakRiskEnabled(_ enabled: Bool) async { log.append("streak:\(enabled)") }

    func reset() async { log.append("reset") }

    func authorizationStatus() async -> NotificationAuthorization { .authorized }
}

private final class WiringPushAuthorizer: PushAuthorizing {
    @discardableResult
    func requestAuthorization() async -> Bool { true }
}

/// チェックインと取り消しだけができるサービス(HomeViewModel の能力検出: CheckinCanceling)
private final class EchoCheckinService: CheckinPerforming, CheckinCanceling {
    func performCheckin(current: PairSnapshot) async throws -> PairSnapshot {
        var updated = current
        updated.todayMeDone = true
        return updated
    }

    func cancelCheckin(current: PairSnapshot) async throws -> PairSnapshot {
        var updated = current
        updated.todayMeDone = false
        return updated
    }
}

@MainActor
final class LocalNotificationWiringTests: XCTestCase {
    private typealias Clock = NotificationClock

    // MARK: AppModel

    private struct Harness {
        let model: AppModel
        let reminders: RecordingReminders
        let temp: TempStore
        let auth: StubAuthService
        let client: MockSnapshotClient
    }

    private func makeHarness(
        signedIn: Bool = true,
        local: PairSnapshot? = SnapshotFactory.paired(),
        server: Result<PairSnapshot, Error> = .success(SnapshotFactory.paired()),
        withReminders: Bool = true
    ) async throws -> Harness {
        let temp = TempStore()
        if let local { try temp.store.saveSnapshot(local) }
        let auth = StubAuthService()
        if signedIn { try await auth.signInAnonymously() }
        let client = MockSnapshotClient(result: server)
        let reminders = RecordingReminders()
        let services = AppServices(
            isLive: true,
            auth: auth,
            pushAuthorizer: WiringPushAuthorizer(),
            inviteClient: StubInviteClient(),
            promiseClient: StubPromiseAPIClient(),
            snapshotClient: client,
            checkinService: LocalEchoCheckinService(),
            nudgeService: nil,
            reactionService: nil,
            pendingOps: nil,
            store: temp.store,
            pushTokenSync: PushTokenSync(
                registrar: auth,
                currentUserID: { auth.currentUserID },
                environment: .sandbox,
                ledger: InMemoryPushRegistrationLedger()
            ),
            reloadWidgets: {},
            accountClient: StubAccountClient(store: temp.store),
            reminders: withReminders ? reminders : nil
        )
        return Harness(
            model: AppModel(services: services),
            reminders: reminders,
            temp: temp,
            auth: auth,
            client: client
        )
    }

    func testStartSyncsTheLocalNotificationsAfterReadingTheSnapshot() async throws {
        let h = try await makeHarness()
        defer { h.temp.cleanup() }
        XCTAssertEqual(h.reminders.syncCount, 0, "init では予約に触れない")

        await h.model.start()
        await waitUntil { h.reminders.syncCount >= 1 }

        XCTAssertGreaterThanOrEqual(h.reminders.syncCount, 1)
    }

    func testStartSyncsTheScheduleEvenBeforeAnythingIsReadFromTheServer() async throws {
        // 起動した時点で、端末にある snapshot で予約を合わせる(サーバーが遅くても・オフラインでも)。
        // サインアウトの途中で終了して、予約だけが残っていたときも、オンボーディングのまま起動した時点で片づく
        let h = try await makeHarness(signedIn: false, local: nil)
        defer { h.temp.cleanup() }
        XCTAssertEqual(h.model.phase, .onboarding)
        await h.model.start()
        await waitUntil { h.reminders.syncCount >= 1 }
        XCTAssertGreaterThanOrEqual(h.reminders.syncCount, 1)
        XCTAssertEqual(h.client.callCount, 0, "オンボーディングでは、サーバーとは同期しない")
    }

    func testForegroundSyncOfTheServerAlsoRefreshesTheSchedule() async throws {
        // オフラインで取得に失敗しても、端末の snapshot で予約を合わせ直す(日付が変わったあとの窓の更新)
        let h = try await makeHarness(server: .failure(SnapshotClientError.network))
        defer { h.temp.cleanup() }

        await h.model.refresh()
        await waitUntil { h.reminders.syncCount >= 1 }

        XCTAssertGreaterThanOrEqual(h.reminders.syncCount, 1)
    }

    func testSavingAPromiseRecordsItsRemindAtBeforeTheScheduleIsRefreshed() async throws {
        let h = try await makeHarness(local: SnapshotFactory.noPromise())
        defer { h.temp.cleanup() }
        let promise = Promise(id: "p-1", title: "筋トレ", emoji: "💪", remindAt: "21:15")

        h.model.promiseSaved(promise)
        await waitUntil { h.reminders.syncCount >= 1 }

        let firstRecord = h.reminders.log.firstIndex(of: "record:21:15")
        let firstSync = h.reminders.log.firstIndex(of: "sync")
        XCTAssertNotNil(firstRecord)
        XCTAssertNotNil(firstSync)
        if let firstRecord, let firstSync {
            XCTAssertLessThan(firstRecord, firstSync, "保存した時刻を覚えてから予約を合わせる(古い値や、サーバーの読み直しで合わせない)")
        }
    }

    func testSavingAPromiseWithoutRemindAtRecordsOff() async throws {
        let h = try await makeHarness()
        defer { h.temp.cleanup() }
        h.model.promiseSaved(Promise(id: "p-1", title: "筋トレ", emoji: "💪", remindAt: nil))
        XCTAssertTrue(h.reminders.log.contains("record:off"))
    }

    func testPromiseSavedWithoutAPromiseArgumentStillRefreshesTheSchedule() async throws {
        // 引数なしの呼び出し(既存の呼び出し元・テスト)は、リマインドの時刻を触らずに、予約だけを合わせる
        let h = try await makeHarness()
        defer { h.temp.cleanup() }
        h.model.promiseSaved()
        await waitUntil { h.reminders.syncCount >= 1 }
        XCTAssertFalse(h.reminders.log.contains { $0.hasPrefix("record:") })
    }

    func testReminderSavedFromTheSettingsScreenRecordsAndSyncs() async throws {
        let h = try await makeHarness()
        defer { h.temp.cleanup() }

        h.model.reminderSaved(Promise(id: "p-1", title: "筋トレ", emoji: "💪", remindAt: "06:30"))
        await waitUntil { h.reminders.syncCount >= 1 }

        XCTAssertEqual(Array(h.reminders.log.prefix(2)), ["record:06:30", "sync"])
    }

    func testLocalStateChangeFromTheHomeSyncsTheSchedule() async throws {
        let h = try await makeHarness()
        defer { h.temp.cleanup() }
        h.model.localStateChanged()
        await waitUntil { h.reminders.syncCount == 1 }
        XCTAssertEqual(h.reminders.syncCount, 1)
    }

    func testSigningOutClearsTheSettingsAndTheSchedule() async throws {
        let h = try await makeHarness()
        defer { h.temp.cleanup() }
        try h.temp.store.saveNotificationPreferences(NotificationPreferences(reminder: .off, streakRiskEnabled: false))

        await h.model.signOut()
        await waitUntil { h.reminders.syncCount >= 1 }

        XCTAssertEqual(h.reminders.resetCount, 1)
        XCTAssertNil(h.temp.store.loadSnapshot(), "端末の記録を消したあとで")
        XCTAssertNil(h.temp.store.loadNotificationPreferences(NotificationPreferences.self), "設定のファイルも消える")
        let lastReset = try XCTUnwrap(h.reminders.log.lastIndex(of: "reset"))
        let lastSync = try XCTUnwrap(h.reminders.log.lastIndex(of: "sync"))
        XCTAssertGreaterThan(lastSync, lastReset, "オンボーディングへ戻る再読み込みの同期は、消したあとに走る")
    }

    func testDeletingTheAccountAlsoClearsTheSchedule() async throws {
        let h = try await makeHarness()
        defer { h.temp.cleanup() }
        try await h.model.deleteAccount()
        XCTAssertEqual(h.reminders.resetCount, 1)
    }

    func testNothingHappensWithoutReminders() async throws {
        // 通知を扱わない構成(store が無いなど)でも、アプリは普段どおり動く
        let h = try await makeHarness(withReminders: false)
        defer { h.temp.cleanup() }
        await h.model.start()
        h.model.promiseSaved(Promise(id: "p-1", title: "筋トレ", emoji: "💪", remindAt: "20:00"))
        h.model.reminderSaved(Promise(id: "p-1", title: "筋トレ", emoji: "💪", remindAt: "20:00"))
        h.model.localStateChanged()
        await h.model.signOut()
        XCTAssertEqual(h.reminders.log, [])
        XCTAssertEqual(h.model.phase, .onboarding)
    }

    func testAppServicesBuildsRemindersOnlyWhenThereIsAStore() {
        XCTAssertNil(AppServices.makeReminders(store: nil, reminderLoader: nil))
        let temp = TempStore()
        defer { temp.cleanup() }
        XCTAssertNotNil(AppServices.makeReminders(store: temp.store, reminderLoader: nil))
    }

    // MARK: HomeViewModel

    private func makeHome(
        snapshot: PairSnapshot,
        notified: ReloadCounter
    ) throws -> (vm: HomeViewModel, temp: TempStore) {
        let temp = TempStore()
        try temp.store.saveSnapshot(snapshot)
        let vm = HomeViewModel(
            store: temp.store,
            checkinService: EchoCheckinService(),
            reloadWidgets: {},
            localStateChanged: { notified.value += 1 }
        )
        vm.load()
        return (vm, temp)
    }

    func testCheckinAndCancelTellTheScheduleSideButReloadingDoesNot() async throws {
        let notified = ReloadCounter()
        let (vm, temp) = try makeHome(snapshot: SnapshotFactory.paired(), notified: notified)
        defer { temp.cleanup() }
        XCTAssertEqual(notified.value, 0, "読み直し(load)では知らせない: 状態は変わっていない")

        await vm.performCheckin()
        XCTAssertEqual(notified.value, 1, "自分が完了した: 今日のリマインドを取り消してもらう")
        XCTAssertTrue(vm.snapshot?.todayMeDone == true)

        await vm.performCancel()
        XCTAssertEqual(notified.value, 2, "取り消した: 今日のリマインドを戻してもらう")
        XCTAssertTrue(vm.snapshot?.todayMeDone == false)

        vm.load()
        XCTAssertEqual(notified.value, 2)
    }

    func testAFailedCheckinDoesNotTellTheScheduleSide() async throws {
        // 失敗したときは snapshot が変わらない(楽観の反映もしない)ので、予約も触らない
        final class Failing: CheckinPerforming {
            func performCheckin(current: PairSnapshot) async throws -> PairSnapshot { throw URLError(.notConnectedToInternet) }
        }
        let notified = ReloadCounter()
        let temp = TempStore()
        defer { temp.cleanup() }
        try temp.store.saveSnapshot(SnapshotFactory.paired())
        let vm = HomeViewModel(
            store: temp.store, checkinService: Failing(), reloadWidgets: {}, localStateChanged: { notified.value += 1 }
        )
        vm.load()
        await vm.performCheckin()
        XCTAssertEqual(notified.value, 0)
    }

    // MARK: 本物の ReminderScheduler と組み合わせて

    func testCheckinCancelsTodaysReminderAndCancelingBringsItBack() async throws {
        let now = Clock.date(2026, 10, 14, 12, 0)
        let temp = TempStore()
        defer { temp.cleanup() }
        try temp.store.saveSnapshot(NotificationSnapshots.paired(updatedAt: now))
        let center = FakeNotificationCenter()
        let store = temp.store
        let scheduler = ReminderScheduler(
            center: center,
            preferences: InMemoryNotificationPreferencesStore(NotificationPreferences(reminder: .daily(hour: 20, minute: 0))),
            snapshotSource: { store.loadSnapshot() },
            now: { now },
            calendar: { Clock.calendar() }
        )
        let vm = HomeViewModel(
            store: temp.store,
            checkinService: EchoCheckinService(),
            now: { now },
            reloadWidgets: {},
            localStateChanged: { Task { await scheduler.sync() } }
        )
        vm.load()
        await scheduler.sync()
        XCTAssertTrue(center.ourPending.contains { $0.id == "lien.local.reminder.2026-10-14" })

        // 自分のチェックイン(EchoCheckinService は updatedAt を触らない = 今日のまま)
        await vm.performCheckin()
        await waitUntil { !center.ourPending.contains { $0.id == "lien.local.reminder.2026-10-14" } }
        XCTAssertFalse(center.ourPending.contains { $0.id == "lien.local.reminder.2026-10-14" }, "今日のリマインドは取り消される")
        XCTAssertTrue(center.ourPending.contains { $0.id == "lien.local.reminder.2026-10-15" }, "明日からは残る")

        await vm.performCancel()
        await waitUntil { center.ourPending.contains { $0.id == "lien.local.reminder.2026-10-14" } }
        XCTAssertTrue(center.ourPending.contains { $0.id == "lien.local.reminder.2026-10-14" }, "取り消すと、今日のリマインドが戻る")
    }
}
