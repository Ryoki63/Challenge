// ModerationView.swift — ホームの長押しメニュー(通報・ブロック)と、その確認の表示(T23 #23)
//
// App Store ガイドライン 1.2(UGC): 相手が共有するコンテンツ(写真・ニックネーム・約束の文・植物の名前)を
// 長押しして、通報(運営宛のメールの下書き)かブロック(= ペア解消)ができる。
//   - 写真: PartnerPhotoView の長押し(PartnerPhotoModel.actions。RootView が作る)
//   - 相手のチップ(ニックネームと約束の文)・植物の名前: このファイルの modifier
// VoiceOver には同じ操作をアクションとして出す(長押しのメニューは VoiceOver から開きにくい)。
// 確認の表示(通報の確認・メールを開けなかったとき・ブロックの説明シート)は ModerationPresentation が
// ホームにまとめて付ける。状態は ModerationViewModel。

import SwiftUI

// MARK: - 長押しメニュー

/// 相手のチップ(ニックネームと約束の文)の長押しメニュー。moderation が nil(Stub 構成・プレビュー)なら何も付けない
struct PartnerChipMenu: ViewModifier {
    let moderation: ModerationViewModel?
    let nickname: String?
    let promiseEmoji: String?
    let promiseTitle: String?

    func body(content: Content) -> some View {
        if let moderation {
            content
                .contextMenu {
                    Button {
                        moderation.requestReport(.nickname(nickname ?? ""))
                    } label: {
                        Label(Strings.Report.menuReportNickname, systemImage: "flag")
                    }
                    Button {
                        moderation.requestReport(.promise(emoji: promiseEmoji, title: promiseTitle))
                    } label: {
                        Label(Strings.Report.menuReportPromise, systemImage: "flag")
                    }
                    Button(role: .destructive) {
                        moderation.requestBlock()
                    } label: {
                        Label(Strings.Report.menuBlock, systemImage: "hand.raised")
                    }
                }
                .accessibilityActions {
                    Button(Strings.Report.menuReportNickname) {
                        moderation.requestReport(.nickname(nickname ?? ""))
                    }
                    Button(Strings.Report.menuReportPromise) {
                        moderation.requestReport(.promise(emoji: promiseEmoji, title: promiseTitle))
                    }
                    Button(Strings.Report.menuBlock) {
                        moderation.requestBlock()
                    }
                }
        } else {
            content
        }
    }
}

/// 植物の名前の長押しメニュー(名前はどちらのペアも付けられるので、通報の対象になる)
struct PlantNameMenu: ViewModifier {
    let moderation: ModerationViewModel?
    let plantName: String

    func body(content: Content) -> some View {
        if let moderation {
            content
                .contextMenu {
                    Button {
                        moderation.requestReport(.plantName(plantName))
                    } label: {
                        Label(Strings.Report.menuReportPlantName, systemImage: "flag")
                    }
                    Button(role: .destructive) {
                        moderation.requestBlock()
                    } label: {
                        Label(Strings.Report.menuBlock, systemImage: "hand.raised")
                    }
                }
                .accessibilityActions {
                    Button(Strings.Report.menuReportPlantName) {
                        moderation.requestReport(.plantName(plantName))
                    }
                    Button(Strings.Report.menuBlock) {
                        moderation.requestBlock()
                    }
                }
        } else {
            content
        }
    }
}

extension View {
    /// 相手のチップに、通報とブロックの長押しメニューを付ける
    func partnerChipMenu(
        _ moderation: ModerationViewModel?,
        nickname: String?,
        promiseEmoji: String?,
        promiseTitle: String?
    ) -> some View {
        modifier(PartnerChipMenu(
            moderation: moderation,
            nickname: nickname,
            promiseEmoji: promiseEmoji,
            promiseTitle: promiseTitle
        ))
    }

    /// 植物の名前に、通報とブロックの長押しメニューを付ける
    func plantNameMenu(_ moderation: ModerationViewModel?, plantName: String) -> some View {
        modifier(PlantNameMenu(moderation: moderation, plantName: plantName))
    }

    /// ホームに、通報の確認・メールを開けなかったときのアラート・ブロックの説明シートを付ける(nil なら何もしない)
    @ViewBuilder
    func moderationPresentation(_ moderation: ModerationViewModel?) -> some View {
        if let moderation {
            modifier(ModerationPresentation(moderation: moderation))
        } else {
            self
        }
    }
}

// MARK: - 確認の表示

/// ホームにまとめて付ける、通報・ブロックの確認:
///   - 通報の確認(「この内容を通報しますか?」→「メールを開く」)
///   - メールを開けなかったとき(メールアプリが無い・宛先が不正)のアラート
///   - ブロック(= ペア解消)の説明シート → 最後の確認のアラート(DestructiveConfirmView)
struct ModerationPresentation: ViewModifier {
    let moderation: ModerationViewModel

    @Environment(\.openURL) private var openURL

    func body(content: Content) -> some View {
        content
            .confirmationDialog(
                Strings.Report.confirmTitle,
                isPresented: reportBinding,
                titleVisibility: .visible
            ) {
                Button(Strings.Report.openMail) {
                    openReportMail()
                }
                Button(Strings.Report.cancel, role: .cancel) {
                    moderation.cancelReport()
                }
            } message: {
                Text(Strings.Report.confirmMessage)
            }
            .alert(Strings.Report.mailFailedTitle, isPresented: mailFailureBinding) {
                Button(Strings.Report.mailFailedOK, role: .cancel) {}
            } message: {
                Text(Strings.Report.mailFailedMessage)
            }
            .sheet(isPresented: blockBinding) {
                NavigationStack {
                    DissolvePairConfirmView(flow: moderation.block)
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                Button(Strings.Dissolve.cancel) {
                                    moderation.block.cancel()
                                }
                                .disabled(moderation.block.stage == .working)
                            }
                        }
                }
                .interactiveDismissDisabled(moderation.block.stage == .working)
            }
    }

    private var reportBinding: Binding<Bool> {
        Binding(
            get: { moderation.pendingReport != nil },
            set: { isPresented in
                if !isPresented { moderation.cancelReport() }
            }
        )
    }

    private var mailFailureBinding: Binding<Bool> {
        Binding(
            get: { moderation.showsMailFailure },
            set: { moderation.showsMailFailure = $0 }
        )
    }

    /// ブロックの説明シートを出しているか(流れが idle でない間)。下げて閉じたら取り消す(実行中は閉じられない)
    private var blockBinding: Binding<Bool> {
        Binding(
            get: { moderation.block.stage != .idle },
            set: { isPresented in
                if !isPresented { moderation.block.cancel() }
            }
        )
    }

    private func openReportMail() {
        guard let url = moderation.confirmReport() else { return }
        let moderation = moderation
        openURL(url) { accepted in
            if !accepted {
                Task { @MainActor in moderation.mailOpenFailed() }
            }
        }
    }
}
