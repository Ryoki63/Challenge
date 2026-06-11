// PromiseSetupView.swift — 約束設定画面(T12 / REQUIREMENTS §3.3 / §6)
//
// タイトル入力+絵文字(固定候補)+リマインド toggle(デフォルト 20:00)の Form。
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
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .listRowBackground(Color.clear)
            }

            Section(Strings.PromiseSetup.titleSectionTitle) {
                TextField(Strings.PromiseSetup.titlePlaceholder, text: $viewModel.title)
                    .submitLabel(.done)
                if viewModel.titleError == .tooLong {
                    Text(Strings.PromiseSetup.titleTooLongError)
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
            }

            Section(Strings.PromiseSetup.emojiSectionTitle) {
                EmojiPaletteGrid(selection: $viewModel.emoji)
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
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
                Button {
                    Task { await viewModel.save() }
                } label: {
                    if viewModel.isSaving {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                    } else {
                        Text(Strings.PromiseSetup.saveButton)
                            .frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!viewModel.canSave)
                .listRowBackground(Color.clear)

                Text(Strings.PromiseSetup.editKeepsStreakNote)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .listRowBackground(Color.clear)
            }
        }
        .navigationTitle(Strings.PromiseSetup.title)
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - 絵文字パレット(固定候補から選択 — issue #12)

private struct EmojiPaletteGrid: View {
    @Binding var selection: String

    private let columns = Array(repeating: GridItem(.flexible()), count: 8)

    var body: some View {
        LazyVGrid(columns: columns, spacing: 8) {
            ForEach(Strings.PromiseSetup.emojiPalette, id: \.self) { emoji in
                Button {
                    selection = emoji
                } label: {
                    Text(emoji)
                        .font(.title2)
                        .frame(maxWidth: .infinity, minHeight: 36)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(selection == emoji
                                    ? Color.accentColor.opacity(0.2)
                                    : Color.clear)
                        )
                }
                .buttonStyle(.plain)
                .accessibilityLabel(emoji)
                .accessibilityAddTraits(selection == emoji ? .isSelected : [])
            }
        }
        .padding(.vertical, 4)
    }
}

#Preview {
    NavigationStack {
        PromiseSetupView(client: StubPromiseAPIClient(), store: nil)
    }
}
