// StreakRiskPlan.swift — 夜 9 時のストリーク危機の計画(純粋関数。REQUIREMENTS §3.5・§3.12 / T16 #16)
//
// いまの snapshot から、予約すべきストリーク危機の通知を **0 件か 1 件** 決める。入出力だけで決まり、通知センターにも時計にも触れない。
// アプリの同期(ReminderScheduler.desiredRequests)と、相手の push を受けた NSE(LocalNotificationPushSync)が**同じ関数**を使う
// (Lien / LienNSE の 2 ターゲットでソース共有する — project.yml。Foundation だけに依存させること)。
//
// なぜ NSE も使うのか
//   この通知は、「アプリを開くのを忘れた日」のための通知。ところが予約はアプリの同期の中でしかできないと、
//   ①前の日に先にチェックインした人が、相手のあとにアプリを開かなかった ②お休みチケットで守られた翌日(close-day の
//   push は NSE だけが受ける)に、その日の分が無い。そこで、相手の push(snapshot を運ぶ)を受けた NSE も、この関数で
//   予約を合わせる(足りないものを足し、古いものを消す)。アプリの同期と NSE は、同じ snapshot から同じ答えを出す。
//
// 「記録が確かに続いていると分かる日」にしか予約しない
//   ストリークは、1 日でも抜けるとリセットされる(お休みチケットで守られない限り)。何日も先の夜 9 時に「ふたりの N 日」と
//   出すのは、その日までふたりが続けた場合の話で、アプリを開かないまま途切れた記録について通知してしまう。そこで:
//     - snapshot が今日のもの: 今日(まだふたりそろっていなければ)。今日すでにふたりそろっていれば、**明日**(記録は続いていく)
//     - snapshot が昨日のもの(同期できないまま日をまたいだ)で、昨日ふたりそろっていた: 今日(昨日までの記録が続いている)
//     - それ以外(2 日以上前・日付が先・ふたりそろった日が分からない・ストリークが 0)は予約しない
//   完了の組み合わせが確かでないとき(日付が変わって 1:00 までに作られた snapshot — TodayCompletion)は、完了を前提にせず、
//   「どちらも未完」の言い方で今日の分を予約する。

import Foundation

enum StreakRiskPlan {
    /// 時刻(端末のローカル時刻で夜 9 時。文言の「あと3時間」は、ここから日付が変わるまで)
    static let hour = 21
    static let minute = 0

    /// 文言の出し分け(自分と相手の、その日の完了の組み合わせ)
    enum Situation: Equatable {
        case neither
        case partnerDone
        case meDone
    }

    /// どの日の夜 9 時に、どの言い方で出すか(dayOffset: 今日から数えた日。0 = 今日 / 1 = 明日)
    struct Target: Equatable {
        let dayOffset: Int
        let situation: Situation
    }

    // MARK: 計画

    /// 設定(ストリーク危機のオン・オフ)・現役の約束・snapshot を踏まえて、予約すべき 1 件(無ければ nil)
    static func desired(
        prefs: NotificationPreferences,
        snapshot: PairSnapshot?,
        now: Date,
        calendar: Calendar
    ) -> PlannedNotification? {
        guard prefs.streakRiskEnabled, let snapshot, snapshot.hasActivePromise else { return nil }
        return notification(snapshot: snapshot, now: now, calendar: calendar)
    }

    /// 設定を見ずに、snapshot だけから決めた予約(夜 9 時を過ぎていれば nil)
    static func notification(snapshot: PairSnapshot, now: Date, calendar: Calendar) -> PlannedNotification? {
        guard
            let target = target(snapshot: snapshot, now: now, calendar: calendar),
            let day = calendar.date(byAdding: .day, value: target.dayOffset, to: calendar.startOfDay(for: now)),
            let fire = LocalNotificationCalendar.fireDate(on: day, hour: hour, minute: minute, calendar: calendar),
            fire > now // 過ぎた時刻は予約しない
        else { return nil }

        return PlannedNotification(
            id: LocalNotificationID.streakRisk(dayKey: LocalNotificationID.dayKey(for: day, calendar: calendar)),
            fireAt: FireTime(fire, calendar: calendar),
            title: Strings.LocalNotification.title,
            body: body(situation: target.situation, snapshot: snapshot)
        )
    }

    /// どの日に・どの言い方で出すか(時刻を過ぎたかは見ない)。ペアのストリーク(続いている日数が 1 以上)が無ければ nil
    static func target(snapshot: PairSnapshot, now: Date, calendar: Calendar) -> Target? {
        guard snapshot.pairId != nil, snapshot.streakCurrent > 0 else { return nil }
        let today = calendar.startOfDay(for: now)
        let snapshotDay = calendar.startOfDay(for: snapshot.updatedAt)
        guard let daysSinceSnapshot = calendar.dateComponents([.day], from: snapshotDay, to: today).day else { return nil }

        switch daysSinceSnapshot {
        case 0: // snapshot は今日のもの
            guard let completion = snapshot.completionOnItsOwnDay(calendar: calendar) else {
                return Target(dayOffset: 0, situation: .neither) // 完了が確かでない: 完了を前提にしない
            }
            if completion.both {
                return Target(dayOffset: 1, situation: .neither) // 今日はふたりそろった。記録は明日へ続く
            }
            if completion.me {
                return Target(dayOffset: 0, situation: .meDone)
            }
            if completion.partner {
                return Target(dayOffset: 0, situation: .partnerDone)
            }
            return Target(dayOffset: 0, situation: .neither)
        case 1: // 同期できないまま日をまたいだ。昨日ふたりそろっていたなら、昨日までの記録が続いている
            guard snapshot.completionOnItsOwnDay(calendar: calendar)?.both == true else { return nil }
            return Target(dayOffset: 0, situation: .neither)
        default:
            return nil
        }
    }

    // MARK: 文言

    private static func body(situation: Situation, snapshot: PairSnapshot) -> String {
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
}
