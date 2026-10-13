// LocalNotificationPushSync.swift — 相手の push(snapshot を運ぶ)を受けた NSE が、端末のローカル通知を合わせる(T16 #16)
//
// 夜 9 時のストリーク危機は、「アプリを開くのを忘れた日」のための通知。アプリを開かない日は、アプリの同期が走らないので、
// その日の予約を作れるのは、相手の push を受けた NSE だけ。そこで NSE は、受けた snapshot ごとに、アプリの同期と同じ計画
// (StreakRiskPlan)に予約を合わせる:
//
//   ① ストリーク危機: 計画どおりに足し・置き換え・消す(足りなければ足し、古ければ消す)
//        前の日に先にチェックインして、相手のあとにアプリを開かなかった … 相手の push が「ふたりそろった」を運ぶ → 明日の分を足す
//        お休みチケットで守られた翌日 … close-day の ticket_used の push → その日の分を足す
//        ストリークが途切れた … close-day の streak_reset の push(ストリーク 0)→ 残っている分を消す
//        相手が先に済ませた … 今日の分を「相手は済み」の言い方に置き換える
//   ② 今日のリマインド: 自分がもう済んでいれば取り消す(足しはしない。14 日ぶんはアプリが予約している)
//   ③ 通知センターに届いてしまった古い通知を外す
//   ④ ①〜③がシステムに届くのを待つ(予約の一覧を読み直す。同じ接続の応答なので、それ以前の要求は届いている)
//
// **NSE が本体のアプリの予約を読み・消し・足せるかは、実機でしか確かめられない**(T20。ios/README.md §12)。
// できなかったときのふるまいは、これまでと同じ(アプリを開いたときの同期が合わせる)になるだけで、害はない。
// 同じ識別子を消してすぐ置き直すことはしない(NotificationReconciler)。
//
// アプリと NSE が同じ snapshot から同じ答えを出すことは、テストが確かめている(LocalNotificationPushSyncTests)。
// Lien / LienNSE の 2 ターゲットでソース共有する(project.yml)。Foundation だけに依存させること。

import Foundation

enum LocalNotificationPushSync {
    static func align(
        center: NotificationScheduling,
        prefs: NotificationPreferences,
        snapshot: PairSnapshot,
        now: Date,
        calendar: Calendar
    ) async {
        // ① ストリーク危機(アプリの同期と同じ計画)
        let streakRisk = StreakRiskPlan.desired(prefs: prefs, snapshot: snapshot, now: now, calendar: calendar)
        await NotificationReconciler.reconcile(
            center: center,
            desired: streakRisk.map { [$0] } ?? [],
            scope: LocalNotificationID.isStreakRisk
        )

        // ② 今日のリマインド: 自分が今日すでに完了していれば取り消す
        let stale = LocalNotificationCancellation.staleIDsForToday(snapshot: snapshot, now: now, calendar: calendar)
        let staleReminders = stale.filter(LocalNotificationID.isReminder)
        if !staleReminders.isEmpty {
            let pendingIDs = Set(await center.pendingLocalNotifications().map(\.id))
            let toRemove = staleReminders.filter(pendingIDs.contains)
            if !toRemove.isEmpty { await center.removePending(ids: toRemove) }
        }

        // ③ 通知センターに届いてしまった古い通知
        await NotificationReconciler.dismissDelivered(center: center, snapshot: snapshot, now: now, calendar: calendar)

        // ④ 取り消し・追加がシステムに届くのを待つ
        _ = await center.pendingLocalNotifications()
    }
}
