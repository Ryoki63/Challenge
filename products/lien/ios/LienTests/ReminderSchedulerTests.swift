// ReminderSchedulerTests.swift — ローカル通知の予約の合わせ込み(ReminderScheduler。T16 #16)
//
// 検証対象(ReminderScheduler.swift):
//   - 予約中の通知を、計算した予約(desiredRequests)に合わせる: 足りないものを足し、要らないものを消し、同じ内容には触れない(何度でも同じ)
//   - 取り消し条件: 自分のチェックイン / チェックインの取り消し / ふたりそろった / 設定の変更 / 約束の変更 / ペアの解消 / サインアウト
//   - 通知センターに残っている古い通知(配信済み)を外す
//   - タイムゾーンが変わったら付け替える / 日付をまたいだ朝の窓の更新
//   (リマインドの時刻をまだ知らないとき・同期の畳み込み・許可・NSE が取り消せなかったときは ReminderSchedulerLearningTests)

import XCTest
@testable import Lien

@MainActor
final class ReminderSchedulerTests: XCTestCase {
    private typealias Clock = NotificationClock

    private let noon = NotificationClock.date(2026, 10, 14, 12, 0)

    private func freshSnapshot(
        at date: Date? = nil,
        meDone: Bool = false,
        partnerDone: Bool = false,
        title: String? = "筋トレ"
    ) -> PairSnapshot {
        NotificationSnapshots.paired(updatedAt: date ?? noon, meDone: meDone, partnerDone: partnerDone, title: title)
    }

    // MARK: - 基本

    func testFirstSyncSchedulesTheReminderWindowAndTonightsStreakRisk() async {
        let rig = SchedulerRig(snapshot: freshSnapshot(), now: noon)
        await rig.sync()

        XCTAssertEqual(rig.reminderIDs.count, 14)
        XCTAssertEqual(rig.riskIDs, ["lien.local.streak-risk.2026-10-14"])
        XCTAssertEqual(rig.center.scheduledCount, 15)
        XCTAssertEqual(rig.center.removedPendingIDs, [])
    }

    func testSyncingAgainWithTheSameStateTouchesNothing() async {
        let rig = SchedulerRig(snapshot: freshSnapshot(), now: noon)
        await rig.sync()
        rig.center.resetLog()

        await rig.sync()
        await rig.sync()

        XCTAssertEqual(rig.center.scheduledCount, 0, "内容が同じ予約は、置き直さない")
        XCTAssertEqual(rig.center.removedPendingIDs, [])
        XCTAssertEqual(rig.center.ourPending.count, 15)
    }

    func testOtherNotificationsAreNeverTouched() async {
        let rig = SchedulerRig(snapshot: freshSnapshot(), now: noon)
        rig.center.addForeign(id: "someone-else")
        await rig.sync()
        XCTAssertNotNil(rig.center.pending["someone-else"])
        XCTAssertFalse(rig.center.removedPendingIDs.contains("someone-else"))

        rig.snapshot = nil // サインアウト相当
        await rig.sync()
        XCTAssertNotNil(rig.center.pending["someone-else"], "このアプリのローカル通知だけを消す")
        XCTAssertEqual(rig.center.ourPending.count, 0)
    }

    // MARK: - 取り消し条件

    func testMyCheckinCancelsOnlyTodaysReminder() async {
        let rig = SchedulerRig(snapshot: freshSnapshot(), now: noon)
        await rig.sync()
        rig.center.resetLog()

        rig.snapshot = freshSnapshot(meDone: true)
        await rig.sync()

        XCTAssertEqual(rig.center.removedPendingIDs, ["lien.local.reminder.2026-10-14"])
        XCTAssertEqual(rig.reminderIDs.count, 13)
        XCTAssertEqual(rig.riskIDs, ["lien.local.streak-risk.2026-10-14"], "相手がまだ。ストリーク危機は残る")
        XCTAssertEqual(
            rig.center.scheduledIDs, ["lien.local.streak-risk.2026-10-14"],
            "残るストリーク危機は、「自分は済んだ」の言い方に置き換わる(それ以外には触らない)"
        )
        XCTAssertEqual(
            rig.center.pending["lien.local.streak-risk.2026-10-14"]?.body,
            Strings.LocalNotification.streakRiskMeDone(partnerName: "ゆうき", days: 23)
        )
    }

    func testCancelingTheCheckinPutsTodaysReminderBack() async {
        let rig = SchedulerRig(snapshot: freshSnapshot(meDone: true), now: noon)
        await rig.sync()
        XCTAssertEqual(rig.reminderIDs.count, 13)
        rig.center.resetLog()

        rig.snapshot = freshSnapshot(meDone: false)
        await rig.sync()

        XCTAssertEqual(
            Set(rig.center.scheduledIDs),
            ["lien.local.reminder.2026-10-14", "lien.local.streak-risk.2026-10-14"],
            "今日のリマインドが戻り、ストリーク危機の言い方も「どちらも未完」に戻る"
        )
        XCTAssertEqual(rig.center.removedPendingIDs, [])
        XCTAssertEqual(rig.reminderIDs.count, 14)
    }

    func testBothDoneCancelsTonightsRiskAndPlansTomorrows() async {
        let rig = SchedulerRig(snapshot: freshSnapshot(meDone: true), now: noon)
        await rig.sync()
        XCTAssertEqual(rig.riskIDs, ["lien.local.streak-risk.2026-10-14"])
        rig.center.resetLog()

        rig.snapshot = freshSnapshot(at: noon.addingTimeInterval(600), meDone: true, partnerDone: true)
        await rig.sync()

        XCTAssertEqual(rig.center.removedPendingIDs, ["lien.local.streak-risk.2026-10-14"])
        XCTAssertEqual(rig.center.scheduledIDs, ["lien.local.streak-risk.2026-10-15"], "記録は明日へ続く。明日の夜の分を用意する")
        XCTAssertEqual(rig.riskIDs, ["lien.local.streak-risk.2026-10-15"])
    }

    func testDissolvingThePairCancelsTheStreakRiskButKeepsTheReminders() async {
        let rig = SchedulerRig(snapshot: freshSnapshot(), now: noon)
        await rig.sync()

        rig.snapshot = NotificationSnapshots.solo(updatedAt: noon)
        await rig.sync()

        XCTAssertEqual(rig.riskIDs, [])
        XCTAssertEqual(rig.reminderIDs.count, 14, "自分の約束のリマインドは、ペアが無くても続く")
    }

    func testChangingThePromiseTitleReplacesTheBodiesOfEveryReminder() async {
        let rig = SchedulerRig(snapshot: freshSnapshot(), now: noon)
        await rig.sync()
        rig.center.resetLog()

        rig.snapshot = freshSnapshot(title: "読書")
        await rig.sync()

        XCTAssertEqual(rig.center.scheduledCount, 14, "14 日ぶんのリマインドの文言が付け替わる")
        XCTAssertTrue(rig.center.ourPending.filter(\.isReminder).allSatisfy { $0.body.contains("読書") })
        XCTAssertFalse(rig.center.ourPending.contains { $0.body.contains("筋トレ") && $0.isReminder })
        XCTAssertEqual(rig.center.ourPending.count, 15, "重複しない")
    }

    func testRemovingThePromiseCancelsEverything() async {
        let rig = SchedulerRig(snapshot: freshSnapshot(), now: noon)
        await rig.sync()
        rig.snapshot = NotificationSnapshots.paired(updatedAt: noon, title: nil)
        await rig.sync()
        XCTAssertEqual(rig.ids, [])
    }

    // MARK: - 設定の変更

    func testChangingTheRemindTimeReplacesTheWholeWindow() async {
        let rig = SchedulerRig(snapshot: freshSnapshot(), now: noon)
        await rig.sync()
        rig.center.resetLog()

        rig.scheduler.recordReminder(from: Promise(id: "p", title: "筋トレ", emoji: "💪", remindAt: "07:30"))
        await rig.sync()

        let reminders = rig.center.ourPending.filter(\.isReminder)
        XCTAssertEqual(reminders.count, 13, "今日の 7:30 は過ぎているので、明日からの 13 日ぶん")
        XCTAssertTrue(reminders.allSatisfy { $0.fireAt.hour == 7 && $0.fireAt.minute == 30 })
        XCTAssertEqual(rig.center.scheduledCount, 13)
        XCTAssertEqual(rig.center.removedPendingIDs, ["lien.local.reminder.2026-10-14"], "今日の 20:00 の分は消える")
        XCTAssertEqual(rig.reminderIDs.first, "lien.local.reminder.2026-10-15")
        XCTAssertEqual(rig.riskIDs.count, 1, "ストリーク危機は変わらない")
    }

    func testTurningTheReminderOffRemovesRemindersOnly() async {
        let rig = SchedulerRig(snapshot: freshSnapshot(), now: noon)
        await rig.sync()

        rig.scheduler.recordReminder(from: Promise(id: "p", title: "筋トレ", emoji: "💪", remindAt: nil))
        await rig.sync()

        XCTAssertEqual(rig.reminderIDs, [])
        XCTAssertEqual(rig.riskIDs.count, 1)
        XCTAssertEqual(rig.scheduler.preferences.reminder, .off)
    }

    func testTurningTheStreakRiskOffAndOnAgain() async {
        let rig = SchedulerRig(snapshot: freshSnapshot(), now: noon)
        await rig.sync()

        await rig.scheduler.setStreakRiskEnabled(false)
        XCTAssertEqual(rig.riskIDs, [])
        XCTAssertEqual(rig.reminderIDs.count, 14)
        XCTAssertFalse(rig.scheduler.preferences.streakRiskEnabled)
        XCTAssertFalse(rig.store.load().streakRiskEnabled, "設定は保存される")

        await rig.scheduler.setStreakRiskEnabled(true)
        XCTAssertEqual(rig.riskIDs, ["lien.local.streak-risk.2026-10-14"])
        XCTAssertTrue(rig.store.load().streakRiskEnabled)
    }

    func testRecordReminderStoresTheServerValueAndIgnoresOtherFields() {
        let rig = SchedulerRig(prefs: NotificationPreferences(reminder: .unknown, streakRiskEnabled: false), snapshot: nil, now: noon)
        rig.scheduler.recordReminder(from: Promise(id: "p", title: "x", emoji: "y", remindAt: "21:15"))
        XCTAssertEqual(rig.store.load(), NotificationPreferences(reminder: .daily(hour: 21, minute: 15), streakRiskEnabled: false))
    }

    // MARK: - 日付またぎ

    func testRollingOverToTheNextDayDropsYesterdayAndExtendsTheWindow() async {
        let rig = SchedulerRig(snapshot: freshSnapshot(), now: noon)
        await rig.sync()
        XCTAssertEqual(rig.reminderIDs.first, "lien.local.reminder.2026-10-14")

        // 翌日の朝(同期できて、snapshot も新しくなった)
        let nextMorning = Clock.date(2026, 10, 15, 8, 0)
        rig.now = nextMorning
        rig.snapshot = freshSnapshot(at: nextMorning)
        await rig.sync()

        XCTAssertEqual(rig.reminderIDs.count, 14)
        XCTAssertEqual(rig.reminderIDs.first, "lien.local.reminder.2026-10-15")
        XCTAssertEqual(rig.reminderIDs.last, "lien.local.reminder.2026-10-28", "窓が 1 日ぶん進んだ")
        XCTAssertEqual(rig.riskIDs, ["lien.local.streak-risk.2026-10-15"], "昨日の分は消え、今日の分が入る")
        XCTAssertTrue(rig.center.removedPendingIDs.contains("lien.local.reminder.2026-10-14"), "過ぎた日の予約は残さない")
    }

    func testOfflineMorningKeepsTonightsStreakRiskThatWasPlannedTheNightBefore() async {
        // 14 日の夜にふたりそろい、明日(15 日)の夜 9 時の分を予約した。15 日の朝、オフラインでアプリを開いた
        // (snapshot は昨日のまま)。同期しても、その予約を消さない
        let night = Clock.date(2026, 10, 14, 22, 0)
        let both = NotificationSnapshots.paired(updatedAt: night, meDone: true, partnerDone: true, streak: 24)
        let rig = SchedulerRig(snapshot: both, now: night)
        await rig.sync()
        XCTAssertEqual(rig.riskIDs, ["lien.local.streak-risk.2026-10-15"])
        rig.center.resetLog()

        rig.now = Clock.date(2026, 10, 15, 8, 0)
        await rig.sync()

        XCTAssertEqual(rig.riskIDs, ["lien.local.streak-risk.2026-10-15"])
        XCTAssertFalse(rig.center.removedPendingIDs.contains("lien.local.streak-risk.2026-10-15"), "付け替えもしない")
        XCTAssertEqual(rig.center.scheduledIDs, ["lien.local.reminder.2026-10-28"], "窓が 1 日ぶん進んだ分のリマインドだけを足す")
    }

    // MARK: - タイムゾーン

    func testChangingTheTimeZoneReplacesTheWholeWindow() async {
        // 東京の 14 日の朝 6 時 = ロサンゼルスの 13 日の午後 2 時(どちらも、今日の 20:00 はまだ先)
        let early = Clock.date(2026, 10, 14, 6, 0)
        let rig = SchedulerRig(snapshot: freshSnapshot(at: early), now: early)
        await rig.sync()
        XCTAssertTrue(rig.center.ourPending.allSatisfy { $0.fireAt.timeZoneIdentifier == "Asia/Tokyo" })
        rig.center.resetLog()

        // ロサンゼルスへ移動してアプリを開いた(同じ瞬間の、現地の壁時計で作り直す)
        rig.timeZone = Clock.losAngeles
        await rig.sync()

        XCTAssertTrue(rig.center.ourPending.allSatisfy { $0.fireAt.timeZoneIdentifier == "America/Los_Angeles" })
        XCTAssertEqual(rig.reminderIDs.count, 14)
        XCTAssertGreaterThan(rig.center.scheduledCount, 0, "タイムゾーンが違う予約は付け替わる")
    }

    func testAPendingRequestThatLostItsTimeZoneIsNotReplacedEveryTime() async {
        // OS が予約のタイムゾーンを覚えていなくても、同期のたびに付け替えない(タイムゾーンの無い予約は端末のタイムゾーンに追従する)
        let rig = SchedulerRig(snapshot: freshSnapshot(), now: noon)
        await rig.sync()
        let withoutZone = rig.center.ourPending.map { item in
            PlannedNotification(
                id: item.id,
                fireAt: FireTime(
                    year: item.fireAt.year, month: item.fireAt.month, day: item.fireAt.day,
                    hour: item.fireAt.hour, minute: item.fireAt.minute, timeZoneIdentifier: ""
                ),
                title: item.title, body: item.body
            )
        }
        for item in withoutZone { await rig.center.schedule(item) }
        rig.center.resetLog()

        await rig.sync()

        XCTAssertEqual(rig.center.scheduledCount, 0)
        XCTAssertEqual(rig.center.removedPendingIDs, [])
    }

    // MARK: - 配信済みの通知

    func testCompletingRemovesTheAlreadyDeliveredReminderFromTheNotificationCenter() async {
        let rig = SchedulerRig(snapshot: freshSnapshot(), now: noon)
        rig.center.markDelivered(["lien.local.reminder.2026-10-14", "lien.local.reminder.2026-10-13", "other"])

        rig.snapshot = freshSnapshot(meDone: true)
        await rig.sync()

        XCTAssertEqual(rig.center.removedDeliveredIDs, ["lien.local.reminder.2026-10-14"])
        XCTAssertEqual(rig.center.delivered, ["lien.local.reminder.2026-10-13", "other"], "昨日の分とほかの通知は残す")
    }

    func testBothDoneRemovesTheDeliveredStreakRisk() async {
        let rig = SchedulerRig(snapshot: freshSnapshot(meDone: true), now: noon)
        rig.center.markDelivered(["lien.local.streak-risk.2026-10-14"])

        rig.snapshot = freshSnapshot(meDone: true, partnerDone: true)
        await rig.sync()

        XCTAssertEqual(rig.center.removedDeliveredIDs, ["lien.local.streak-risk.2026-10-14"])
    }

    func testNothingIsRemovedFromTheNotificationCenterWhenNothingIsStale() async {
        let rig = SchedulerRig(snapshot: freshSnapshot(), now: noon)
        rig.center.markDelivered(["lien.local.reminder.2026-10-14"])
        await rig.sync()
        XCTAssertEqual(rig.center.removedDeliveredIDs, [])
    }

    func testSigningOutRemovesEverythingIncludingDeliveredNotifications() async {
        let rig = SchedulerRig(snapshot: freshSnapshot(), now: noon)
        await rig.sync()
        rig.center.markDelivered(["lien.local.reminder.2026-10-13", "lien.local.streak-risk.2026-10-13", "other"])

        rig.snapshot = nil
        await rig.scheduler.reset()

        XCTAssertEqual(rig.ids, [])
        XCTAssertEqual(rig.center.delivered, ["other"])
        XCTAssertEqual(rig.store.load(), NotificationPreferences(), "設定も消える(前のアカウントの設定を持ち越さない)")
    }
}
