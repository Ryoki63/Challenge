// PlantSpriteTests.swift — stage×mood → imageset 名解決の網羅テスト(T13)
//
// imageset 名は契約(assets/plant/mapping.md / build_asset_catalog.py の EXPECTED と一致)。
// G2 で v2 スプライトに差し替えてもこの名前は変えない — このテストがその契約を固定する。

import XCTest
@testable import Lien

final class PlantSpriteTests: XCTestCase {
    /// PlantMood の全値(PlantMood は共有契約モデルのため CaseIterable を足さず、ここで列挙)
    private let allMoods: [PlantMood] = [.normal, .happy, .fidget, .sad]

    /// カタログに存在する 13 imageset(正本: build_asset_catalog.py EXPECTED)
    private let catalogNames: Set<String> = [
        "plant_soil",
        "plant_stage1_normal", "plant_stage1_happy",
        "plant_stage2_normal", "plant_stage2_happy",
        "plant_stage3_normal", "plant_stage3_happy",
        "plant_stage4_normal", "plant_stage4_happy",
        "plant_stage5_normal", "plant_stage5_happy",
        "plant_stage2_sad", "plant_stage5_sad",
    ]

    // MARK: stage 0(種 = 土の中)とソロ

    func testStageZeroIsSoilForAllMoods() {
        for mood in allMoods {
            XCTAssertEqual(
                PlantSprite.assetName(stage: 0, mood: mood),
                "plant_soil",
                "stage0 は mood によらず土(mapping.md §2)"
            )
        }
        XCTAssertEqual(PlantSprite.soloAssetName, "plant_soil")
    }

    // MARK: normal / happy(全 stage 網羅)

    func testNormalAndHappyMapToOwnStage() {
        for stage in 1...5 {
            XCTAssertEqual(
                PlantSprite.assetName(stage: stage, mood: .normal),
                "plant_stage\(stage)_normal"
            )
            XCTAssertEqual(
                PlantSprite.assetName(stage: stage, mood: .happy),
                "plant_stage\(stage)_happy"
            )
        }
    }

    // MARK: fidget(v0 欠損 → normal 代用+View 側の揺れ)

    func testFidgetFallsBackToNormalSprite() {
        for stage in 1...5 {
            XCTAssertEqual(
                PlantSprite.assetName(stage: stage, mood: .fidget),
                "plant_stage\(stage)_normal",
                "fidget は v0 では normal で代用(揺れは View 側 — mapping.md §2)"
            )
        }
    }

    // MARK: sad(v0 は2枚のみ → 近接代用)

    func testSadUsesNearestAvailableSprite() {
        // 小さい株(1〜3)= stage2_sad / 大きい株(4〜5)= stage5_sad(mapping.md §2)
        XCTAssertEqual(PlantSprite.assetName(stage: 1, mood: .sad), "plant_stage2_sad")
        XCTAssertEqual(PlantSprite.assetName(stage: 2, mood: .sad), "plant_stage2_sad")
        XCTAssertEqual(PlantSprite.assetName(stage: 3, mood: .sad), "plant_stage2_sad")
        XCTAssertEqual(PlantSprite.assetName(stage: 4, mood: .sad), "plant_stage5_sad")
        XCTAssertEqual(PlantSprite.assetName(stage: 5, mood: .sad), "plant_stage5_sad")
    }

    // MARK: 範囲外 stage の防御(クランプ)

    func testOutOfRangeStageIsClamped() {
        XCTAssertEqual(PlantSprite.assetName(stage: -1, mood: .normal), "plant_soil")
        XCTAssertEqual(PlantSprite.assetName(stage: -1, mood: .sad), "plant_soil")
        XCTAssertEqual(PlantSprite.assetName(stage: 6, mood: .normal), "plant_stage5_normal")
        XCTAssertEqual(PlantSprite.assetName(stage: 99, mood: .happy), "plant_stage5_happy")
        XCTAssertEqual(PlantSprite.assetName(stage: 99, mood: .sad), "plant_stage5_sad")
    }

    // MARK: カタログ契約(どんな入力でも実在 imageset 名に解決される)

    func testEveryResolutionLandsInsideCatalog() {
        for stage in -2...8 {
            for mood in allMoods {
                let name = PlantSprite.assetName(stage: stage, mood: mood)
                XCTAssertTrue(
                    catalogNames.contains(name),
                    "stage=\(stage) mood=\(mood) → \(name) はカタログ(13 imageset)に存在しない"
                )
            }
        }
    }

    // MARK: スプライト原寸(整数倍拡大の基準 — DESIGN §3.5)

    func testSpriteCanvasSizeMatchesMapping() {
        XCTAssertEqual(PlantSprite.pixelWidth, 16)
        XCTAssertEqual(PlantSprite.pixelHeight, 24)
    }
}
