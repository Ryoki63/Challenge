// LocalNotificationID.swift — 端末のローカル通知(リマインド・ストリーク危機)の識別子と、「もう出さなくてよい」の判定
// (REQUIREMENTS §3.12 / DESIGN §3.3・§4 / T16 #16)
//
// - アプリ本体(ReminderScheduler が予約する)と NSE(相手の push を受けたとき、今日の分の取り消しを試みる)が
//   **同じ規則**を使うので、Lien / LienNSE の 2 ターゲットでソース共有する(project.yml)。Foundation だけに依存させること
//   (NSE は必須理由 API を使わない — PrivacyManifestTests。日時の計算は Calendar だけ)
// - 識別子は日付つき: `lien.local.reminder.2026-10-14` / `lien.local.streak-risk.2026-10-14`。
//   「今日の分」を日付から指せるので、NSE は予約の一覧を読まずに取り消せる
// - 日付はすべて**端末のローカル日**(DESIGN §9-2: 日付計算は date_local)。暦はグレゴリオ暦に固定する
//   (端末の暦が和暦・仏暦でも、年の数え方が変わって日付のキーや通知の日時がずれないように)

import Foundation

// MARK: - 識別子

enum LocalNotificationID {
    /// このアプリが予約するローカル通知の識別子の接頭辞(これで始まるものだけを、アプリが作り・消す)
    static let prefix = "lien.local."
    private static let reminderPrefix = prefix + "reminder."
    private static let streakRiskPrefix = prefix + "streak-risk."

    /// リマインド(約束の remind_at)。dayKey = その日の "yyyy-MM-dd"
    static func reminder(dayKey: String) -> String {
        reminderPrefix + dayKey
    }

    /// ストリーク危機(夜 9 時)
    static func streakRisk(dayKey: String) -> String {
        streakRiskPrefix + dayKey
    }

    static func isOurs(_ identifier: String) -> Bool {
        identifier.hasPrefix(prefix)
    }

    static func isReminder(_ identifier: String) -> Bool {
        identifier.hasPrefix(reminderPrefix)
    }

    static func isStreakRisk(_ identifier: String) -> Bool {
        identifier.hasPrefix(streakRiskPrefix)
    }

    /// calendar のタイムゾーンでの日付 "yyyy-MM-dd"
    static func dayKey(for date: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
}

// MARK: - 暦

enum LocalNotificationCalendar {
    /// グレゴリオ暦+端末の現在のタイムゾーン。呼ぶたびに作る(旅行・タイムゾーンの変更に追従する)
    static func current() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone.current
        return calendar
    }
}

// MARK: - snapshot が「今日」のものか

extension PairSnapshot {
    /// この snapshot が、`now` の日(端末のローカル日)のものか。`todayMeDone` / `todayPartnerDone` は snapshot を作った日の
    /// 「今日」の完了なので、前の日の snapshot の「完了」を今日の完了と取り違えないために使う
    func reflectsToday(now: Date, calendar: Calendar) -> Bool {
        calendar.isDate(updatedAt, inSameDayAs: now)
    }
}

// MARK: - 取り消し条件(アプリの同期と NSE で共通)

enum LocalNotificationCancellation {
    /// snapshot から見て、**今日の分のうち、もう出さなくてよい**ローカル通知の識別子。
    ///   - リマインド: 自分が今日すでに完了している
    ///   - ストリーク危機: ふたりとも完了した / ペアがない(解消された)
    /// snapshot が今日のもの(reflectsToday)でなければ、何も言えないので空。
    /// ReminderScheduler.desiredRequests は、ここに挙がる識別子を**予約しない**(両者が食い違わないことをテストが確かめる)
    static func staleIDsForToday(snapshot: PairSnapshot, now: Date, calendar: Calendar) -> [String] {
        guard snapshot.reflectsToday(now: now, calendar: calendar) else { return [] }
        let today = LocalNotificationID.dayKey(for: now, calendar: calendar)
        var identifiers: [String] = []
        if snapshot.todayMeDone {
            identifiers.append(LocalNotificationID.reminder(dayKey: today))
        }
        if snapshot.pairId == nil || (snapshot.todayMeDone && snapshot.todayPartnerDone) {
            identifiers.append(LocalNotificationID.streakRisk(dayKey: today))
        }
        return identifiers
    }

    /// アプリが前面にいるときに届いたローカル通知を、出さずに捨ててよいか(NSE が取り消せなかった場合の、最後の網。
    /// 前面にいないときは出してしまう — ReminderScheduler のコメント「取り消せなかったとき」)
    static func shouldSuppress(
        identifier: String,
        snapshot: PairSnapshot?,
        now: Date,
        calendar: Calendar
    ) -> Bool {
        guard LocalNotificationID.isOurs(identifier), let snapshot else { return false }
        return staleIDsForToday(snapshot: snapshot, now: now, calendar: calendar).contains(identifier)
    }
}
