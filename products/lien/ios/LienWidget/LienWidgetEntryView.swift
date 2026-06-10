// LienWidgetEntryView.swift — systemSmall のレイアウト(T07。DESIGN §3.5 / REQUIREMENTS §3.10)
//
// 表示原則(REQUIREMENTS §3.10):
//   - 自分が未完なら自分側をグレー
//   - 相手が先に完了していたら「(名前)が待ってるよ」を見せる
//
// ドット絵方針(DESIGN §3.5):
//   植物スプライト(T09 で作成、T13/T17 で結線)は必ず
//     Image("plant_<stage>_<mood>").resizable().interpolation(.none)
//   で**整数倍拡大**する(にじみ禁止)。
//   T07 時点ではアセットが無いため SF Symbols で代替している。

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
            plantPlaceholder
                .font(.system(size: 28))
                .foregroundStyle(.green)

            if snapshot.pairId == nil {
                // ソロ状態: 鉢は土だけ(REQUIREMENTS §3.9)
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

    /// 植物のプレースホルダ(T09 のスプライト完成後に interpolation(.none) の Image へ差し替える)
    private var plantPlaceholder: some View {
        Image(systemName: plantSymbolName)
    }

    private var plantSymbolName: String {
        switch snapshot.plantStage {
        case ..<1: return "circle.dashed"      // 土(ソロ/開始前)
        case 1...2: return "leaf"              // 芽〜双葉
        case 3...4: return "leaf.fill"         // 若葉〜つぼみ
        default: return "camera.macro"         // 開花
        }
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
