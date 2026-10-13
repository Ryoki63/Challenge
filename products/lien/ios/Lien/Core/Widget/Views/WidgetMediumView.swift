// WidgetMediumView.swift — ホーム画面・中(systemMedium)のレイアウト(issue #17 T17a / REQUIREMENTS §3.10)
//
// S の内容+植物を大きく(高さいっぱいの 3:4)。右の列に、ストリーク・2人の今日の状態(呼び名つき)・進み具合のバー・
// 相手が先に完了していれば「(相手)が待ってるよ」。
//   ┌──────────────────────────────────────────┐
//   │ [植物      ]   🔥 23日                    │
//   │ [大きく    ]   💪 じぶん   🏃 ゆうき       │
//   │ [3:4      ]    ✓           ○             │
//   │                ▬▬▬▬▬▬▬▬▬──────────        │
//   │                ゆうきが待ってるよ           │
//   └──────────────────────────────────────────┘
// **相手の今日の写真は v1.0.1(T17b)**。v1.0 で相手の写真を見られるのは、当日のホームだけ(PV #59。D3)。
// ソロ・データ無し: 眠るタネの子(大きく)+ 一言。

import SwiftUI

struct WidgetMediumView: View {
    let content: WidgetContent
    var imageStyle: PlantImageStyle = .plain

    /// 一言の行の高さ(.caption の1行。出ないときも空けて、右の列の位置を状態で動かさない)
    private static let captionHeight: CGFloat = 16

    var body: some View {
        GeometryReader { proxy in
            let metrics = WidgetMediumMetrics(size: proxy.size)
            HStack(alignment: .center, spacing: WidgetMediumMetrics.columnGap) {
                PlantCharacterView(state: content.plant, imageStyle: imageStyle)
                    .frame(width: metrics.plantSize.width, height: metrics.plantSize.height)
                column
                    .frame(width: metrics.columnWidth, alignment: .leading)
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .leading)
        }
    }

    @ViewBuilder
    private var column: some View {
        switch content.mode {
        case .paired:
            pairedColumn
        case .solo, .noData:
            if let note = content.note {
                Text(note)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                    .minimumScaleFactor(0.8)
            }
        }
    }

    /// 右の列。高さに収まらないとき(iPhone SE の M は内側 109pt・文字を大きくした設定)は、呼び名を外した小さい方に替える。
    /// 収まらないまま詰めると、ストリークの文字が縮んで読みにくくなる
    private var pairedColumn: some View {
        ViewThatFits(in: .vertical) {
            pairedStack(showsNames: true, spacing: 10)
            pairedStack(showsNames: false, spacing: 6)
        }
    }

    private func pairedStack(showsNames: Bool, spacing: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: spacing) {
            if let days = content.streakDays {
                WidgetStreakLabel(days: days, font: .headline)
            }
            if let me = content.me, let partner = content.partner {
                WidgetStatusChips(me: me, partner: partner, showsNames: showsNames, spacing: 16)
            }
            if let progress = content.progress {
                WidgetProgressBar(fraction: progress, height: 6)
            }
            WidgetCaption(text: content.waitingMessage, font: .caption)
                .frame(height: Self.captionHeight, alignment: .leading)
        }
    }
}
