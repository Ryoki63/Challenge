// PromiseSetupView.swift — 約束設定画面(T12 / REQUIREMENTS §3.3 / §6)
//
// タイトル入力+リマインド toggle(デフォルト 20:00)の Form。
// 約束の絵文字は UI から廃止した(2026-10-26 オーナー判断)。サーバーの promise-set が emoji 必須のため、
// 保存時は PromiseSetupViewModel.placeholderEmoji を送る(画面のどこにも出さない)。
// 文言は Strings.PromiseSetup に集約(View 内に直書きしない — DESIGN §3.8。罰なし原則)。
// LienApp への結線は T13 ホーム画面の責務(本タスクでは独立フィーチャー — issue #12)。

import SwiftUI

@MainActor
struct PromiseSetupView: View {
    @State private var viewModel: PromiseSetupViewModel

    init(
        client: PromiseAPIClient,
        store: AppGroupStore?,
        existing: Promise? = nil,
        onSaved: @escaping (Promise) -> Void = { _ in }
    ) {
        _viewModel = State(initialValue: PromiseSetupViewModel(
            client: client,
            store: store,
            existing: existing,
            onSaved: onSaved
        ))
    }

    var body: some View {
        Form {
            Section {
                Text(Strings.PromiseSetup.subtitle)
                    .font(.lien(.body))
                    .foregroundStyle(LienColors.inkSecondary)
                    .listRowBackground(Color.clear)
            }

            Section(Strings.PromiseSetup.titleSectionTitle) {
                TextField(Strings.PromiseSetup.titlePlaceholder, text: $viewModel.title)
                    .submitLabel(.done)
                if viewModel.titleError == .tooLong {
                    Text(Strings.PromiseSetup.titleTooLongError)
                        .font(.lien(.footnote))
                        .foregroundStyle(LienColors.gentleAlert)
                }
            }

            Section(Strings.PromiseSetup.remindSectionTitle) {
                Toggle(Strings.PromiseSetup.remindToggleLabel, isOn: $viewModel.remindEnabled)
                if viewModel.remindEnabled {
                    DatePicker(
                        Strings.PromiseSetup.remindTimeLabel,
                        selection: $viewModel.remindTime,
                        displayedComponents: .hourAndMinute
                    )
                }
            }

            Section {
                if let message = viewModel.saveErrorMessage {
                    Text(message)
                        .font(.lien(.footnote))
                        .foregroundStyle(LienColors.gentleAlert)
                }
                Button {
                    Task { await viewModel.save() }
                } label: {
                    if viewModel.isSaving {
                        ProgressView()
                            .tint(LienColors.accent)
                    } else {
                        Text(Strings.PromiseSetup.saveButton)
                    }
                }
                .buttonStyle(.lienPrimary)
                .disabled(!viewModel.canSave)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)

                Text(Strings.PromiseSetup.editKeepsStreakNote)
                    .font(.lien(.caption))
                    .foregroundStyle(LienColors.inkSecondary)
                    .frame(maxWidth: .infinity)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }
        }
        .lienFormBackground()
        .navigationTitle(Strings.PromiseSetup.title)
        .navigationBarTitleDisplayMode(.inline)
    }
}

#Preview {
    NavigationStack {
        PromiseSetupView(client: StubPromiseAPIClient(), store: nil)
    }
}
