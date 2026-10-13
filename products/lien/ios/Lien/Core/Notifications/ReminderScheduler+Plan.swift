// ReminderScheduler+Plan.swift — ローカル通知の予約内容を決める純粋関数(REQUIREMENTS §3.12 / T16 #16)
//
// desiredRequests(設定・snapshot・いま・暦)→ 予約すべき通知の一覧。入出力だけで決まり、通知センターにも時計にも触れない
// (テストは日付またぎ・タイムゾーン・夏時間・取り消し条件をここで確かめる)。
//
// 「今日」の判断(取り消し条件)
//   snapshot の todayMeDone / todayPartnerDone は、snapshot を作った日の「今日」の完了。snapshot が今日のものでない(古い)ときは、
//   昨日の「完了」を今日の完了と取り違えないよう、今日は「まだ」とみなす(リマインドは出す)。
//   「今日の分をもう出さなくてよい」の規則は LocalNotificationCancellation と同じで(NSE と共通)、
//   ここで予約しないものと、そちらが「もう出さなくてよい」とするものは、食い違わない(テストで全状態を確かめている)。
//
// ストリーク危機は、「記録が確かに続いていると分かる日」にしか予約しない
//   ストリークは、1 日でも抜けるとリセットされる(お休みチケットで守られない限り)。何日も先の夜 9 時に「ふたりの N 日」と
//   出すのは、その日までふたりが続けた場合の話で、アプリを開かないまま途切れた記録について通知してしまう。そこで:
//     - snapshot が今日のもの: 今日(まだふたりそろっていなければ)。今日すでにふたりそろっていれば、**明日**(記録は続いていく)
//     - snapshot が昨日のもの(同期できないまま日をまたいだ)で、昨日ふたりそろっていた: 今日(昨日までの記録が続いている)
//     - それ以外(2 日以上前・日付が先・ふたりそろった日が分からない)は予約しない
//   毎日の使い方(アプリを開いてチェックインする)なら、開くたびに作り直されるので、これで足りる。

import Foundation

extension ReminderScheduler {
    /// 先の何日ぶんまで予約するか(今日を含む)。14 日アプリを開かなければ、その先は届かない
    static let horizonDays = 14
    /// ストリーク危機の時刻(端末のローカル時刻で夜 9 時。文言の「あと3時間」は、ここから日付が変わるまで)
    static let streakRiskHour = 21
    static let streakRiskMinute = 0

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
        if prefs.streakRiskEnabled {
            planned += streakRiskRequests(snapshot: snapshot, now: now, calendar: calendar)
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
        let meDoneToday = snapshot.reflectsToday(now: now, calendar: calendar) && snapshot.todayMeDone
        let bodies = Strings.LocalNotification.reminderBodies(promiseTitle, emoji: emoji)
        let today = calendar.startOfDay(for: now)

        var requests: [PlannedNotification] = []
        for offset in 0..<horizonDays {
            guard
                let day = calendar.date(byAdding: .day, value: offset, to: today),
                let fire = fireDate(on: day, hour: hour, minute: minute, calendar: calendar),
                fire > now // 過ぎた時刻は予約しない
            else { continue }
            if offset == 0 && meDoneToday { continue } // 今日の分は、もう済んでいる
            requests.append(PlannedNotification(
                id: LocalNotificationID.reminder(dayKey: LocalNotificationID.dayKey(for: day, calendar: calendar)),
                fireAt: fireTime(fire, calendar: calendar),
                title: Strings.LocalNotification.title,
                body: bodies[variantIndex(for: day, count: bodies.count, calendar: calendar)]
            ))
        }
        return requests
    }

    // MARK: ストリーク危機

    /// 文言の出し分け(自分と相手の、その日の完了の組み合わせ)
    private enum StreakRiskSituation {
        case neither
        case partnerDone
        case meDone
    }

    private static func streakRiskRequests(
        snapshot: PairSnapshot,
        now: Date,
        calendar: Calendar
    ) -> [PlannedNotification] {
        // ペアのストリークがある(続いている日数が 1 以上)ときだけ
        guard snapshot.pairId != nil, snapshot.streakCurrent > 0 else { return [] }
        let today = calendar.startOfDay(for: now)
        let snapshotDay = calendar.startOfDay(for: snapshot.updatedAt)
        guard let daysSinceSnapshot = calendar.dateComponents([.day], from: snapshotDay, to: today).day else { return [] }
        let bothDone = snapshot.todayMeDone && snapshot.todayPartnerDone

        // (今日から数えた日, 文言の出し分け)
        let target: (offset: Int, situation: StreakRiskSituation)?
        switch daysSinceSnapshot {
        case 0: // snapshot は今日のもの
            if bothDone {
                target = (1, .neither) // 今日はふたりそろった。記録は明日へ続く
            } else if snapshot.todayMeDone {
                target = (0, .meDone)
            } else if snapshot.todayPartnerDone {
                target = (0, .partnerDone)
            } else {
                target = (0, .neither)
            }
        case 1: // 同期できないまま日をまたいだ。昨日ふたりそろっていたなら、昨日までの記録が続いている
            target = bothDone ? (0, .neither) : nil
        default:
            target = nil
        }
        guard
            let target,
            let day = calendar.date(byAdding: .day, value: target.offset, to: today),
            let fire = fireDate(on: day, hour: streakRiskHour, minute: streakRiskMinute, calendar: calendar),
            fire > now
        else { return [] }

        return [PlannedNotification(
            id: LocalNotificationID.streakRisk(dayKey: LocalNotificationID.dayKey(for: day, calendar: calendar)),
            fireAt: fireTime(fire, calendar: calendar),
            title: Strings.LocalNotification.title,
            body: streakRiskBody(situation: target.situation, snapshot: snapshot)
        )]
    }

    private static func streakRiskBody(situation: StreakRiskSituation, snapshot: PairSnapshot) -> String {
        let days = snapshot.streakCurrent
        let partner = (snapshot.partnerName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let partnerName = partner.isEmpty ? Strings.Home.partnerFallbackLabel : partner
        switch situation {
        case .neither:
            return Strings.LocalNotification.streakRiskNeither(days: days)
        case .partnerDone:
            return Strings.LocalNotification.streakRiskPartnerDone(partnerName: partnerName, days: days)
        case .meDone:
            return Strings.LocalNotification.streakRiskMeDone(partnerName: partnerName, days: days)
        }
    }

    // MARK: 日時

    /// day(その日のどの時刻でもよい)の hour:minute。夏時間で存在しない時刻は、その日の次の有効な時刻になる。
    /// 日付が動いてしまうとき(通常は無い)は nil
    private static func fireDate(on day: Date, hour: Int, minute: Int, calendar: Calendar) -> Date? {
        guard let fire = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day),
              calendar.isDate(fire, inSameDayAs: day)
        else { return nil }
        return fire
    }

    private static func fireTime(_ date: Date, calendar: Calendar) -> FireTime {
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        return FireTime(
            year: parts.year ?? 0,
            month: parts.month ?? 0,
            day: parts.day ?? 0,
            hour: parts.hour ?? 0,
            minute: parts.minute ?? 0,
            timeZoneIdentifier: calendar.timeZone.identifier
        )
    }

    /// 文言の候補から、その日の分を選ぶ添字(日付から決まる。同じ日は何度作り直しても同じ言葉 = 予約が付け替わらない)
    private static func variantIndex(for day: Date, count: Int, calendar: Calendar) -> Int {
        guard count > 0 else { return 0 }
        let ordinal = calendar.ordinality(of: .day, in: .era, for: day) ?? 0
        return ((ordinal % count) + count) % count
    }
}
