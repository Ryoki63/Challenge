// ReminderScheduler+Plan.swift — ローカル通知の予約内容を決める純粋関数(REQUIREMENTS §3.12 / T16 #16)
//
// desiredRequests(設定・snapshot・いま・暦)→ 予約すべき通知の一覧。入出力だけで決まり、通知センターにも時計にも触れない
// (テストは日付またぎ・タイムゾーン・夏時間・取り消し条件をここで確かめる)。
//
// 「今日」の判断(取り消し条件)
//   snapshot の todayMeDone / todayPartnerDone は、snapshot を作った日の「今日」の完了。snapshot が今日のものでない(古い)ときは、
//   昨日の「完了」を今日の完了と取り違えないよう、今日は「まだ」とみなす(リマインドは出す)。日付が変わって 1:00 までに
//   作られた snapshot の完了も、前の日のことかもしれないので使わない(TodayCompletion)。
//   「今日の分をもう出さなくてよい」の規則は LocalNotificationCancellation と同じで(NSE と共通)、
//   ここで予約しないものと、そちらが「もう出さなくてよい」とするものは、食い違わない(テストで全状態を確かめている)。
//
// ストリーク危機は StreakRiskPlan(NSE と共通の純粋関数)で決める。リマインドの 14 日ぶんは、アプリの同期だけが予約する
// (NSE は今日の分を取り消すだけ)。毎日の使い方(アプリを開いてチェックインする)なら、開くたびに作り直される。
// アプリを開かない日のストリーク危機は、相手の push を受けた NSE が予約を合わせる(LocalNotificationPushSync)。

import Foundation

extension ReminderScheduler {
    /// 先の何日ぶんまで予約するか(今日を含む)。14 日アプリを開かなければ、その先は届かない
    static let horizonDays = 14
    /// ストリーク危機の時刻(端末のローカル時刻で夜 9 時。文言の「あと3時間」は、ここから日付が変わるまで)
    static let streakRiskHour = StreakRiskPlan.hour
    static let streakRiskMinute = StreakRiskPlan.minute

    /// 予約すべきローカル通知(発火の早い順。同時刻は識別子順)。
    /// 通知は「自分の現役の約束がある」間だけ(約束が無い・snapshot が無いときは空 = すべて取り消す)
    static func desiredRequests(
        prefs: NotificationPreferences,
        snapshot: PairSnapshot?,
        now: Date,
        calendar: Calendar
    ) -> [PlannedNotification] {
        guard let snapshot, snapshot.hasActivePromise else { return [] }
        var planned = reminderRequests(reminder: prefs.reminder, snapshot: snapshot, now: now, calendar: calendar)
        if let streakRisk = StreakRiskPlan.desired(prefs: prefs, snapshot: snapshot, now: now, calendar: calendar) {
            planned.append(streakRisk)
        }
        return planned.sorted { ($0.fireAt, $0.id) < ($1.fireAt, $1.id) }
    }

    // MARK: リマインド

    private static func reminderRequests(
        reminder: ReminderPreference,
        snapshot: PairSnapshot,
        now: Date,
        calendar: Calendar
    ) -> [PlannedNotification] {
        guard case .daily(let hour, let minute) = reminder else { return [] }
        let promiseTitle = (snapshot.myPromiseTitle ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !promiseTitle.isEmpty else { return [] }
        let emoji = (snapshot.myPromiseEmoji ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let meDoneToday = snapshot.todayCompletion(now: now, calendar: calendar)?.me == true
        let bodies = Strings.LocalNotification.reminderBodies(promiseTitle, emoji: emoji)
        let today = calendar.startOfDay(for: now)

        var requests: [PlannedNotification] = []
        for offset in 0..<horizonDays {
            guard
                let day = calendar.date(byAdding: .day, value: offset, to: today),
                let fire = LocalNotificationCalendar.fireDate(on: day, hour: hour, minute: minute, calendar: calendar),
                fire > now // 過ぎた時刻は予約しない
            else { continue }
            if offset == 0 && meDoneToday { continue } // 今日の分は、もう済んでいる
            requests.append(PlannedNotification(
                id: LocalNotificationID.reminder(dayKey: LocalNotificationID.dayKey(for: day, calendar: calendar)),
                fireAt: FireTime(fire, calendar: calendar),
                title: Strings.LocalNotification.title,
                body: bodies[variantIndex(for: day, count: bodies.count, calendar: calendar)]
            ))
        }
        return requests
    }

    /// 文言の候補から、その日の分を選ぶ添字(日付から決まる。同じ日は何度作り直しても同じ言葉 = 予約が付け替わらない)
    private static func variantIndex(for day: Date, count: Int, calendar: Calendar) -> Int {
        guard count > 0 else { return 0 }
        let ordinal = calendar.ordinality(of: .day, in: .era, for: day) ?? 0
        return ((ordinal % count) + count) % count
    }
}
