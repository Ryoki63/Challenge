// DeviceTokenDebugView.swift — APNs デバイストークンの表示・コピー(DEBUG 限定 / issue #8 準備②)
//
// G1 計測(scripts/g1/RUNBOOK.md 手順6)で各端末のトークンをコピーして
// seed-pair.sh に渡すための開発者向けハーネス。Release ビルドには一切含まれない。
// 開発者専用 UI のため、文言はユーザー向け文言の集約(Strings.swift)には置かない。

#if DEBUG
import SwiftUI
import UIKit

struct DeviceTokenDebugView: View {
    var body: some View {
        GroupBox("Device Token(G1計測用)") {
            // DeviceTokenStore は @Observable — body 内の読み取りで変更が自動反映される
            if let token = DeviceTokenStore.shared.deviceTokenHex {
                VStack(spacing: 8) {
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
                .frame(maxWidth: .infinity)
            } else {
                Text("未取得(通知許可後に表示)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(.horizontal, 24)
    }
}
#endif
