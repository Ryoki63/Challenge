// UserNotificationCenterSchedulerTests.swift — 予約 1 件 ⇔ OS の通知リクエストの変換(T16 #16)
//
// 通知センター(UNUserNotificationCenter)そのものには触れない。変換の静的な関数だけを確かめる:
//   - 予約 → リクエスト: 内容・1 回きりのカレンダートリガー・暦(グレゴリオ暦)とタイムゾーンの明示
//   - リクエスト → 予約: 読み戻した予約が、計算した予約と一致する(同期のたびに付け替えない)/ 想定外のトリガーは一致しない

import UserNotifications
import XCTest
@testable import Lien

final class UserNotificationCenterSchedulerTests: XCTestCase {
    private typealias Clock = NotificationClock

    private let reminder = PlannedNotification(
        id: "lien.local.reminder.2099-01-01",
        fireAt: FireTime(year: 2099, month: 1, day: 1, hour: 20, minute: 0, timeZoneIdentifier: "Asia/Tokyo"),
        title: "Lien",
        body: "今日の『筋トレ』、まだ間に合うよ💪"
    )
    private let risk = PlannedNotification(
        id: "lien.local.streak-risk.2099-01-01",
        fireAt: FireTime(year: 2099, month: 1, day: 1, hour: 21, minute: 0, timeZoneIdentifier: "Asia/Tokyo"),
        title: "Lien",
        body: "あと3時間。ふたりの23日、いっしょにつなごう🌱"
    )

    func testRequestCarriesTheContentAndIsAOneShotCalendarTrigger() throws {
        let request = UserNotificationCenterScheduler.makeRequest(reminder)

        XCTAssertEqual(request.identifier, "lien.local.reminder.2099-01-01")
        XCTAssertEqual(request.content.title, "Lien")
        XCTAssertEqual(request.content.body, "今日の『筋トレ』、まだ間に合うよ💪")
        XCTAssertNotNil(request.content.sound)
        XCTAssertEqual(request.content.threadIdentifier, "lien.local.reminder")
        XCTAssertEqual(request.content.userInfo["lienLocalType"] as? String, "reminder")

        let trigger = try XCTUnwrap(request.trigger as? UNCalendarNotificationTrigger)
        XCTAssertFalse(trigger.repeats, "日付ごとの 1 回きり(毎日くり返すと、今日だけ出さないができない)")
    }

    func testStreakRiskRequestIsGroupedSeparatelyFromTheReminder() {
        let request = UserNotificationCenterScheduler.makeRequest(risk)
        XCTAssertEqual(request.content.threadIdentifier, "lien.local.streak-risk")
        XCTAssertEqual(request.content.userInfo["lienLocalType"] as? String, "streak_risk")
    }

    func testTriggerNamesTheGregorianCalendarAndTheTimeZone() throws {
        // 端末の暦が和暦・仏暦でも、年・月・日がグレゴリオ暦として解釈される(暦を明示している)
        let components = UserNotificationCenterScheduler.dateComponents(for: reminder.fireAt)
        XCTAssertEqual(components.calendar?.identifier, .gregorian)
        XCTAssertEqual(components.timeZone?.identifier, "Asia/Tokyo")
        XCTAssertEqual(components.year, 2099)
        XCTAssertEqual(components.month, 1)
        XCTAssertEqual(components.day, 1)
        XCTAssertEqual(components.hour, 20)
        XCTAssertEqual(components.minute, 0)
        XCTAssertNil(components.second, "秒は指定しない(分の頭に出る)")
    }

    func testTheTriggerFiresAtTheIntendedInstantInThatTimeZone() throws {
        let tokyo = try XCTUnwrap(
            UserNotificationCenterScheduler.makeRequest(reminder).trigger as? UNCalendarNotificationTrigger
        )
        XCTAssertEqual(tokyo.nextTriggerDate(), Clock.date(2099, 1, 1, 20, 0, in: Clock.tokyo))

        // 同じ壁時計でも、別のタイムゾーンの予約は別の瞬間
        let losAngeles = PlannedNotification(
            id: reminder.id,
            fireAt: FireTime(year: 2099, month: 1, day: 1, hour: 20, minute: 0, timeZoneIdentifier: "America/Los_Angeles"),
            title: reminder.title, body: reminder.body
        )
        let la = try XCTUnwrap(
            UserNotificationCenterScheduler.makeRequest(losAngeles).trigger as? UNCalendarNotificationTrigger
        )
        XCTAssertEqual(la.nextTriggerDate(), Clock.date(2099, 1, 1, 20, 0, in: Clock.losAngeles))
        XCTAssertNotEqual(la.nextTriggerDate(), tokyo.nextTriggerDate())
    }

    func testRequestReadsBackAsTheSamePlannedNotification() {
        for planned in [reminder, risk] {
            let readBack = UserNotificationCenterScheduler.plannedNotification(
                from: UserNotificationCenterScheduler.makeRequest(planned)
            )
            XCTAssertEqual(readBack.id, planned.id)
            XCTAssertEqual(readBack.fireAt, planned.fireAt, "年月日・時分・タイムゾーンが読み戻せる")
            XCTAssertEqual(readBack.title, planned.title)
            XCTAssertEqual(readBack.body, planned.body)
            XCTAssertTrue(planned.matches(pending: readBack), "読み戻した予約は、計算した予約と一致する(同期のたびに付け替えない)")
        }
    }

    func testAPendingRequestWithAnUnexpectedTriggerNeverMatches() {
        // カレンダートリガーでない予約(旧バージョンの名残など)は、発火の日時が合わない値になり、次の同期で付け替わる
        let content = UNMutableNotificationContent()
        content.title = reminder.title
        content.body = reminder.body
        let request = UNNotificationRequest(
            identifier: reminder.id,
            content: content,
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: 3600, repeats: false)
        )
        let readBack = UserNotificationCenterScheduler.plannedNotification(from: request)
        XCTAssertEqual(readBack.id, reminder.id)
        XCTAssertEqual(readBack.fireAt.year, 0)
        XCTAssertFalse(reminder.matches(pending: readBack))
    }
}
