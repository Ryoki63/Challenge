// PushManager.swift — 通知許可とリモート通知登録(DESIGN §3.3 / T10)
//
// - オンボのプレ許可画面(ページ3)で説明してから OS ダイアログを1回だけ出す(issue #10)。
//   「あとで」を選んでもオンボは完了できる(初回拒否されると設定アプリ誘導しかなくなるため)
// - 許可されたら APNs 登録を開始する。デバイストークンの受け取りと users.push_token への
//   保存はプッシュパイプライン側の後続タスクで実装する

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
}
