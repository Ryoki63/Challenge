// DestructiveConfirmView.swift — 取り消せない操作の確認画面(ペアの解消・アカウントの削除。T23 #23)
//
// 確認は2段階(DestructiveFlow):
//   1. この画面 — 何が起きるか(消えるもの・残るもの)を説明する。ボタンを押すと次へ
//   2. 最後の確認のアラート — 「本当に〜しますか?」。ここの「実行」を押して初めて操作が走る
// 説明の画面は、設定画面(NavigationStack に push)とホームの長押しのブロック(シート)の両方で使う。
// 文言は Strings.Dissolve / Strings.DeleteAccount、色・余白は DesignSystem の定数(DESIGN §3.8)。

import SwiftUI

@MainActor
struct DestructiveConfirmView: View {
    struct Content {
        let screenTitle: String
        let lead: String
        /// 何が起きるか(消える・止まる・残るもの)。1 行ずつ
        let effects: [String]
        /// 補足(相手への知らせ・元に戻せないこと)
        let footnote: String?
        let buttonTitle: String
        let workingTitle: String
        let finalTitle: String
        let finalMessage: String
        let finalConfirm: String
        let cancelTitle: String
    }

    let flow: DestructiveFlow
    let content: Content

    var body: some View {
        Form {
            Section {
                Text(content.lead)
                    .font(.body)
                    .listRowBackground(Color.clear)
            }

            Section {
                ForEach(content.effects, id: \.self) { effect in
                    Text(effect)
                        .font(.subheadline)
                }
            }

            if let footnote = content.footnote {
                Section {
                    Text(footnote)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .listRowBackground(Color.clear)
                }
            }

            Section {
                if let message = flow.errorMessage {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(LienColors.gentleAlert)
                }
                Button(role: .destructive) {
                    flow.proceedToFinalConfirmation()
                } label: {
                    if flow.stage == .working {
                        HStack(spacing: LienSpacing.s) {
                            ProgressView()
                            Text(content.workingTitle)
                        }
                        .frame(maxWidth: .infinity)
                    } else {
                        Text(content.buttonTitle)
                            .frame(maxWidth: .infinity)
                    }
                }
                .disabled(flow.stage == .working)
            }
        }
        .navigationTitle(content.screenTitle)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        // 実行中は戻れない(途中で閉じて、結果を見失わないように)
        .navigationBarBackButtonHiddenWhile(flow.stage == .working)
        .interactiveDismissDisabled(flow.stage == .working)
        .alert(content.finalTitle, isPresented: finalPromptBinding) {
            Button(content.finalConfirm, role: .destructive) {
                flow.confirm()
            }
            Button(content.cancelTitle, role: .cancel) {
                flow.dismissFinalPrompt()
            }
        } message: {
            Text(content.finalMessage)
        }
    }

    /// 最後の確認のアラートを出しているか。閉じられたとき(「やめる」・外側のタップ)に、
    /// 実行へ進んでいなければ説明の画面へ戻す(finalPromptDidClose)
    private var finalPromptBinding: Binding<Bool> {
        Binding(
            get: { flow.stage == .finalPrompt },
            set: { isPresented in
                if !isPresented { flow.finalPromptDidClose() }
            }
        )
    }
}

private extension View {
    /// 戻るボタンを隠す(iOS だけ。macOS の型検査では何もしない)
    @ViewBuilder
    func navigationBarBackButtonHiddenWhile(_ hidden: Bool) -> some View {
        #if os(iOS)
        navigationBarBackButtonHidden(hidden)
        #else
        self
        #endif
    }
}

// MARK: - ペアの解消 / アカウントの削除

extension DestructiveConfirmView.Content {
    /// ペアの解消(= ブロック)の説明
    static var dissolvePair: Self {
        Self(
            screenTitle: Strings.Dissolve.screenTitle,
            lead: Strings.Dissolve.lead,
            effects: [
                Strings.Dissolve.effectPhotos,
                Strings.Dissolve.effectNudges,
                Strings.Dissolve.effectArchive,
                Strings.Dissolve.effectHistory,
            ],
            footnote: Strings.Dissolve.partnerNote,
            buttonTitle: Strings.Dissolve.button,
            workingTitle: Strings.Dissolve.working,
            finalTitle: Strings.Dissolve.finalTitle,
            finalMessage: Strings.Dissolve.finalMessage,
            finalConfirm: Strings.Dissolve.finalConfirm,
            cancelTitle: Strings.Dissolve.cancel
        )
    }

    /// アカウントの削除の説明
    static var deleteAccount: Self {
        Self(
            screenTitle: Strings.DeleteAccount.screenTitle,
            lead: Strings.DeleteAccount.lead,
            effects: [
                Strings.DeleteAccount.effectProfile,
                Strings.DeleteAccount.effectPhotos,
                Strings.DeleteAccount.effectPair,
            ],
            footnote: Strings.DeleteAccount.irreversible,
            buttonTitle: Strings.DeleteAccount.button,
            workingTitle: Strings.DeleteAccount.working,
            finalTitle: Strings.DeleteAccount.finalTitle,
            finalMessage: Strings.DeleteAccount.finalMessage,
            finalConfirm: Strings.DeleteAccount.finalConfirm,
            cancelTitle: Strings.DeleteAccount.cancel
        )
    }
}

/// ペアの解消の説明画面(設定の NavigationStack とホームの長押しのシートで共有)
@MainActor
struct DissolvePairConfirmView: View {
    let flow: DestructiveFlow

    var body: some View {
        DestructiveConfirmView(flow: flow, content: .dissolvePair)
    }
}

/// アカウントの削除の説明画面
@MainActor
struct DeleteAccountConfirmView: View {
    let flow: DestructiveFlow

    var body: some View {
        DestructiveConfirmView(flow: flow, content: .deleteAccount)
    }
}
