// NotificationReconciler.swift — OS に残っている予約を、計算した予約に合わせる(アプリの同期と NSE で共通。T16 #16)
//
// アプリの同期(ReminderScheduler.sync)は、リマインド 14 日ぶん+ストリーク危機の全体を、NSE(LocalNotificationPushSync)は、
// ストリーク危機だけを(scope で絞って)同じ手順で合わせる。Lien / LienNSE の 2 ターゲットでソース共有する(project.yml)。
// Foundation だけに依存させること(通知センターは NotificationScheduling の抽象越しに触る)。

import Foundation

enum NotificationReconciler {
    /// `scope` に入る識別子の予約を、`desired` に合わせる。
    ///   - desired に無い予約は消す(`scope` の外の予約には触れない)
    ///   - desired にあって、まだ無い・内容が違う予約は置く(同じ識別子は置き換わる)
    ///   - 内容が同じ予約は触らない(何度呼んでも同じ)
    /// 内容が違うだけの予約は、**消さずに置き換える**: removePendingNotificationRequests は内部で遅れて実行されることがあり、
    /// 同じ識別子を消してすぐ置くと、遅れた削除が新しい予約を消すおそれがある(消すのは、desired に無い識別子だけ)。
    /// desired は `scope` の内側の識別子だけを含めること
    static func reconcile(
        center: NotificationScheduling,
        desired: [PlannedNotification],
        scope: (String) -> Bool
    ) async {
        let pending = await center.pendingLocalNotifications().filter { scope($0.id) }
        let desiredByID = Dictionary(desired.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let kept = Set(pending.filter { desiredByID[$0.id]?.matches(pending: $0) == true }.map(\.id))
        let obsolete = Set(pending.map(\.id)).subtracting(desiredByID.keys).sorted()
        if !obsolete.isEmpty {
            await center.removePending(ids: obsolete)
        }
        for notification in desired where !kept.contains(notification.id) {
            await center.schedule(notification)
        }
    }

    /// 通知センターに残っている、もう古い通知を外す(リマインドを出したあとで完了した / ふたりそろった)。
    /// snapshot が無い(サインアウト後)ときは、このアプリのローカル通知をすべて外す
    static func dismissDelivered(
        center: NotificationScheduling,
        snapshot: PairSnapshot?,
        now: Date,
        calendar: Calendar
    ) async {
        guard let snapshot else {
            let delivered = await center.deliveredLocalNotificationIDs()
            if !delivered.isEmpty { await center.removeDelivered(ids: delivered) }
            return
        }
        let stale = LocalNotificationCancellation.staleIDsForToday(snapshot: snapshot, now: now, calendar: calendar)
        guard !stale.isEmpty else { return }
        let delivered = Set(await center.deliveredLocalNotificationIDs())
        let toRemove = stale.filter(delivered.contains)
        if !toRemove.isEmpty { await center.removeDelivered(ids: toRemove) }
    }
}
