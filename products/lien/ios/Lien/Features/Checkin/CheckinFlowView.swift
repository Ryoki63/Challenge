// CheckinFlowView.swift — チェックインフロー UI(T14 / REQUIREMENTS §3.4)
//
// ホーム画面のチェックイン領域(T13 の CheckinArea を置き換え):
//   未完: 1タップの「できた!」ボタン
//   完了済: 「今日のぶんは完了」+「写真を添える」(PhotosPicker)+「取り消す」(confirmationDialog)
// 文言は Strings.Home / Strings.Checkin に集約(罰・恥系は使わない — §3.5。取消も責めない)。
//
// - 写真はフォトライブラリ(PhotosPicker)から選ぶ。PhotosPicker はプロセス外 UI のため
//   Info.plist の利用許可文言は不要。カメラ撮影(§3.4「撮影 or ライブラリ」)は
//   NSCameraUsageDescription(project.yml)が必要なため後続タスクに分離(issue #14 に明記)
// - 取消・写真の導線は HomeViewModel の能力検出(canCancelCheckin / canAttachPhoto)に従う。
//   LocalEchoCheckinService 注入時(実 API 未結線)は自動的に非表示になる

import SwiftUI
import PhotosUI

@MainActor
struct CheckinFlowView: View {
    let viewModel: HomeViewModel

    @State private var showsCancelDialog = false
    @State private var photoItem: PhotosPickerItem?

    private var isDone: Bool {
        viewModel.snapshot?.todayMeDone == true
    }

    var body: some View {
        VStack(spacing: LienSpacing.s) {
            messageArea

            if isDone {
                doneStateControls
            } else {
                checkinButton
            }
        }
        .confirmationDialog(
            Strings.Checkin.cancelDialogTitle,
            isPresented: $showsCancelDialog,
            titleVisibility: .visible
        ) {
            Button(Strings.Checkin.cancelConfirm) {
                Task { await viewModel.performCancel() }
            }
            Button(Strings.Checkin.cancelKeep, role: .cancel) {}
        } message: {
            Text(Strings.Checkin.cancelDialogMessage)
        }
        .onChange(of: photoItem) {
            guard let item = photoItem else { return }
            photoItem = nil
            Task {
                // 取り出せなかった場合も責めない定型文言で再試行に誘導(§3.5)
                if let data = try? await item.loadTransferable(type: Data.self) {
                    await viewModel.attachPhoto(data)
                } else {
                    await viewModel.attachPhoto(Data()) // 空データは処理側で unreadable → エラー文言
                }
            }
        }
    }

    // MARK: 文言エリア(エラー/完了の一言。責めない文言のみ — §3.5)

    @ViewBuilder
    private var messageArea: some View {
        if let message = viewModel.checkinErrorMessage
            ?? viewModel.cancelErrorMessage
            ?? viewModel.photoErrorMessage {
            Text(message)
                .font(.footnote)
                .foregroundStyle(LienColors.gentleAlert)
                .multilineTextAlignment(.center)
        } else if let note = viewModel.photoAttachedNote {
            Text(note)
                .font(.footnote)
                .foregroundStyle(LienColors.done)
                .multilineTextAlignment(.center)
        }
    }

    // MARK: 未完: チェックインボタン(1日1回 — §3.4)

    private var checkinButton: some View {
        Button {
            Task { await viewModel.performCheckin() }
        } label: {
            Group {
                if viewModel.isCheckingIn {
                    ProgressView()
                } else {
                    Text(Strings.Home.checkinButton)
                }
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .disabled(!viewModel.canCheckin)
    }

    // MARK: 完了済: 完了表示+写真添付+当日取消(§3.4)

    @ViewBuilder
    private var doneStateControls: some View {
        Label(Strings.Home.checkinDoneLabel, systemImage: "checkmark.circle.fill")
            .font(.headline)
            .foregroundStyle(LienColors.done)
            .frame(maxWidth: .infinity)
            .padding(.vertical, LienSpacing.s)

        HStack(spacing: LienSpacing.s) {
            if viewModel.canAttachPhoto || viewModel.isAttachingPhoto {
                PhotosPicker(selection: $photoItem, matching: .images) {
                    Group {
                        if viewModel.isAttachingPhoto {
                            Label(Strings.Checkin.attachPhotoSending, systemImage: "photo")
                        } else {
                            Label(Strings.Checkin.attachPhotoButton, systemImage: "photo")
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(!viewModel.canAttachPhoto)
            }

            if viewModel.canCancelCheckin || viewModel.isCanceling {
                Button {
                    showsCancelDialog = true
                } label: {
                    Group {
                        if viewModel.isCanceling {
                            ProgressView()
                        } else {
                            Text(Strings.Checkin.cancelButton)
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(!viewModel.canCancelCheckin)
            }
        }
        .font(.subheadline)
    }
}

// MARK: - Preview(CheckinService+StubCheckinAPIClient = 実装系の結線をそのまま確認)

#if DEBUG
@MainActor
private func makePreviewViewModel(snapshot: PairSnapshot) -> HomeViewModel {
    let store = AppGroupStore.preview(snapshot: snapshot)
    let service = CheckinService(
        api: StubCheckinAPIClient(snapshot: snapshot),
        queue: PendingOpsQueue(store: store)
    )
    let vm = HomeViewModel(store: store, checkinService: service, reloadWidgets: {})
    vm.load()
    return vm
}

#Preview("未完(チェックインボタン)") {
    CheckinFlowView(viewModel: makePreviewViewModel(
        snapshot: PairSnapshot.previewValue(todayMeDone: false)
    ))
    .padding()
}

#Preview("完了済(写真+取消の導線)") {
    CheckinFlowView(viewModel: makePreviewViewModel(
        snapshot: PairSnapshot.previewValue(todayMeDone: true, todayPartnerDone: true, plantMood: .happy)
    ))
    .padding()
}

#Preview("ソロ完了済(写真導線なし)") {
    CheckinFlowView(viewModel: makePreviewViewModel(
        snapshot: PairSnapshot.previewValue(pairId: nil, todayMeDone: true, todayPartnerDone: false)
    ))
    .padding()
}
#endif
