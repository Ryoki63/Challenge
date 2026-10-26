// HomeViewModel+Plant.swift — ホームの植物まわりの導出(issue #57 / docs/GROWTH.md §4.5・§5.1・§5.3・§5.4)
//
// ゲージの文・VoiceOver の読み上げ文・植物の名前・名前付けの導線・ひとこと・ハートは、
// snapshot からの純粋な導出(状態を持たない)。HomeViewModel.swift を 300 行の目安(DESIGN §9-4)に近づけるため、ここに分けた。

import Foundation

extension HomeViewModel {
    /// ゲージの文(「ふたりそろって あと2回で めばえ」— GROWTH §5.1)。ソロ・新しいキーが無い snapshot では nil(出さない)
    var growthGaugeText: String? {
        snapshot.flatMap(GrowthGauge.text(for:))
    }

    /// 植物の VoiceOver の読み上げ文(GROWTH §5.4)。snapshot が無い空状態は nil(装飾画像として隠す)
    var plantAccessibilityText: String? {
        snapshot.map(PlantVoiceOver.label(for:))
    }

    /// ホームに出す植物の名前(ペアの鉢の名前だけ。ソロには名前を出さない)
    var plantName: String? {
        guard let snapshot, snapshot.pairId != nil, let name = snapshot.plantName, !name.isEmpty else { return nil }
        return name
    }

    /// 「名前をつける」を出すか: ペアで、最初の「ふたば」(段階1)以降で、まだ名前が無いとき。
    /// 演出を閉じても、名前が付くまでここに残る(GROWTH §5.3)。名前付けの口が無い構成では出さない
    var canNamePlant: Bool {
        guard plantNaming != nil, let snapshot, snapshot.pairId != nil, plantName == nil else { return false }
        return PlantLayers.clampedStage(snapshot.plantStage) >= 1
    }

    /// 名前を変えられるか(名前があるペア)。名前の行がボタンになる
    var canRenamePlant: Bool {
        plantNaming != nil && plantName != nil
    }

    /// 名前のシートを開く(まだ名前が無ければ付ける・あれば変える)
    func presentPlantNameSheet() {
        guard let plantNaming else { return }
        if canRenamePlant {
            plantNaming.presentSheet(mode: .rename, currentName: plantName)
        } else if canNamePlant {
            plantNaming.presentSheet(mode: .first, currentName: nil)
        }
    }

    /// 段階アップの演出の「(相手)にハートを送る」を出すか: リアクションを送れる(ペア成立+相手が今日チェックイン済み)で、
    /// 今日まだリアクションを送っていないとき。サーバーの react は、同じチェックインへの2回目以降を付け替え(上書き)にして
    /// 相手へ通知を送り直さない。「ハートを送ったよ」と出しても届かないので、送った日は出さない(PB のレビュー)
    var canSendHeart: Bool {
        canReact && !plantExperience.hasReactedToday
    }

    /// 植物をタップして「今日のひとこと」を出せるか(ペア成立中)。VoiceOver のアクション「タネの子のひとこと」を出すかの判定。
    /// 土の中で眠るソロには、ひとことが無い
    var canWhisper: Bool {
        guard let snapshot else { return false }
        return snapshot.pairId != nil
    }
}
