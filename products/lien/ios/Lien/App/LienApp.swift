// LienApp.swift — アプリエントリポイント(DESIGN §3.3)
// ルートは AppPhase で画面系統を切り替える。各画面の実装は後続タスク(Features/ 配下)。

import SwiftUI

@main
struct LienApp: App {
    /// ルート状態。永続化・サーバー同期による遷移は後続タスクで実装する。
    @State private var phase: AppPhase = .onboarding

    var body: some Scene {
        WindowGroup {
            RootView(phase: phase)
        }
    }
}

/// AppPhase に応じて画面系統を切り替えるルート View(DESIGN §3.3)。
/// 現状はビルド検証用の最小プレースホルダ。
struct RootView: View {
    let phase: AppPhase

    var body: some View {
        switch phase {
        case .onboarding:
            placeholder(systemImage: "hand.wave")
        case .solo:
            placeholder(systemImage: "leaf")
        case .paired:
            placeholder(systemImage: "heart")
        }
    }

    private func placeholder(systemImage: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("Lien")
                .font(.title2)
        }
    }
}
