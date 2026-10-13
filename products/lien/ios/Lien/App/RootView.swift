// RootView.swift — AppPhase に応じて画面系統を切り替えるルート View(DESIGN §3.3 / issue #55)
//
//   onboarding   : オンボーディング3画面(T10)。完了で AppModel.onboardingFinished
//   promiseSetup : 約束設定(T12)を本番導線に。保存で AppModel.promiseSaved → ホームへ
//   solo / paired: ホーム(T13)。ソロは土の鉢+チェックイン+「相手を招待する」導線で、
//                  招待画面(T11)はホームからシートで開く(招待コードのディープリンクでも自動で開く)。
//                  右上の歯車から設定画面(T23 #23)をシートで開く。相手の写真・ニックネーム・約束の文・植物の名前の
//                  長押しメニュー(通報・ブロック)は ModerationViewModel(AppModel が 1 つ持つ)
//
// 前面復帰・起動・ディープリンクは AppModel に委ねる(サーバー同期と phase 更新はそちらの責務)。
// セッションが使えなくなったとき(snapshot の取得が 401 / user_not_found で続く)の確認もここで出す。

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
                            onSaved: { saved in model.promiseSaved(saved) }
                        )
                        // 約束を決める前でも、設定(サインアウト・アカウントの削除)には入れる
                        .toolbar { settingsButton }
                    }
                }
            case .solo, .paired:
                NavigationStack {
                    HomeView(
                        viewModel: HomeViewModel(
                            store: model.services.store,
                            checkinService: model.services.checkinService,
                            nudgeService: model.services.nudgeService,
                            reactionService: model.services.reactionService,
                            // 相手の今日の写真(PV #59)。Live 構成だけ。長押しメニューは通報とブロック(ペア解消 — T23 #23)
                            partnerPhoto: model.services.partnerPhotos.map {
                                PartnerPhotoModel(provider: $0, actions: model.moderation.photoActions)
                            },
                            // 植物の名前付け(plant-name)と、演出の「もう見せたか」の記録(PB #57)
                            plantNaming: model.services.plantNaming,
                            plantMemory: model.services.plantMemory,
                            reloadWidgets: model.services.reloadWidgets,
                            // チェックイン・取り消しで端末の snapshot が変わったら、ローカル通知の予約を合わせる(issue #16)
                            localStateChanged: { model.localStateChanged() }
                        ),
                        reloadToken: model.snapshotRevision,
                        onInvite: model.phase == .solo ? { model.presentPairing() } : nil,
                        moderation: model.moderation
                    )
                    .toolbar { settingsButton }
                }
            }
        }
        .sheet(isPresented: $model.showsPairing) {
            PairingSheet(model: model)
        }
        .sheet(isPresented: $model.showsSettings) {
            SettingsSheetView(model: model)
        }
        // セッションが使えなくなったとき: 一時的な不調かもしれないので、勝手には消さない。「はじめからやり直す」を選んだときだけ
        // サインアウトして端末の記録を消し、オンボーディングへ戻る(登録なしで始めたアカウントには戻れない)
        .alert(Strings.Session.lostTitle, isPresented: sessionLostBinding(isShown: model.sessionLost)) {
            Button(Strings.Session.restart, role: .destructive) {
                Task { await model.restartAfterSessionLost() }
            }
            Button(Strings.Session.later, role: .cancel) {
                model.dismissSessionLostPrompt()
            }
        } message: {
            Text(Strings.Session.lostMessage)
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

extension RootView {
    /// 右上の歯車(設定画面をシートで開く)。ホームと、約束を決める前の画面に付ける
    @ToolbarContentBuilder
    fileprivate var settingsButton: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Button {
                model.presentSettings()
            } label: {
                Image(systemName: "gearshape")
            }
            .accessibilityLabel(Strings.Settings.openButtonLabel)
        }
    }

    /// 「ログイン状態を確認できません」の確認を出しているか。閉じられたら(「あとで」・外側のタップ)数え直す
    fileprivate func sessionLostBinding(isShown: Bool) -> Binding<Bool> {
        Binding(
            get: { isShown },
            set: { isPresented in
                if !isPresented { model.dismissSessionLostPrompt() }
            }
        )
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
