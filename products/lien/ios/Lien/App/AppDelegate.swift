// AppDelegate.swift — リモート通知登録のコールバック受け口(issue #8 準備②)
//
// - LienApp の @UIApplicationDelegateAdaptor から結線される(SwiftUI ライフサイクルは維持)
// - APNs デバイストークンを hex 化して DeviceTokenStore に保持するまでを担う
//   (DEBUG ビルドの表示・コピー UI = DeviceTokenDebugView が読む)。
//   users.push_token への自動アップロードはプッシュパイプラインの後続タスク

import Observation
import UIKit

/// APNs デバイストークンの保持(G1 計測ハーネス — scripts/g1/RUNBOOK.md 手順6)。
/// UIApplicationDelegate のコールバックも SwiftUI の body も MainActor 上のため
/// @MainActor で隔離する。
@MainActor
@Observable
final class DeviceTokenStore {
    static let shared = DeviceTokenStore()

    /// hex 文字列化した APNs デバイストークン(未取得は nil)
    private(set) var deviceTokenHex: String?

    func update(deviceToken: Data) {
        deviceTokenHex = Self.hexString(from: deviceToken)
    }

    /// Data → 小文字 hex 文字列(APNs トークンの慣例形式。seed-pair.sh にそのまま渡せる)
    nonisolated static func hexString(from data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }
}

/// UIApplicationDelegate(クラス全体が protocol の @MainActor 注釈で MainActor 隔離になる)
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
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
}
