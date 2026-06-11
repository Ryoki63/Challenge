// PairingView.swift — 招待画面(T11 / REQUIREMENTS §3.2 / DESIGN §6)
//
// solo 系統のルート画面。招待の3導線(リンク共有 / QR 表示 / 8文字コード手入力)を1画面に置く。
// 文言は Strings.Pairing に集約(View 内に直書きしない — DESIGN §3.8)。
// QR には webUrl をエンコードする(アプリ未所持の相手でも静的ページ経由で誘導できる。
// アプリ所持済みなら静的ページの「アプリで開く」→ lien:// で合流 — DESIGN §6)。

import SwiftUI

@MainActor
struct PairingView: View {
    @State private var viewModel: PairingViewModel
    /// ディープリンクで受けた招待コード(消費したら nil に戻す)
    @Binding private var pendingInviteToken: String?

    init(
        inviteClient: InviteClient,
        store: AppGroupStore?,
        pendingInviteToken: Binding<String?>,
        onPaired: @escaping () -> Void
    ) {
        _viewModel = State(initialValue: PairingViewModel(
            inviteClient: inviteClient,
            store: store,
            onPaired: onPaired
        ))
        _pendingInviteToken = pendingInviteToken
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text(Strings.Pairing.title)
                    .font(.title2.bold())
                    .padding(.top, 32)
                Text(Strings.Pairing.subtitle)
                    .font(.body)
                    .foregroundStyle(.secondary)

                InviteSection(viewModel: viewModel)
                Divider()
                AcceptSection(viewModel: viewModel)

                #if DEBUG
                // G1 計測用ハーネス(issue #8 準備②)。Release には含まれない
                DeviceTokenDebugView()
                #endif
            }
            .padding(24)
        }
        .onAppear { consumePendingToken() }
        .onChange(of: pendingInviteToken) { consumePendingToken() }
    }

    /// ディープリンクのコードを入力欄へプリフィルする(自動送信はしない —
    /// 実 invite-accept 結線後の自動受諾は後続タスク。DESIGN §3.6)
    private func consumePendingToken() {
        guard let token = pendingInviteToken else { return }
        viewModel.prefill(token: token)
        pendingInviteToken = nil
    }
}

// MARK: - 招待をおくる(発行: リンク / QR / コード)

private struct InviteSection: View {
    let viewModel: PairingViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(Strings.Pairing.inviteSectionTitle)
                .font(.headline)

            switch viewModel.issueState {
            case .idle, .loading:
                Text(Strings.Pairing.inviteExplainer)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                if let message = viewModel.issueErrorMessage {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
                Button {
                    Task { await viewModel.issueInvite() }
                } label: {
                    if viewModel.issueState == .loading {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                    } else {
                        Text(Strings.Pairing.issueButton)
                            .frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(viewModel.issueState == .loading)

            case .issued(let invite):
                IssuedInviteContent(invite: invite)
            }
        }
    }
}

/// 発行済み招待の表示(QR / コード / 共有リンクの3導線)
private struct IssuedInviteContent: View {
    let invite: InviteCreateResponse

    var body: some View {
        VStack(spacing: 12) {
            if let qrImage = QRCodeGenerator.generate(from: invite.webUrl) {
                Image(decorative: qrImage, scale: 1)
                    .resizable()
                    .interpolation(.none) // 整数倍拡大でにじませない
                    .frame(width: 200, height: 200)
                    .accessibilityLabel(Strings.Pairing.qrCaption)
                Text(Strings.Pairing.qrCaption)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            VStack(spacing: 4) {
                Text(Strings.Pairing.codeCaption)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Text(invite.token)
                    .font(.title.monospaced().bold())
                    .textSelection(.enabled)
            }

            if let url = invite.webURL {
                ShareLink(item: url, message: Text(Strings.Pairing.shareMessage)) {
                    Label(Strings.Pairing.shareButton, systemImage: "square.and.arrow.up")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }

            Text(Strings.Pairing.expiresNote(
                invite.expiresAt.formatted(date: .abbreviated, time: .shortened)
            ))
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - コードを入力(受諾)

private struct AcceptSection: View {
    @Bindable var viewModel: PairingViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(Strings.Pairing.acceptSectionTitle)
                .font(.headline)
            Text(Strings.Pairing.acceptExplainer)
                .font(.footnote)
                .foregroundStyle(.secondary)

            TextField(Strings.Pairing.codePlaceholder, text: $viewModel.codeInput)
                .textFieldStyle(.roundedBorder)
                .font(.body.monospaced())
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.done)

            if let message = viewModel.acceptErrorMessage {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }

            Button {
                Task { await viewModel.acceptInvite() }
            } label: {
                if viewModel.isAccepting {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                } else {
                    Text(Strings.Pairing.acceptButton)
                        .frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .disabled(!viewModel.canAccept)
        }
    }
}
