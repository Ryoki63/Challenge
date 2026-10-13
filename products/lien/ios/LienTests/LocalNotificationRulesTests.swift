// LocalNotificationRulesTests.swift — ローカル通知の識別子と取り消し条件(アプリの同期と NSE で共通の規則。T16 #16)
//
// 検証対象(LocalNotificationID.swift。Lien / LienNSE でソース共有):
//   - 識別子(日付つき)・暦(グレゴリオ暦+端末のタイムゾーン)
//   - 「今日の分をもう出さなくてよい」の条件(自分が完了 → リマインド / ふたりそろった・ペアが無い → ストリーク危機)
//   - snapshot が今日のものでないときは何も言わない(昨日の完了を今日の完了と取り違えない)
//   - 前面で届いたローカル通知を捨ててよいか(NSE が取り消せなかったときの最後の網)

import XCTest
@testable import Lien

final class LocalNotificationRulesTests: XCTestCase {
    private typealias Clock = NotificationClock
    private let calendar = NotificationClock.calendar()
    private let now = NotificationClock.date(2026, 10, 14, 15, 0)

    // MARK: 識別子

    func testIdentifiersCarryTheDayAndAreRecognizedByKind() {
        let reminder = LocalNotificationID.reminder(dayKey: "2026-10-14")
        let risk = LocalNotificationID.streakRisk(dayKey: "2026-10-14")
        XCTAssertEqual(reminder, "lien.local.reminder.2026-10-14")
        XCTAssertEqual(risk, "lien.local.streak-risk.2026-10-14")

        XCTAssertTrue(LocalNotificationID.isOurs(reminder))
        XCTAssertTrue(LocalNotificationID.isOurs(risk))
        XCTAssertTrue(LocalNotificationID.isReminder(reminder))
        XCTAssertFalse(LocalNotificationID.isReminder(risk))
        XCTAssertTrue(LocalNotificationID.isStreakRisk(risk))
        XCTAssertFalse(LocalNotificationID.isStreakRisk(reminder))

        // リモート通知の識別子(APNs の apns-collapse-id など)やほかのアプリの通知は、このアプリのローカル通知ではない
        XCTAssertFalse(LocalNotificationID.isOurs("B2A6D0C8-5B6F-4A33-9C54-0123456789AB"))
        XCTAssertFalse(LocalNotificationID.isOurs("lien.remote.reminder.2026-10-14"))
        XCTAssertFalse(LocalNotificationID.isOurs(""))
    }

    func testDayKeyIsZeroPaddedAndFollowsTheCalendarsTimeZone() {
        XCTAssertEqual(LocalNotificationID.dayKey(for: Clock.date(2026, 1, 5, 9, 0), calendar: calendar), "2026-01-05")
        XCTAssertEqual(LocalNotificationID.dayKey(for: Clock.date(2026, 12, 31, 23, 59, 59), calendar: calendar), "2026-12-31")
        XCTAssertEqual(LocalNotificationID.dayKey(for: Clock.date(2027, 1, 1, 0, 0, 0), calendar: calendar), "2027-01-01")
        // 日付が変わる瞬間は、タイムゾーンで決まる(東京の 2026-10-15 00:30 は、ロサンゼルスではまだ 10-14)
        let instant = Clock.date(2026, 10, 15, 0, 30)
        XCTAssertEqual(LocalNotificationID.dayKey(for: instant, calendar: Clock.calendar(Clock.tokyo)), "2026-10-15")
        XCTAssertEqual(LocalNotificationID.dayKey(for: instant, calendar: Clock.calendar(Clock.losAngeles)), "2026-10-14")
    }

    func testTheNotificationCalendarIsGregorianEvenIfTheDeviceUsesAnotherCalendar() {
        // 端末の暦が和暦・仏暦でも、年の数え方が変わって日付のキーや通知の日時がずれないように、暦は固定する
        let calendar = LocalNotificationCalendar.current()
        XCTAssertEqual(calendar.identifier, .gregorian)
        XCTAssertEqual(calendar.timeZone.identifier, TimeZone.current.identifier)

        var japanese = Calendar(identifier: .japanese)
        japanese.timeZone = TimeZone(identifier: Clock.tokyo)!
        let instant = Clock.date(2026, 10, 14, 12, 0)
        XCTAssertEqual(
            LocalNotificationID.dayKey(for: instant, calendar: Clock.calendar()), "2026-10-14",
            "グレゴリオ暦では 2026 年"
        )
        XCTAssertNotEqual(
            LocalNotificationID.dayKey(for: instant, calendar: japanese), "2026-10-14",
            "和暦のままだと年が令和の年になる(だから固定する)"
        )
    }

    // MARK: snapshot が今日のものか

    func testReflectsTodayFollowsTheLocalDay() {
        let snapshot = NotificationSnapshots.paired(updatedAt: Clock.date(2026, 10, 14, 0, 0, 1))
        XCTAssertTrue(snapshot.reflectsToday(now: Clock.date(2026, 10, 14, 23, 59, 59), calendar: calendar))
        XCTAssertFalse(snapshot.reflectsToday(now: Clock.date(2026, 10, 15, 0, 0, 0), calendar: calendar))
        XCTAssertFalse(snapshot.reflectsToday(now: Clock.date(2026, 10, 13, 23, 59, 59), calendar: calendar))
    }

    // MARK: 取り消し条件

    func testCompletingTodayMakesTodaysReminderStaleButNotTheStreakRisk() {
        let snapshot = NotificationSnapshots.paired(updatedAt: now, meDone: true, partnerDone: false)
        XCTAssertEqual(
            LocalNotificationCancellation.staleIDsForToday(snapshot: snapshot, now: now, calendar: calendar),
            ["lien.local.reminder.2026-10-14"],
            "自分が済んだらリマインドは要らない。相手がまだなら、ストリーク危機は残す"
        )
    }

    func testBothDoneMakesTodaysStreakRiskStaleAsWell() {
        let snapshot = NotificationSnapshots.paired(updatedAt: now, meDone: true, partnerDone: true)
        XCTAssertEqual(
            Set(LocalNotificationCancellation.staleIDsForToday(snapshot: snapshot, now: now, calendar: calendar)),
            ["lien.local.reminder.2026-10-14", "lien.local.streak-risk.2026-10-14"]
        )
    }

    func testPartnerAloneDoingItCancelsNothing() {
        // 相手が済んで自分がまだ: 自分のリマインドも、ストリーク危機(自分が済ませれば間に合う)も、まだ要る
        let snapshot = NotificationSnapshots.paired(updatedAt: now, meDone: false, partnerDone: true)
        XCTAssertEqual(LocalNotificationCancellation.staleIDsForToday(snapshot: snapshot, now: now, calendar: calendar), [])
    }

    func testNothingIsDoneYetCancelsNothing() {
        let snapshot = NotificationSnapshots.paired(updatedAt: now)
        XCTAssertEqual(LocalNotificationCancellation.staleIDsForToday(snapshot: snapshot, now: now, calendar: calendar), [])
    }

    func testDissolvedPairMakesTodaysStreakRiskStale() {
        var snapshot = NotificationSnapshots.paired(updatedAt: now)
        snapshot.pairId = nil
        XCTAssertEqual(
            LocalNotificationCancellation.staleIDsForToday(snapshot: snapshot, now: now, calendar: calendar),
            ["lien.local.streak-risk.2026-10-14"],
            "ペアが無くなったら、ストリーク危機は要らない(リマインドは自分の約束のものなので残す)"
        )
    }

    func testAStaleSnapshotSaysNothingAboutToday() {
        // 昨日ふたりそろった snapshot(todayMeDone / todayPartnerDone は昨日の完了)を、今日の完了と取り違えない
        let yesterday = NotificationSnapshots.paired(
            updatedAt: Clock.date(2026, 10, 13, 22, 0), meDone: true, partnerDone: true
        )
        XCTAssertEqual(LocalNotificationCancellation.staleIDsForToday(snapshot: yesterday, now: now, calendar: calendar), [])
    }

    // MARK: 前面で届いたときに捨ててよいか(NSE が取り消せなかったときの最後の網)

    func testShouldSuppressOnlyTheStaleLocalNotificationOfToday() {
        let both = NotificationSnapshots.paired(updatedAt: now, meDone: true, partnerDone: true)
        let risk = "lien.local.streak-risk.2026-10-14"
        let reminder = "lien.local.reminder.2026-10-14"
        XCTAssertTrue(LocalNotificationCancellation.shouldSuppress(identifier: risk, snapshot: both, now: now, calendar: calendar))
        XCTAssertTrue(LocalNotificationCancellation.shouldSuppress(identifier: reminder, snapshot: both, now: now, calendar: calendar))

        let none = NotificationSnapshots.paired(updatedAt: now)
        XCTAssertFalse(LocalNotificationCancellation.shouldSuppress(identifier: risk, snapshot: none, now: now, calendar: calendar))
        XCTAssertFalse(LocalNotificationCancellation.shouldSuppress(identifier: reminder, snapshot: none, now: now, calendar: calendar))

        // 別の日の通知・リモート通知・snapshot が無いときは、捨てない(通知を失わない側に倒す)
        XCTAssertFalse(LocalNotificationCancellation.shouldSuppress(
            identifier: "lien.local.streak-risk.2026-10-15", snapshot: both, now: now, calendar: calendar
        ))
        XCTAssertFalse(LocalNotificationCancellation.shouldSuppress(
            identifier: "B2A6D0C8-5B6F-4A33-9C54-0123456789AB", snapshot: both, now: now, calendar: calendar
        ))
        XCTAssertFalse(LocalNotificationCancellation.shouldSuppress(identifier: risk, snapshot: nil, now: now, calendar: calendar))
    }
}
