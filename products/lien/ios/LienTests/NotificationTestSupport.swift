// NotificationTestSupport.swift — ローカル通知(T16 #16)のテストが共有する道具
//
//   - NotificationClock : 暦・タイムゾーンつきの日時の作り方(グレゴリオ暦に固定)
//   - NotificationSnapshots : リマインド・ストリーク危機の判断に効く項目だけを指定できる snapshot
//   - FakeNotificationCenter : 通知センターの偽物(予約・配信済みを覚え、呼び出しを記録する)

import Foundation
import XCTest
@testable import Lien

// MARK: - 日時

enum NotificationClock {
    static let tokyo = "Asia/Tokyo"
    static let losAngeles = "America/Los_Angeles"

    /// グレゴリオ暦+指定のタイムゾーン(本番の LocalNotificationCalendar.current() と同じ作り)
    static func calendar(_ timeZone: String = tokyo) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: timeZone)!
        return calendar
    }

    /// そのタイムゾーンの壁時計の日時
    static func date(
        _ year: Int, _ month: Int, _ day: Int,
        _ hour: Int = 0, _ minute: Int = 0, _ second: Int = 0,
        in timeZone: String = tokyo
    ) -> Date {
        let components = DateComponents(
            year: year, month: month, day: day, hour: hour, minute: minute, second: second
        )
        return calendar(timeZone).date(from: components)!
    }
}

// MARK: - snapshot

enum NotificationSnapshots {
    /// ペア成立中の snapshot(約束「筋トレ」💪・相手「ゆうき」)。リマインド・ストリーク危機の判断に効く項目を指定する
    static func paired(
        updatedAt: Date,
        meDone: Bool = false,
        partnerDone: Bool = false,
        streak: Int = 23,
        partnerName: String? = "ゆうき",
        title: String? = "筋トレ",
        emoji: String? = "💪"
    ) -> PairSnapshot {
        var snapshot = SnapshotFactory.paired(todayMeDone: meDone, todayPartnerDone: partnerDone, updatedAt: updatedAt)
        snapshot.streakCurrent = streak
        snapshot.partnerName = partnerName
        snapshot.myPromiseTitle = title
        snapshot.myPromiseEmoji = emoji
        return snapshot
    }

    /// 約束あり・ペアなし
    static func solo(updatedAt: Date, meDone: Bool = false) -> PairSnapshot {
        SnapshotFactory.solo(todayMeDone: meDone, updatedAt: updatedAt)
    }
}

// MARK: - 通知センターの偽物

/// 予約・配信済みを覚える通知センター。本番と同じく、同じ識別子の予約は置き換わる。
/// `gate` を渡すと、予約の一覧の読み出しがそこで止まる(同期の途中で状態を変えるテスト用)
final class FakeNotificationCenter: NotificationScheduling {
    /// 識別子 → 予約(このアプリのもの + ほかの通知)
    private(set) var pending: [String: PlannedNotification] = [:]
    private(set) var delivered: [String] = []
    var authorization: NotificationAuthorization = .authorized

    // 呼び出しの記録
    private(set) var scheduledIDs: [String] = []
    private(set) var removedPendingBatches: [[String]] = []
    private(set) var removedDeliveredBatches: [[String]] = []
    private(set) var pendingReads = 0

    var gate: AsyncGate?

    var scheduledCount: Int { scheduledIDs.count }
    var removedPendingIDs: [String] { removedPendingBatches.flatMap { $0 } }
    var removedDeliveredIDs: [String] { removedDeliveredBatches.flatMap { $0 } }

    /// このアプリのもの(識別子が lien.local. で始まる)だけの予約
    var ourPending: [PlannedNotification] {
        pending.values.filter { LocalNotificationID.isOurs($0.id) }.sorted { $0.id < $1.id }
    }

    /// 呼び出しの記録だけを消す(予約は残す)
    func resetLog() {
        scheduledIDs = []
        removedPendingBatches = []
        removedDeliveredBatches = []
        pendingReads = 0
    }

    /// このアプリ以外の通知(触られないことを確かめる)
    func addForeign(id: String) {
        pending[id] = PlannedNotification(
            id: id,
            fireAt: FireTime(year: 2026, month: 10, day: 20, hour: 9, minute: 0, timeZoneIdentifier: "Asia/Tokyo"),
            title: "other", body: "other"
        )
    }

    /// 通知センターに「出ている」ことにする
    func markDelivered(_ ids: [String]) {
        delivered.append(contentsOf: ids)
    }

    /// NSE が取り消せたことにする(アプリを通さずに予約を消す)
    func removePendingBehindTheAppsBack(ids: [String]) {
        for id in ids { pending[id] = nil }
    }

    // MARK: NotificationScheduling

    func pendingLocalNotifications() async -> [PlannedNotification] {
        pendingReads += 1
        if let gate { await gate.wait() }
        return ourPending
    }

    func deliveredLocalNotificationIDs() async -> [String] {
        delivered.filter(LocalNotificationID.isOurs)
    }

    func schedule(_ notification: PlannedNotification) async {
        scheduledIDs.append(notification.id)
        pending[notification.id] = notification
    }

    func removePending(ids: [String]) async {
        removedPendingBatches.append(ids)
        for id in ids { pending[id] = nil }
    }

    func removeDelivered(ids: [String]) async {
        removedDeliveredBatches.append(ids)
        delivered.removeAll { ids.contains($0) }
    }

    func authorizationStatus() async -> NotificationAuthorization {
        authorization
    }
}

// MARK: - ReminderScheduler のテスト用の組み立て

/// ReminderScheduler とその周辺(通知センターの偽物・設定のメモリ保存・snapshot・時計・タイムゾーン)。
/// ReminderScheduler の注入クロージャが、ここの状態を読む。テストは、この状態を書き換えて sync() を呼ぶ
@MainActor
final class SchedulerRig {
    var scheduler: ReminderScheduler!
    let center = FakeNotificationCenter()
    let store: InMemoryNotificationPreferencesStore
    var snapshot: PairSnapshot?
    var now: Date
    var timeZone: String
    var loaderCalls = 0
    var loaderResult: ReminderPreference?
    /// 読み込み(loader)の途中で止めるための門
    var loaderGate: AsyncGate?

    init(
        prefs: NotificationPreferences = NotificationPreferences(reminder: .daily(hour: 20, minute: 0)),
        snapshot: PairSnapshot?,
        now: Date,
        timeZone: String = NotificationClock.tokyo,
        withLoader: Bool = false
    ) {
        self.store = InMemoryNotificationPreferencesStore(prefs)
        self.snapshot = snapshot
        self.now = now
        self.timeZone = timeZone
        var loader: ReminderScheduler.ReminderLoader?
        if withLoader {
            loader = { [unowned self] in
                self.loaderCalls += 1
                if let gate = self.loaderGate { await gate.wait() }
                return self.loaderResult
            }
        }
        self.scheduler = ReminderScheduler(
            center: center,
            preferences: store,
            snapshotSource: { [unowned self] in self.snapshot },
            reminderLoader: loader,
            now: { [unowned self] in self.now },
            calendar: { [unowned self] in NotificationClock.calendar(self.timeZone) }
        )
    }

    func sync() async { await scheduler.sync() }

    var ids: [String] { center.ourPending.map(\.id) }
    var reminderIDs: [String] { center.ourPending.filter(\.isReminder).map(\.id) }
    var riskIDs: [String] { center.ourPending.filter(\.isStreakRisk).map(\.id) }
}

extension SchedulerRig {
    /// 日付 noon の時点で今日の snapshot(ペア成立・約束「筋トレ」💪・相手「ゆうき」・ストリーク 23)
    static func snapshot(
        at date: Date,
        meDone: Bool = false,
        partnerDone: Bool = false,
        title: String? = "筋トレ"
    ) -> PairSnapshot {
        NotificationSnapshots.paired(updatedAt: date, meDone: meDone, partnerDone: partnerDone, title: title)
    }
}
