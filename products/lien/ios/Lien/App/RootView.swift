// RootView.swift — AppPhase に応じて画面系統を切り替えるルート View(DESIGN §3.3 / issue #55)
//
//   onboarding   : オンボーディング3画面(T10)。完了で AppModel.onboardingFinished
//   promiseSetup : 約束設定(T12)を本番導線に。保存で AppModel.promiseSaved → ホームへ
//   solo / paired: ホーム(T13)。ソロは土の鉢+チェックイン+「相手を招待する」導線で、
//                  招待画面(T11)はホームからシートで開く(招待コードのディープリンクでも自動で開く)
//
// 前面復帰・起動・ディープリンクは AppModel に委ねる(サーバー同期と phase 更新はそちらの責務)。

import SwiftUI

struct RootView: View {
    @Bindable var model: AppModel
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            switch model.phase {
            case .onboarding:
                OnboardingView(
                    authService: model.services.auth,
                    pushAuthorizer: model.services.pushAuthorizer,
                    onProfileSubmitStarted: { model.onboardingProfileSubmitStarted() },
                    onFinished: { Task { await model.onboardingFinished() } }
                )
            case .promiseSetup:
                if model.isResolving {
                    ResolvingView()
                } else {
                    NavigationStack {
                        PromiseSetupView(
                            client: model.services.promiseClient,
                            store: model.services.store,
                            onSaved: { _ in model.promiseSaved() }
                        )
                    }
                }
            case .solo, .paired:
                HomeView(
                    viewModel: HomeViewModel(
                        store: model.services.store,
                        checkinService: model.services.checkinService,
                        nudgeService: model.services.nudgeService,
                        reactionService: model.services.reactionService,
                        // 相手の今日の写真(PV #59)。Live 構成だけ。T23 が長押しメニュー(通報・ブロック)の項目を渡す
                        partnerPhoto: model.services.partnerPhotos.map { PartnerPhotoModel(provider: $0) },
                        reloadWidgets: model.services.reloadWidgets
                    ),
                    reloadToken: model.snapshotRevision,
                    onInvite: model.phase == .solo ? { model.presentPairing() } : nil
                )
            }
        }
        .sheet(isPresented: $model.showsPairing) {
            PairingSheet(model: model)
        }
        .onOpenURL { url in
            // 招待リンクの受け口(DESIGN §3.6)。招待以外・不正形式は無視する
            model.handleDeepLink(url)
        }
        .task { await model.start() }
        .onChange(of: scenePhase) {
            if scenePhase == .active {
                Task { await model.sceneDidBecomeActive() }
            }
        }
    }
}

// MARK: - 初回同期待ち

/// セッションはあるが snapshot が未取得の間(再インストール直後など)。
/// 既存の約束・ペアがサーバーにあるかもしれないので、約束設定は同期の結果を待ってから出す
private struct ResolvingView: View {
    var body: some View {
        VStack(spacing: LienSpacing.m) {
            ProgressView()
            Text(Strings.Home.emptyMessage)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - 招待画面(ソロのホームから開くシート)

private struct PairingSheet: View {
    @Bindable var model: AppModel

    var body: some View {
        NavigationStack {
            PairingView(
                inviteClient: model.services.inviteClient,
                store: model.services.store,
                pendingInviteToken: $model.pendingInviteToken,
                onPaired: { model.pairingSucceeded() }
            )
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(Strings.Pairing.closeButton) {
                        model.showsPairing = false
                    }
                }
            }
        }
        .task {
            // 招待した側が、相手の受諾(ペア成立)を push なしでも画面上で知れるようにする。
            // シートが開いている間だけ snapshot を取り直す。相手がなかなか受諾しない間に無駄な通信を
            // 続けないよう、間隔は 4秒 → 8秒 → … → 30秒と段階的に伸ばす(InviteSyncSchedule)
            // (成立すると phase が paired になり、AppModel がシートを閉じる)
            var attempt = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(InviteSyncSchedule.interval(forAttempt: attempt)))
                if Task.isCancelled { break }
                await model.refresh()
                attempt += 1
            }
        }
    }
}
