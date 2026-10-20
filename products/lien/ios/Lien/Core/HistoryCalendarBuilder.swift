// HistoryCalendarBuilder.swift — 月グリッドの状態判定(T18 / REQUIREMENTS §3.11)
//
// 判定の正本はサーバーの close-day(_shared/streak.ts / DESIGN §5.4)に合わせる:
//   1. ペア成立日より前 → .beforePair(判定対象外)
//   2. 未来 → .future
//   3. 今日 → チェックイン状況のプレビュー(確定は明日の close-day)
//   4. 昨日まで → streak_days の行だけを信じる。both → .bothDone / ticket → .restTicket /
//      行が無い → .noRecord(途切れ)
//
// 例外は 0:00〜1:00 の「昨日」だけ。close-day(00:10 JST)がまだ動いていない時間帯に
// 昨日の行が無く、2人ともチェックインしているなら、close-day は必ず both を書くので
// 先に見せる(DESIGN §5.4「昨日の仮判定」。スナップショットのプレビューと同じ窓)。
// 片方だけの日はチケット残数が分からないため先取りしない(確定した行だけを信じる)。
//
// このファイルは純粋関数だけを持ち、通信・時計・タイムゾーンに依存しない
// (Calendar と today を注入する。テストは Asia/Tokyo の暦で固定する)。

import Foundation

enum HistoryCalendarBuilder {
    /// close-day の確定を待つ時間(時)。DESIGN §5.4 の CLOSE_DAY_SETTLE_HOUR と同じ
    static let closeDaySettleHour = 1

    /// 月グリッドを作る。先頭は週の先頭(calendar.firstWeekday)までの nil パディング
    static func buildMonth(
        _ month: HistoryMonth,
        calendar: Calendar = .lienHistory,
        today: Date,
        data: MonthHistoryData
    ) -> [HistoryDay?] {
        let todayLocal = HistoryDate.string(from: today, calendar: calendar)
        let yesterdayDate = calendar.date(byAdding: .day, value: -1, to: today) ?? today
        let yesterdayLocal = HistoryDate.string(from: yesterdayDate, calendar: calendar)
        // close-day が確定する前の時間帯(0:00〜1:00)だけ、昨日をプレビューする
        let isBeforeCloseDay = calendar.component(.hour, from: today) < closeDaySettleHour

        let firstDate = month.firstDate(calendar: calendar)
        let leading = (calendar.component(.weekday, from: firstDate) - calendar.firstWeekday + 7) % 7
        var cells: [HistoryDay?] = Array(repeating: nil, count: leading)
        // 壊れた started_on で全月を「成立前」にしない(読めない値は境界なしとして扱う)
        let pairStartedOn = data.pairStartedOn.flatMap {
            HistoryDate.date(from: $0, calendar: calendar) == nil ? nil : $0
        }
        var data = data
        data.pairStartedOn = pairStartedOn

        for day in 1...month.dayCount(calendar: calendar) {
            guard let date = calendar.date(
                from: DateComponents(year: month.year, month: month.month, day: day, hour: 12)
            ) else { continue }
            let dateLocal = HistoryDate.string(from: date, calendar: calendar)
            let mark = mark(
                dateLocal: dateLocal,
                todayLocal: todayLocal,
                yesterdayLocal: yesterdayLocal,
                isBeforeCloseDay: isBeforeCloseDay,
                data: data
            )
            cells.append(
                HistoryDay(
                    date: date,
                    dateLocal: dateLocal,
                    year: month.year,
                    month: month.month,
                    day: day,
                    mark: mark,
                    isToday: dateLocal == todayLocal
                )
            )
        }
        return cells
    }

    /// 年・月を直接渡す版(issue #18 の実装計画と同じ形)
    static func buildMonth(
        year: Int,
        month: Int,
        calendar: Calendar = .lienHistory,
        today: Date,
        pairStartedOn: String?,
        data: MonthHistoryData
    ) -> [HistoryDay?] {
        var data = data
        data.pairStartedOn = pairStartedOn
        return buildMonth(
            HistoryMonth(year: year, month: month),
            calendar: calendar,
            today: today,
            data: data
        )
    }

    // MARK: - 1日の判定

    private static func mark(
        dateLocal: String,
        todayLocal: String,
        yesterdayLocal: String,
        isBeforeCloseDay: Bool,
        data: MonthHistoryData
    ) -> DayMark {
        if let startedOn = data.pairStartedOn, dateLocal < startedOn {
            return .beforePair
        }
        if dateLocal > todayLocal {
            return .future
        }
        if dateLocal == todayLocal {
            return todayMark(data: data, dateLocal: dateLocal)
        }
        if let kind = data.streakDays[dateLocal] {
            return kind == .both ? .bothDone : .restTicket
        }
        // 0:00〜1:00 の昨日だけ: 両者チェックイン済みなら close-day は both を書く
        if isBeforeCloseDay,
           dateLocal == yesterdayLocal,
           data.myCheckinDays.contains(dateLocal),
           data.partnerCheckinDays.contains(dateLocal) {
            return .bothDone
        }
        // 確定済みの日に streak_days の行が無い = 途切れた日。
        // チェックインが片方だけ・両方あっても、確定前のプレビュー以外では行を推測しない
        return .noRecord
    }

    private static func todayMark(data: MonthHistoryData, dateLocal: String) -> DayMark {
        let me = data.myCheckinDays.contains(dateLocal)
        let partner = data.partnerCheckinDays.contains(dateLocal)
        switch (me, partner) {
        case (true, true): return .bothDone
        case (true, false): return .meOnly
        case (false, true): return .partnerOnly
        case (false, false): return .todayPending
        }
    }
}
