// HistoryViewModel.swift — カレンダー履歴の状態管理(T18 / REQUIREMENTS §3.11)
//
// - 表示する月を持ち、前月/翌月の移動をペア成立月〜当月にクランプする
// - 取得は HistoryRepository(テストはモック)。状態の判定は HistoryCalendarBuilder(純粋関数)
// - 月をすばやく切り替えたとき、古い取得の結果で新しい月を上書きしない(generation で捨てる)
// - 「今日」は Calendar.lienHistory(Asia/Tokyo)で決める。端末のタイムゾーンに左右されない
// - 失敗しても責めない文言で、もう一度読み込める(REQUIREMENTS §3.5)

import Foundation
import Observation

@MainActor
@Observable
final class HistoryViewModel {
    enum LoadState: Equatable {
        case idle
        case loading
        case loaded
        case failed
    }

    // MARK: 画面状態

    /// 表示中の月
    private(set) var month: HistoryMonth
    /// 月グリッド(先頭の曜日パディングを含む。nil は空のマス)
    private(set) var days: [HistoryDay?] = []
    private(set) var state: LoadState = .idle
    /// ペア成立月まで戻れるか
    private(set) var canGoPrevious = false
    /// 当月より先へ進めるか
    private(set) var canGoNext = false
    /// ペア成立日("YYYY-MM-DD")。nil = ペアが無い(空状態)
    private(set) var pairStartedOn: String?

    // MARK: 依存

    private let repository: HistoryRepository
    private let calendar: Calendar
    private let now: () -> Date
    /// ペア成立月(取得できるまでは nil)
    private var pairStartMonth: HistoryMonth?
    /// 古い取得の結果を捨てるための世代
    private var generation = 0

    init(
        repository: HistoryRepository,
        calendar: Calendar = .lienHistory,
        now: @escaping () -> Date = Date.init
    ) {
        self.repository = repository
        self.calendar = calendar
        self.now = now
        self.month = HistoryMonth.containing(now(), calendar: calendar)
    }

    /// 当月(端末の時計・カレンダーで決める)
    private var currentMonth: HistoryMonth {
        HistoryMonth.containing(now(), calendar: calendar)
    }

    // MARK: 読み込み

    func load() async {
        generation += 1
        let generation = generation
        let requested = month
        state = .loading
        days = []

        do {
            let data = try await repository.fetchMonth(requested)
            // 取得中に月が変わっていたら、この結果は捨てる(新しい月の取得が正)
            guard generation == self.generation, requested == month else { return }
            pairStartedOn = data.pairStartedOn
            pairStartMonth = data.pairStartedOn.flatMap { HistoryMonth(dateLocal: $0) }
            days = HistoryCalendarBuilder.buildMonth(
                requested,
                calendar: calendar,
                today: now(),
                data: data
            )
            state = .loaded
            updateNavigation()
        } catch is CancellationError {
            // 画面を離れた・次の読み込みに置き換わった。状態は次の読み込みに任せる
        } catch {
            guard generation == self.generation, requested == month else { return }
            state = .failed
            updateNavigation()
        }
    }

    /// 失敗したときの「もう一度」
    func retry() async {
        await load()
    }

    // MARK: 月の移動

    func goPrevious() async {
        guard canGoPrevious else { return }
        month = month.previous
        updateNavigation()
        await load()
    }

    func goNext() async {
        guard canGoNext else { return }
        month = month.next
        updateNavigation()
        await load()
    }

    /// 前月/翌月の可否。ペア成立月より前・当月より先へは動かさない
    private func updateNavigation() {
        canGoNext = month < currentMonth
        if let pairStartMonth {
            canGoPrevious = pairStartMonth < month
        } else {
            canGoPrevious = false
        }
    }
}
