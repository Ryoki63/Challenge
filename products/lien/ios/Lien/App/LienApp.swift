// LienApp.swift — アプリエントリポイント(DESIGN §3.3)
// ルートは AppPhase で画面系統を切り替える。
// 初期 phase は「auth セッション有無 + App Group snapshot」から導出する
// (独自の永続フラグは持たない。状態の正はサーバー — issue #10)。

import SwiftUI

@main
struct LienApp: App {
    private let authService: AuthServicing
    private let pushAuthorizer: PushAuthorizing

    /// ルート状態。サーバー同期による solo ⇄ paired の遷移は後続タスク(T13)で実装する
    @State private var phase: AppPhase

    init() {
        let authService = SupabaseService.makeDefault()
        self.authService = authService
        self.pushAuthorizer = PushManager()
        _phase = State(initialValue: Self.initialPhase(
            authService: authService,
            store: AppGroupStore.standard()
        ))
    }

    var body: some Scene {
        WindowGroup {
            RootView(
                phase: $phase,
                authService: authService,
                pushAuthorizer: pushAuthorizer
            )
        }
    }

    /// 起動時のルート状態の導出(issue #10):
    /// セッション無し → onboarding / セッション有り+pairId 無し → solo / pairId 有り → paired
    static func initialPhase(authService: AuthServicing, store: AppGroupStore?) -> AppPhase {
        guard authService.currentUserID != nil else { return .onboarding }
        if store?.loadSnapshot()?.pairId != nil { return .paired }
        return .solo
    }
}

/// AppPhase に応じて画面系統を切り替えるルート View(DESIGN §3.3)。
/// solo / paired はプレースホルダ(招待 UI は T11、ホームは T13 で実装)。
struct RootView: View {
    @Binding var phase: AppPhase
    let authService: AuthServicing
    let pushAuthorizer: PushAuthorizing

    var body: some View {
        switch phase {
        case .onboarding:
            OnboardingView(
                authService: authService,
                pushAuthorizer: pushAuthorizer,
                onFinished: { phase = .solo }
            )
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
