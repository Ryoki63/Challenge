// ProfileEditView.swift — プロフィール(ニックネーム8字+アイコン)の編集画面(REQUIREMENTS §3.15 / T23 #23)
//
// 設定のプロフィール欄から push で開く。ニックネームの検証とアイコンの選び方(タネの子のイラスト12種)は
// オンボーディングと同じ(NicknameRules / AvatarPicker)。保存できたら前の画面へ戻る(設定画面に「保存しました」が出る)。
// 状態と保存は ProfileEditViewModel。文言は Strings、色・余白は DesignSystem の定数(DESIGN §3.8)。

import SwiftUI

@MainActor
struct ProfileEditView: View {
    @State private var editor: ProfileEditViewModel
    @Environment(\.dismiss) private var dismiss

    init(editor: ProfileEditViewModel) {
        // 親の再描画で作り直された editor に差し替わらないよう、最初の 1 つを State が持ち続ける
        _editor = State(initialValue: editor)
    }

    var body: some View {
        Form {
            Section {
                TextField(Strings.Onboarding.nicknamePlaceholder, text: $editor.nickname)
                    .submitLabel(.done)
                if let message = nicknameErrorMessage {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(LienColors.gentleAlert)
                }
            } header: {
                Text(Strings.Settings.nicknameLabel)
            }

            Section {
                AvatarPicker(selection: $editor.avatar)
                    // Form の行の上下の余白とは別に、輪とチェックが行の端で詰まらないよう少し空ける
                    .padding(.vertical, LienSpacing.xs)
            } header: {
                Text(Strings.Onboarding.avatarTitle)
            } footer: {
                Text(Strings.Settings.profileEditFooter)
            }

            if let message = editor.errorMessage {
                Section {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(LienColors.gentleAlert)
                }
            }
        }
        .navigationTitle(Strings.Settings.profileEditTitle)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                if editor.isSaving {
                    ProgressView()
                        .accessibilityLabel(Strings.Settings.profileSaving)
                } else {
                    Button(Strings.Settings.profileSave) {
                        Task {
                            if await editor.save() { dismiss() }
                        }
                    }
                    .disabled(!editor.canSave)
                }
            }
        }
    }

    // MARK: 部品

    /// 8字超は即時に示す。空欄の案内は「空白だけ入力」のときのみ(未入力のままの保存は、ボタンが押せないことで防ぐ)
    private var nicknameErrorMessage: String? {
        switch editor.nicknameError {
        case .tooLong:
            return Strings.Onboarding.nicknameTooLongError
        case .empty:
            return editor.nickname.isEmpty ? nil : Strings.Onboarding.nicknameEmptyError
        case nil:
            return nil
        }
    }
}
