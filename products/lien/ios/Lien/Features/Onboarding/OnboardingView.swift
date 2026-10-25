// OnboardingView.swift — オンボーディング(T10 / REQUIREMENTS §6)
//
// 1画面に、コンセプト → ニックネーム+絵文字 → 規約の同意 → 通知の予告 をすべて置く。
// もとは3画面に分けていたが、実測すると1画面に収まる分量だったので分けるのをやめた
// (2026-10-25 の UI/UX レビュー。画面を分けないならステップ目印も要らない)。
//
// 送信は匿名のサインイン(アカウントの作成)を兼ねるので、規約への明示の同意が入るまで押せない
// (App Store ガイドライン 1.2 / issue #23)。押せない理由は、押せないあいだだけ1行で書く。
// 通知の許可は、送信できたあとに続けて OS のダイアログで求める(拒否されても完了する — issue #10)。
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

    /// 組み立て済みの ViewModel で描く(プレビュー・描画テスト用)。
    /// scrolls = false は、ImageRenderer が ScrollView を描けないため(スクロール位置が先頭のときの見た目と同じ)
    init(viewModel: OnboardingViewModel, scrolls: Bool = true) {
        _viewModel = State(initialValue: viewModel)
        self.scrolls = scrolls
    }

    private var scrolls = true

    // 下端の帯は safeAreaInset ではなく VStack で積む。Group に safeAreaInset を付けた形では
    // 帯が描かれなかった(実描画で確認)。スクロールの器と帯を兄弟にすれば確実に固定できる
    // (内容が帯の下を流れる半透明の効果は失うが、そのぶん読みやすい)
    @ViewBuilder
    var body: some View {
        VStack(spacing: 0) {
            if scrolls {
                ScrollView { content }
                    // 送信中はキーボードを閉じて、ボタンのスピナーとダイアログに集中させる
                    .scrollDismissesKeyboard(.interactively)
            } else {
                content
                Spacer(minLength: 0)
            }
            footer
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: LienSpacing.l) {
            header
            profileFields
            ConsentSection(isAgreed: $viewModel.agreedToTerms)
            notificationNote

            // 匿名開始の注意(DESIGN §10 の明示義務)
            Text(Strings.Onboarding.anonymousStartNote)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, LienSpacing.l)
        .padding(.bottom, LienSpacing.m)
    }

    // MARK: - 冒頭(コンセプト)

    private var header: some View {
        VStack(spacing: LienSpacing.s) {
            // アプリの主役はタネの子。SF Symbols の葉ではなく、本物の絵を最初に見せる
            PlantCharacterView(
                state: PlantCharacterState(stage: 3, meOpen: true, partnerOpen: true, expression: .happy)
            )
            .frame(width: 104, height: 139) // 3:4
            .padding(.top, LienSpacing.m)

            Text(Strings.Onboarding.conceptTitle)
                .font(.title2.bold())
                .foregroundStyle(.primary)
            Text(Strings.Onboarding.conceptBody)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text(Strings.Onboarding.conceptNote)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .multilineTextAlignment(.center)
    }

    // MARK: - ニックネームとアイコン

    private var profileFields: some View {
        VStack(alignment: .leading, spacing: LienSpacing.m) {
            VStack(alignment: .leading, spacing: LienSpacing.s) {
                Text(Strings.Onboarding.profileTitle)
                    .font(.headline)
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
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
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
                                    selected ? Color.accentColor.opacity(0.18) : Color.clear,
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
        }
    }

    // MARK: - 通知の予告(OS のダイアログの前に、何に使うかを書く)

    private var notificationNote: some View {
        HStack(alignment: .top, spacing: LienSpacing.s) {
            Image(systemName: "bell")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(Strings.Onboarding.notificationTitle)
                    .font(.footnote.weight(.medium))
                Text(Strings.Onboarding.notificationBody)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: - 下部の固定(理由 + 送信)

    private var footer: some View {
        VStack(spacing: LienSpacing.s) {
            // 押せない理由を、押せないあいだだけ書く(無効なボタンだけ置くと、なぜ進めないか分からない)
            if let blockedReason = blockedReason {
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

            submitButton
        }
        .padding(.horizontal, LienSpacing.l)
        .padding(.top, LienSpacing.s)
        .padding(.bottom, LienSpacing.m)
        .background(.bar)
    }

    /// 送信ボタン。押せないあいだは淡い塗り + 枠線にする。
    /// iOS 26 の無効な .borderedProminent はほぼ白になり、ボタンの形が見えなくなるため自作する
    private var submitButton: some View {
        let ready = viewModel.canSubmitProfile
        return Button {
            Task { await viewModel.submitAndFinish() }
        } label: {
            Group {
                if viewModel.isSubmitting {
                    ProgressView()
                } else {
                    Text(submitButtonTitle)
                }
            }
            .font(.body.weight(.semibold))
            .foregroundStyle(ready ? Color.white : LienColors.accent)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 15)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(ready ? LienColors.accent : LienColors.accent.opacity(0.14))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(ready ? Color.clear : LienColors.accent.opacity(0.45), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .disabled(!ready)
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

// MARK: - 規約への同意

/// 利用規約・プライバシーポリシーへの同意のチェックと、それぞれを読むリンク(App Store ガイドライン 1.2 / issue #23)
private struct ConsentSection: View {
    @Binding var isAgreed: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: LienSpacing.s) {
            Button {
                isAgreed.toggle()
            } label: {
                HStack(alignment: .top, spacing: LienSpacing.s) {
                    Image(systemName: isAgreed ? "checkmark.square.fill" : "square")
                        .font(.title3)
                        .foregroundStyle(isAgreed ? Color.accentColor : Color.secondary)
                    Text(Strings.Onboarding.consentLabel)
                        .font(.footnote)
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(.leading)
                }
            }
            .buttonStyle(.plain)
            .accessibilityValue(
                isAgreed ? Strings.Onboarding.consentCheckedValue : Strings.Onboarding.consentUncheckedValue
            )

            HStack(spacing: LienSpacing.m) {
                Link(Strings.Onboarding.consentTermsLink, destination: SupportLinks.termsURL)
                Link(Strings.Onboarding.consentPrivacyLink, destination: SupportLinks.privacyURL)
            }
            .font(.caption)

            Text(Strings.Onboarding.consentNote)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}
