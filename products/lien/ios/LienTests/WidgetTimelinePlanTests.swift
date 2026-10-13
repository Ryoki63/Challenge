// WidgetTimelinePlanTests.swift — ウィジェットのタイムライン(日付またぎ)の検証(issue #17 T17a / DESIGN §3.5)
//
// エントリは2点: 今(now)と翌日 0:00。0:00 で2枚の葉をたたむ。ストリーク・段階・進み具合・名前は保つ(罰なし・後退しない)。
// 前の日に作られた snapshot の「今日」は前の日のことなので、今日の分は「まだ」として描く。
// 日付の判断は端末のローカル日(Calendar)で行う(タイムゾーン・夏時間・0:00 ちょうどの境目を確かめる)。
// Foundation だけで書いてあるので、macOS の下見(scripts/macos-check)でも走る。

import XCTest
@testable import Lien

final class WidgetTimelinePlanTests: XCTestCase {
    // MARK: - 道具

    private func calendar(_ timeZone: String = "Asia/Tokyo") -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: timeZone)!
        return calendar
    }

    private func date(
        _ year: Int, _ month: Int, _ day: Int,
        _ hour: Int = 0, _ minute: Int = 0, _ second: Int = 0,
        in timeZone: String = "Asia/Tokyo"
    ) -> Date {
        calendar(timeZone).date(
            from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute, second: second)
        )!
    }

    /// ペア成立中・段階3(わかば)・ストリーク 23・進み具合のキーつき。完了と時刻を指定する
    private func paired(
        updatedAt: Date,
        me: Bool = false,
        partner: Bool = false,
        mood: PlantMood = .normal,
        photo: Bool = false
    ) -> PairSnapshot {
        PairSnapshot(
            schemaVersion: PairSnapshot.currentSchemaVersion,
            pairId: "1f0c5a4e-9d3b-4c1a-8f2e-7b6d5a4c3b2a",
            updatedAt: updatedAt,
            streakCurrent: 23,
            streakBest: 40,
            todayMeDone: me,
            todayPartnerDone: partner,
            myPromiseTitle: "筋トレ",
            myPromiseEmoji: "💪",
            partnerName: "ゆうき",
            partnerPromiseTitle: "ランニング",
            partnerPromiseEmoji: "🏃",
            plantStage: 3,
            plantGrownDays: 9,
            plantStageFloor: 7,
            plantNextStageAt: 14,
            plantMood: mood,
            plantName: "みどり",
            hasPartnerPhotoToday: photo
        )
    }

    // MARK: - 2点のエントリ

    func testStepsAreNowAndTheNextMidnight() {
        let now = date(2026, 10, 14, 21, 30)
        let steps = WidgetTimelinePlan.steps(snapshot: paired(updatedAt: now, me: true), now: now, calendar: calendar())
        XCTAssertEqual(steps.count, 2)
        XCTAssertEqual(steps[0].date, now)
        XCTAssertEqual(steps[1].date, date(2026, 10, 15, 0, 0))
    }

    func testTheFirstStepShowsTodaysSnapshotAsIs() {
        let now = date(2026, 10, 14, 21, 30)
        let snapshot = paired(updatedAt: date(2026, 10, 14, 20, 5), me: true, partner: true, mood: .happy, photo: true)
        let steps = WidgetTimelinePlan.steps(snapshot: snapshot, now: now, calendar: calendar())
        XCTAssertEqual(steps[0].snapshot, snapshot, "今日作られた snapshot は、そのまま描く")
    }

    func testTheMidnightStepClosesBothLeavesAndKeepsEverythingElse() throws {
        let now = date(2026, 10, 14, 21, 30)
        let snapshot = paired(updatedAt: now, me: true, partner: true, mood: .happy, photo: true)
        let steps = WidgetTimelinePlan.steps(snapshot: snapshot, now: now, calendar: calendar())
        let next = try XCTUnwrap(steps[1].snapshot)

        // 変わるのは「今日の分」だけ
        XCTAssertFalse(next.todayMeDone)
        XCTAssertFalse(next.todayPartnerDone)
        XCTAssertFalse(next.hasPartnerPhotoToday, "相手の写真は当日だけ")
        XCTAssertEqual(next.plantMood, .normal, "前日の表情を持ち越さない")
        // 保つもの(ストリーク・段階・進み具合・名前・約束・相手の名前)
        var expected = snapshot
        expected.todayMeDone = false
        expected.todayPartnerDone = false
        expected.hasPartnerPhotoToday = false
        expected.plantMood = .normal
        XCTAssertEqual(next, expected)
        XCTAssertEqual(next.streakCurrent, 23)
        XCTAssertEqual(next.plantStage, 3)
        XCTAssertEqual(next.plantGrownDays, 9)
        XCTAssertEqual(next.plantName, "みどり")
    }

    func testTheMidnightStepDrawsBothLeavesFoldedWithANormalFace() throws {
        let now = date(2026, 10, 14, 21, 30)
        let snapshot = paired(updatedAt: now, me: true, partner: true, mood: .happy)
        let steps = WidgetTimelinePlan.steps(snapshot: snapshot, now: now, calendar: calendar())

        // 今: ふたりそろった(葉は2枚ともひらき、にっこり)
        let today = PlantCharacterState(snapshot: try XCTUnwrap(steps[0].snapshot))
        XCTAssertTrue(today.meOpen)
        XCTAssertTrue(today.partnerOpen)
        XCTAssertEqual(today.expression, .happy)
        // 0:00: 2枚ともたたむ(眠っているだけ。段階はそのまま)
        let tomorrow = PlantCharacterState(snapshot: try XCTUnwrap(steps[1].snapshot))
        XCTAssertFalse(tomorrow.meOpen)
        XCTAssertFalse(tomorrow.partnerOpen)
        XCTAssertEqual(tomorrow.expression, .normal)
        XCTAssertEqual(tomorrow.stage, 3, "段階は後退しない")

        let content = WidgetContent(snapshot: steps[1].snapshot)
        XCTAssertNil(content.waitingMessage)
        XCTAssertEqual(content.me?.done, false)
        XCTAssertEqual(content.partner?.done, false)
        XCTAssertEqual(content.streakDays, 23, "ストリークは 0:00 では減らさない(GROWTH §7.3)")
        XCTAssertEqual(content.progress ?? -1, 2.0 / 7.0, accuracy: 0.0001, "進み具合も保つ")
    }

    func testWithoutASnapshotBothStepsAreEmpty() {
        let now = date(2026, 10, 14, 9, 0)
        let steps = WidgetTimelinePlan.steps(snapshot: nil, now: now, calendar: calendar())
        XCTAssertEqual(steps.count, 2)
        XCTAssertNil(steps[0].snapshot)
        XCTAssertNil(steps[1].snapshot)
        XCTAssertEqual(WidgetContent(snapshot: steps[0].snapshot), .noData)
    }

    // MARK: - 前の日に作られた snapshot

    func testASnapshotFromAnEarlierDayShowsTodayAsNotYet() throws {
        // 昨日の夜にふたりそろった snapshot のまま、朝になった(push を受け取らず、アプリも開いていない)
        let snapshot = paired(updatedAt: date(2026, 10, 13, 21, 0), me: true, partner: true, mood: .happy, photo: true)
        let now = date(2026, 10, 14, 8, 0)
        let steps = WidgetTimelinePlan.steps(snapshot: snapshot, now: now, calendar: calendar())
        let first = try XCTUnwrap(steps[0].snapshot)
        XCTAssertFalse(first.todayMeDone, "昨日の「完了」を、今日の葉の絵にしない")
        XCTAssertFalse(first.todayPartnerDone)
        XCTAssertFalse(first.hasPartnerPhotoToday)
        XCTAssertEqual(first.plantMood, .normal)
        XCTAssertEqual(first.streakCurrent, 23, "ストリーク・段階は保つ")
        XCTAssertEqual(first.plantStage, 3)
        let state = PlantCharacterState(snapshot: first)
        XCTAssertFalse(state.meOpen)
        XCTAssertFalse(state.partnerOpen)
    }

    func testASnapshotFromLongAgoIsTreatedTheSameWay() throws {
        let snapshot = paired(updatedAt: date(2026, 9, 1, 12, 0), me: true, partner: false)
        let now = date(2026, 10, 14, 8, 0)
        let first = try XCTUnwrap(WidgetTimelinePlan.steps(snapshot: snapshot, now: now, calendar: calendar())[0].snapshot)
        XCTAssertFalse(first.todayMeDone)
    }

    func testTheDayBoundaryIsExactlyMidnightInTheLocalCalendar() {
        let calendar = calendar()
        let now = date(2026, 10, 14, 0, 0, 1)
        // 昨日の 23:59:59 に作られた = 前の日
        XCTAssertTrue(WidgetTimelinePlan.isFromEarlierDay(
            paired(updatedAt: date(2026, 10, 13, 23, 59, 59), me: true), now: now, calendar: calendar
        ))
        // 今日の 0:00:00 ちょうどに作られた = 今日
        XCTAssertFalse(WidgetTimelinePlan.isFromEarlierDay(
            paired(updatedAt: date(2026, 10, 14, 0, 0, 0), me: true), now: now, calendar: calendar
        ))
        // 0:00:00 ちょうどに now が来ても、今日の 0:00 より前の snapshot だけが前の日
        let midnight = date(2026, 10, 14, 0, 0, 0)
        XCTAssertTrue(WidgetTimelinePlan.isFromEarlierDay(
            paired(updatedAt: date(2026, 10, 13, 23, 59, 59), me: true), now: midnight, calendar: calendar
        ))
        XCTAssertFalse(WidgetTimelinePlan.isFromEarlierDay(paired(updatedAt: midnight, me: true), now: midnight, calendar: calendar))
    }

    func testASnapshotFromTheFutureIsTrusted() throws {
        // サーバーの時計が端末より進んでいて、updatedAt が(端末から見て)明日の 0:00 台になった
        let now = date(2026, 10, 14, 23, 59, 50)
        let snapshot = paired(updatedAt: date(2026, 10, 15, 0, 0, 20), me: true, partner: true, mood: .happy)
        let steps = WidgetTimelinePlan.steps(snapshot: snapshot, now: now, calendar: calendar())
        XCTAssertEqual(steps[0].snapshot, snapshot, "時計のずれで、今日の完了を消さない")
        XCTAssertEqual(steps[1].date, date(2026, 10, 15, 0, 0), "それでも 0:00 には切り替える")
    }

    func testTheCalendarDecidesWhichDayItIs() {
        // 同じ時刻・同じ snapshot でも、端末のタイムゾーンで「今日」が変わる(date_local の原則 — DESIGN §9)
        let updatedAt = date(2026, 10, 13, 22, 0, in: "Asia/Tokyo")   // 東京: 13日の 22:00 = ホノルル: 13日の 03:00
        let now = date(2026, 10, 14, 0, 30, in: "Asia/Tokyo")          // 東京: 14日の 0:30 = ホノルル: 13日の 05:30
        let snapshot = paired(updatedAt: updatedAt, me: true)
        XCTAssertTrue(WidgetTimelinePlan.isFromEarlierDay(snapshot, now: now, calendar: calendar("Asia/Tokyo")))
        XCTAssertFalse(WidgetTimelinePlan.isFromEarlierDay(snapshot, now: now, calendar: calendar("Pacific/Honolulu")))
        // 0:00 の切り替えもその暦の日付境界
        XCTAssertEqual(
            WidgetTimelinePlan.steps(snapshot: snapshot, now: now, calendar: calendar("Pacific/Honolulu"))[1].date,
            date(2026, 10, 14, 0, 0, in: "Pacific/Honolulu")
        )
    }

    // MARK: - 翌日 0:00 の日付

    func testTheMidnightStepIsAlwaysStrictlyAfterNow() {
        let calendar = calendar()
        let nows = [
            date(2026, 10, 14, 0, 0, 0),    // 0:00 ちょうど
            date(2026, 10, 14, 0, 0, 1),
            date(2026, 10, 14, 12, 0, 0),
            date(2026, 10, 14, 23, 59, 59),
            date(2026, 12, 31, 23, 59, 59), // 年末
            date(2026, 2, 28, 12, 0, 0),    // 月末(2月)
        ]
        for now in nows {
            let steps = WidgetTimelinePlan.steps(snapshot: nil, now: now, calendar: calendar)
            XCTAssertGreaterThan(steps[1].date, now, "\(now)")
            XCTAssertEqual(calendar.component(.hour, from: steps[1].date), 0)
            XCTAssertEqual(calendar.component(.minute, from: steps[1].date), 0)
            XCTAssertEqual(calendar.component(.second, from: steps[1].date), 0)
            // 同じ日の中には入らない(今日の 0:00 に張り直して、reload を繰り返さない)
            XCTAssertFalse(calendar.isDate(steps[1].date, inSameDayAs: now), "\(now)")
            // ちょうど翌日
            XCTAssertEqual(calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: steps[1].date).day, 1)
        }
    }

    func testTheMidnightStepAtTheStartOfADaylightSavingDay() {
        // 米国の夏時間の開始日(2026-03-08)は 23 時間(2:00 が 3:00 に進む)。翌日の 0:00 は、24 時間後ではなく暦の翌日
        let la = calendar("America/Los_Angeles")
        let now = date(2026, 3, 8, 0, 30, in: "America/Los_Angeles")
        let next = WidgetTimelinePlan.steps(snapshot: nil, now: now, calendar: la)[1].date
        XCTAssertEqual(la.component(.day, from: next), 9)
        XCTAssertEqual(la.component(.hour, from: next), 0)
        XCTAssertEqual(next.timeIntervalSince(now), 22.5 * 3600, "0:30 から翌 0:00 まで、23 時間の日は 22 時間半")
    }

    func testTheMidnightStepAtTheEndOfADaylightSavingDay() {
        // 米国の夏時間の終了日(2026-11-01)は 25 時間(1:00〜2:00 が2回ある)
        let la = calendar("America/Los_Angeles")
        let now = date(2026, 11, 1, 0, 30, in: "America/Los_Angeles")
        let next = WidgetTimelinePlan.steps(snapshot: nil, now: now, calendar: la)[1].date
        XCTAssertEqual(la.component(.day, from: next), 2)
        XCTAssertEqual(la.component(.hour, from: next), 0)
        XCTAssertEqual(next.timeIntervalSince(now), 24.5 * 3600, "0:30 から翌 0:00 まで、25 時間の日は 24 時間半")
    }

    // MARK: - 状態を後退させない

    func testResettingNeverLowersTheStreakOrTheStageOrTheProgress() throws {
        // 罰なし(REQUIREMENTS §3.5・§3.9): 日付が変わっても、ストリークも段階も進み具合も減らない。変わるのは今日の葉だけ
        for stage in [0, 1, 3, 9, 12] {
            var snapshot = paired(updatedAt: date(2026, 10, 13, 22, 0), me: true, partner: true, mood: .happy)
            snapshot.plantStage = stage
            snapshot.streakCurrent = 7
            snapshot.streakBest = 7
            let before = WidgetContent(snapshot: snapshot)
            for step in WidgetTimelinePlan.steps(snapshot: snapshot, now: date(2026, 10, 14, 7, 0), calendar: calendar()) {
                let content = WidgetContent(snapshot: step.snapshot)
                XCTAssertEqual(content.streakDays, before.streakDays, "stage \(stage)")
                XCTAssertEqual(content.plant.stage, before.plant.stage, "stage \(stage)")
                XCTAssertEqual(content.progress, before.progress, "stage \(stage)")
                XCTAssertFalse(content.plant.meOpen, "stage \(stage)")
                XCTAssertFalse(content.plant.partnerOpen, "stage \(stage)")
            }
        }
    }
}
