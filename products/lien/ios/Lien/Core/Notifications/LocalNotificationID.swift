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

    /// dayKey("yyyy-MM-dd"。桁は固定)を、calendar のタイムゾーンでのその日の 0:00 に戻す。形が違う・存在しない日
    /// (2026-02-31 など、暦が繰り上げて別の日になるもの)は nil。"2026-1-5" のような桁の足りない書き方も受けない
    /// (サーバーの date_local はゼロ埋めされた 10 文字 — DESIGN §9)
    static func date(fromDayKey dayKey: String, calendar: Calendar) -> Date? {
        let parts = dayKey.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3,
              parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              parts.allSatisfy({ $0.allSatisfy { $0.isASCII && $0.isNumber } }),
              let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2])
        else { return nil }
        let components = DateComponents(year: year, month: month, day: day)
        guard let date = calendar.date(from: components) else { return nil }
        let roundTrip = calendar.dateComponents([.year, .month, .day], from: date)
        guard roundTrip.year == year, roundTrip.month == month, roundTrip.day == day else { return nil }
        return date
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
    /// `dateLocal`)で上書きされていることがあり、前の日のことかもしれない(→ `PairSnapshot.completionOnItsOwnDay`)。
    /// サーバーが snapshot に `dateLocal` を載せるようになった(2026-10-20・issue #72)ので、この値を使うのは
    /// **キーが無い古いサーバー**の snapshot だけ
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
    /// サーバーが載せた「組み立てに使った今日」(`dateLocal`)を、端末の暦でのその日の 0:00 にしたもの。
    /// 無い(古いサーバー・古いキャッシュ)・null・読めない値("yyyy-MM-dd" でない・存在しない日)は nil。
    /// そのときは `updatedAt` から保守的に判定する(= 古いサーバーの snapshot と同じ扱い)
    func serverDay(calendar: Calendar) -> Date? {
        guard let dateLocal else { return nil }
        return LocalNotificationID.date(fromDayKey: dateLocal, calendar: calendar)
    }

    /// この snapshot の完了フラグ(`todayMeDone` / `todayPartnerDone`)が属する日(端末のローカル日の 0:00)。
    /// サーバーが組み立てに使った「今日」(`dateLocal`)があればその日、無ければ(古いサーバー・古いキャッシュ)
    /// `updatedAt` のローカル日
    func snapshotDay(calendar: Calendar) -> Date {
        serverDay(calendar: calendar) ?? calendar.startOfDay(for: updatedAt)
    }

    /// `now` のローカル日から見て、この snapshot の完了が属する日が何日前か(0 = 今日 / 1 = 昨日 / 負 = 未来)。
    /// 日付の差は暦で数える(夏時間で 1 日が 23/25 時間でも 1 日と数える)
    func daysSinceSnapshotDay(now: Date, calendar: Calendar) -> Int? {
        calendar.dateComponents([.day], from: snapshotDay(calendar: calendar), to: calendar.startOfDay(for: now)).day
    }

    /// この snapshot が、`now` の日(端末のローカル日)のものか。`todayMeDone` / `todayPartnerDone` は snapshot の
    /// 「今日」の完了なので、前の日の snapshot の「完了」を今日の完了と取り違えないために使う。
    /// サーバーの `dateLocal`(組み立てに使った「今日」)があればその日で、無ければ `updatedAt` のローカル日で判定する
    func reflectsToday(now: Date, calendar: Calendar) -> Bool {
        daysSinceSnapshotDay(now: now, calendar: calendar) == 0
    }

    /// この snapshot の完了が属する日(`dateLocal`)の、自分と相手の完了。**確かなときだけ**値を返す。
    ///
    /// `todayMeDone` / `todayPartnerDone` が**どの日の**完了かは、`updatedAt`(組み立てた時刻)からは決まらない:
    /// サーバーは、checkin・checkin-cancel・nudge の snapshot を、クライアントが送った日付を「今日」として組み立てる
    /// (深夜 0 時前後の時計のずれや、送信キューの再送を吸収するため。相手へ送る snapshot も同じ)。その日付は、翌日の
    /// 1:00 になるまで有効なので、**日付が変わって 1:00 までの間に組み立てられた snapshot の完了フラグは、前の日の
    /// こと**かもしれない(たとえば 23:58 に圏外で押したチェックインが、0:07 に届く)。
    /// そこでサーバーは組み立てに使った「今日」を `dateLocal` に載せる(2026-10-20・issue #72)。このキーがあれば、
    /// 完了がどの日のものかは**確か**なので、0:00〜1:00 でも「不明」にしない(その時間帯に自分でチェックインした人の、
    /// その日のリマインドが、済んでいるのに残るのを直す)。キーが無い(読めない)古いサーバーの snapshot だけ、
    /// 時刻から保守的に判定する
    func completionOnItsOwnDay(calendar: Calendar) -> TodayCompletion? {
        guard serverDay(calendar: calendar) == nil else {
            return TodayCompletion(me: todayMeDone, partner: todayPartnerDone)
        }
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
    /// snapshot が今日のもの(reflectsToday)でなければ、何も言えないので空。完了が確かでない(キーが無い古いサーバーの
    /// snapshot で、日付が変わって間もない)ときは、完了を理由にした取り消しはしない(TodayCompletion)。
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
