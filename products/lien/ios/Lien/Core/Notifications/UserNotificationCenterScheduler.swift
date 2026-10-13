// UserNotificationCenterScheduler.swift — NotificationScheduling の本実装(UNUserNotificationCenter。T16 #16)
//
// OS の通知センターとの薄い橋渡しだけを持つ(予約の中身の計算は ReminderScheduler)。
//   - 予約は日時を指す 1 回きりのカレンダートリガー(repeats: false)。DateComponents には**暦(グレゴリオ暦)とタイムゾーンを
//     明示する**: 端末の暦が和暦・仏暦でも、年の数え方が変わって遠い未来の日付と取り違えられないように
//   - 識別子が LocalNotificationID.prefix で始まるものだけを扱う(ほかの通知には触れない)
//   - 通知の許可は、ここでは求めない(オンボーディングの許可画面と、通知の設定画面のリマインドを保存したときに、PushAuthorizing が求める)。
//     許可が無くても予約はできる(許可されたとき、予約済みのものがそのまま届く)

import Foundation
import UserNotifications

final class UserNotificationCenterScheduler: NotificationScheduling {
    private let injectedCenter: UNUserNotificationCenter?

    /// center を省くと、使うたびに UNUserNotificationCenter.current()(アプリの共有の通知センター)を使う。
    /// 組み立てだけでは OS に触れない(アプリのバンドルの無い環境でも、AppServices を組み立てられる)
    init(center: UNUserNotificationCenter? = nil) {
        self.injectedCenter = center
    }

    private var center: UNUserNotificationCenter {
        injectedCenter ?? UNUserNotificationCenter.current()
    }

    func pendingLocalNotifications() async -> [PlannedNotification] {
        await center.pendingNotificationRequests()
            .filter { LocalNotificationID.isOurs($0.identifier) }
            .map(Self.plannedNotification(from:))
    }

    func deliveredLocalNotificationIDs() async -> [String] {
        await center.deliveredNotifications()
            .map { $0.request.identifier }
            .filter(LocalNotificationID.isOurs)
    }

    func schedule(_ notification: PlannedNotification) async {
        // 失敗(許可が無い・上限など)は握りつぶす。次の同期でもう一度合わせる
        try? await center.add(Self.makeRequest(notification))
    }

    func removePending(ids: [String]) async {
        center.removePendingNotificationRequests(withIdentifiers: ids)
    }

    func removeDelivered(ids: [String]) async {
        center.removeDeliveredNotifications(withIdentifiers: ids)
    }

    func authorizationStatus() async -> NotificationAuthorization {
        switch await center.notificationSettings().authorizationStatus {
        case .notDetermined:
            return .notDetermined
        case .denied:
            return .denied
        default: // authorized / provisional / ephemeral
            return .authorized
        }
    }

    // MARK: 値の変換(通知センターに触れない。テストが直接呼ぶ)

    /// 予約 1 件 → OS の通知リクエスト
    static func makeRequest(_ notification: PlannedNotification) -> UNNotificationRequest {
        let content = UNMutableNotificationContent()
        content.title = notification.title
        content.body = notification.body
        content.sound = .default
        // 通知センターでの束ね方と、タップされたときの種別(AppDelegate はどの通知でも snapshot を取り直す)
        content.threadIdentifier = notification.isStreakRisk ? "lien.local.streak-risk" : "lien.local.reminder"
        content.userInfo = ["lienLocalType": notification.isStreakRisk ? "streak_risk" : "reminder"]
        let trigger = UNCalendarNotificationTrigger(
            dateMatching: dateComponents(for: notification.fireAt),
            repeats: false
        )
        return UNNotificationRequest(identifier: notification.id, content: content, trigger: trigger)
    }

    /// 発火の日時 → DateComponents(暦とタイムゾーンを明示する)
    static func dateComponents(for fireAt: FireTime) -> DateComponents {
        var calendar = Calendar(identifier: .gregorian)
        let zone = TimeZone(identifier: fireAt.timeZoneIdentifier) ?? TimeZone.current
        calendar.timeZone = zone
        return DateComponents(
            calendar: calendar,
            timeZone: zone,
            year: fireAt.year,
            month: fireAt.month,
            day: fireAt.day,
            hour: fireAt.hour,
            minute: fireAt.minute
        )
    }

    /// OS に残っている予約 → 予約 1 件。トリガーが想定外の形(カレンダートリガーでない・成分が足りない)のときは、
    /// 発火の日時が 0 の値にする(どんな予約とも一致しないので、次の同期で付け替わる)
    static func plannedNotification(from request: UNNotificationRequest) -> PlannedNotification {
        let components = (request.trigger as? UNCalendarNotificationTrigger)?.dateComponents
        return PlannedNotification(
            id: request.identifier,
            fireAt: FireTime(
                year: components?.year ?? 0,
                month: components?.month ?? 0,
                day: components?.day ?? 0,
                hour: components?.hour ?? 0,
                minute: components?.minute ?? 0,
                timeZoneIdentifier: components?.timeZone?.identifier ?? ""
            ),
            title: request.content.title,
            body: request.content.body
        )
    }
}
