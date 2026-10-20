// HistoryCalendarBuilderTests.swift — 月グリッドの判定(T18 #18)
//
// 正本は server の close-day(_shared/streak.ts / DESIGN §5.4)。同じ入力から同じ印になることを固定する:
//   - 両者チェックイン → both 行 → ふたり達成
//   - 片方だけ + チケット → ticket 行 → お休み
//   - 片方だけ + チケットなし → 行なし → 途切れ(noRecord)
//   - ペア成立前 → beforePair / 未来 → future / 今日 → チェックインのプレビュー
// 月境界・うるう年・週頭のパディング・Asia/Tokyo の「今日」もここで固定する。

import XCTest
@testable import Lien

final class HistoryCalendarBuilderTests: XCTestCase {
    private let calendar = Calendar.lienHistory

    // MARK: 道具

    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 12, _ minute: Int = 0) -> Date {
        calendar.date(
            from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute)
        )!
    }

    private func build(
        _ year: Int,
        _ month: Int,
        today: Date,
        data: MonthHistoryData,
        calendar: Calendar? = nil
    ) -> [HistoryDay?] {
        HistoryCalendarBuilder.buildMonth(
            HistoryMonth(year: year, month: month),
            calendar: calendar ?? self.calendar,
            today: today,
            data: data
        )
    }

    private func day(_ dateLocal: String, in cells: [HistoryDay?]) -> HistoryDay? {
        cells.compactMap { $0 }.first { $0.dateLocal == dateLocal }
    }

    private func mark(_ dateLocal: String, in cells: [HistoryDay?]) -> DayMark? {
        day(dateLocal, in: cells)?.mark
    }

    private var emptyData: MonthHistoryData {
        MonthHistoryData(pairStartedOn: "2026-10-01")
    }

    // MARK: 月の形

    func testOctober2026StartsWithSundayBasedPaddingAndHas31Days() {
        let cells = build(2026, 10, today: date(2026, 10, 20), data: emptyData)

        // 2026-10-01 は木曜日。日曜はじまりでは前に4マス空ける
        XCTAssertTrue(cells.prefix(4).allSatisfy { $0 == nil }, "週頭のパディング")
        XCTAssertEqual(cells[4]?.dateLocal, "2026-10-01")
        XCTAssertEqual(cells.compactMap { $0 }.count, 31)
        XCTAssertEqual(cells.compactMap { $0 }.last?.dateLocal, "2026-10-31")
    }

    func testMonthLengthsCoverLeapAndNonLeapFebruary() {
        let cases: [(year: Int, month: Int, days: Int)] = [
            (2024, 2, 29), // うるう年
            (2026, 2, 28),
            (2026, 4, 30),
            (2026, 5, 31),
        ]
        for entry in cases {
            let cells = build(
                entry.year,
                entry.month,
                today: date(entry.year, entry.month, 15),
                data: MonthHistoryData(pairStartedOn: String(format: "%04d-%02d-01", entry.year, entry.month))
            )
            XCTAssertEqual(cells.compactMap { $0 }.count, entry.days, "\(entry.year)-\(entry.month)")
        }
    }

    func testWeekStartFollowsTheInjectedCalendar() {
        var mondayFirst = Calendar.lienHistory
        mondayFirst.firstWeekday = 2 // 月曜はじまり(端末のロケール設定を模す)

        let cells = build(
            2026,
            10,
            today: date(2026, 10, 20),
            data: emptyData,
            calendar: mondayFirst
        )

        // 木曜日は月曜はじまりでは3マス目
        XCTAssertTrue(cells.prefix(3).allSatisfy { $0 == nil })
        XCTAssertEqual(cells[3]?.dateLocal, "2026-10-01")
    }

    // MARK: streak_days の意味論(streak.ts と同じ)

    func testBothAndTicketStreakRowsBecomeTheTwoPositiveMarks() {
        var data = emptyData
        data.streakDays = [
            "2026-10-02": .both,
            "2026-10-03": .ticket,
        ]
        let cells = build(2026, 10, today: date(2026, 10, 20), data: data)

        XCTAssertEqual(mark("2026-10-02", in: cells), .bothDone)
        XCTAssertEqual(mark("2026-10-03", in: cells), .restTicket)
    }

    func testFinalizedDayWithoutStreakRowIsNoRecordEvenWhenBothCheckedIn() {
        // close-day が行を書かなかった日(= 途切れ)を、チェックインの有無から勝手に達成へ変えない
        var data = emptyData
        data.myCheckinDays = ["2026-10-05"]
        data.partnerCheckinDays = ["2026-10-05"]
        let cells = build(2026, 10, today: date(2026, 10, 20), data: data)

        XCTAssertEqual(mark("2026-10-05", in: cells), .noRecord)
    }

    func testFinalizedTicketRowWinsOverBothCheckins() {
        // 確定済みの日はサーバーの行だけを信じる(チェックインが両方あっても ticket 行ならお休み)
        var data = emptyData
        data.streakDays = ["2026-10-05": .ticket]
        data.myCheckinDays = ["2026-10-05"]
        data.partnerCheckinDays = ["2026-10-05"]
        let cells = build(2026, 10, today: date(2026, 10, 20), data: data)

        XCTAssertEqual(mark("2026-10-05", in: cells), .restTicket)
    }

    // MARK: 今日のプレビュー

    func testTodayWithoutCheckinsIsTodayPendingNotNoRecord() {
        let cells = build(2026, 10, today: date(2026, 10, 20), data: emptyData)
        let today = day("2026-10-20", in: cells)

        XCTAssertEqual(today?.mark, .todayPending, "今日はまだ途切れではない")
        XCTAssertEqual(today?.isToday, true)
    }

    func testTodayShowsEachCheckinCombination() {
        var mineOnly = emptyData
        mineOnly.myCheckinDays = ["2026-10-20"]
        XCTAssertEqual(
            mark("2026-10-20", in: build(2026, 10, today: date(2026, 10, 20), data: mineOnly)),
            .meOnly
        )

        var partnerOnly = emptyData
        partnerOnly.partnerCheckinDays = ["2026-10-20"]
        XCTAssertEqual(
            mark("2026-10-20", in: build(2026, 10, today: date(2026, 10, 20), data: partnerOnly)),
            .partnerOnly
        )

        var both = emptyData
        both.myCheckinDays = ["2026-10-20"]
        both.partnerCheckinDays = ["2026-10-20"]
        XCTAssertEqual(
            mark("2026-10-20", in: build(2026, 10, today: date(2026, 10, 20), data: both)),
            .bothDone
        )
    }

    func testFutureDaysAreFuture() {
        let cells = build(2026, 10, today: date(2026, 10, 20), data: emptyData)
        XCTAssertEqual(mark("2026-10-21", in: cells), .future)
        XCTAssertEqual(mark("2026-10-31", in: cells), .future)
    }

    // MARK: ペア成立前

    func testBeforePairStartIsBeforePairAndTheStartDayIsJudged() {
        var data = emptyData
        data.pairStartedOn = "2026-10-10"
        let cells = build(2026, 10, today: date(2026, 10, 20), data: data)

        XCTAssertEqual(mark("2026-10-09", in: cells), .beforePair)
        XCTAssertNotEqual(mark("2026-10-10", in: cells), .beforePair, "成立日は判定対象")
        XCTAssertEqual(mark("2026-10-10", in: cells), .noRecord)
    }

    func testNilPairStartDoesNotMarkEveryDayAsBeforePair() {
        let cells = build(
            2026,
            10,
            today: date(2026, 10, 20),
            data: MonthHistoryData(pairStartedOn: nil)
        )
        XCTAssertEqual(mark("2026-10-01", in: cells), .noRecord)
    }

    // MARK: 0:00〜1:00 の昨日のプレビュー(DESIGN §5.4)

    func testYesterdayBothCheckinsPreviewAsBothUntilOneAM() {
        var data = emptyData
        data.myCheckinDays = ["2026-10-05"]
        data.partnerCheckinDays = ["2026-10-05"]

        let beforeCloseDay = build(2026, 10, today: date(2026, 10, 6, 0, 30), data: data)
        XCTAssertEqual(mark("2026-10-05", in: beforeCloseDay), .bothDone)

        let afterCloseDay = build(2026, 10, today: date(2026, 10, 6, 1, 30), data: data)
        XCTAssertEqual(mark("2026-10-05", in: afterCloseDay), .noRecord, "確定後は行だけを信じる")
    }

    func testConfirmedTicketRowIsNotOverriddenByTheSettleWindow() {
        var data = emptyData
        data.myCheckinDays = ["2026-10-05"]
        data.partnerCheckinDays = ["2026-10-05"]
        data.streakDays = ["2026-10-05": .ticket]

        let cells = build(2026, 10, today: date(2026, 10, 6, 0, 30), data: data)
        XCTAssertEqual(mark("2026-10-05", in: cells), .restTicket)
    }

    func testOneSidedCheckinIsNotPreviewedAsTicketWithoutTheRow() {
        // チケット残数はこの画面では分からない。片方だけの昨日は、確定した行が無ければ途切れのまま
        var data = emptyData
        data.myCheckinDays = ["2026-10-05"]
        let cells = build(2026, 10, today: date(2026, 10, 6, 0, 30), data: data)
        XCTAssertEqual(mark("2026-10-05", in: cells), .noRecord)
    }

    // MARK: タイムゾーン

    func testTodayIsDecidedInAsiaTokyoNotInUTC() {
        // 2026-10-04T16:30Z = 2026-10-05 01:30 JST
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(secondsFromGMT: 0)!
        let instant = utc.date(from: DateComponents(year: 2026, month: 10, day: 4, hour: 16, minute: 30))!

        let cells = build(2026, 10, today: instant, data: emptyData)

        XCTAssertEqual(day("2026-10-05", in: cells)?.isToday, true, "JST では 10/5")
        XCTAssertEqual(mark("2026-10-04", in: cells), .noRecord)
        XCTAssertEqual(mark("2026-10-06", in: cells), .future)
    }

    // MARK: 年・月を直接渡す版

    func testYearMonthConvenienceMatchesTheMonthAPI() {
        let data = MonthHistoryData(
            pairStartedOn: "2026-10-01",
            myCheckinDays: ["2026-10-02"],
            partnerCheckinDays: ["2026-10-02"],
            streakDays: ["2026-10-02": .both]
        )
        let viaMonth = HistoryCalendarBuilder.buildMonth(
            HistoryMonth(year: 2026, month: 10),
            calendar: calendar,
            today: date(2026, 10, 20),
            data: data
        )
        let viaYearMonth = HistoryCalendarBuilder.buildMonth(
            year: 2026,
            month: 10,
            calendar: calendar,
            today: date(2026, 10, 20),
            pairStartedOn: "2026-10-01",
            data: data
        )
        XCTAssertEqual(viaMonth, viaYearMonth)
    }

    // MARK: DESIGN §5.4 の例(close-day と同じ意味論)

    /// テスト用の小さな close-day。streak.ts の decideCloseDay と同じ順で、確定行だけを作る
    private func runCloseDays(
        checkins: [String: (me: Bool, partner: Bool)],
        startedOn: String,
        initialTickets: Int
    ) -> (streak: [String: StreakDayKind], tickets: Int) {
        var streak: [String: StreakDayKind] = [:]
        var tickets = initialTickets
        for date in checkins.keys.sorted() where date >= startedOn {
            let entry = checkins[date]!
            if entry.me && entry.partner {
                streak[date] = .both
            } else if tickets > 0 {
                tickets -= 1
                streak[date] = .ticket
            }
        }
        return (streak, tickets)
    }

    func testDesignExample1BothAndTicketDaysBecomeTheRightMarks() {
        let checkins = [
            "2026-06-01": (true, true),
            "2026-06-02": (true, true),
            "2026-06-03": (true, true),
            "2026-06-04": (true, false), // チケット1枚で守られる
            "2026-06-05": (true, true),
        ]
        let result = runCloseDays(checkins: checkins, startedOn: "2026-06-01", initialTickets: 1)
        XCTAssertEqual(result.tickets, 0)
        var data = MonthHistoryData(pairStartedOn: "2026-06-01", streakDays: result.streak)
        data.myCheckinDays = Set(checkins.filter { $0.value.0 }.keys)
        data.partnerCheckinDays = Set(checkins.filter { $0.value.1 }.keys)
        let cells = build(2026, 6, today: date(2026, 6, 10), data: data)

        XCTAssertEqual(mark("2026-06-01", in: cells), .bothDone)
        XCTAssertEqual(mark("2026-06-04", in: cells), .restTicket)
        XCTAssertEqual(mark("2026-06-05", in: cells), .bothDone)
    }

    func testDesignExample2WithoutTicketTheDayIsNoRecord() {
        let checkins = [
            "2026-06-01": (true, true),
            "2026-06-02": (true, true),
            "2026-06-03": (true, true),
            "2026-06-04": (true, false),
            "2026-06-05": (true, true),
        ]
        let result = runCloseDays(checkins: checkins, startedOn: "2026-06-01", initialTickets: 0)
        XCTAssertNil(result.streak["2026-06-04"])
        let data = MonthHistoryData(pairStartedOn: "2026-06-01", streakDays: result.streak)
        let cells = build(2026, 6, today: date(2026, 6, 10), data: data)

        XCTAssertEqual(mark("2026-06-04", in: cells), .noRecord)
        XCTAssertEqual(mark("2026-06-05", in: cells), .bothDone)
    }

    func testDesignExample3BeforeStartedOnIsNotJudged() {
        let checkins = [
            "2026-06-08": (true, true),
            "2026-06-09": (true, true),
            "2026-06-10": (true, true),
        ]
        let result = runCloseDays(checkins: checkins, startedOn: "2026-06-10", initialTickets: 2)
        XCTAssertEqual(result.streak.keys.sorted(), ["2026-06-10"])
        let data = MonthHistoryData(pairStartedOn: "2026-06-10", streakDays: result.streak)
        let cells = build(2026, 6, today: date(2026, 6, 15), data: data)

        XCTAssertEqual(mark("2026-06-09", in: cells), .beforePair)
        XCTAssertEqual(mark("2026-06-10", in: cells), .bothDone)
    }

    // MARK: date_local の検証

    func testInvalidDateLocalIsRejected() {
        XCTAssertNil(HistoryDate.date(from: "2026-02-30", calendar: calendar))
        XCTAssertNil(HistoryDate.date(from: "2026-13-01", calendar: calendar))
        XCTAssertNil(HistoryDate.date(from: "2026-1-1", calendar: calendar))
        XCTAssertNotNil(HistoryDate.date(from: "2024-02-29", calendar: calendar))
        XCTAssertEqual(HistoryDate.string(from: date(2026, 10, 5), calendar: calendar), "2026-10-05")
    }
}
