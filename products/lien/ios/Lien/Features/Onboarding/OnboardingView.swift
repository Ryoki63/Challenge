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
        onProfileSubmitStarted: (() -> Void)? = nil,
        onFinished: @escaping () -> Void
    ) {
        _viewModel = State(initialValue: OnboardingViewModel(
            authService: authService,
            pushAuthorizer: pushAuthorizer,
            onProfileSubmitStarted: onProfileSubmitStarted,
            onFinished: onFinished
        ))
    }

    /// 組み立て済みの ViewModel で描く(プレビュー・描画テスト・特定ステップの確認用)
    init(viewModel: OnboardingViewModel) {
        _viewModel = State(initialValue: viewModel)
    }

    var body: some View {
        VStack(spacing: 0) {
            // 3ステップのうちどこにいるかを常に出す(何画面あるか分からないと、先が見えず離脱する)
            OnboardingStepIndicator(step: viewModel.step)
                .padding(.top, LienSpacing.m)
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
        }
        .animation(.default, value: viewModel.step)
    }
}

// MARK: - ステップの目印

/// 3つの点で現在地を示す。読み上げは「3ステップ中1」。
private struct OnboardingStepIndicator: View {
    let step: OnboardingViewModel.Step

    private var index: Int {
        switch step {
        case .concept: 0
        case .nickname: 1
        case .notification: 2
        }
    }

    var body: some View {
        HStack(spacing: LienSpacing.xs) {
            ForEach(0..<3, id: \.self) { i in
                Capsule()
                    .fill(i == index ? Color.accentColor : Color.secondary.opacity(0.25))
                    .frame(width: i == index ? 20 : 6, height: 6)
                    .animation(.easeInOut(duration: 0.2), value: index)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Strings.Onboarding.stepIndicator(index + 1))
    }
}

// MARK: - ページ1: コンセプト

private struct ConceptPage: View {
    let onStart: () -> Void

    var body: some View {
        // 文字を大きくする設定でも切れないよう、スクロールできる器に入れる
        ScrollView {
            VStack(spacing: LienSpacing.m) {
                // アプリの主役はタネの子。SF Symbols の葉ではなく、本物の絵を最初に見せる
                PlantCharacterView(
                    state: PlantCharacterState(stage: 3, meOpen: true, partnerOpen: true, expression: .happy)
                )
                .frame(width: 150, height: 200) // 3:4

                Text(Strings.Onboarding.conceptTitle)
                    .font(.title2.bold())
                    .multilineTextAlignment(.center)
                Text(Strings.Onboarding.conceptBody)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            // 画面の高さいっぱいに広げて中身を縦中央に置く(上に寄ると、下の余白だけが間延びする)
            .containerRelativeFrame(.vertical, alignment: .center)
            .padding(.horizontal, LienSpacing.l)
            .padding(.bottom, LienSpacing.m)
        }
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: LienSpacing.s) {
                Text(Strings.Onboarding.conceptNote)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button(action: onStart) {
                    Text(Strings.Onboarding.conceptStart)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
            .padding(.horizontal, LienSpacing.l)
            .padding(.bottom, LienSpacing.m)
        }
    }
}

// MARK: - ページ2: ニックネーム+アイコン

private struct NicknamePage: View {
    @Bindable var viewModel: OnboardingViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: LienSpacing.l) {
                Text(Strings.Onboarding.profileTitle)
                    .font(.title2.bold())
                    .padding(.top, LienSpacing.l)

                VStack(alignment: .leading, spacing: LienSpacing.s) {
                    TextField(Strings.Onboarding.nicknamePlaceholder, text: $viewModel.nickname)
                        .textFieldStyle(.roundedBorder)
                        .submitLabel(.done)
                    if let message = nicknameErrorMessage {
                        Text(message)
                            .font(.footnote)
                            .foregroundStyle(LienColors.gentleAlert)
                    }
                }

                VStack(alignment: .leading, spacing: LienSpacing.s) {
                    Text(Strings.Onboarding.avatarTitle)
                        .font(.headline)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 44))], spacing: LienSpacing.s) {
                        ForEach(Strings.Onboarding.avatarPalette, id: \.self) { emoji in
                            let selected = viewModel.avatarEmoji == emoji
                            Button {
                                viewModel.avatarEmoji = emoji
                            } label: {
                                Text(emoji)
                                    .font(.title2)
                                    .frame(width: 44, height: 44)
                                    .background(
                                        selected
                                            ? Color.accentColor.opacity(0.18)
                                            : Color.clear,
                                        in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    )
                                    // 選択が色だけだと分かりにくいので、枠でも示す
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                                            .strokeBorder(
                                                selected ? Color.accentColor : Color.clear,
                                                lineWidth: 1.5
                                            )
                                    )
                            }
                            .buttonStyle(.plain)
                            .accessibilityAddTraits(selected ? .isSelected : [])
                        }
                    }
                }

                // 規約への明示の同意(チェック)。同意ボタン(下の「同意してはじめる」)はチェックが入るまで押せない
                ConsentSection(isAgreed: $viewModel.agreedToTerms)
            }
            .padding(.horizontal, LienSpacing.l)
            .padding(.bottom, LienSpacing.m)
        }
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: LienSpacing.s) {
                // 押せない理由を、押せないあいだだけ書く(無効なボタンだけ置くと、なぜ進めないか分からない)
                if let blockedReason {
                    Text(blockedReason)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                if let errorMessage = viewModel.submitErrorMessage {
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundStyle(LienColors.gentleAlert)
                        .multilineTextAlignment(.center)
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
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, LienSpacing.l)
            .padding(.bottom, LienSpacing.m)
        }
    }

    /// 送信できない理由(無ければ nil)。ボタンの無効化だけに頼らない
    private var blockedReason: String? {
        if viewModel.trimmedNickname.isEmpty { return Strings.Onboarding.nicknameRequiredHint }
        if viewModel.nicknameError != nil { return nil }
        if !viewModel.agreedToTerms { return Strings.Onboarding.consentRequiredHint }
        return nil
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

// MARK: - 規約への同意(ページ2)

/// 利用規約・プライバシーポリシーへの同意のチェックと、それぞれを読むリンク(App Store ガイドライン 1.2 / issue #23)
private struct ConsentSection: View {
    @Binding var isAgreed: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                isAgreed.toggle()
            } label: {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: isAgreed ? "checkmark.square.fill" : "square")
                        .font(.title3)
                        .foregroundStyle(isAgreed ? Color.accentColor : Color.secondary)
                    Text(Strings.Onboarding.consentLabel)
                        .font(.subheadline)
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(.leading)
                }
            }
            .buttonStyle(.plain)
            .accessibilityValue(
                isAgreed ? Strings.Onboarding.consentCheckedValue : Strings.Onboarding.consentUncheckedValue
            )

            HStack(spacing: 16) {
                Link(Strings.Onboarding.consentTermsLink, destination: SupportLinks.termsURL)
                Link(Strings.Onboarding.consentPrivacyLink, destination: SupportLinks.privacyURL)
            }
            .font(.footnote)

            Text(Strings.Onboarding.consentNote)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - ページ3: 通知プレ許可

private struct NotificationPage: View {
    let viewModel: OnboardingViewModel

    var body: some View {
        ScrollView {
            VStack(spacing: LienSpacing.m) {
                Image(systemName: "bell.badge")
                    .font(.system(size: 56))
                    .foregroundStyle(.tint)
                    .padding(.top, LienSpacing.xl)
                Text(Strings.Onboarding.notificationTitle)
                    .font(.title2.bold())
                    .multilineTextAlignment(.center)
                Text(Strings.Onboarding.notificationBody)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, LienSpacing.l)
        }
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: LienSpacing.s) {
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
            .padding(.horizontal, LienSpacing.l)
            .padding(.bottom, LienSpacing.m)
        }
    }
}
