// SettingsSheetView.swift — 設定画面を包むシート(T23 #23)
//
// ホームの歯車(RootView)から開く。シートの中で NavigationStack を持ち、約束の編集・ペアの解消・
// アカウントの削除の説明画面を push する。閉じるボタンは右上。

import SwiftUI

@MainActor
struct SettingsSheetView: View {
    let model: AppModel

    var body: some View {
        NavigationStack {
            SettingsView(
                auth: model.services.auth,
                store: model.services.store,
                account: model,
                promiseClient: model.services.promiseClient,
                onPromiseSaved: { model.promiseSaved() }
            )
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(Strings.Settings.closeButton) {
                        model.showsSettings = false
                    }
                }
            }
        }
    }
}
