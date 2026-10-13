// LocalNotificationPushSyncTests.swift — 相手の push を受けた NSE が、端末のローカル通知を合わせる(T16 #16。Opus レビューの must_fix)
//
// 夜 9 時のストリーク危機は、「アプリを開くのを忘れた日」のための通知。アプリの同期の中でしか予約できないと、
//   ①前の日に先にチェックインして、相手のあとにアプリを開かなかった人 ②お休みチケットで守られた翌日の人は、その日の分が無い。
// そこで NSE が、受けた snapshot ごとに、アプリの同期と同じ計画(StreakRiskPlan)で予約を合わせる(足りなければ足し、古ければ消す)。
//
// 検証対象(LocalNotificationPushSync.swift。NSE の NotificationService が呼ぶ。通知センターは偽物):
//   - 「A が先・B があと」→ 明日の 21:00 が、アプリを開かなくても入る
//   - お休みチケットで守られた翌日(ticket_used の push)→ その日の 21:00 が入る
//   - ストリークが途切れた(streak_reset の push)→ 残っている分が消える
//   - 相手が先に済ませた → 今日の分が「相手は済み」の言い方に置き換わる(消さずに置き換える)
//   - 自分が済み → 今日のリマインドを取り消す(ほかの日のリマインド・ほかの通知には触れない)
//   - 日付が変わって 1:00 までに作られた snapshot の完了は、前の日のことかもしれない(読み違えて取り消さない)
//   - アプリの同期と NSE は、どんな snapshot からでも、同じストリーク危機の予約に行き着く

import XCTest
@testable import Lien

@MainActor
final class LocalNotificationPushSyncTests: XCTestCase {
    private typealias Clock = NotificationClock

    private let defaults = NotificationPreferences(reminder: .daily(hour: 20, minute: 0), streakRiskEnabled: true)

    private func align(
        _ center: FakeNotificationCenter,
        _ snapshot: PairSnapshot,
        now: Date,
        prefs: NotificationPreferences? = nil
    ) async {
        await LocalNotificationPushSync.align(
            center: center,
            prefs: prefs ?? defaults,
            snapshot: snapshot,
            now: now,
            calendar: Clock.calendar()
        )
    }

    private func risk(_ day: String) -> String {
        "lien.local.streak-risk.\(day)"
    }

    private func reminder(_ day: String) -> String {
        "lien.local.reminder.\(day)"
    }

    // MARK: - 前の日に先にチェックインして、相手のあとにアプリを開かなかった

    func testPartnerFinishingAfterMeKeepsTheChainGoingWithoutOpeningTheApp() async throws {
        // 14 日の昼、自分がチェックインした(アプリを開いた)。夜 9 時の分は「自分は済み」
        let noon = Clock.date(2026, 10, 14, 12, 0)
        let rig = SchedulerRig(snapshot: SchedulerRig.snapshot(at: noon, meDone: true), now: noon)
        await rig.sync()
        XCTAssertEqual(rig.riskIDs, [risk("2026-10-14")])
        XCTAssertEqual(rig.reminderIDs.count, 13, "今日の分は済んだので、明日からの 13 日ぶん")

        // 18:00 に相手がチェックインした。相手の push を NSE が受ける(アプリは開かない)
        let evening = Clock.date(2026, 10, 14, 18, 0)
        let both = NotificationSnapshots.paired(updatedAt: evening, meDone: true, partnerDone: true, streak: 24)
        await align(rig.center, both, now: evening)

        XCTAssertEqual(rig.riskIDs, [risk("2026-10-15")], "今日の分は消え、明日の夜 9 時の分が入る(アプリを開かなくても)")
        let tomorrow = try XCTUnwrap(rig.center.pending[risk("2026-10-15")])
        XCTAssertEqual(
            tomorrow.fireAt,
            FireTime(year: 2026, month: 10, day: 15, hour: 21, minute: 0, timeZoneIdentifier: "Asia/Tokyo")
        )
        XCTAssertEqual(tomorrow.title, Strings.LocalNotification.title)
        XCTAssertEqual(tomorrow.body, Strings.LocalNotification.streakRiskNeither(days: 24), "明日の状態は分からない: どちらも未完の言い方")
        XCTAssertEqual(rig.reminderIDs.count, 13, "リマインドの窓には触れない")

        // 15 日はアプリを開かないまま夜 9 時を迎える。その予約は残っている = A の端末に「忘れた日」の通知が届く
        XCTAssertNotNil(rig.center.pending[risk("2026-10-15")])

        // 次にアプリを開いたとき(同じ snapshot で同期)も、NSE の予約は付け替えない
        rig.center.resetLog()
        rig.snapshot = both
        rig.now = Clock.date(2026, 10, 15, 8, 0)
        await rig.sync()
        XCTAssertEqual(rig.riskIDs, [risk("2026-10-15")])
        XCTAssertFalse(rig.center.scheduledIDs.contains(risk("2026-10-15")), "アプリの計画と NSE の計画が同じなので、触らない")
        XCTAssertFalse(rig.center.removedPendingIDs.contains(risk("2026-10-15")))
    }

    // MARK: - お休みチケットで守られた翌日

    func testTicketUsedPushAtMidnightPlantsThatDaysStreakRiskWithoutOpeningTheApp() async throws {
        // 13 日の夜 9 時の分は届いた(もう予約に無い)。14 日 0:10 に close-day が、チケットを使って記録を守った(ticket_used の push)。
        // この snapshot は両者とも「今日はまだ」で、ストリークは続いている
        let center = FakeNotificationCenter()
        let midnight = Clock.date(2026, 10, 14, 0, 10)
        let ticketUsed = NotificationSnapshots.paired(updatedAt: midnight, streak: 23)

        await align(center, ticketUsed, now: midnight)

        XCTAssertEqual(center.ourPending.map(\.id), [risk("2026-10-14")], "その日の夜 9 時の分が入る")
        let planted = try XCTUnwrap(center.pending[risk("2026-10-14")])
        XCTAssertEqual(
            planted.fireAt,
            FireTime(year: 2026, month: 10, day: 14, hour: 21, minute: 0, timeZoneIdentifier: "Asia/Tokyo")
        )
        XCTAssertEqual(planted.body, Strings.LocalNotification.streakRiskNeither(days: 23))
    }

    func testTicketUsedPushPlantsNothingWhenTheStreakRiskIsSwitchedOff() async {
        let center = FakeNotificationCenter()
        let midnight = Clock.date(2026, 10, 14, 0, 10)
        let off = NotificationPreferences(reminder: .daily(hour: 20, minute: 0), streakRiskEnabled: false)
        await align(center, NotificationSnapshots.paired(updatedAt: midnight, streak: 23), now: midnight, prefs: off)
        XCTAssertEqual(center.ourPending, [], "オフにした人の端末に、NSE が勝手に足さない")
    }

    // MARK: - ストリークが途切れた

    func testStreakResetPushRemovesWhateverStreakRiskIsLeft() async {
        // 13 日の夜、ふたりそろった。14 日(明日)の夜 9 時の分が入っている
        let night = Clock.date(2026, 10, 13, 22, 0)
        let both = NotificationSnapshots.paired(updatedAt: night, meDone: true, partnerDone: true, streak: 24)
        let rig = SchedulerRig(snapshot: both, now: night)
        await rig.sync()
        XCTAssertEqual(rig.riskIDs, [risk("2026-10-14")])

        // 14 日は誰もチェックインせず、15 日 0:10 にストリークが途切れた(チケットなし → streak_reset の push。ストリーク 0)
        let reset = NotificationSnapshots.paired(updatedAt: Clock.date(2026, 10, 15, 0, 10), streak: 0)
        // (14 日の夜 9 時の分が、もし届かずに残っていても)古い日数の通知を、これ以上届けない
        await rig.center.schedule(PlannedNotification(
            id: risk("2026-10-16"),
            fireAt: FireTime(year: 2026, month: 10, day: 16, hour: 21, minute: 0, timeZoneIdentifier: "Asia/Tokyo"),
            title: "Lien", body: Strings.LocalNotification.streakRiskNeither(days: 24)
        ))
        await align(rig.center, reset, now: Clock.date(2026, 10, 15, 0, 10))

        XCTAssertEqual(rig.riskIDs, [], "ストリークが 0 なら、残っているストリーク危機はすべて消える")
        XCTAssertGreaterThan(rig.reminderIDs.count, 0, "リマインドは続く")
    }

    // MARK: - 相手が先に済ませた

    func testPartnerFinishingFirstReplacesTodaysWordingWithoutRemovingTheReservation() async throws {
        let rig = SchedulerRig(snapshot: SchedulerRig.snapshot(at: Clock.date(2026, 10, 14, 12, 0)), now: Clock.date(2026, 10, 14, 12, 0))
        await rig.sync()
        XCTAssertEqual(rig.center.pending[risk("2026-10-14")]?.body, Strings.LocalNotification.streakRiskNeither(days: 23))
        rig.center.resetLog()

        // 相手が先にチェックインした(自分はまだ)。NSE が受けた
        let afternoon = Clock.date(2026, 10, 14, 15, 0)
        await align(rig.center, NotificationSnapshots.paired(updatedAt: afternoon, partnerDone: true), now: afternoon)

        XCTAssertEqual(
            rig.center.pending[risk("2026-10-14")]?.body,
            Strings.LocalNotification.streakRiskPartnerDone(partnerName: "ゆうき", days: 23)
        )
        XCTAssertEqual(rig.center.scheduledIDs, [risk("2026-10-14")], "置き換える")
        XCTAssertEqual(
            rig.center.removedPendingIDs, [],
            "同じ識別子を消してすぐ置き直さない(遅れた削除が新しい予約を消すおそれがある — NotificationReconciler)"
        )
        XCTAssertEqual(rig.reminderIDs.count, 14, "自分はまだなので、今日のリマインドも残る")
    }

    // MARK: - 自分が済んでいる・ふたりそろった

    func testBothDoneCancelsTodaysReminderAndTonightsRiskAndRemovesTheDeliveredOnes() async {
        let noon = Clock.date(2026, 10, 14, 12, 0)
        let rig = SchedulerRig(snapshot: SchedulerRig.snapshot(at: noon), now: noon)
        await rig.sync()
        XCTAssertTrue(rig.ids.contains(reminder("2026-10-14")))
        XCTAssertTrue(rig.ids.contains(risk("2026-10-14")))
        rig.center.markDelivered([reminder("2026-10-14"), risk("2026-10-14"), reminder("2026-10-13"), "other"])
        rig.center.addForeign(id: "someone-else")

        let afternoon = Clock.date(2026, 10, 14, 16, 0)
        await align(
            rig.center,
            NotificationSnapshots.paired(updatedAt: afternoon, meDone: true, partnerDone: true, streak: 24),
            now: afternoon
        )

        XCTAssertFalse(rig.ids.contains(reminder("2026-10-14")), "自分が済んだので、今日のリマインドは要らない")
        XCTAssertFalse(rig.ids.contains(risk("2026-10-14")))
        XCTAssertTrue(rig.ids.contains(risk("2026-10-15")), "明日の分は入る")
        XCTAssertTrue(rig.ids.contains(reminder("2026-10-15")), "明日からのリマインドは残る")
        XCTAssertEqual(rig.reminderIDs.count, 13)
        XCTAssertEqual(
            rig.center.delivered, [reminder("2026-10-13"), "other"],
            "届いてしまった今日の分は通知センターから外す。昨日の分とほかの通知は残す"
        )
        XCTAssertNotNil(rig.center.pending["someone-else"], "このアプリのローカル通知以外には触れない")
    }

    func testOnlyMeDoneCancelsOnlyTodaysReminderAndKeepsTheStreakRisk() async {
        let noon = Clock.date(2026, 10, 14, 12, 0)
        let rig = SchedulerRig(snapshot: SchedulerRig.snapshot(at: noon), now: noon)
        await rig.sync()
        rig.center.resetLog()

        // 自分が済んだことを、受けた push の snapshot が運んでいた(たとえば、自分のチェックインへの相手のリアクション)
        let afternoon = Clock.date(2026, 10, 14, 16, 0)
        await align(rig.center, NotificationSnapshots.paired(updatedAt: afternoon, meDone: true), now: afternoon)

        XCTAssertFalse(rig.ids.contains(reminder("2026-10-14")))
        XCTAssertEqual(rig.center.removedPendingIDs, [reminder("2026-10-14")])
        XCTAssertEqual(rig.riskIDs, [risk("2026-10-14")], "相手がまだなので、夜 9 時の分は残る")
        XCTAssertEqual(
            rig.center.pending[risk("2026-10-14")]?.body,
            Strings.LocalNotification.streakRiskMeDone(partnerName: "ゆうき", days: 23),
            "言い方は「自分は済み」に置き換わる"
        )
    }

    func testNSEDoesNotPlantReminders() async {
        // リマインドの 14 日ぶんは、アプリの同期だけが予約する(NSE は今日の分を取り消すだけ)
        let center = FakeNotificationCenter()
        let noon = Clock.date(2026, 10, 14, 12, 0)
        await align(center, NotificationSnapshots.paired(updatedAt: noon), now: noon)
        XCTAssertEqual(center.ourPending.map(\.id), [risk("2026-10-14")])
        XCTAssertEqual(center.ourPending.filter(\.isReminder), [])
    }

    // MARK: - 日付が変わって間もない snapshot

    func testASnapshotBuiltRightAfterMidnightDoesNotCancelTodaysReminderOrMoveTheRiskToTomorrow() async {
        // 14 日(昨日)、自分は済ませた。相手が 23:58 に圏外で押したチェックインが、15 日 0:20 に届いた。サーバーはクライアントが
        // 送った日付(14 日)を「今日」として snapshot を作る → ふたりそろった(14 日の分)。updatedAt は 15 日の 0:20
        let noon = Clock.date(2026, 10, 15, 0, 5)
        let rig = SchedulerRig(snapshot: SchedulerRig.snapshot(at: Clock.date(2026, 10, 14, 22, 0), meDone: true, partnerDone: false), now: noon)
        await rig.sync()
        XCTAssertTrue(rig.ids.contains(reminder("2026-10-15")), "15 日のリマインドは入っている")
        XCTAssertEqual(rig.riskIDs, [], "snapshot は昨日のもので、昨日はふたりそろっていない: 記録が続いているか分からないので、まだ入れない")

        let arrival = Clock.date(2026, 10, 15, 0, 20)
        let queuedFromYesterday = NotificationSnapshots.paired(updatedAt: arrival, meDone: true, partnerDone: true, streak: 24)
        await align(rig.center, queuedFromYesterday, now: arrival)

        XCTAssertTrue(rig.ids.contains(reminder("2026-10-15")), "昨日の完了を今日の完了と読んで、今日のリマインドを取り消さない")
        XCTAssertEqual(rig.riskIDs, [risk("2026-10-15")], "15 日の夜 9 時の分は、16 日に回さない(完了が分からないので、どちらも未完の言い方で今日)")
        XCTAssertEqual(
            rig.center.pending[risk("2026-10-15")]?.body,
            Strings.LocalNotification.streakRiskNeither(days: 24)
        )
    }

    // MARK: - 何もしない・触れない

    func testAligningTwiceWithTheSameSnapshotTouchesNothingTheSecondTime() async {
        let center = FakeNotificationCenter()
        let noon = Clock.date(2026, 10, 14, 12, 0)
        let snapshot = NotificationSnapshots.paired(updatedAt: noon, meDone: true, partnerDone: true, streak: 24)
        await align(center, snapshot, now: noon)
        center.resetLog()

        await align(center, snapshot, now: noon)

        XCTAssertEqual(center.scheduledIDs, [])
        XCTAssertEqual(center.removedPendingIDs, [])
        XCTAssertEqual(center.removedDeliveredIDs, [])
    }

    func testNoPairOrNoStreakOrNoPromiseClearsTheStreakRiskAndPlantsNothing() async {
        let noon = Clock.date(2026, 10, 14, 12, 0)
        var solo = NotificationSnapshots.paired(updatedAt: noon)
        solo.pairId = nil
        let snapshots: [(String, PairSnapshot)] = [
            ("ペアが解消された", solo),
            ("ストリークが 0", NotificationSnapshots.paired(updatedAt: noon, streak: 0)),
            ("約束が無い", NotificationSnapshots.paired(updatedAt: noon, title: nil)),
        ]
        for (label, snapshot) in snapshots {
            let center = FakeNotificationCenter()
            await center.schedule(PlannedNotification(
                id: risk("2026-10-14"),
                fireAt: FireTime(year: 2026, month: 10, day: 14, hour: 21, minute: 0, timeZoneIdentifier: "Asia/Tokyo"),
                title: "Lien", body: Strings.LocalNotification.streakRiskNeither(days: 23)
            ))
            await align(center, snapshot, now: noon)
            XCTAssertEqual(center.ourPending.filter(\.isStreakRisk), [], label)
        }
    }

    func testTurningTheStreakRiskOffRemovesWhatWasPlanned() async {
        let center = FakeNotificationCenter()
        let noon = Clock.date(2026, 10, 14, 12, 0)
        let snapshot = NotificationSnapshots.paired(updatedAt: noon)
        await align(center, snapshot, now: noon)
        XCTAssertEqual(center.ourPending.count, 1)

        let off = NotificationPreferences(reminder: .daily(hour: 20, minute: 0), streakRiskEnabled: false)
        await align(center, snapshot, now: noon, prefs: off)
        XCTAssertEqual(center.ourPending, [])
    }

    func testAfterNineTheTodaysStreakRiskIsNotPlantedButTomorrowsIs() async {
        let center = FakeNotificationCenter()
        let late = Clock.date(2026, 10, 14, 21, 30)
        await align(center, NotificationSnapshots.paired(updatedAt: late), now: late)
        XCTAssertEqual(center.ourPending, [], "夜 9 時を過ぎた。今日の分は出せず、明日の分も(今日ふたりそろっていないので)入れない")

        let bothLate = NotificationSnapshots.paired(updatedAt: late, meDone: true, partnerDone: true, streak: 24)
        await align(center, bothLate, now: late)
        XCTAssertEqual(center.ourPending.map(\.id), [risk("2026-10-15")])
    }

    func testAlignEndsByReadingThePendingListAgainSoTheRequestsHaveReachedTheSystem() async {
        let center = FakeNotificationCenter()
        let noon = Clock.date(2026, 10, 14, 12, 0)
        await align(center, NotificationSnapshots.paired(updatedAt: noon, meDone: true, partnerDone: true), now: noon)
        XCTAssertEqual(center.callLog.last, "read", "取り消しと追加のあと、最後に一覧を読み直す(その応答が返れば、それ以前の要求は届いている)")
        XCTAssertTrue(center.callLog.contains("schedule"))
    }

    // MARK: - アプリの同期と NSE は、同じ snapshot から同じ答えを出す

    func testTheAppAndTheNSEReachTheSameStreakRiskForEverySnapshot() async {
        let calendar = Clock.calendar()
        let nows = [
            Clock.date(2026, 10, 14, 0, 30), Clock.date(2026, 10, 14, 6, 0), Clock.date(2026, 10, 14, 20, 30),
            Clock.date(2026, 10, 14, 21, 30), Clock.date(2026, 10, 15, 8, 0),
        ]
        let updatedAts = [
            Clock.date(2026, 10, 14, 0, 10), // 日付が変わって 1:00 までに作られた
            Clock.date(2026, 10, 14, 9, 0), Clock.date(2026, 10, 14, 21, 30),
            Clock.date(2026, 10, 13, 0, 30), Clock.date(2026, 10, 13, 22, 0), Clock.date(2026, 10, 12, 22, 0),
            Clock.date(2026, 10, 15, 9, 0), // 時計がずれている(先の日付)
        ]
        let leftovers = ["2026-10-13", "2026-10-14", "2026-10-15", "2026-10-16"].map { day in
            PlannedNotification(
                id: risk(day),
                fireAt: FireTime(year: 2026, month: 10, day: Int(day.suffix(2)) ?? 0, hour: 21, minute: 0, timeZoneIdentifier: "Asia/Tokyo"),
                title: "Lien", body: "古い文言"
            )
        }
        var checked = 0
        for now in nows {
            for updatedAt in updatedAts {
                for meDone in [false, true] {
                    for partnerDone in [false, true] {
                        for paired in [false, true] {
                            for streak in [0, 5] {
                                var snapshot = NotificationSnapshots.paired(
                                    updatedAt: updatedAt, meDone: meDone, partnerDone: partnerDone, streak: streak
                                )
                                if !paired { snapshot.pairId = nil }
                                let app = ReminderScheduler
                                    .desiredRequests(prefs: defaults, snapshot: snapshot, now: now, calendar: calendar)
                                    .filter(\.isStreakRisk)
                                let label = "now=\(now) updatedAt=\(updatedAt) me=\(meDone) partner=\(partnerDone) paired=\(paired) streak=\(streak)"

                                // 何も予約が無いところから / 古い予約が散らばっているところから / すでに正しいところから
                                let starts: [[PlannedNotification]] = [[], leftovers, app]
                                for start in starts {
                                    let center = FakeNotificationCenter()
                                    for item in start { await center.schedule(item) }
                                    await align(center, snapshot, now: now)
                                    XCTAssertEqual(center.ourPending.filter(\.isStreakRisk), app, label)
                                    checked += 1
                                }
                            }
                        }
                    }
                }
            }
        }
        XCTAssertGreaterThan(checked, 1000)
    }
}
