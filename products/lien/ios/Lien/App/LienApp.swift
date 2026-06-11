// LienApp.swift — アプリエントリポイント(DESIGN §3.3)
// ルートは AppPhase で画面系統を切り替える。
// 初期 phase は「auth セッション有無 + App Group snapshot」から導出する
// (独自の永続フラグは持たない。状態の正はサーバー — issue #10)。

import SwiftUI

@main
struct LienApp: App {
    /// リモート通知登録コールバックの受け口(issue #8 準備② — AppDelegate.swift)
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    private let authService: AuthServicing
    private let pushAuthorizer: PushAuthorizing
    private let inviteClient: InviteClient

    /// ルート状態。サーバー同期による solo ⇄ paired の遷移は後続タスク(T13)で実装する
    @State private var phase: AppPhase

    init() {
        let authService = SupabaseService.makeDefault()
        self.authService = authService
        self.pushAuthorizer = PushManager()
        // 実 HTTP クライアント(Edge Functions 呼び出し)は G0 デプロイ後の後続タスクで
        // SupabaseService.makeDefault と同様に Config の有無で差し替える(issue #11)
        self.inviteClient = StubInviteClient()
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
                pushAuthorizer: pushAuthorizer,
                inviteClient: inviteClient
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
/// solo = 招待画面(T11)/ paired = ホーム画面(T13)。
struct RootView: View {
    @Binding var phase: AppPhase
    let authService: AuthServicing
    let pushAuthorizer: PushAuthorizing
    let inviteClient: InviteClient

    /// ディープリンク lien://invite/<token> で受けた招待コード。
    /// solo の招待画面がプリフィルとして消費する(onboarding 中に届いた場合も保持しておく)
    @State private var pendingInviteToken: String?

    var body: some View {
        Group {
            switch phase {
            case .onboarding:
                OnboardingView(
                    authService: authService,
                    pushAuthorizer: pushAuthorizer,
                    onFinished: { phase = .solo }
                )
            case .solo:
                PairingView(
                    inviteClient: inviteClient,
                    store: AppGroupStore.standard(),
                    pendingInviteToken: $pendingInviteToken,
                    onPaired: { phase = .paired }
                )
            case .paired:
                HomeView(
                    store: AppGroupStore.standard(),
                    // T13 はローカルエコー(楽観反映のみ)。実 API+オフラインキューは T14 で差し替え
                    checkinService: LocalEchoCheckinService()
                )
            }
        }
        .onOpenURL { url in
            // 招待リンクの受け口(DESIGN §3.6)。招待以外・不正形式は無視する
            if let token = DeepLinkHandler.inviteToken(from: url) {
                pendingInviteToken = token
            }
        }
    }
}
