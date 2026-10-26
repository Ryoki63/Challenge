// DeviceTokenDebugView.swift — APNs デバイストークンの表示・コピー(DEBUG 限定 / issue #8 準備②)
//
// G1 計測(scripts/g1/RUNBOOK.md 手順6)で各端末のトークンをコピーして
// seed-pair.sh に渡すための開発者向けハーネス。Release ビルドには一切含まれない。
// 置き場所は**設定画面(SettingsView)の Form の最後のセクション**だけ(2026-10-26 オーナー判断)。
// 以前はホームと招待画面の中に出ていて、普段の画面(TestFlight のスクショ含む)に写っていた。
// 呼び出し側(SettingsView)も #if DEBUG で囲む。型名は scripts/verify_archive.py が Release の
// アーカイブに残っていないかを調べる目印なので、変えない。
// 開発者専用 UI のため、文言はユーザー向け文言の集約(Strings.swift)には置かない。

#if DEBUG
import SwiftUI
import UIKit

/// 設定画面の Form に最後のセクションとして足す(Form / List の中でだけ使う)
struct DeviceTokenDebugView: View {
    var body: some View {
        Section("開発用(DEBUG)") {
            // DeviceTokenStore は @Observable — body 内の読み取りで変更が自動反映される
            if let token = DeviceTokenStore.shared.deviceTokenHex {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Device Token(G1計測用)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(token)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                    Button {
                        UIPasteboard.general.string = token
                    } label: {
                        Label("コピー", systemImage: "doc.on.doc")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Device Token(G1計測用)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("未取得(通知許可後に表示)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}
#endif
