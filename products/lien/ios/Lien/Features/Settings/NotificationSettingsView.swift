// NotificationSettingsView.swift — 通知の設定画面(REQUIREMENTS §3.12・§3.15 / T16 #16)
//
// 設定 → 通知から push で開く。リマインド(ON/OFF・時刻 — 約束の remind_at。「保存する」で確定)・ストリーク危機(夜 9 時の
// ON/OFF — 端末ローカル。すぐ反映)・相手からの通知(v1.0 は iOS の設定アプリで切り替える)。OS の通知が拒否されているときは案内を出す。
// 状態と保存は NotificationSettingsViewModel。文言は Strings.NotificationSettings、色・余白は DesignSystem の定数(DESIGN §3.8)。

import SwiftUI

@MainActor
struct NotificationSettingsView: View {
    @State private var viewModel: NotificationSettingsViewModel

    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase

    init(viewModel: NotificationSettingsViewModel) {
        // 親の再描画で作り直された viewModel に差し替わらないよう、最初の 1 つを State が持ち続ける
        _viewModel = State(initialValue: viewModel)
    }

    var body: some View {
        Form {
            if viewModel.authorization == .denied {
                deniedSection
            }
            reminderSection
            streakSection
            partnerSection
        }
        .navigationTitle(Strings.NotificationSettings.title)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task { await viewModel.load() }
        .onChange(of: scenePhase) {
            // iOS の設定アプリで許可を変えて戻ってきたら、案内を読み直す
            if scenePhase == .active {
                Task { await viewModel.refreshAuthorization() }
            }
        }
    }

    // MARK: セクション

    private var deniedSection: some View {
        Section {
            Text(Strings.NotificationSettings.deniedNotice)
                .font(.footnote)
                .foregroundStyle(LienColors.gentleAlert)
            systemSettingsButton
        }
    }

    private var reminderSection: some View {
        Section {
            switch viewModel.loadState {
            case .loading:
                ProgressView()
                    .frame(maxWidth: .infinity)
            case .failed:
                HStack {
                    Text(Strings.NotificationSettings.loadFailed)
                        .foregroundStyle(LienColors.gentleAlert)
                    Spacer()
                    Button(Strings.NotificationSettings.retry) {
                        Task { await viewModel.load() }
                    }
                    .buttonStyle(.borderless)
                }
            case .loaded:
                if viewModel.canEditReminder {
                    reminderControls
                } else {
                    Text(Strings.NotificationSettings.reminderNoPromise)
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            Text(Strings.NotificationSettings.reminderSection)
        } footer: {
            Text(Strings.NotificationSettings.reminderFooter)
        }
    }

    @ViewBuilder
    private var reminderControls: some View {
        Toggle(Strings.NotificationSettings.reminderToggle, isOn: $viewModel.reminderEnabled)
            .disabled(viewModel.isSaving)
        if viewModel.reminderEnabled {
            DatePicker(
                Strings.NotificationSettings.reminderTime,
                selection: $viewModel.reminderTime,
                displayedComponents: .hourAndMinute
            )
            .disabled(viewModel.isSaving)
        }
        if viewModel.isReminderDirty || viewModel.isSaving {
            Button {
                Task { await viewModel.saveReminder() }
            } label: {
                if viewModel.isSaving {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .accessibilityLabel(Strings.NotificationSettings.reminderSaving)
                } else {
                    Text(Strings.NotificationSettings.reminderSave)
                        .frame(maxWidth: .infinity)
                }
            }
            .disabled(!viewModel.canSaveReminder)
        }
        if let message = viewModel.saveErrorMessage {
            Text(message)
                .font(.footnote)
                .foregroundStyle(LienColors.gentleAlert)
        }
        if viewModel.showsSavedNote && !viewModel.isReminderDirty {
            Text(Strings.NotificationSettings.reminderSaved)
                .font(.footnote)
                .foregroundStyle(LienColors.done)
        }
    }

    private var streakSection: some View {
        Section {
            Toggle(
                Strings.NotificationSettings.streakToggle,
                isOn: Binding(
                    get: { viewModel.streakRiskEnabled },
                    set: { enabled in Task { await viewModel.setStreakRiskEnabled(enabled) } }
                )
            )
        } header: {
            Text(Strings.NotificationSettings.streakSection)
        } footer: {
            Text(Strings.NotificationSettings.streakFooter)
        }
    }

    private var partnerSection: some View {
        Section {
            systemSettingsButton
        } header: {
            Text(Strings.NotificationSettings.partnerSection)
        } footer: {
            Text(Strings.NotificationSettings.partnerFooter)
        }
    }

    private var systemSettingsButton: some View {
        Button {
            openURL(SupportLinks.appSettingsURL)
        } label: {
            Text(Strings.NotificationSettings.openSystemSettings)
        }
    }
}

// MARK: - 設定画面の「通知」セクション(設定 → 通知の設定画面への入口)

/// 設定画面の「通知」セクション。ローカル通知の管理があれば、通知の設定画面への行(右側に、いまのリマインドの状態)。
/// 無い構成(通知を扱わない)では、iOS の設定アプリへの行だけ
@MainActor
struct NotificationSettingsSection: View {
    let auth: AuthServicing
    let promiseClient: PromiseAPIClient
    let reminders: ReminderManaging?
    let pushAuthorizer: PushAuthorizing
    /// 設定画面がサーバーから読めている自分の約束(行の要約に使う。読めていなければ nil)
    let savedPromise: Promise?
    /// リマインドを保存できた(設定画面の表示と、AppModel の端末の予約を更新する)
    let onReminderSaved: (Promise) -> Void

    @Environment(\.openURL) private var openURL

    var body: some View {
        Section {
            if let reminders {
                NavigationLink {
                    NotificationSettingsView(viewModel: NotificationSettingsViewModel(
                        auth: auth,
                        promiseClient: promiseClient,
                        reminders: reminders,
                        authorizer: pushAuthorizer,
                        onReminderSaved: onReminderSaved
                    ))
                } label: {
                    LabeledContent(Strings.Settings.notificationRow) {
                        if let summary = summary(of: reminders) {
                            Text(summary)
                        }
                    }
                }
            } else {
                // 通知を扱わない構成(ローカル通知の管理が無い): iOS の設定アプリで切り替える
                Button {
                    openURL(SupportLinks.appSettingsURL)
                } label: {
                    Text(Strings.NotificationSettings.openSystemSettings)
                }
            }
        } header: {
            Text(Strings.Settings.notificationSection)
        } footer: {
            Text(Strings.Settings.notificationFooter)
        }
    }

    /// 行の右側: リマインドのいまの状態。サーバーから読めた約束の remind_at を優先し、無ければ端末が覚えている値
    private func summary(of reminders: ReminderManaging) -> String? {
        let preference = savedPromise.map { ReminderPreference(remindAt: $0.remindAt) } ?? reminders.preferences.reminder
        return preference.summaryText
    }
}
