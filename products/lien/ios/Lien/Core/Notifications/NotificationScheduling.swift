// NotificationScheduling.swift — ローカル通知の予約を扱う抽象と、予約1件の値(T16 #16)
//
// ReminderScheduler(予約の計算と合わせ込み)と NSE(LocalNotificationPushSync)は、OS の通知センター
// (UNUserNotificationCenter)を直接は触らず、ここの抽象越しに触る。本実装は UserNotificationCenterScheduler、
// テストは記録するだけの偽物。
// 予約1件は値型(PlannedNotification)で、「計算した予約」と「OS に残っている予約」を同じ型で比べられる。
// このファイルは Lien / LienNSE の 2 ターゲットでソース共有される(project.yml)。Foundation だけに依存させること。

import Foundation

// MARK: - OS の通知許可

/// OS の通知許可の状態(設定画面の案内用)
enum NotificationAuthorization: Equatable, Sendable {
    /// まだ聞いていない(許可のダイアログを出せる)
    case notDetermined
    /// 拒否されている(iOS の設定アプリでしか変えられない)
    case denied
    /// 許可されている(仮の許可・一時的な許可も含む)
    case authorized
}

// MARK: - 予約1件

/// 発火の日時(暦の年月日と時分+そのタイムゾーン)。**予約した時点のタイムゾーンの壁時計**で持つ。
/// 端末のタイムゾーンが変わると、読み戻した予約のタイムゾーンと食い違って「別の予約」になり、次の同期で付け替わる
struct FireTime: Equatable, Comparable, Sendable {
    let year: Int
    let month: Int
    let day: Int
    let hour: Int
    let minute: Int
    /// TimeZone.identifier(例: "Asia/Tokyo")
    let timeZoneIdentifier: String

    static func < (lhs: FireTime, rhs: FireTime) -> Bool {
        (lhs.year, lhs.month, lhs.day, lhs.hour, lhs.minute)
            < (rhs.year, rhs.month, rhs.day, rhs.hour, rhs.minute)
    }

    /// calendar の壁時計(分まで)と、そのタイムゾーンで持つ
    init(_ date: Date, calendar: Calendar) {
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        self.init(
            year: parts.year ?? 0,
            month: parts.month ?? 0,
            day: parts.day ?? 0,
            hour: parts.hour ?? 0,
            minute: parts.minute ?? 0,
            timeZoneIdentifier: calendar.timeZone.identifier
        )
    }

    init(year: Int, month: Int, day: Int, hour: Int, minute: Int, timeZoneIdentifier: String) {
        self.year = year
        self.month = month
        self.day = day
        self.hour = hour
        self.minute = minute
        self.timeZoneIdentifier = timeZoneIdentifier
    }
}

/// ローカル通知の予約1件。通知の名義はアプリ(title は Strings.LocalNotification.title)
struct PlannedNotification: Equatable, Sendable {
    /// LocalNotificationID の識別子(日付つき)
    let id: String
    let fireAt: FireTime
    let title: String
    let body: String

    var isStreakRisk: Bool { LocalNotificationID.isStreakRisk(id) }
    var isReminder: Bool { LocalNotificationID.isReminder(id) }

    /// 計算した予約(self)が、OS に残っている予約(pending)と同じ内容か(同じなら触らない)。
    /// 読み戻した予約にタイムゾーンが無い(空)ときは、タイムゾーンを比べない: OS が覚えていなくても、同期のたびに
    /// 付け替えない(タイムゾーンを持たない予約は、端末のタイムゾーンに追従する)
    func matches(pending: PlannedNotification) -> Bool {
        guard id == pending.id, title == pending.title, body == pending.body else { return false }
        guard (fireAt.year, fireAt.month, fireAt.day, fireAt.hour, fireAt.minute)
            == (pending.fireAt.year, pending.fireAt.month, pending.fireAt.day, pending.fireAt.hour, pending.fireAt.minute)
        else { return false }
        return pending.fireAt.timeZoneIdentifier.isEmpty
            || pending.fireAt.timeZoneIdentifier == fireAt.timeZoneIdentifier
    }
}

// MARK: - 通知センターの抽象

protocol NotificationScheduling: AnyObject {
    /// 予約中の、このアプリのローカル通知(識別子が LocalNotificationID.prefix で始まるものだけ)。
    /// 読み戻せない予約(トリガーが想定外の形など)は、発火の日時が合わない値として返す(次の同期で付け替わる)
    func pendingLocalNotifications() async -> [PlannedNotification]
    /// 通知センターに出ている(配信済みの)、このアプリのローカル通知の識別子
    func deliveredLocalNotificationIDs() async -> [String]
    /// 予約する。同じ識別子があれば置き換わる。失敗(許可が無いなど)は握りつぶす: 次の同期でもう一度合わせる
    func schedule(_ notification: PlannedNotification) async
    func removePending(ids: [String]) async
    func removeDelivered(ids: [String]) async
    func authorizationStatus() async -> NotificationAuthorization
}
