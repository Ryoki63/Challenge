// HistoryModels.swift — カレンダー履歴のモデル(T18 / REQUIREMENTS §3.11)
//
// 正本はサーバー(DESIGN §5.4):
//   - 「日 d のふたり達成」= ペア両メンバーに date_local = d の checkin があること
//   - streak_days(pair_id, d, kind) に行があれば「d は継続日」(kind = both | ticket)
//   - close-day が確定するのは昨日まで。今日はチェックイン状況からプレビューする
//
// 日付はサーバーと同じ date_local("YYYY-MM-DD")で扱う。端末のタイムゾーンや
// ロケールで日付がずれないよう、Date への変換は必ず Calendar.lienHistory(Asia/Tokyo)を通す。
// このファイルは Foundation だけに依存させる(LienTests が macOS でも読む)。

import Foundation

/// streak_days.kind(DESIGN §5.4)
enum StreakDayKind: String, Equatable, Sendable {
    /// 2人ともその日の約束をチェックインした日
    case both
    /// 片方(または両方)が未達だったが、お休みチケットで守られた日
    case ticket
}

/// カレンダーの1日につける印(REQUIREMENTS §3.11)
///
/// 確定済みの日(昨日まで)は streak_days の行だけを信じる:
///   - both 行 → .bothDone / ticket 行 → .restTicket
///   - 行が無い → .noRecord(途切れた日)。罰なしのため、画面では無彩色の点だけを出す
/// 今日は close-day の確定前なので、チェックイン状況からプレビューする。
enum DayMark: Equatable, Sendable {
    /// ふたり達成(streak_days.kind = both)
    case bothDone
    /// お休みチケットで守られた日(streak_days.kind = ticket)
    case restTicket
    /// 自分だけチェックインしている(今日のプレビュー)
    case meOnly
    /// 相手だけチェックインしている(今日のプレビュー)
    case partnerOnly
    /// 確定済みなのに streak_days に行が無い日(途切れ)。表示は中立の点だけ
    case noRecord
    /// ペア成立前(判定対象外 — DESIGN §5.4)
    case beforePair
    /// 未来の日
    case future
    /// 今日で、まだ誰もチェックインしていない
    case todayPending
}

/// カレンダーの1マス
struct HistoryDay: Equatable, Identifiable, Sendable {
    /// その日の正午(表示・曜日の計算用。日付の判定には dateLocal を使う)
    let date: Date
    /// サーバーと同じ "YYYY-MM-DD"
    let dateLocal: String
    let year: Int
    let month: Int
    let day: Int
    let mark: DayMark
    /// 今日のマスか(今日のリングを出す)
    let isToday: Bool

    var id: String { dateLocal }
}

/// 1か月分の履歴データ(HistoryRepository が返す)
struct MonthHistoryData: Equatable, Sendable {
    /// ペア成立日("YYYY-MM-DD")。nil = ペアが無い(判定対象外)
    var pairStartedOn: String?
    /// 自分のチェックイン日
    var myCheckinDays: Set<String>
    /// 相手のチェックイン日
    var partnerCheckinDays: Set<String>
    /// streak_days の確定行(date_local → kind)
    var streakDays: [String: StreakDayKind]

    init(
        pairStartedOn: String? = nil,
        myCheckinDays: Set<String> = [],
        partnerCheckinDays: Set<String> = [],
        streakDays: [String: StreakDayKind] = [:]
    ) {
        self.pairStartedOn = pairStartedOn
        self.myCheckinDays = myCheckinDays
        self.partnerCheckinDays = partnerCheckinDays
        self.streakDays = streakDays
    }

    static let empty = MonthHistoryData()
}

/// 表示する月(年・月)。前月/翌月の移動と、ペア成立月〜当月のクランプに使う
struct HistoryMonth: Hashable, Comparable, Sendable {
    let year: Int
    let month: Int

    init(year: Int, month: Int) {
        precondition((1...12).contains(month), "month は 1〜12: \(month)")
        self.year = year
        self.month = month
    }

    /// "YYYY-MM-DD" の年月(不正な文字列は nil)
    init?(dateLocal: String) {
        guard dateLocal.count >= 7 else { return nil }
        let prefix = String(dateLocal.prefix(7))
        let parts = prefix.split(separator: "-", omittingEmptySubsequences: false)
        guard
            parts.count == 2,
            parts[0].count == 4,
            parts[1].count == 2,
            let year = Int(parts[0]),
            let month = Int(parts[1]),
            (1...12).contains(month)
        else { return nil }
        self.init(year: year, month: month)
    }

    /// date(カレンダーのタイムゾーン)を含む月
    static func containing(_ date: Date, calendar: Calendar) -> HistoryMonth {
        let components = calendar.dateComponents([.year, .month], from: date)
        return HistoryMonth(year: components.year ?? 1970, month: components.month ?? 1)
    }

    static func < (lhs: HistoryMonth, rhs: HistoryMonth) -> Bool {
        (lhs.year, lhs.month) < (rhs.year, rhs.month)
    }

    var previous: HistoryMonth {
        month == 1 ? HistoryMonth(year: year - 1, month: 12) : HistoryMonth(year: year, month: month - 1)
    }

    var next: HistoryMonth {
        month == 12 ? HistoryMonth(year: year + 1, month: 1) : HistoryMonth(year: year, month: month + 1)
    }

    /// 月の1日(正午。夏時間の境界でも曜日がずれないようにする)
    func firstDate(calendar: Calendar) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: 1, hour: 12))
            ?? Date(timeIntervalSince1970: 0)
    }

    /// その月の日数(うるう年も Calendar に任せる)
    func dayCount(calendar: Calendar) -> Int {
        calendar.range(of: .day, in: .month, for: firstDate(calendar: calendar))?.count ?? 31
    }

    /// PostgREST の date_local 範囲(両端を含む)
    func dateLocalRange(calendar: Calendar) -> (first: String, last: String) {
        let last = dayCount(calendar: calendar)
        return (
            String(format: "%04d-%02d-01", year, month),
            String(format: "%04d-%02d-%02d", year, month, last)
        )
    }
}

/// date_local("YYYY-MM-DD")と Date の変換。端末のタイムゾーンに依存させない
enum HistoryDate {
    /// Date → "YYYY-MM-DD"(calendar のタイムゾーンで数える)
    static func string(from date: Date, calendar: Calendar) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(
            format: "%04d-%02d-%02d",
            components.year ?? 1970,
            components.month ?? 1,
            components.day ?? 1
        )
    }

    /// "YYYY-MM-DD" → その日の正午。形式・実在しない日付は nil
    static func date(from dateLocal: String, calendar: Calendar) -> Date? {
        let parts = dateLocal.split(separator: "-", omittingEmptySubsequences: false)
        guard
            parts.count == 3,
            parts[0].count == 4,
            parts[1].count == 2,
            parts[2].count == 2,
            let year = Int(parts[0]),
            let month = Int(parts[1]),
            let day = Int(parts[2]),
            (1...12).contains(month),
            day >= 1,
            let date = calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 12))
        else { return nil }
        // 2026-02-30 のような存在しない日付を弾く(Calendar は繰り上げる)
        let check = calendar.dateComponents([.year, .month, .day], from: date)
        guard check.year == year, check.month == month, check.day == day else { return nil }
        return date
    }
}

extension Calendar {
    /// 履歴の日付を数える暦。アプリの既定(Asia/Tokyo)に固定し、週の先頭は日曜にする
    /// (端末のロケール・タイムゾーンで「今日」や曜日の並びが変わらないようにする)
    static var lienHistory: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "ja_JP")
        calendar.timeZone = TimeZone(identifier: "Asia/Tokyo") ?? TimeZone(secondsFromGMT: 9 * 60 * 60)!
        calendar.firstWeekday = 1
        return calendar
    }
}
