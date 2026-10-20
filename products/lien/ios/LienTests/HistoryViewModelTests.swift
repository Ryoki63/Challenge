// HistoryViewModelTests.swift — カレンダー履歴の月移動と読み込み(T18 #18)
//
// HistoryRepository をモックして、通信なしで検証する:
//   - 起動時は当月。ペア成立月〜当月にクランプする
//   - 失敗しても月は保ち、もう一度読み込める(責めない文言は Strings.History)
//   - 月を続けて切り替えたとき、古い取得の結果で新しい月を上書きしない
//   - 「今日」は Asia/Tokyo で決める(端末のタイムゾーンに左右されない)

import XCTest
@testable import Lien

private enum HistoryTestError: Error {
    case failed
}

/// 月ごとの応答を返すモック。gateForMonth に入れた月だけ、open() まで待たせる
private final class MockHistoryRepository: HistoryRepository {
    var dataByMonth: [HistoryMonth: MonthHistoryData] = [:]
    var errorByMonth: [HistoryMonth: Error] = [:]
    var gateForMonth: [HistoryMonth: AsyncGate] = [:]
    var defaultData = MonthHistoryData(pairStartedOn: "2026-09-01")
    private(set) var requested: [HistoryMonth] = []

    func fetchMonth(_ month: HistoryMonth) async throws -> MonthHistoryData {
        requested.append(month)
        if let gate = gateForMonth[month] {
            await gate.wait()
        }
        if let error = errorByMonth[month] {
            throw error
        }
        return dataByMonth[month] ?? defaultData
    }
}

@MainActor
final class HistoryViewModelTests: XCTestCase {
    private let calendar = Calendar.lienHistory

    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 12) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }

    private func month(_ year: Int, _ month: Int) -> HistoryMonth {
        HistoryMonth(year: year, month: month)
    }

    private func makeViewModel(
        repository: MockHistoryRepository,
        now: Date
    ) -> HistoryViewModel {
        HistoryViewModel(repository: repository, calendar: calendar, now: { now })
    }

    // MARK: 起動時

    func testInitialLoadUsesTheCurrentMonthAndShowsTheGrid() async {
        let repo = MockHistoryRepository()
        let vm = makeViewModel(repository: repo, now: date(2026, 10, 20))

        await vm.load()

        XCTAssertEqual(vm.month, month(2026, 10))
        XCTAssertEqual(vm.state, .loaded)
        XCTAssertEqual(vm.days.compactMap { $0 }.count, 31)
        XCTAssertTrue(vm.canGoPrevious, "ペア成立月(9月)まで戻れる")
        XCTAssertFalse(vm.canGoNext, "当月より先へは進めない")
        XCTAssertEqual(repo.requested, [month(2026, 10)])
    }

    func testCurrentMonthIsDecidedInAsiaTokyo() {
        // 2026-09-30T16:30Z = 2026-10-01 01:30 JST
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(secondsFromGMT: 0)!
        let instant = utc.date(from: DateComponents(year: 2026, month: 9, day: 30, hour: 16, minute: 30))!

        let repo = MockHistoryRepository()
        let vm = makeViewModel(repository: repo, now: instant)

        XCTAssertEqual(vm.month, month(2026, 10), "UTC では 9/30 でも、JST では 10/1")
    }

    // MARK: 月の移動とクランプ

    func testPreviousIsClampedAtThePairStartMonth() async {
        let repo = MockHistoryRepository()
        repo.defaultData = MonthHistoryData(pairStartedOn: "2026-08-15")
        let vm = makeViewModel(repository: repo, now: date(2026, 10, 20))
        await vm.load()

        await vm.goPrevious()
        XCTAssertEqual(vm.month, month(2026, 9))
        XCTAssertTrue(vm.canGoPrevious)
        XCTAssertTrue(vm.canGoNext)

        await vm.goPrevious()
        XCTAssertEqual(vm.month, month(2026, 8))
        XCTAssertFalse(vm.canGoPrevious, "成立月より前へは戻らない")
        XCTAssertTrue(vm.canGoNext)

        await vm.goPrevious() // ガードで何もしない
        XCTAssertEqual(vm.month, month(2026, 8))
    }

    func testNextIsClampedAtTheCurrentMonth() async {
        let repo = MockHistoryRepository()
        repo.defaultData = MonthHistoryData(pairStartedOn: "2026-08-15")
        let vm = makeViewModel(repository: repo, now: date(2026, 10, 20))
        await vm.load()
        await vm.goPrevious() // 9月
        await vm.goPrevious() // 8月

        await vm.goNext()
        XCTAssertEqual(vm.month, month(2026, 9))
        await vm.goNext()
        XCTAssertEqual(vm.month, month(2026, 10))
        XCTAssertFalse(vm.canGoNext, "当月より先へは進まない")

        await vm.goNext() // ガードで何もしない
        XCTAssertEqual(vm.month, month(2026, 10))
    }

    func testNoPairDisablesPreviousNavigation() async {
        let repo = MockHistoryRepository()
        repo.defaultData = MonthHistoryData(pairStartedOn: nil)
        let vm = makeViewModel(repository: repo, now: date(2026, 10, 20))

        await vm.load()

        XCTAssertEqual(vm.state, .loaded)
        XCTAssertNil(vm.pairStartedOn)
        XCTAssertFalse(vm.canGoPrevious)
        XCTAssertFalse(vm.canGoNext)
    }

    // MARK: 失敗と再試行

    func testFailedLoadKeepsTheMonthAndRetrySucceeds() async {
        let repo = MockHistoryRepository()
        repo.errorByMonth[month(2026, 10)] = HistoryTestError.failed
        let vm = makeViewModel(repository: repo, now: date(2026, 10, 20))

        await vm.load()
        XCTAssertEqual(vm.state, .failed)
        XCTAssertEqual(vm.month, month(2026, 10), "失敗しても表示中の月は変えない")
        XCTAssertTrue(vm.days.isEmpty)

        repo.errorByMonth.removeValue(forKey: month(2026, 10))
        await vm.retry()
        XCTAssertEqual(vm.state, .loaded)
        XCTAssertEqual(vm.days.compactMap { $0 }.count, 31)
    }

    // MARK: 古い取得の結果を捨てる

    func testStaleResponseDoesNotOverwriteTheNewerMonth() async {
        let repo = MockHistoryRepository()
        repo.defaultData = MonthHistoryData(pairStartedOn: "2026-08-15")
        let vm = makeViewModel(repository: repo, now: date(2026, 10, 20))
        await vm.load()

        let gate = AsyncGate()
        repo.gateForMonth[month(2026, 9)] = gate
        let previous = Task { await vm.goPrevious() }
        await waitUntil { repo.requested.contains(self.month(2026, 9)) }
        XCTAssertEqual(vm.month, month(2026, 9), "9月の取得中")

        // 取得中に当月へ戻る。9月の応答は後から返るが、表示は10月のまま
        let next = Task { await vm.goNext() }
        await waitUntil { vm.month == self.month(2026, 10) && vm.state == .loaded }
        gate.open()
        await previous.value
        await next.value

        XCTAssertEqual(vm.month, month(2026, 10))
        XCTAssertEqual(vm.state, .loaded)
        XCTAssertEqual(vm.days.compactMap { $0 }.count, 31, "9月の応答(30日)で上書きされない")
    }
}
