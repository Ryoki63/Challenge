// SettingsView.swift — 設定画面(REQUIREMENTS §3.15 / T23 #23)
//
// ホームの歯車から開くシートの中身(NavigationStack は SettingsSheetView)。
//   プロフィール(ニックネームとアイコン。編集は ProfileEditView)/ 約束(編集は約束設定の画面)/ 通知(iOS の設定アプリへ)/
//   ペア(相手の名前・ペアを解消する)/ サポート(お問い合わせ・通報・利用規約・プライバシーポリシー)/
//   アカウント(サインアウト・アカウントを削除する)
// 取り消せない操作(ペアの解消・アカウントの削除)は、説明の画面(push)→ 最後のアラートの2段階
// (DestructiveFlow / DestructiveConfirmView)。文言は Strings.Settings ほか、色・余白は DesignSystem の定数(DESIGN §3.8)。

import SwiftUI

@MainActor
struct SettingsView: View {
    @State private var viewModel: SettingsViewModel
    private let promiseClient: PromiseAPIClient
    private let store: AppGroupStore?
    /// 約束を保存できた(AppModel が snapshot を読み直し、ウィジェットを更新し、サーバーとも突き合わせる)
    private let onPromiseSaved: () -> Void

    @Environment(\.openURL) private var openURL
    /// メールを開けなかったときのアラート
    @State private var showsMailFailure = false

    init(
        auth: AuthServicing,
        store: AppGroupStore?,
        account: AccountOperating,
        promiseClient: PromiseAPIClient,
        onPromiseSaved: @escaping () -> Void
    ) {
        _viewModel = State(initialValue: SettingsViewModel(auth: auth, store: store, account: account))
        self.promiseClient = promiseClient
        self.store = store
        self.onPromiseSaved = onPromiseSaved
    }

    var body: some View {
        // 観測する状態は body の中で読む(Binding の getter の中で読むと、変化が画面の更新に結びつかないことがある)
        let showsDissolveScreen = viewModel.dissolve.stage != .idle
        let showsDeletionScreen = viewModel.deletion.stage != .idle
        return Form {
            profileSection
            promiseSection
            notificationSection
            pairSection
            supportSection
            accountSection
        }
        .navigationTitle(Strings.Settings.title)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task { await viewModel.load() }
        // 取り消せない操作の説明の画面(確認の1段階目)。最後の確認(2段階目)はその画面のアラート
        .navigationDestination(isPresented: flowBinding(viewModel.dissolve, isShown: showsDissolveScreen)) {
            DissolvePairConfirmView(flow: viewModel.dissolve)
        }
        .navigationDestination(isPresented: flowBinding(viewModel.deletion, isShown: showsDeletionScreen)) {
            DeleteAccountConfirmView(flow: viewModel.deletion)
        }
        .alert(Strings.SignOut.confirmTitle, isPresented: $viewModel.showsSignOutConfirmation) {
            Button(Strings.SignOut.confirmButton, role: .destructive) {
                Task { await viewModel.confirmSignOut() }
            }
            Button(Strings.SignOut.cancel, role: .cancel) {
                viewModel.cancelSignOut()
            }
        } message: {
            Text(Strings.SignOut.confirmMessage)
        }
        .alert(Strings.Report.mailFailedTitle, isPresented: $showsMailFailure) {
            Button(Strings.Report.mailFailedOK, role: .cancel) {}
        } message: {
            Text(Strings.Report.mailFailedMessage)
        }
    }

    // MARK: セクション

    private var profileSection: some View {
        Section(Strings.Settings.profileSection) {
            switch viewModel.loadState {
            case .loading:
                ProgressView()
                    .frame(maxWidth: .infinity)
            case .failed:
                loadFailedRow
            case .loaded:
                // ニックネームとアイコンの編集画面へ(REQUIREMENTS §3.15)。編集画面の状態は開くたびに作る
                NavigationLink {
                    if let editor = viewModel.makeProfileEditor() {
                        ProfileEditView(editor: editor)
                    }
                } label: {
                    LabeledContent(Strings.Settings.nicknameLabel) {
                        Text([viewModel.profile?.avatarEmoji, viewModel.profile?.nickname]
                            .compactMap { $0 }
                            .filter { !$0.isEmpty }
                            .joined(separator: " "))
                    }
                }
                if viewModel.showsProfileSavedNote {
                    Text(Strings.Settings.profileSavedNote)
                        .font(.footnote)
                        .foregroundStyle(LienColors.done)
                }
            }
        }
    }

    private var promiseSection: some View {
        Section(Strings.Settings.promiseSection) {
            if viewModel.canEditPromise, let promise = viewModel.promise {
                NavigationLink {
                    PromiseEditScreen(
                        client: promiseClient,
                        store: store,
                        promise: promise,
                        onSaved: { saved in
                            viewModel.promiseSaved(saved)
                            onPromiseSaved()
                        }
                    )
                } label: {
                    LabeledContent(Strings.Settings.promiseEditRow) {
                        Text(viewModel.promiseSummary ?? Strings.Settings.promiseUnset)
                            .lineLimit(1)
                    }
                }
                if viewModel.showsPromiseSavedNote {
                    Text(Strings.Settings.promiseSavedNote)
                        .font(.footnote)
                        .foregroundStyle(LienColors.done)
                }
            } else if viewModel.loadState == .failed {
                loadFailedRow
            } else if viewModel.loadState == .loading {
                ProgressView()
                    .frame(maxWidth: .infinity)
            } else {
                Text(Strings.Settings.promiseUnset)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var notificationSection: some View {
        Section {
            Button {
                openURL(SupportLinks.appSettingsURL)
            } label: {
                Text(Strings.Settings.notificationRow)
            }
        } header: {
            Text(Strings.Settings.notificationSection)
        } footer: {
            Text(Strings.Settings.notificationFooter)
        }
    }

    @ViewBuilder
    private var pairSection: some View {
        Section {
            if viewModel.isPaired {
                if let name = viewModel.partnerName {
                    LabeledContent(Strings.Settings.partnerLabel) {
                        Text(name)
                    }
                }
                Button(role: .destructive) {
                    viewModel.dissolve.begin()
                } label: {
                    Text(Strings.Settings.dissolveRow)
                }
                if viewModel.dissolve.succeeded {
                    Text(Strings.Settings.dissolvedNote)
                        .font(.footnote)
                        .foregroundStyle(LienColors.done)
                }
            } else {
                Text(Strings.Settings.soloNote)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                if viewModel.dissolve.succeeded {
                    Text(Strings.Settings.dissolvedNote)
                        .font(.footnote)
                        .foregroundStyle(LienColors.done)
                }
            }
        } header: {
            Text(Strings.Settings.pairSection)
        } footer: {
            if viewModel.isPaired {
                Text(Strings.Settings.dissolveFooter)
            }
        }
    }

    private var supportSection: some View {
        Section {
            Button {
                openMail(viewModel.contactURL())
            } label: {
                Text(Strings.Settings.contactRow)
            }
            Button {
                openMail(viewModel.generalReportURL())
            } label: {
                Text(Strings.Settings.reportRow)
            }
            Link(Strings.Settings.termsRow, destination: SupportLinks.termsURL)
            Link(Strings.Settings.privacyRow, destination: SupportLinks.privacyURL)
        } header: {
            Text(Strings.Settings.supportSection)
        } footer: {
            Text(Strings.Settings.supportFooter)
        }
    }

    private var accountSection: some View {
        Section {
            Button {
                viewModel.requestSignOut()
            } label: {
                Text(Strings.Settings.signOutRow)
            }
            Button(role: .destructive) {
                viewModel.deletion.begin()
            } label: {
                Text(Strings.Settings.deleteRow)
            }
            LabeledContent(Strings.Settings.versionLabel) {
                Text(viewModel.versionText)
            }
        } header: {
            Text(Strings.Settings.accountSection)
        } footer: {
            Text(Strings.Settings.accountFooter)
        }
    }

    // MARK: 部品

    private var loadFailedRow: some View {
        HStack {
            Text(Strings.Settings.loadFailed)
                .foregroundStyle(LienColors.gentleAlert)
            Spacer()
            Button(Strings.Settings.retry) {
                Task { await viewModel.load() }
            }
            .buttonStyle(.borderless)
        }
    }

    /// 説明の画面を出しているか(流れの stage が idle でない間。呼び出し側が body の中で読んだ値)。
    /// 戻る・下げるで閉じられたら、流れを取り消す
    private func flowBinding(_ flow: DestructiveFlow, isShown: Bool) -> Binding<Bool> {
        Binding(
            get: { isShown },
            set: { isPresented in
                if !isPresented { flow.cancel() }
            }
        )
    }

    /// メールの下書きを開く。開けなかった(メールアプリが無い・宛先が不正)ときはアラート
    private func openMail(_ url: URL?) {
        guard let url else {
            showsMailFailure = true
            return
        }
        openURL(url) { accepted in
            if !accepted {
                Task { @MainActor in showsMailFailure = true }
            }
        }
    }
}

// MARK: - 約束の編集(約束設定の画面を再利用)

/// 約束設定の画面(PromiseSetupView)に、保存できたら前の画面へ戻る動作を足したもの。
/// 保存しても、ふたりの記録(ストリーク)は続く(サーバーが同一の約束を更新する — REQUIREMENTS §3.3)
@MainActor
private struct PromiseEditScreen: View {
    let client: PromiseAPIClient
    let store: AppGroupStore?
    let promise: Promise
    let onSaved: (Promise) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        PromiseSetupView(
            client: client,
            store: store,
            existing: promise,
            onSaved: { saved in
                onSaved(saved)
                dismiss()
            }
        )
    }
}
