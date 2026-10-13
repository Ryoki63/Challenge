// PushManager.swift — 通知許可とリモート通知登録(DESIGN §3.3 / T10)
//
// - オンボのプレ許可画面(ページ3)で説明してから OS ダイアログを1回だけ出す(issue #10)。
//   「あとで」を選んでもオンボは完了できる(初回拒否されると設定アプリ誘導しかなくなるため)。
//   「あとで」を選んだ人には、リマインド付きの約束を保存したとき(AppModel.promiseSaved)と、通知の設定画面でリマインドか
//   夜 9 時のお知らせを ON にしたとき(NotificationSettingsViewModel)に、まだ聞いていなければ求める(issue #16)
// - 許可されたら APNs 登録を開始する。デバイストークンの受け取りは AppDelegate(DeviceTokenStore)、
//   users.push_token / push_env への保存は PushTokenSync(issue #55)が担う

import Foundation
import UIKit
import UserNotifications

/// 通知許可要求の抽象(テストはモック注入)
protocol PushAuthorizing {
    /// OS の通知許可ダイアログを表示し、許可されたら true
    @discardableResult
    func requestAuthorization() async -> Bool
}

final class PushManager: PushAuthorizing {
    @discardableResult
    func requestAuthorization() async -> Bool {
        let granted = (try? await UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound, .badge])) ?? false
        if granted {
            await MainActor.run {
                UIApplication.shared.registerForRemoteNotifications()
            }
        }
        return granted
    }

    /// 起動時フック(issue #8 準備②): 既に許可済みなら OS ダイアログを出さずに
    /// APNs 登録を(再)実行する。トークンは変わり得るため毎起動で呼んでよい。
    /// 未決定・拒否なら何もしない(ダイアログは、オンボのプレ許可画面・リマインド付きの約束の保存・通知の設定画面が、
    /// 文脈の中で出す。起動のたびには出さない)
    func registerForRemoteNotificationsIfAuthorized() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            await MainActor.run {
                UIApplication.shared.registerForRemoteNotifications()
            }
        default:
            break
        }
    }
}
