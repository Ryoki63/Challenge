// PlantCelebrationPlantsView.swift — 全画面の演出の「変わる前 → 後」の植物の行(issue #57 / docs/GROWTH.md §5.2)
//
// 段階アップ: 変わる前(小さく)→ 後(大きく。驚いた顔・ふたりの葉がひらいて、お祝いのきらきら)。段階0(はじめまして)は、
// 土の中で眠っていた姿から。おかえり: 目をさました植物 1 体。あとの植物は、`revealed` になると、ぽんと現れる
// (アニメは PlantCelebrationContent が掛ける。視差効果を減らす設定ではそのまま出す)。VoiceOver には行全体を 1 つの文で読み上げる。
// PlantCelebrationView.swift を 300 行の目安(DESIGN §9-4)に収めるため、ここに分けた。

import SwiftUI

struct PlantCelebrationPlantsView: View {
    let presentation: PlantExperienceModel.Presentation
    let snapshot: PairSnapshot?
    /// あとの植物を出したか
    let revealed: Bool

    /// 植物の行の高さ(あとの植物がこの高さに収まる大きさにする)
    private static let height: CGFloat = 280

    private var afterState: PlantCharacterState {
        switch presentation {
        case .stageUp(let celebration):
            // ふたりの葉がひらいて、驚いて喜ぶ(段階0は、ふたりの芽が光る)
            return PlantCharacterState(stage: celebration.stage, meOpen: true, partnerOpen: true, expression: .wow)
        case .welcomeBack:
            // おかえり: 目をさました植物。自分はいまチェックインした(葉がひらく)。相手の葉は今日の状態のまま
            let stage = snapshot?.plantStage ?? 0
            return PlantCharacterState(
                stage: stage,
                meOpen: true,
                partnerOpen: snapshot?.todayPartnerDone ?? false,
                expression: .wow
            )
        }
    }

    private var beforeState: PlantCharacterState? {
        guard case .stageUp(let celebration) = presentation else { return nil }
        guard let before = celebration.beforeStage else { return .solo } // はじめまして: 土の中で眠っていた姿から
        return PlantCharacterState(stage: before, meOpen: true, partnerOpen: true, expression: .normal)
    }

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let height = Self.height
            // 変わる前(小さく)→ 後(大きく)。3:4 のキャンバスなので、幅は高さの 0.75 倍まで
            let afterWidth = min(width * (beforeState == nil ? 0.7 : 0.58), height * 0.75)
            let beforeWidth = min(width * 0.28, height * 0.5 * 0.75)
            let beforeHeight = beforeWidth / 0.75
            HStack(alignment: .bottom, spacing: LienSpacing.s) {
                if let beforeState {
                    PlantCharacterView(state: beforeState)
                        .frame(width: beforeWidth)
                    // 矢印は、変わる前の植物の顔の高さのあたり(キャンバスの下から約 4 割)に置く
                    Image(systemName: "arrow.right")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .padding(.bottom, max(beforeHeight * 0.41 - 10, 0))
                        .accessibilityHidden(true)
                }
                PlantCharacterView(state: afterState)
                    .frame(width: afterWidth)
                    .scaleEffect(revealed ? 1 : 0.7, anchor: .bottom)
                    .opacity(revealed ? 1 : 0)
            }
            .frame(width: width, height: height, alignment: .bottom)
        }
        .frame(height: Self.height)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(plantsAccessibilityLabel)
    }

    /// VoiceOver: 変わる前と後の段階
    private var plantsAccessibilityLabel: String {
        switch presentation {
        case .stageUp(let celebration):
            let after = Strings.Plant.celebrationAfter(Strings.Plant.stageName(celebration.stage))
            guard let before = celebration.beforeStage else { return after }
            return Strings.Plant.celebrationBefore(Strings.Plant.stageName(before)) + "。" + after
        case .welcomeBack:
            return Strings.Plant.stageName(snapshot?.plantStage ?? 0)
        }
    }
}
