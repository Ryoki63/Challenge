// InviteSyncScheduleTests.swift — 招待シートの同期間隔(4s → 8s → 16s → 30s で頭打ち — issue #62)

import XCTest
@testable import Lien

final class InviteSyncScheduleTests: XCTestCase {
    func testIntervalsGrowStepwiseFromFourToThirtySeconds() {
        let intervals = (0..<8).map { InviteSyncSchedule.interval(forAttempt: $0) }
        XCTAssertEqual(intervals, [4, 8, 16, 30, 30, 30, 30, 30])
    }

    func testIntervalNeverExceedsTheMaximumAndNeverShrinks() {
        var previous: TimeInterval = 0
        for attempt in 0..<100 {
            let interval = InviteSyncSchedule.interval(forAttempt: attempt)
            XCTAssertLessThanOrEqual(interval, InviteSyncSchedule.maximumInterval)
            XCTAssertGreaterThanOrEqual(interval, previous, "待つほど間隔は伸びる(縮まない)")
            previous = interval
        }
    }

    func testOutOfRangeAttemptsAreClamped() {
        XCTAssertEqual(InviteSyncSchedule.interval(forAttempt: -1), InviteSyncSchedule.initialInterval)
        XCTAssertEqual(InviteSyncSchedule.interval(forAttempt: Int.min), InviteSyncSchedule.initialInterval)
        XCTAssertEqual(InviteSyncSchedule.interval(forAttempt: Int.max), InviteSyncSchedule.maximumInterval)
    }

    func testFirstIntervalKeepsTheOriginalQuickCheck() {
        // 相手がすぐ開いた場合にすぐ気づける(従来の固定 4 秒と同じ最初の間隔)
        XCTAssertEqual(InviteSyncSchedule.initialInterval, 4)
        XCTAssertEqual(InviteSyncSchedule.maximumInterval, 30)
    }
}
