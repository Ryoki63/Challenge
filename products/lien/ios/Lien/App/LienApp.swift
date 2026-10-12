// LienApp.swift — アプリエントリポイント(DESIGN §3.3 / issue #55)
//
// 依存の組み立て(Live / Stub の切替)は AppServices、ルート画面系統の導出は AppRouter、
// サーバー同期とルート状態の保持は AppModel、画面の切替は RootView が担う。
// ここは「それらを1回だけ作ってつなぐ」ことだけを行う。
// 初期 phase は「auth セッション有無 + App Group snapshot」から導出する
// (独自の永続フラグは持たない。状態の正はサーバー — issue #10)。

import SwiftUI

@main
@MainActor
struct LienApp: App {
    /// リモート通知登録コールバックの受け口(issue #8 準備② — AppDelegate.swift)
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    @State private var model: AppModel

    init() {
        let services = AppServices.make()
        let model = AppModel(services: services)
        _model = State(initialValue: model)

        // AppDelegate が受けた APNs トークン → users.push_token / push_env の自動保存
        // (セッション確立を待ち、変化時だけ送る — PushTokenSync)
        let pushTokenSync = services.pushTokenSync
        DeviceTokenStore.shared.onUpdate = { token in
            Task { await pushTokenSync.receive(token: token) }
        }
        // リモート通知の受信 → snapshot の再同期
        RemoteNotificationRelay.shared.handler = {
            await model.remoteNotificationReceived()
        }
    }

    var body: some Scene {
        WindowGroup {
            RootView(model: model)
        }
    }
}
