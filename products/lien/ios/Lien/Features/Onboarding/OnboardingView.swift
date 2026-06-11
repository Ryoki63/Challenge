// OnboardingView.swift — オンボーディング3画面(T10 / REQUIREMENTS §6)
//
// concept → nickname(+絵文字アイコン)→ notification(プレ許可)の順に進む。
// 文言は Strings.Onboarding に集約(View 内に直書きしない — DESIGN §3.8)。

import SwiftUI

@MainActor
struct OnboardingView: View {
    @State private var viewModel: OnboardingViewModel

    init(
        authService: AuthServicing,
        pushAuthorizer: PushAuthorizing,
        onFinished: @escaping () -> Void
    ) {
        _viewModel = State(initialValue: OnboardingViewModel(
            authService: authService,
            pushAuthorizer: pushAuthorizer,
            onFinished: onFinished
        ))
    }

    var body: some View {
        Group {
            switch viewModel.step {
            case .concept:
                ConceptPage(onStart: { viewModel.advanceFromConcept() })
            case .nickname:
                NicknamePage(viewModel: viewModel)
            case .notification:
                NotificationPage(viewModel: viewModel)
            }
        }
        .animation(.default, value: viewModel.step)
    }
}

// MARK: - ページ1: コンセプト

private struct ConceptPage: View {
    let onStart: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "leaf.circle")
                .font(.system(size: 64))
                .foregroundStyle(.green)
            Text(Strings.Onboarding.conceptTitle)
                .font(.title2.bold())
            Text(Strings.Onboarding.conceptBody)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Spacer()
            Text(Strings.Onboarding.conceptNote)
                .font(.footnote)
                .foregroundStyle(.secondary)
            Button(action: onStart) {
                Text(Strings.Onboarding.conceptStart)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .padding(24)
    }
}

// MARK: - ページ2: ニックネーム+アイコン

private struct NicknamePage: View {
    @Bindable var viewModel: OnboardingViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text(Strings.Onboarding.profileTitle)
                    .font(.title2.bold())
                    .padding(.top, 32)

                VStack(alignment: .leading, spacing: 8) {
                    TextField(Strings.Onboarding.nicknamePlaceholder, text: $viewModel.nickname)
                        .textFieldStyle(.roundedBorder)
                        .submitLabel(.done)
                    if let message = nicknameErrorMessage {
                        Text(message)
                            .font(.footnote)
                            .foregroundStyle(.orange)
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text(Strings.Onboarding.avatarTitle)
                        .font(.headline)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 44))], spacing: 8) {
                        ForEach(Strings.Onboarding.avatarPalette, id: \.self) { emoji in
                            Button {
                                viewModel.avatarEmoji = emoji
                            } label: {
                                Text(emoji)
                                    .font(.title2)
                                    .frame(width: 44, height: 44)
                                    .background(
                                        viewModel.avatarEmoji == emoji
                                            ? Color.accentColor.opacity(0.2)
                                            : Color.clear,
                                        in: RoundedRectangle(cornerRadius: 8)
                                    )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                if let errorMessage = viewModel.submitErrorMessage {
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }

                Button {
                    Task { await viewModel.submitProfile() }
                } label: {
                    if viewModel.isSubmitting {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                    } else {
                        Text(submitButtonTitle)
                            .frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!viewModel.canSubmitProfile)

                // 匿名開始の注意(DESIGN §10 の明示義務)
                Text(Strings.Onboarding.anonymousStartNote)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(24)
        }
    }

    /// 8字超は即時に示す。空欄エラーは「空白だけ入力」のときのみ表示する
    /// (未入力のまま送信はボタン無効で防ぐ)
    private var nicknameErrorMessage: String? {
        switch viewModel.nicknameError {
        case .tooLong:
            return Strings.Onboarding.nicknameTooLongError
        case .empty:
            return viewModel.nickname.isEmpty ? nil : Strings.Onboarding.nicknameEmptyError
        case nil:
            return nil
        }
    }

    private var submitButtonTitle: String {
        viewModel.submitErrorMessage == nil
            ? Strings.Onboarding.profileSubmit
            : Strings.Onboarding.retry
    }
}

// MARK: - ページ3: 通知プレ許可

private struct NotificationPage: View {
    let viewModel: OnboardingViewModel

    var body: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "bell.badge")
                .font(.system(size: 56))
                .foregroundStyle(.tint)
            Text(Strings.Onboarding.notificationTitle)
                .font(.title2.bold())
            Text(Strings.Onboarding.notificationBody)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Spacer()
            Button {
                Task { await viewModel.requestNotifications() }
            } label: {
                Text(Strings.Onboarding.notificationAllow)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(viewModel.isRequestingNotifications)

            Button(Strings.Onboarding.notificationLater) {
                viewModel.skipNotifications()
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .padding(24)
    }
}
