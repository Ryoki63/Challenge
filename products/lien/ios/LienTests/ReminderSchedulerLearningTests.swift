// ReminderSchedulerLearningTests.swift — ReminderScheduler の、設定を知らない間の読み込み・同期の畳み込み・NSE が取り消せなかったとき(T16 #16)
//
// 検証対象(ReminderScheduler.swift):
//   - リマインドの時刻をまだ知らないとき、サーバーの約束から読む(同期の中では待たない / 読めなければ予約せず、間隔をあけて読み直す /
//     読んでいる間の約束の保存・サインアウトを優先する)
//   - 走行中に来た同期の要求を畳む
//   - OS の通知許可の状態の受け渡し(許可が無くても予約は合わせる)
//   - NSE が取り消せなかったときのふるまい(ふたりそろっていても予約が残る → 前面なら捨てる・次の同期で消える)
//   (予約の合わせ込みの基本は ReminderSchedulerTests)

import XCTest
@testable import Lien

@MainActor
final class ReminderSchedulerLearningTests: XCTestCase {
    private typealias Clock = NotificationClock

    private let noon = NotificationClock.date(2026, 10, 14, 12, 0)

    private func freshSnapshot(
        at date: Date? = nil,
        meDone: Bool = false,
        partnerDone: Bool = false,
        title: String? = "筋トレ"
    ) -> PairSnapshot {
        SchedulerRig.snapshot(at: date ?? noon, meDone: meDone, partnerDone: partnerDone, title: title)
    }

    // MARK: - リマインドの時刻をまだ知らないとき

    func testUnknownReminderIsLearnedFromTheServerPromiseOnceAndThenScheduled() async {
        let rig = SchedulerRig(prefs: NotificationPreferences(), snapshot: freshSnapshot(), now: noon, withLoader: true)
        rig.loaderResult = .daily(hour: 20, minute: 0)

        await rig.sync()
        await waitUntil { rig.reminderIDs.count == 14 } // 読み終わったら、もう一度同期して予約する

        XCTAssertEqual(rig.loaderCalls, 1)
        XCTAssertEqual(rig.store.load().reminder, .daily(hour: 20, minute: 0))
        XCTAssertEqual(rig.reminderIDs.count, 14)

        await rig.sync()
        XCTAssertEqual(rig.loaderCalls, 1, "知ったあとは読みに行かない")
    }

    func testUnknownReminderThatTheServerSaysIsOffSchedulesNoReminder() async {
        let rig = SchedulerRig(prefs: NotificationPreferences(), snapshot: freshSnapshot(), now: noon, withLoader: true)
        rig.loaderResult = .off
        await rig.sync()
        await waitUntil { rig.store.load().reminder == .off }
        await waitUntil { !rig.scheduler.isLearningReminder }
        XCTAssertEqual(rig.store.load().reminder, .off)
        XCTAssertEqual(rig.reminderIDs, [], "オフにした人に、リマインドを勝手に出さない")
        XCTAssertEqual(rig.riskIDs.count, 1)
    }

    func testReminderIsNotScheduledWhileTheServerCannotBeRead() async {
        let rig = SchedulerRig(prefs: NotificationPreferences(), snapshot: freshSnapshot(), now: noon, withLoader: true)
        rig.loaderResult = nil // 通信の失敗

        await rig.sync()
        await waitUntil { rig.loaderCalls == 1 && !rig.scheduler.isLearningReminder }
        XCTAssertEqual(rig.reminderIDs, [], "時刻が分からない間は予約しない")
        XCTAssertEqual(rig.store.load().reminder, .unknown)
        XCTAssertEqual(rig.loaderCalls, 1)
        XCTAssertEqual(rig.riskIDs.count, 1, "ストリーク危機はサーバーの約束を使わないので、予約できる")

        await rig.sync()
        XCTAssertEqual(rig.loaderCalls, 1, "失敗が続くとき、同期のたびに通信しない(間隔をあける)")

        rig.now = noon.addingTimeInterval(ReminderScheduler.loadRetryInterval + 1)
        rig.snapshot = freshSnapshot(at: rig.now)
        rig.loaderResult = .daily(hour: 20, minute: 0)
        await rig.sync()
        await waitUntil { rig.reminderIDs.count == 14 }
        XCTAssertEqual(rig.loaderCalls, 2, "間隔をあけて読み直す")
        XCTAssertEqual(rig.reminderIDs.count, 14)
    }

    func testTheSyncDoesNotWaitForTheServerRead() async {
        // 通信が詰まっていても、自分のチェックインによる取り消しやストリーク危機の予約は遅れない
        let rig = SchedulerRig(prefs: NotificationPreferences(), snapshot: freshSnapshot(), now: noon, withLoader: true)
        let gate = AsyncGate()
        rig.loaderGate = gate
        rig.loaderResult = .daily(hour: 20, minute: 0)

        await rig.sync() // 読み込みは止まったまま、同期は終わる
        XCTAssertTrue(rig.scheduler.isLearningReminder)
        XCTAssertEqual(rig.reminderIDs, [])
        XCTAssertEqual(rig.riskIDs.count, 1)

        rig.snapshot = freshSnapshot(meDone: true, partnerDone: true)
        await rig.sync() // まだ止まっている間も、同期は進む
        XCTAssertEqual(rig.riskIDs, ["lien.local.streak-risk.2026-10-15"])
        XCTAssertEqual(rig.loaderCalls, 1, "読み込みは重ねて始めない")

        gate.open()
        await waitUntil { rig.reminderIDs.count == 13 }
        XCTAssertEqual(rig.reminderIDs.count, 13, "読めたら予約される(今日の分は、完了済みなので除く)")
        XCTAssertFalse(rig.scheduler.isLearningReminder)
    }

    func testTheServerIsNotAskedWithoutAPromise() async {
        let rig = SchedulerRig(
            prefs: NotificationPreferences(), snapshot: SnapshotFactory.noPromise(updatedAt: noon), now: noon, withLoader: true
        )
        await rig.sync()
        XCTAssertEqual(rig.loaderCalls, 0, "約束が無い間は、読むものが無い")
        rig.snapshot = nil
        await rig.sync()
        XCTAssertEqual(rig.loaderCalls, 0)
    }

    func testAPromiseSavedWhileTheServerIsBeingReadWins() async {
        // 読んでいる最中に、約束を保存した(新しい時刻が入った)。古い読み取りの結果で上書きしない
        let rig = SchedulerRig(prefs: NotificationPreferences(), snapshot: freshSnapshot(), now: noon, withLoader: true)
        let gate = AsyncGate()
        rig.loaderGate = gate
        rig.loaderResult = .daily(hour: 20, minute: 0)

        await rig.sync()
        await waitUntil { rig.loaderCalls == 1 }
        rig.scheduler.recordReminder(from: Promise(id: "p", title: "筋トレ", emoji: "💪", remindAt: "06:00"))
        gate.open()
        await waitUntil { !rig.scheduler.isLearningReminder }

        XCTAssertEqual(rig.store.load().reminder, .daily(hour: 6, minute: 0))
    }

    func testSigningOutWhileTheServerIsBeingReadDiscardsTheResult() async {
        // 読んでいる最中にサインアウトした。前のアカウントの約束の結果を、設定に入れない
        let rig = SchedulerRig(prefs: NotificationPreferences(), snapshot: freshSnapshot(), now: noon, withLoader: true)
        let gate = AsyncGate()
        rig.loaderGate = gate
        rig.loaderResult = .daily(hour: 20, minute: 0)

        await rig.sync()
        await waitUntil { rig.loaderCalls == 1 }
        rig.snapshot = nil
        await rig.scheduler.reset()
        XCTAssertFalse(rig.scheduler.isLearningReminder)

        gate.open()
        await Task.yield()
        await Task.yield()

        XCTAssertEqual(rig.store.load().reminder, .unknown, "前のアカウントの約束の時刻が、あとから設定に入らない")
        XCTAssertEqual(rig.ids, [])
    }

    func testNoLoaderMeansUnknownStaysUnknown() async {
        let rig = SchedulerRig(prefs: NotificationPreferences(), snapshot: freshSnapshot(), now: noon, withLoader: false)
        await rig.sync()
        XCTAssertEqual(rig.reminderIDs, [])
        XCTAssertEqual(rig.store.load().reminder, .unknown)
        XCTAssertFalse(rig.scheduler.isLearningReminder)
    }

    // MARK: - 同期の畳み込み

    func testASyncRequestedWhileOneIsRunningRunsOnceMoreAfterwards() async {
        let rig = SchedulerRig(snapshot: freshSnapshot(), now: noon)
        let gate = AsyncGate()
        rig.center.gate = gate

        let first = Task { @MainActor in await rig.sync() }
        await waitUntil { rig.center.pendingReads == 1 } // 1 本目は、予約の読み出しで止まっている

        // 止まっている間に、自分がチェックインした。2 本目の要求は、1 本目の終わりに 1 回だけ取り直される
        rig.snapshot = freshSnapshot(meDone: true)
        let second = Task { @MainActor in await rig.sync() }
        let third = Task { @MainActor in await rig.sync() }
        await Task.yield()

        rig.center.gate = nil
        gate.open()
        await first.value
        await second.value
        await third.value

        XCTAssertEqual(rig.center.pendingReads, 2, "走行中の要求は何回来ても、取り直しは 1 回")
        XCTAssertFalse(rig.reminderIDs.contains("lien.local.reminder.2026-10-14"), "取り直しで、最新の状態に合っている")
        XCTAssertEqual(rig.reminderIDs.count, 13)
    }

    // MARK: - 許可

    func testAuthorizationStatusComesFromTheNotificationCenter() async {
        let rig = SchedulerRig(snapshot: freshSnapshot(), now: noon)
        for status in [NotificationAuthorization.notDetermined, .denied, .authorized] {
            rig.center.authorization = status
            let current = await rig.scheduler.authorizationStatus()
            XCTAssertEqual(current, status)
        }
    }

    func testSchedulingDoesNotDependOnTheAuthorizationStatus() async {
        // 許可がまだ・拒否のときも、予約は合わせておく(あとで許可されたとき、そのまま届く)
        let rig = SchedulerRig(snapshot: freshSnapshot(), now: noon)
        rig.center.authorization = .denied
        await rig.sync()
        XCTAssertEqual(rig.center.ourPending.count, 15)
    }

    // MARK: - NSE が取り消せなかったとき

    func testWhenTheNSECannotCancelTheStreakRiskStaysUntilTheNextSync() async {
        // 夜 9 時の予約がある。相手のチェックインの push で、ふたりそろった。NSE は今日の分を取り消そうとするが、
        // 本体の予約を消せなかった(実機では未確認 — ReminderScheduler のコメント)
        let rig = SchedulerRig(snapshot: freshSnapshot(meDone: true), now: noon)
        await rig.sync()
        XCTAssertEqual(rig.riskIDs, ["lien.local.streak-risk.2026-10-14"])

        // NSE が受けた snapshot = ふたりそろった。端末の snapshot に書かれるが、アプリは同期していない(予約はそのまま)
        let both = freshSnapshot(at: noon.addingTimeInterval(1800), meDone: true, partnerDone: true)
        rig.snapshot = both
        XCTAssertEqual(rig.riskIDs, ["lien.local.streak-risk.2026-10-14"], "取り消せなかった間は、予約が残る(夜 9 時にそのまま届く)")

        // 前面にいるときに届いたら、出さずに捨てる
        XCTAssertTrue(LocalNotificationCancellation.shouldSuppress(
            identifier: "lien.local.streak-risk.2026-10-14",
            snapshot: both,
            now: noon.addingTimeInterval(9 * 3600),
            calendar: Clock.calendar()
        ))

        // 次にアプリを開いたとき(同期)に消える
        rig.center.markDelivered(["lien.local.streak-risk.2026-10-14"])
        await rig.sync()
        XCTAssertEqual(rig.riskIDs, ["lien.local.streak-risk.2026-10-15"], "今日の分は消え、明日の分が入る")
        XCTAssertEqual(rig.center.delivered, [], "届いてしまっていた通知も、通知センターから外す")
    }

    func testWhenTheNSECanCancelTheNextSyncHasNothingLeftToRemove() async {
        let rig = SchedulerRig(snapshot: freshSnapshot(meDone: true), now: noon)
        await rig.sync()

        // NSE が今日の分を取り消せた(本体の予約を直接消した)
        let ids = LocalNotificationCancellation.staleIDsForToday(
            snapshot: freshSnapshot(at: noon.addingTimeInterval(1800), meDone: true, partnerDone: true),
            now: noon.addingTimeInterval(1800),
            calendar: Clock.calendar()
        )
        XCTAssertEqual(Set(ids), ["lien.local.reminder.2026-10-14", "lien.local.streak-risk.2026-10-14"])
        rig.center.removePendingBehindTheAppsBack(ids: ids)
        XCTAssertEqual(rig.riskIDs, [])
        rig.center.resetLog()

        rig.snapshot = freshSnapshot(at: noon.addingTimeInterval(1800), meDone: true, partnerDone: true)
        await rig.sync()

        XCTAssertEqual(rig.center.removedPendingIDs, [], "すでに無い予約は消さない")
        XCTAssertEqual(rig.riskIDs, ["lien.local.streak-risk.2026-10-15"], "明日の分だけ足される")
    }

    func testTheStreakRiskWordingIsHarmlessEvenIfItArrivesAfterBothAreDone() {
        // 取り消せなかった通知が、ふたりそろったあとに届いても、読んで困らない(責めない・急かさない・事実と食い違わない)
        let bodies = [
            Strings.LocalNotification.streakRiskNeither(days: 23),
            Strings.LocalNotification.streakRiskPartnerDone(partnerName: "ゆうき", days: 23),
            Strings.LocalNotification.streakRiskMeDone(partnerName: "ゆうき", days: 23),
        ]
        for body in bodies {
            XCTAssertEqual(PunishmentFreeLint.violations(in: body), [], body)
            XCTAssertFalse(body.contains("失"), "記録を失う言い方をしない: \(body)")
            XCTAssertFalse(body.contains("途切"), "途切れる言い方をしない: \(body)")
            XCTAssertFalse(body.contains("切れ"), "切れる言い方をしない: \(body)")
            XCTAssertFalse(body.contains("懸"), "プレッシャーをかけない: \(body)")
        }
    }
}
