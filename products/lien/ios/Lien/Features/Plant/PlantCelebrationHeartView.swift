// PlantCelebrationHeartView.swift — 段階アップの演出の「(相手)にハートを送る」(issue #57 P1 / docs/GROWTH.md §5.2)
//
// T15 のリアクション ❤️ を使い回す(相手の今日のチェックインへ)。出すかどうか(canSend)は呼び出し側が決める:
// 相手が今日チェックイン済みで、**今日まだリアクションを送っていない**とき(送った日は、付け替えが相手に届かないので出さない —
// HomeViewModel.canSendHeart)。送ったあとは canSend が false になっても、「ハートを送ったよ」は残す。
// 失敗は責めない文言で、もう一度押せる(§3.5)。
// PlantCelebrationView.swift を 300 行の目安(DESIGN §9-4)に収めるため、ここに分けた。

import SwiftUI

struct PlantCelebrationHeartView: View {
    let partnerName: String
    /// ボタンを出すか(送ったあとは false になってよい)
    let canSend: Bool
    /// ハートを送る。成功したら true
    let onSend: () async -> Bool

    /// ボタンの状態
    private enum HeartState {
        case idle
        case sending
        case sent
        case failed
    }

    @State private var heartState: HeartState = .idle

    var body: some View {
        if canSend || heartState != .idle {
            VStack(spacing: LienSpacing.xs) {
                switch heartState {
                case .idle, .failed:
                    Button {
                        Task { await send() }
                    } label: {
                        Text(Strings.Plant.celebrationHeart(partnerName))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    if heartState == .failed {
                        Text(Strings.Plant.celebrationHeartError)
                            .font(.footnote)
                            .foregroundStyle(LienColors.gentleAlert)
                            .multilineTextAlignment(.center)
                    }
                case .sending:
                    Text(Strings.Plant.celebrationHeartSending)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                case .sent:
                    Text(Strings.Plant.celebrationHeartSent)
                        .font(.footnote)
                        .foregroundStyle(LienColors.done)
                }
            }
        }
    }

    private func send() async {
        heartState = .sending
        heartState = await onSend() ? .sent : .failed
    }
}
