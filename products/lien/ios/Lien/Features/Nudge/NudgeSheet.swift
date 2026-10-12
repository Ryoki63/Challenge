// NudgeSheet.swift — つつく/リアクションのスタンプ選択 UI(T15 / REQUIREMENTS §3.7, §3.8)
//
// - 自由テキスト入力は無し。スタンプのグリッドをタップするだけ(チャット化を避ける — §3.7)
// - 送信中はグリッドを disabled にし、ProgressView を重ねる(他ボタンと同じ「押しっぱなし」防止)
// - 送信後はシートを閉じる(結果の一言は HomeView 側の messageArea で表示 — CheckinFlowView と同じ構成)

import SwiftUI

@MainActor
struct NudgeSheet: View {
    let viewModel: HomeViewModel
    @Binding var isPresented: Bool

    var body: some View {
        VStack(spacing: LienSpacing.m) {
            Text(Strings.Nudge.sheetTitle)
                .font(.headline)
            Text(Strings.Nudge.sheetSubtitle)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            StampGrid(stamps: NudgeStamp.allCases, isDisabled: viewModel.isSendingNudge) { stamp in
                Task {
                    await viewModel.sendNudge(stamp: stamp)
                    isPresented = false
                }
            }

            if viewModel.isSendingNudge {
                ProgressView()
            }
        }
        .padding(LienSpacing.l)
        .presentationDetents([.medium])
    }
}

@MainActor
struct ReactionSheet: View {
    let viewModel: HomeViewModel
    @Binding var isPresented: Bool

    var body: some View {
        VStack(spacing: LienSpacing.m) {
            Text(Strings.Reaction.sheetTitle)
                .font(.headline)

            StampGrid(stamps: ReactionStamp.allCases, isDisabled: viewModel.isSendingReaction) { stamp in
                Task {
                    await viewModel.sendReaction(stamp: stamp)
                    isPresented = false
                }
            }

            if viewModel.isSendingReaction {
                ProgressView()
            }
        }
        .padding(LienSpacing.l)
        .presentationDetents([.medium])
    }
}

/// スタンプの固定語彙グリッド(RawRepresentable == String なスタンプ enum に対して汎用)。
/// 自由入力欄は意図的に置かない(§3.7)
private struct StampGrid<Stamp: Hashable & RawRepresentable>: View where Stamp.RawValue == String {
    let stamps: [Stamp]
    let isDisabled: Bool
    let onSelect: (Stamp) -> Void

    private let columns = Array(repeating: GridItem(.flexible()), count: 3)

    var body: some View {
        LazyVGrid(columns: columns, spacing: LienSpacing.s) {
            ForEach(stamps, id: \.self) { stamp in
                Button {
                    onSelect(stamp)
                } label: {
                    Text(stamp.rawValue)
                        .font(.largeTitle)
                        .frame(maxWidth: .infinity, minHeight: 56)
                }
                .buttonStyle(.bordered)
                .disabled(isDisabled)
            }
        }
    }
}

// MARK: - Preview

#if DEBUG
@MainActor
private func makePreviewViewModel(snapshot: PairSnapshot) -> HomeViewModel {
    let store = AppGroupStore.preview(snapshot: snapshot)
    let vm = HomeViewModel(store: store, checkinService: LocalEchoCheckinService(), reloadWidgets: {})
    vm.load()
    return vm
}

#Preview("つつく") {
    NudgeSheet(
        viewModel: makePreviewViewModel(
            snapshot: PairSnapshot.previewValue(todayPartnerDone: false)
        ),
        isPresented: .constant(true)
    )
}

#Preview("リアクション") {
    ReactionSheet(
        viewModel: makePreviewViewModel(
            snapshot: PairSnapshot.previewValue(todayPartnerDone: true)
        ),
        isPresented: .constant(true)
    )
}
#endif
