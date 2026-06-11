// PlantSprite.swift — stage/mood → 植物スプライト imageset 名の解決(T13 / issue #13)
//
// **imageset 名は契約として固定**(正本: assets/plant/mapping.md / build_asset_catalog.py):
//   plant_soil / plant_stage<1-5>_normal / plant_stage<1-5>_happy / plant_stage2_sad / plant_stage5_sad
// 現在取込済みの v0 スプライトはプレースホルダで、トーンは G2(#40)で選定中。
// v2 への差し替えは PlantAssets.xcassets の再生成のみで行い、**この名前とこの解決関数は変えない**
// (差し替え点をこのファイル1箇所に集約する)。T17(ウィジェット)/ T22(シェア画像)も本関数を再利用する。
//
// 解決規則(mapping.md §2):
//   - stage 0(種 = 土の中)とソロ状態 → plant_soil(全 mood 共通)
//   - normal / happy → plant_stage<N>_normal / plant_stage<N>_happy
//   - fidget(そわそわ)→ v0 では normal で代用(差分は View 側の揺れアニメで表現)
//   - sad は v0 では2枚のみ: stage1〜3 → plant_stage2_sad / stage4〜5 → plant_stage5_sad(近接代用)
//   - 範囲外 stage は防御的にクランプ(負 → 0、6以上 → 5)
//
// 罰なし原則(REQUIREMENTS §3.9): sad でも葉が垂れるだけで、枯れ・後退には見せない。
// このファイルは Foundation 以外に依存させないこと(Widget / シェア画像生成からも使うため)。

import Foundation

enum PlantSprite {
    /// スプライト原寸(16×24 px — mapping.md §3)。整数倍拡大の基準(DESIGN §3.5)
    static let pixelWidth = 16
    static let pixelHeight = 24

    /// PairSnapshot.plantStage の取りうる範囲(REQUIREMENTS §3.9: 0=種 〜 5=開花)
    static let stageRange = 0...5

    /// ソロ状態(ペア未成立)の鉢 = 土だけ(REQUIREMENTS §3.9)
    static let soloAssetName = "plant_soil"

    /// stage × mood → imageset 名。純粋関数(単体テスト対象 — PlantSpriteTests)
    static func assetName(stage: Int, mood: PlantMood) -> String {
        let clamped = min(max(stage, stageRange.lowerBound), stageRange.upperBound)
        // stage 0 = 種は土の中で見えない(soil と同一見た目 — mapping.md §2)
        guard clamped >= 1 else { return soloAssetName }
        switch mood {
        case .normal, .fidget:
            // fidget は v0 では normal 画像+View 側の揺れアニメで表現(mapping.md §2)
            return "plant_stage\(clamped)_normal"
        case .happy:
            return "plant_stage\(clamped)_happy"
        case .sad:
            // v0 の sad は2枚のみ。小さい株(1〜3)= stage2_sad / 大きい株(4〜5)= stage5_sad で近接代用
            return clamped <= 3 ? "plant_stage2_sad" : "plant_stage5_sad"
        }
    }
}
