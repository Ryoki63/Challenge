// AppDelegate.swift — リモート通知まわりのコールバック受け口(issue #8 準備② / issue #55)
//
// - LienApp の @UIApplicationDelegateAdaptor から結線される(SwiftUI ライフサイクルは維持)
// - APNs デバイストークンを hex 化して DeviceTokenStore に保持する。
//   取得のたびに onUpdate フックが呼ばれ、LienApp が PushTokenSync(users.push_token / push_env の
//   自動保存)へ橋渡しする。DEBUG ビルドの表示・コピー UI(DeviceTokenDebugView)も同じ値を読む
// - リモート通知の受信(フォアグラウンドの表示前・サイレント push・通知タップ)を
//   RemoteNotificationRelay 経由で AppModel の snapshot 同期へ伝える
//   (サイレント push をバックグラウンドで受けるには Info.plist の UIBackgroundModes: remote-notification
//    が必要 — project.yml)

import Observation
import UIKit
import UserNotifications

/// APNs デバイストークンの保持(G1 計測ハーネス — scripts/g1/RUNBOOK.md 手順6)。
/// UIApplicationDelegate のコールバックも SwiftUI の body も MainActor 上のため
/// @MainActor で隔離する。
@MainActor
@Observable
final class DeviceTokenStore {
    static let shared = DeviceTokenStore()

    /// hex 文字列化した APNs デバイストークン(未取得は nil)
    private(set) var deviceTokenHex: String?

    /// トークンが取得(更新)されるたびに呼ばれる橋渡しフック(PushTokenSync へ)。
    /// 設定した時点で取得済みのトークンがあれば、その場で1回呼ぶ(起動順序に依存しない)
    @ObservationIgnored
    var onUpdate: ((String) -> Void)? {
        didSet {
            if let onUpdate, let deviceTokenHex { onUpdate(deviceTokenHex) }
        }
    }

    func update(deviceToken: Data) {
        let hex = Self.hexString(from: deviceToken)
        deviceTokenHex = hex
        onUpdate?(hex)
    }

    /// Data → 小文字 hex 文字列(APNs トークンの慣例形式。seed-pair.sh にそのまま渡せる)
    nonisolated static func hexString(from data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }
}

/// リモート通知を受信したことを AppModel へ伝える橋渡し(snapshot の再同期を起動する)。
/// AppDelegate は SwiftUI が生成するため、LienApp が handler を設定する
@MainActor
final class RemoteNotificationRelay {
    static let shared = RemoteNotificationRelay()

    var handler: (@MainActor () async -> Void)?

    func notify() async {
        await handler?()
    }
}

/// UIApplicationDelegate(クラス全体が protocol の @MainActor 注釈で MainActor 隔離になる)
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        // フォアグラウンドで届いた通知の受信を捕まえる(snapshot 同期の起点)
        UNUserNotificationCenter.current().delegate = self
        // 通知許可済みの既存ユーザー向け: 起動ごとに APNs 登録を再実行する
        // (トークンは変わり得るため。オンボ中の初回登録は PushManager.requestAuthorization が行う)
        Task { await PushManager().registerForRemoteNotificationsIfAuthorized() }
        return true
    }

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        DeviceTokenStore.shared.update(deviceToken: deviceToken)
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        // シミュレータ・無署名ビルドでは失敗が正常系(APNs 登録は実機+署名が必要)
        print("[Lien] APNs 登録に失敗: \(error.localizedDescription)")
    }

    /// サイレント push(content-available: 1 — checkin-cancel / promise-set の pair_update)と、
    /// フォアグラウンドで受けたリモート通知。snapshot をサーバーから取り直す
    func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any],
        fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
    ) {
        Task { @MainActor in
            await RemoteNotificationRelay.shared.notify()
            completionHandler(.newData)
        }
    }

    // MARK: UNUserNotificationCenterDelegate

    /// フォアグラウンド中に届いた可視 push: バナーを出しつつ snapshot を同期する
    /// (NSE が App Group に書いた snapshot に、アプリ本体の表示を追従させる)。
    /// 届いたのがローカル通知(リマインド・ストリーク危機)で、端末の snapshot が「今日の分はもう要らない」(自分が完了した /
    /// ふたりそろった)を示すときは、出さずに捨てる(NSE が取り消せなかったときの最後の網 — issue #16。前面にいないときは出てしまう)
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        Task { @MainActor in await RemoteNotificationRelay.shared.notify() }
        let store = AppGroupStore.standard() ?? AppGroupStore.localFallback()
        let isStale = LocalNotificationCancellation.shouldSuppress(
            identifier: notification.request.identifier,
            snapshot: store.loadSnapshot(),
            now: Date(),
            calendar: LocalNotificationCalendar.current()
        )
        let options: UNNotificationPresentationOptions = isStale ? [] : [.banner, .list, .sound]
        completionHandler(options)
    }

    /// 通知のタップ(アプリが前面へ来る。前面復帰の同期とは別に、確実に取り直す)
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        Task { @MainActor in await RemoteNotificationRelay.shared.notify() }
        completionHandler()
    }
}
