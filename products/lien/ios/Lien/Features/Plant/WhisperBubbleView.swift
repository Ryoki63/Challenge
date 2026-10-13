// WhisperBubbleView.swift — 今日のひとこと(タネの子の吹き出し)の見た目と寿命(issue #57 / docs/GROWTH.md §5.5)
//
// 短い吹き出し(角丸 + 下向きのしっぽ)。文言は呼び出し側から(絵は使わない)。大きさと余白の計算は WhisperBubbleMetrics
// (PlantWhisper.swift。最大2行の吹き出しが、文字を大きくしても ScrollView の上端に食い込まないよう、余白を広げる)。
// 置き場所は PlantHeroView(植物の枠の上)。寿命は下の plantWhisperLifetime(数秒で消える・出すたびに VoiceOver へ読み上げる)。

import SwiftUI

struct WhisperBubbleView: View {
    let text: String

    var body: some View {
        VStack(spacing: 0) {
            Text(text)
                .font(.footnote)
                .multilineTextAlignment(.center)
                .lineLimit(WhisperBubbleMetrics.maxLines)
                .padding(.horizontal, WhisperBubbleMetrics.horizontalPadding)
                .padding(.vertical, WhisperBubbleMetrics.verticalPadding)
                .background(
                    RoundedRectangle(cornerRadius: 14)
                        .fill(LienColors.chipBackground)
                )
            BubbleTail()
                .fill(LienColors.chipBackground)
                .frame(width: WhisperBubbleMetrics.tailWidth, height: WhisperBubbleMetrics.tailHeight)
        }
        .accessibilityElement(children: .combine)
    }
}

/// 吹き出しのしっぽ(下向きの三角)
private struct BubbleTail: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

// MARK: - 寿命(出すたびに VoiceOver へ読み上げ、数秒後に消す)
//
// 吹き出しは数秒で消える(PlantExperienceModel.whisperDuration)。出すたびに(その日はじめてホームを開いたときも、
// 植物のタップ / VoiceOver のアクションで出し直すときも)次の2つを行う:
//   - VoiceOver へ読み上げる: 数秒で消える吹き出しは、VoiceOver の操作では読めないことがある。VoiceOver が動いていなければ何も起きない
//   - タイマーを作り直し、数秒後に消す
// 出し直しは whisperToken の増加で知る(同じ言葉でも増える)。View が消えると、実行中のタイマーは取り消される。

private struct PlantWhisperLifetime: ViewModifier {
    let experience: PlantExperienceModel

    func body(content: Content) -> some View {
        content.task(id: experience.whisperToken) {
            guard let line = experience.whisper else { return }
            AccessibilityNotification.Announcement(line).post()
            try? await Task.sleep(nanoseconds: PlantExperienceModel.whisperDuration)
            if !Task.isCancelled { experience.hideWhisper() }
        }
    }
}

extension View {
    /// 今日のひとこと(吹き出し)を、出すたびに VoiceOver へ読み上げ、数秒後に消す
    func plantWhisperLifetime(_ experience: PlantExperienceModel) -> some View {
        modifier(PlantWhisperLifetime(experience: experience))
    }
}
