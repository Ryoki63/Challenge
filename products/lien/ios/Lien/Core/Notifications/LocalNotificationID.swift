// LocalNotificationID.swift — 端末のローカル通知(リマインド・ストリーク危機)の識別子と、日付・「今日の完了」・「もう出さなくてよい」の規則
// (REQUIREMENTS §3.12 / DESIGN §3.3・§4 / T16 #16)
//
// - アプリ本体(ReminderScheduler が予約する)と NSE(相手の push を受けたとき、ストリーク危機の予約を合わせ、
//   今日の分の取り消しを行う — LocalNotificationPushSync)が**同じ規則**を使うので、Lien / LienNSE の 2 ターゲットで
//   ソース共有する(project.yml)。Foundation だけに依存させること(NSE は必須理由 API を使わない — PrivacyManifestTests。
//   日時の計算は Calendar だけ)
// - 識別子は日付つき: `lien.local.reminder.2026-10-14` / `lien.local.streak-risk.2026-10-14`。
//   「今日の分」を日付から指せる(今日の分だけを取り消す・配信済みの通知から今日の分を外す)
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

    /// day(その日のどの時刻でもよい)の hour:minute。夏時間で存在しない時刻は、その日の次の有効な時刻になる。
    /// 日付が動いてしまうとき(通常は無い)は nil
    static func fireDate(on day: Date, hour: Int, minute: Int, calendar: Calendar) -> Date? {
        guard let fire = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day),
              calendar.isDate(fire, inSameDayAs: day)
        else { return nil }
        return fire
    }

    /// サーバーが、前の日の確定(close-day)を終えたとみなす時刻(その日の何時か)。サーバーの `CLOSE_DAY_SETTLE_HOUR`
    /// (supabase/functions/_shared/snapshot.ts)と同じ値。cron は 00:10 だが、遅れや再試行を見込んで 1:00 とする。
    /// これより前に組み立てた snapshot の「今日」は、クライアントが送った日付(checkin・checkin-cancel・nudge の
    /// `dateLocal`)で上書きされていることがあり、前の日のことかもしれない(→ `PairSnapshot.completionOnItsOwnDay`)
    static let snapshotSettleHour = 1
}

// MARK: - snapshot が「今日」のものか・今日の完了

/// snapshot が教えてくれる、ある日の自分と相手の完了
struct TodayCompletion: Equatable {
    let me: Bool
    let partner: Bool

    var both: Bool { me && partner }
}

extension PairSnapshot {
    /// この snapshot が、`now` の日(端末のローカル日)に作られたものか。`todayMeDone` / `todayPartnerDone` は snapshot を作った日の
    /// 「今日」の完了なので、前の日の snapshot の「完了」を今日の完了と取り違えないために使う
    func reflectsToday(now: Date, calendar: Calendar) -> Bool {
        calendar.isDate(updatedAt, inSameDayAs: now)
    }

    /// この snapshot が作られた日(`updatedAt` のローカル日)の、自分と相手の完了。**確かなときだけ**値を返す。
    ///
    /// サーバーは、checkin・checkin-cancel・nudge の snapshot を、クライアントが送った日付を「今日」として組み立てる
    /// (深夜 0 時前後の時計のずれや、送信キューの再送を吸収するため。相手へ送る snapshot も同じ)。その日付は、翌日の 1:00 に
    /// なるまで有効なので、**日付が変わって 1:00 までの間に作られた snapshot の完了フラグは、前の日のこと**かもしれない
    /// (たとえば 23:58 に圏外で押したチェックインが、0:07 に届く)。それを「今日の完了」と読むと、今日のリマインドを
    /// 取り消し、ストリーク危機を明日に回してしまう。そこでこの間のものは「不明」(nil)として、完了を前提にしない。
    /// 日付をサーバーが snapshot に載せるようになれば(`dateLocal`)、この判定は要らなくなる
    func completionOnItsOwnDay(calendar: Calendar) -> TodayCompletion? {
        let hour = calendar.component(.hour, from: updatedAt)
        guard hour >= LocalNotificationCalendar.snapshotSettleHour else { return nil }
        return TodayCompletion(me: todayMeDone, partner: todayPartnerDone)
    }

    /// `now` の日の、自分と相手の完了。snapshot が今日のものでないとき・完了が確かでないとき(上の説明)は nil
    func todayCompletion(now: Date, calendar: Calendar) -> TodayCompletion? {
        guard reflectsToday(now: now, calendar: calendar) else { return nil }
        return completionOnItsOwnDay(calendar: calendar)
    }
}

// MARK: - 取り消し条件(アプリの同期と NSE で共通)

enum LocalNotificationCancellation {
    /// snapshot から見て、**今日の分のうち、もう出さなくてよい**ローカル通知の識別子。
    ///   - リマインド: 自分が今日すでに完了している
    ///   - ストリーク危機: ふたりとも完了した / ペアがない(解消された)/ ふたりの記録が続いていない(ストリークが 0)
    /// snapshot が今日のもの(reflectsToday)でなければ、何も言えないので空。完了が確かでない(日付が変わって間もない)ときは、
    /// 完了を理由にした取り消しはしない(TodayCompletion)。
    /// ReminderScheduler.desiredRequests は、ここに挙がる識別子を**予約しない**(両者が食い違わないことをテストが確かめる)
    static func staleIDsForToday(snapshot: PairSnapshot, now: Date, calendar: Calendar) -> [String] {
        guard snapshot.reflectsToday(now: now, calendar: calendar) else { return [] }
        let today = LocalNotificationID.dayKey(for: now, calendar: calendar)
        let completion = snapshot.todayCompletion(now: now, calendar: calendar)
        var identifiers: [String] = []
        if completion?.me == true {
            identifiers.append(LocalNotificationID.reminder(dayKey: today))
        }
        if snapshot.pairId == nil || snapshot.streakCurrent <= 0 || completion?.both == true {
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
