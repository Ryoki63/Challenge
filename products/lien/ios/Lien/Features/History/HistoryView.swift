// HistoryView.swift — カレンダー履歴画面(T18 / REQUIREMENTS §3.11)
//
// 1か月を7列のグリッドで表示し、日ごとに次の印を出す:
//   ふたり達成(2つの点)/ じぶんだけ(左の点)/ あいてだけ(右の点)/ お休み(細いカプセル)
//   途切れた日は無彩色の小さな点だけ(「途切れ」「失敗」などの言葉・赤色は使わない — REVIEW-2026-10-12 §4.2)
// 今日はリングで囲み、チェックイン状況をプレビューする(確定は明日の close-day)。
//
// 状態と月の移動は HistoryViewModel。文言は Strings.History、色・余白は DesignSystem の定数に集約する
// (DESIGN §3.8)。読み込みに失敗しても責めず、もう一度読み込める(REQUIREMENTS §3.5)。

import SwiftUI

@MainActor
struct HistoryView: View {
    @State private var viewModel: HistoryViewModel
    /// スクロールできる器を付けるか(ストア用スクリーンショットでは false)
    private var scrolls = true
    /// 表示したときに読み込むか(ストア用スクリーンショットでは、読み込み済みの状態をそのまま描くので false)
    private var autoload = true

    private static let columnCount = 7

    init(
        repository: HistoryRepository,
        calendar: Calendar = .lienHistory,
        now: @escaping () -> Date = Date.init
    ) {
        _viewModel = State(initialValue: HistoryViewModel(
            repository: repository,
            calendar: calendar,
            now: now
        ))
    }

    /// テスト・プレビュー用(状態を組み立て済みの ViewModel を渡す)。
    /// scrolls = false は、ストア用スクリーンショットの実描画用(ImageRenderer は ScrollView を描けない — issue #80)。
    /// 画面の中身は同じで、スクロールできる器を付けるかどうかだけが変わる
    init(viewModel: HistoryViewModel, scrolls: Bool = true, autoload: Bool = true) {
        _viewModel = State(initialValue: viewModel)
        self.scrolls = scrolls
        self.autoload = autoload
    }

    var body: some View {
        Group {
            if scrolls {
                ScrollView { contentBody }
            } else {
                contentBody
            }
        }
        .navigationTitle(Strings.History.title)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task {
            // ストア用スクリーンショットでは、読み込み済みの状態を描く(ImageRenderer が .task を走らせ、
            // 読み込み中の ProgressView が写るのを避ける — issue #80)
            if autoload { await viewModel.load() }
        }
    }

    /// 画面の中身(月の見出し + グリッド)。ScrollView の有無に関係なく同じ
    private var contentBody: some View {
        VStack(spacing: LienSpacing.l) {
            monthHeader
            content
        }
        .padding(LienSpacing.l)
    }

    // MARK: 月の見出し

    private var monthHeader: some View {
        HStack(spacing: LienSpacing.m) {
            Button {
                Task { await viewModel.goPrevious() }
            } label: {
                Image(systemName: "chevron.left")
                    .frame(width: 32, height: 32)
            }
            .disabled(!viewModel.canGoPrevious)
            .accessibilityLabel(Strings.History.previousMonth)

            Text(Strings.History.monthTitle(year: viewModel.month.year, month: viewModel.month.month))
                .font(.headline)
                .frame(maxWidth: .infinity)

            Button {
                Task { await viewModel.goNext() }
            } label: {
                Image(systemName: "chevron.right")
                    .frame(width: 32, height: 32)
            }
            .disabled(!viewModel.canGoNext)
            .accessibilityLabel(Strings.History.nextMonth)
        }
    }

    // MARK: 中身

    @ViewBuilder
    private var content: some View {
        switch viewModel.state {
        case .idle, .loading:
            ProgressView()
                .frame(maxWidth: .infinity, minHeight: 220)
        case .failed:
            failureView
        case .loaded:
            if viewModel.pairStartedOn == nil {
                emptyView
            } else {
                calendarView
            }
        }
    }

    private var calendarView: some View {
        VStack(spacing: LienSpacing.m) {
            weekdayHeader
            LazyVGrid(columns: columns, spacing: LienSpacing.s) {
                ForEach(viewModel.days.indices, id: \.self) { index in
                    if let day = viewModel.days[index] {
                        HistoryDayCell(day: day)
                    } else {
                        Color.clear
                            .frame(height: 48)
                    }
                }
            }
            legend
        }
    }

    private var columns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: LienSpacing.xs), count: Self.columnCount)
    }

    private var weekdayHeader: some View {
        HStack(spacing: 0) {
            ForEach(0..<Strings.History.weekdaySymbols.count, id: \.self) { index in
                Text(Strings.History.weekdaySymbols[index])
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
            }
        }
        .accessibilityHidden(true)
    }

    private var legend: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 112), alignment: .leading)],
            alignment: .leading,
            spacing: LienSpacing.s
        ) {
            legendItem(mark: .bothDone, text: Strings.History.bothDone)
            legendItem(mark: .meOnly, text: Strings.History.meOnly)
            legendItem(mark: .partnerOnly, text: Strings.History.partnerOnly)
            legendItem(mark: .restTicket, text: Strings.History.restTicket)
        }
        .padding(.top, LienSpacing.s)
    }

    private func legendItem(mark: DayMark, text: String) -> some View {
        HStack(spacing: LienSpacing.xs) {
            HistoryMarkView(mark: mark)
                .frame(width: 18, height: 10)
                .accessibilityHidden(true)
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: 空状態・失敗

    private var emptyView: some View {
        VStack(spacing: LienSpacing.s) {
            Image(systemName: "calendar")
                .font(.title2)
                .foregroundStyle(.secondary)
            Text(Strings.History.empty)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, minHeight: 220)
    }

    private var failureView: some View {
        VStack(spacing: LienSpacing.m) {
            Text(Strings.History.loadFailed)
                .font(.footnote)
                .foregroundStyle(LienColors.gentleAlert)
                .multilineTextAlignment(.center)
            Button(Strings.History.retry) {
                Task { await viewModel.retry() }
            }
            .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity, minHeight: 220)
    }
}

// MARK: - 1マス

private struct HistoryDayCell: View {
    let day: HistoryDay

    var body: some View {
        VStack(spacing: LienSpacing.xs) {
            Text("\(day.day)")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(day.isToday ? .primary : .secondary)
            HistoryMarkView(mark: day.mark)
                .frame(height: 10)
        }
        .frame(maxWidth: .infinity, minHeight: 48)
        .padding(.vertical, LienSpacing.xs)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(day.isToday ? LienColors.chipBackground : Color.clear)
        }
        .overlay {
            if day.isToday {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(LienColors.pending.opacity(0.5), lineWidth: 1)
            }
        }
        .opacity(day.mark == .beforePair ? 0.35 : 1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    /// VoiceOver の読み上げ。見た目に文字を出さない日も、状態だけは伝える
    private var accessibilityText: String {
        let date = Strings.History.dayTitle(month: day.month, day: day.day)
        let mark: String
        switch day.mark {
        case .bothDone: mark = Strings.History.bothDone
        case .restTicket: mark = Strings.History.restTicket
        case .meOnly: mark = Strings.History.meOnly
        case .partnerOnly: mark = Strings.History.partnerOnly
        case .noRecord: mark = Strings.History.noRecord
        case .beforePair: mark = Strings.History.beforePair
        case .future: mark = Strings.History.future
        case .todayPending: mark = Strings.History.todayPending
        }
        return Strings.History.dayAccessibility(date, mark)
    }
}

// MARK: - 印(セルと凡例で共有)

/// カレンダーの印。無彩色の中立表現だけを使う(達成=濃い点、お休み=細いカプセル、途切れ=薄い点)
private struct HistoryMarkView: View {
    let mark: DayMark

    var body: some View {
        switch mark {
        case .bothDone:
            dots(me: true, partner: true)
        case .meOnly:
            dots(me: true, partner: false)
        case .partnerOnly:
            dots(me: false, partner: true)
        case .restTicket:
            Capsule()
                .strokeBorder(LienColors.pending, lineWidth: 1)
                .frame(width: 14, height: 8)
        case .noRecord:
            Circle()
                .fill(LienColors.pending.opacity(0.3))
                .frame(width: 4, height: 4)
        case .todayPending:
            Circle()
                .strokeBorder(LienColors.pending.opacity(0.6), lineWidth: 1)
                .frame(width: 8, height: 8)
        case .beforePair, .future:
            Color.clear
                .frame(width: 14, height: 8)
        }
    }

    /// 自分(左)と相手(右)の点。相手だけ・自分だけの日は、位置で区別する
    private func dots(me: Bool, partner: Bool) -> some View {
        HStack(spacing: 3) {
            dot(me)
            dot(partner)
        }
    }

    private func dot(_ filled: Bool) -> some View {
        Circle()
            .fill(filled ? LienColors.historyMark : Color.clear)
            .frame(width: 5, height: 5)
            .overlay {
                if !filled {
                    Circle()
                        .strokeBorder(LienColors.pending.opacity(0.35), lineWidth: 0.5)
                }
            }
    }
}

#if DEBUG
#Preview("History") {
    NavigationStack {
        HistoryView(repository: StubHistoryRepository())
    }
}
#endif
