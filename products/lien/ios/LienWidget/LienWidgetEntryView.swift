// LienWidgetEntryView.swift — systemSmall のレイアウト(T07。DESIGN §3.5 / REQUIREMENTS §3.10)
//
// 表示原則(REQUIREMENTS §3.10):
//   - 自分が未完なら自分側をグレー
//   - 相手が先に完了していたら「(名前)が待ってるよ」を見せる
//
// 植物(issue #56 の試作。本実装は T17a):
//   アプリ本体と同じ PlantCharacterView(SVG レイヤーの重ね合わせ。PlantAssets.xcassets を共有)で描く。
//   ウィジェットで全レイヤーを重ねて描けるか・メモリに収まるかを実機で確かめる(GROWTH §9.5)。
//   収まらないときの代わりの案は、段階 × 葉の状態をあらかじめ1枚に合成した画像を持つこと。
//   T17a で: 「色合い(accented)」表示でも単色にならないよう、各 Image に widgetAccentedRenderingMode(.fullColor) を付ける。

import SwiftUI
import WidgetKit

struct LienWidgetEntryView: View {
    let entry: LienTimelineEntry

    var body: some View {
        if let snapshot = entry.snapshot {
            SnapshotView(snapshot: snapshot)
        } else {
            EmptyStateView()
        }
    }
}

/// snapshot がある通常表示: 植物+ストリーク+2人の今日の状態
private struct SnapshotView: View {
    let snapshot: PairSnapshot

    var body: some View {
        VStack(spacing: 6) {
            // 3:4 を保ったまま、残りの高さに収まるまで縮む(下の文字・チップを優先する)
            PlantCharacterView(state: PlantCharacterState(snapshot: snapshot))
                .frame(maxHeight: 84)

            if snapshot.pairId == nil {
                // ソロ状態: タネの子は鉢の土の中で眠っている(REQUIREMENTS §3.9)
                Text(Strings.Widget.soloCaption)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            } else {
                if snapshot.streakCurrent > 0 {
                    Text("🔥 " + Strings.Widget.streakDays(snapshot.streakCurrent))
                        .font(.caption.bold())
                }

                HStack(spacing: 10) {
                    StatusChip(
                        emoji: snapshot.myPromiseEmoji,
                        fallbackLabel: Strings.Widget.meFallbackLabel,
                        done: snapshot.todayMeDone
                    )
                    StatusChip(
                        emoji: snapshot.partnerPromiseEmoji,
                        fallbackLabel: snapshot.partnerName ?? Strings.Widget.partnerFallbackLabel,
                        done: snapshot.todayPartnerDone
                    )
                }

                if snapshot.todayPartnerDone, !snapshot.todayMeDone,
                   let partnerName = snapshot.partnerName {
                    // 相手が先に完了 →「(名前)が待ってるよ」(REQUIREMENTS §3.10)
                    Text(Strings.Widget.partnerWaiting(partnerName))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
            }
        }
        .padding(4)
    }
}

/// 1人分の今日の状態。自分未完=グレー表示(REQUIREMENTS §3.10)
private struct StatusChip: View {
    let emoji: String?
    let fallbackLabel: String
    let done: Bool

    var body: some View {
        VStack(spacing: 2) {
            Text(emoji ?? "・")
                .font(.body)
            Image(systemName: done ? "checkmark.circle.fill" : "circle")
                .font(.caption)
                .foregroundStyle(done ? Color.green : Color.gray)
        }
        .opacity(done ? 1.0 : 0.45)
        .accessibilityLabel(fallbackLabel)
    }
}

/// snapshot が無い(初回起動前)ときの空状態
private struct EmptyStateView: View {
    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: "leaf")
                .font(.title2)
                .foregroundStyle(.secondary)
            Text(Strings.Widget.emptyTitle)
                .font(.caption.bold())
            Text(Strings.Widget.emptyMessage)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(4)
    }
}
