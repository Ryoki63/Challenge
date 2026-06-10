// DayBoundaryTests.swift — 日付跨ぎ(翌日0:00)エントリのロジック検証(T07。DESIGN §3.5, §9)

import XCTest
@testable import Lien

final class DayBoundaryTests: XCTestCase {
    /// タイムゾーン既定 Asia/Tokyo(DESIGN §9)
    private var tokyoCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        return calendar
    }

    private func date(
        _ year: Int, _ month: Int, _ day: Int,
        _ hour: Int = 0, _ minute: Int = 0,
        calendar: Calendar
    ) -> Date {
        calendar.date(
            from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute)
        )!
    }

    func testNextMidnightDuringDay() {
        let calendar = tokyoCalendar
        let evening = date(2026, 6, 11, 21, 30, calendar: calendar)
        XCTAssertEqual(
            DayBoundary.nextMidnight(after: evening, calendar: calendar),
            date(2026, 6, 12, calendar: calendar)
        )
    }

    func testNextMidnightAtExactMidnightIsTomorrow() {
        let calendar = tokyoCalendar
        let midnight = date(2026, 6, 11, calendar: calendar)
        XCTAssertEqual(
            DayBoundary.nextMidnight(after: midnight, calendar: calendar),
            date(2026, 6, 12, calendar: calendar),
            "0:00 ちょうどに発火しても次のエントリは翌日 0:00(同日に張り直さない)"
        )
    }

    func testNextMidnightJustBeforeMidnight() {
        let calendar = tokyoCalendar
        let lateNight = date(2026, 6, 11, 23, 59, calendar: calendar)
        XCTAssertEqual(
            DayBoundary.nextMidnight(after: lateNight, calendar: calendar),
            date(2026, 6, 12, calendar: calendar)
        )
    }

    func testNextMidnightAcrossMonthEnd() {
        let calendar = tokyoCalendar
        let endOfMonth = date(2026, 6, 30, 12, 0, calendar: calendar)
        XCTAssertEqual(
            DayBoundary.nextMidnight(after: endOfMonth, calendar: calendar),
            date(2026, 7, 1, calendar: calendar)
        )
    }

    func testNextMidnightAcrossYearEnd() {
        let calendar = tokyoCalendar
        let newYearsEve = date(2026, 12, 31, 23, 0, calendar: calendar)
        XCTAssertEqual(
            DayBoundary.nextMidnight(after: newYearsEve, calendar: calendar),
            date(2027, 1, 1, calendar: calendar)
        )
    }

    func testNextMidnightRespectsCalendarTimeZone() {
        // 同一時刻でも TZ が違えば「翌日0:00」は異なる(date_local の原則 — DESIGN §9)
        var honolulu = Calendar(identifier: .gregorian)
        honolulu.timeZone = TimeZone(identifier: "Pacific/Honolulu")! // UTC-10

        // 2026-06-11 21:30 JST = 2026-06-11 02:30 ホノルル
        let instant = date(2026, 6, 11, 21, 30, calendar: tokyoCalendar)

        let tokyoNext = DayBoundary.nextMidnight(after: instant, calendar: tokyoCalendar)
        let honoluluNext = DayBoundary.nextMidnight(after: instant, calendar: honolulu)

        XCTAssertEqual(tokyoNext, date(2026, 6, 12, calendar: tokyoCalendar))
        XCTAssertEqual(honoluluNext, date(2026, 6, 12, calendar: honolulu))
        XCTAssertNotEqual(tokyoNext, honoluluNext)
    }
}
