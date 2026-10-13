// WidgetSmallView.swift — ホーム画面・小(systemSmall)のレイアウト(issue #17 T17a / REQUIREMENTS §3.10・GROWTH §5.4)
//
// ペア成立中:
//   ┌────────────────────────┐
//   │ [植物 3:4]   🔥 23日    │   植物(ふたりの葉 = 今日の2人。左 = 自分・右 = 相手)
//   │              💪 🏃      │   右の列: ストリーク + 2人の今日の状態(○×の補助。葉の意味が伝わるまで残す)
//   │              ✓  ○      │
//   │ ゆうきが待ってるよ       │   相手が先に完了していれば(出ないときも行を空ける)
//   │ ▬▬▬▬▬▬────────────      │   細い進み具合のバー(数字なし。新しいキーが無いときは出さない)
//   └────────────────────────┘
// ソロ・データ無し: 眠るタネの子+一言(「ペアになると、タネの子が目をさますよ」/「アプリを開いてはじめよう」)。
//
// 寸法は WidgetSmallMetrics(内側の大きさから決める。システムの余白 16pt は、描く側の外 = LienWidget が受け持つ)。
// 内容は WidgetContent。このビューは状態を持たない。ダークは PlantCharacterView が最背面に bg_plate を敷く。
// 文字は Dynamic Type に連れて大きくなるが、小さな枠に収まるよう上限を置く(WidgetRootView)。

import SwiftUI

struct WidgetSmallView: View {
    let content: WidgetContent
    var imageStyle: PlantImageStyle = .plain

    var body: some View {
        GeometryReader { proxy in
            switch content.mode {
            case .paired:
                paired(WidgetSmallMetrics(size: proxy.size))
            case .solo, .noData:
                resting
            }
        }
    }

    // MARK: ペア成立中

    private func paired(_ metrics: WidgetSmallMetrics) -> some View {
        VStack(alignment: .leading, spacing: WidgetSmallMetrics.gap) {
            HStack(alignment: .center, spacing: WidgetSmallMetrics.columnGap) {
                PlantCharacterView(state: content.plant, imageStyle: imageStyle)
                    .frame(width: metrics.plantSize.width, height: metrics.plantSize.height)
                VStack(alignment: .leading, spacing: 8) {
                    if let days = content.streakDays {
                        WidgetStreakLabel(days: days)
                    }
                    if let me = content.me, let partner = content.partner {
                        WidgetStatusChips(me: me, partner: partner, spacing: 6)
                    }
                }
                .frame(width: metrics.columnWidth, alignment: .leading)
            }
            .frame(height: metrics.rowHeight)

            WidgetCaption(text: content.waitingMessage)
                .frame(height: WidgetSmallMetrics.captionHeight, alignment: .leading)

            if let progress = content.progress {
                WidgetProgressBar(fraction: progress)
            } else {
                // 新しいキーが無い snapshot: バーは出さない。行は空けて、植物の大きさを変えない
                Color.clear.frame(height: WidgetSmallMetrics.barHeight)
            }
        }
    }

    // MARK: ソロ・データ無し

    /// 眠るタネの子+一言(ソロ: 「ペアになると、タネの子が目をさますよ」/ データ無し: 「アプリを開いてはじめよう」)
    private var resting: some View {
        VStack(spacing: WidgetSmallMetrics.gap) {
            PlantCharacterView(state: content.plant, imageStyle: imageStyle)
            if let note = content.note {
                Text(note)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
            }
        }
        .frame(maxWidth: .infinity)
    }
}
