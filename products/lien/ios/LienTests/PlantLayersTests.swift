// PlantLayersTests.swift — 植物キャラクターのレイヤーの重ね順・状態の導出・アセットとの対応(issue #56)
//
// 検証すること:
//   1. 全段階 × 葉の4通り × 表情・ソロ・ダーク・のぞき・知らない段階で、重ね順の規則(assets/plant/mapping.md §4)を満たす
//   2. assets/plant/layer_stacks.json(tools/gen_layers.py の stack() が出す基準)と、PlantLayers.stack が一字一句同じ
//      → Python のプレビュー(承認した絵)と iOS の重ね方が食い違わない
//   3. snapshot → 状態の導出(GROWTH §4.1 の表。sad = すやすや)
//   4. 34レイヤーが、コンパイル済みのアセットカタログに実在し、ベクターとして描ける(空白にならない)
//   5. のぞきの位置・既定の花色・ターゲットの依存が assets/plant/ の正本と一致する
//
// 実描画の一覧画像は PlantRenderTests。

import SwiftUI
import UIKit
import XCTest
@testable import Lien

// MARK: - 基準の表記

extension PlantLayer {
    /// assets/plant/layer_stacks.json の表記(tools/gen_layers.py の entry_token と同じ):
    /// 名前 [|mirror] [|tint=me|partner] [|dx=…|dy=…]
    var referenceToken: String {
        var token = name
        if mirrored { token += "|mirror" }
        if let tint { token += "|tint=\(tint.rawValue)" }
        if dx != 0 || dy != 0 {
            token += "|dx=\(String(format: "%g", dx))|dy=\(String(format: "%g", dy))"
        }
        return token
    }
}

private struct StackReference: Decodable {
    struct Case: Decodable {
        let stage: Int
        let me: Bool
        let partner: Bool
        let face: String
        let solo: Bool?
        let soilGlow: Bool?
        let peek: Bool?
        let dark: Bool?
        let layers: String
    }

    let version: Int
    let cases: [Case]
}

private struct PeekReference: Decodable {
    let dx: Double
    let dy: Double
}

@MainActor
final class PlantLayersTests: XCTestCase {
    // MARK: 共通の道具

    private let allStages = Array(-3...15) // 範囲外(負・10以上)を含む

    /// 重ね順の位置(mapping.md §4 の表の「順」。同じ順の中の左右・自分/相手は続けて並ぶ)
    private func rank(of slot: PlantLayer.Slot, solo: Bool) -> Int {
        if solo {
            switch slot {
            case .backPlate: return 0
            case .potBack: return 1
            case .soilGlow: return 2
            case .soloSeed: return 3
            case .potFront: return 4
            case .effect: return 5
            default: return -1
            }
        }
        switch slot {
        case .backPlate: return 0
        case .potBack: return 1
        case .leftLeaf: return 2
        case .rightLeaf: return 3
        case .leftPetal: return 4
        case .rightPetal: return 5
        case .head: return 6
        case .arms: return 7
        case .body: return 8
        case .face: return 9
        case .potFront: return 10
        case .hands: return 11
        case .peek: return 12
        case .effect: return 13
        case .soilGlow, .soloSeed: return -1
        }
    }

    private func names(_ layers: [PlantLayer]) -> [String] {
        layers.map(\.name)
    }

    // MARK: 1. 規則(手書きの期待)

    func testMorningDefaultStage3() {
        let layers = PlantLayers.stack(for: .morning(stage: 3), dark: false)
        XCTAssertEqual(layers.map(\.referenceToken), [
            "pot_back", "leaf_folded", "leaf_folded|mirror", "head_s3",
            "body", "face_normal", "pot_front", "hands_rim",
        ], "毎朝の既定: 葉は2枚ともたたみ、顔はふつう、ふちに手を掛ける")
    }

    func testBothDoneAtFlowerStageHasArmsPetalsAndSparkle() {
        let state = PlantCharacterState(stage: 8, meOpen: true, partnerOpen: true, expression: .happy)
        let layers = PlantLayers.stack(for: state, dark: false)
        XCTAssertEqual(layers.map(\.referenceToken), [
            "pot_back", "leaf_open", "leaf_open|mirror",
            "petal_s8|tint=me", "petal_s8|mirror|tint=partner", "head_s8",
            "arms_up", "body", "face_happy", "pot_front", "fx_sparkle",
        ], "ふたりそろった: 葉は両方ひらき、花の塗りは左=自分・右(反転)=相手、腕を上げ、キラキラ")
    }

    func testSoloStack() {
        XCTAssertEqual(
            PlantLayers.stack(for: .solo, dark: false).map(\.referenceToken),
            ["pot_back", "solo_seed", "pot_front", "fx_zzz"]
        )
        let glow = PlantCharacterState(stage: 0, isSolo: true, soilGlow: true)
        XCTAssertEqual(
            PlantLayers.stack(for: glow, dark: true).map(\.referenceToken),
            ["bg_plate", "pot_back", "fx_soil_glow", "solo_seed", "pot_front", "fx_zzz"],
            "ソロで自分がチェックインした日は土が光る(solo_seed の背後)。ダークはプレートが最背面"
        )
    }

    func testSoloIgnoresStageLeavesAndFace() {
        let baseline = PlantLayers.stack(for: .solo, dark: false)
        for stage in allStages {
            for expression in PlantExpression.allCases {
                let state = PlantCharacterState(
                    stage: stage, meOpen: true, partnerOpen: true, expression: expression, isSolo: true, peek: true
                )
                XCTAssertEqual(PlantLayers.stack(for: state, dark: false), baseline, "stage=\(stage) \(expression)")
            }
        }
    }

    func testStageZeroUsesNubsNotLeaves() {
        let layers = PlantLayers.stack(for: PlantCharacterState(stage: 0, meOpen: true), dark: false)
        XCTAssertEqual(layers[1].name, "nub_lit", "自分がチェックインした人の芽が光る(形も違う)")
        XCTAssertEqual(layers[2].name, "nub_closed")
        XCTAssertTrue(layers[2].mirrored)
        XCTAssertFalse(names(layers).contains { $0.hasPrefix("leaf_") || $0.hasPrefix("head_") || $0.hasPrefix("petal_") })
    }

    func testStageOneHasLeavesButNoHeadPlant() {
        let layers = PlantLayers.stack(for: PlantCharacterState(stage: 1, partnerOpen: true), dark: false)
        XCTAssertEqual(Array(names(layers).prefix(3)), ["pot_back", "leaf_folded", "leaf_open"])
        XCTAssertFalse(names(layers).contains { $0.hasPrefix("head_") })
    }

    func testFoldedLeafKeepsTheSameSlotAsTheOpenLeaf() {
        // ひらく / たたむは同じ位置の絵の差し替え(クロスフェードで二重に見せない — mapping.md §5)
        let folded = PlantLayers.stack(for: PlantCharacterState(stage: 4), dark: false)
        let opened = PlantLayers.stack(for: PlantCharacterState(stage: 4, meOpen: true), dark: false)
        XCTAssertEqual(folded.map(\.slot), opened.map(\.slot))
        XCTAssertEqual(folded[1].name, "leaf_folded")
        XCTAssertEqual(opened[1].name, "leaf_open")
    }

    // MARK: 1b. 全組み合わせの不変条件

    func testInvariantsForEveryCombination() {
        var used = Set<String>()
        let known = Set(PlantLayers.allLayerNames)
        let bools = [false, true]
        for stage in allStages {
            for me in bools {
                for partner in bools {
                    for expression in PlantExpression.allCases {
                        for dark in bools {
                            for peek in bools {
                                let state = PlantCharacterState(
                                    stage: stage, meOpen: me, partnerOpen: partner, expression: expression, peek: peek
                                )
                                let layers = PlantLayers.stack(for: state, dark: dark)
                                let label = "stage=\(stage) me=\(me) partner=\(partner) \(expression) dark=\(dark) peek=\(peek)"
                                checkInvariants(layers, state: state, dark: dark, label: label, known: known)
                                used.formUnion(layers.map(\.name))
                            }
                        }
                    }
                }
            }
        }
        for dark in bools {
            for glow in bools {
                let state = PlantCharacterState(stage: 5, isSolo: true, soilGlow: glow)
                let layers = PlantLayers.stack(for: state, dark: dark)
                let soloRanks = layers.map { rank(of: $0.slot, solo: true) }
                XCTAssertEqual(soloRanks, soloRanks.sorted(), "ソロの重ね順 dark=\(dark) glow=\(glow)")
                XCTAssertFalse(soloRanks.contains(-1))
                XCTAssertTrue(layers.allSatisfy { known.contains($0.name) })
                used.formUnion(layers.map(\.name))
            }
        }
        XCTAssertEqual(used, known, "使われないレイヤー(または、カタログに無い名前)がある")
    }

    private func checkInvariants(
        _ layers: [PlantLayer],
        state: PlantCharacterState,
        dark: Bool,
        label: String,
        known: Set<String>
    ) {
        let stage = PlantLayers.clampedStage(state.stage)
        let ranks = layers.map { rank(of: $0.slot, solo: false) }

        XCTAssertTrue(layers.allSatisfy { known.contains($0.name) }, label)
        XCTAssertEqual(Set(layers.map(\.slot)).count, layers.count, "同じ位置の重複 \(label)")
        XCTAssertEqual(ranks, ranks.sorted(), "重ね順が下から並んでいない \(label)")
        XCTAssertFalse(ranks.contains(-1), label)

        XCTAssertEqual(layers.first?.name == "bg_plate", dark, "bg_plate はダークだけ・最背面 \(label)")
        XCTAssertEqual(layers[dark ? 1 : 0].name, "pot_back", label)
        XCTAssertEqual(layers.filter { $0.name == "pot_front" }.count, 1, label)

        // 葉(段階0は芽)。左 = 自分 / 右 = 相手(反転)
        let leftLeaf = layers.first { $0.slot == .leftLeaf }
        let rightLeaf = layers.first { $0.slot == .rightLeaf }
        let leafKind = stage == 0 ? ("nub_lit", "nub_closed") : ("leaf_open", "leaf_folded")
        XCTAssertEqual(leftLeaf?.name, state.meOpen ? leafKind.0 : leafKind.1, label)
        XCTAssertEqual(rightLeaf?.name, state.partnerOpen ? leafKind.0 : leafKind.1, label)
        XCTAssertEqual(leftLeaf?.mirrored, false, label)
        XCTAssertEqual(rightLeaf?.mirrored, true, label)

        // 花の塗り(6〜9): 左 = 自分の色 / 右 = 反転して相手の色
        let petals = layers.filter { $0.slot == .leftPetal || $0.slot == .rightPetal }
        if (6...9).contains(stage) {
            XCTAssertEqual(petals.map(\.name), ["petal_s\(stage)", "petal_s\(stage)"], label)
            XCTAssertEqual(petals.map(\.mirrored), [false, true], label)
            XCTAssertEqual(petals.map(\.tint), [.me, .partner], label)
        } else {
            XCTAssertTrue(petals.isEmpty, label)
        }
        // 着色するのは花の塗りだけ
        XCTAssertTrue(layers.filter { $0.tint != nil }.allSatisfy { $0.name.hasPrefix("petal_s") }, label)
        // 左右反転するのは葉・芽・花の塗りだけ
        XCTAssertTrue(layers.filter(\.mirrored).allSatisfy {
            $0.name.hasPrefix("leaf_") || $0.name.hasPrefix("nub_") || $0.name.hasPrefix("petal_s")
        }, label)

        // 頭の植物: 段階2以上。段階0・1には無い
        let head = layers.first { $0.slot == .head }
        XCTAssertEqual(head?.name, stage >= 2 ? "head_s\(stage)" : nil, label)

        // 腕とふちの手は顔で決まる(どちらか一方)
        let armsUp = state.expression.raisesArms
        XCTAssertEqual(layers.contains { $0.name == "arms_up" }, armsUp, label)
        XCTAssertEqual(layers.contains { $0.name == "hands_rim" }, !armsUp, label)
        XCTAssertEqual(layers.first { $0.slot == .face }?.name, state.expression.layerName, label)

        // のぞき: 位置がある段階だけ・指定したときだけ。効果より下
        let peek = layers.first { $0.slot == .peek }
        if state.peek, let offset = PlantLayers.peekOffsets[stage] {
            XCTAssertEqual(peek?.dx, offset.dx, label)
            XCTAssertEqual(peek?.dy, offset.dy, label)
        } else {
            XCTAssertNil(peek, label)
        }
        XCTAssertTrue(layers.filter { $0.slot != .peek }.allSatisfy { $0.dx == 0 && $0.dy == 0 }, label)

        // 効果は最前面。顔と対
        let effect = layers.first { $0.slot == .effect }
        XCTAssertEqual(effect?.name, state.expression.effectLayerName, label)
        if effect != nil { XCTAssertEqual(layers.last?.slot, .effect, label) }
    }

    // MARK: 知らない段階

    func testUnknownStageIsDrawnAsTheLargestKnownStage() {
        // サーバーが新しい段階(100回のあとの花壇など)を返しても、古い描画は壊れず「みのり」で描く(GROWTH §8.2)
        for expression in PlantExpression.allCases {
            for peek in [false, true] {
                let reference = PlantCharacterState(stage: 9, meOpen: true, partnerOpen: false, expression: expression, peek: peek)
                for unknown in [10, 11, 25, 1000, Int.max] {
                    var state = reference
                    state.stage = unknown
                    XCTAssertEqual(
                        PlantLayers.stack(for: state, dark: false),
                        PlantLayers.stack(for: reference, dark: false),
                        "stage \(unknown) は 9 として描く(\(expression) peek=\(peek))"
                    )
                }
            }
        }
        // 負は 0(たね)
        for negative in [-1, -50, Int.min] {
            XCTAssertEqual(
                PlantLayers.stack(for: PlantCharacterState(stage: negative), dark: false),
                PlantLayers.stack(for: PlantCharacterState(stage: 0), dark: false)
            )
        }
        XCTAssertEqual(PlantLayers.clampedStage(9), 9)
        XCTAssertEqual(PlantLayers.clampedStage(10), 9)
        XCTAssertEqual(PlantLayers.clampedStage(-1), 0)
    }

    // MARK: 2. Python の基準(layer_stacks.json)との一致

    func testStacksMatchTheReferenceGenerator() throws {
        let data = try SourceTree.lienData("assets/plant/layer_stacks.json")
        let reference = try JSONDecoder().decode(StackReference.self, from: data)
        XCTAssertEqual(reference.version, 1)
        XCTAssertGreaterThanOrEqual(reference.cases.count, 300, "基準が読めていない(空振りで通るのを防ぐ)")
        XCTAssertEqual(Set(reference.cases.map(\.stage)), Set(0...9), "全段階を含む")

        for c in reference.cases {
            guard let expression = PlantExpression.allCases.first(where: { $0.layerName == c.face }) else {
                XCTFail("基準の顔 \(c.face) が PlantExpression に無い")
                continue
            }
            let state = PlantCharacterState(
                stage: c.stage,
                meOpen: c.me,
                partnerOpen: c.partner,
                expression: expression,
                isSolo: c.solo ?? false,
                soilGlow: c.soilGlow ?? false,
                peek: c.peek ?? false
            )
            let got = PlantLayers.stack(for: state, dark: c.dark ?? false).map(\.referenceToken).joined(separator: " ")
            XCTAssertEqual(got, c.layers, "stage=\(c.stage) me=\(c.me) partner=\(c.partner) \(c.face) solo=\(c.solo ?? false) dark=\(c.dark ?? false) peek=\(c.peek ?? false)")
        }
    }

    func testPeekOffsetsMatchThePlantAssets() throws {
        let data = try SourceTree.lienData("assets/plant/peek_offsets.json")
        let reference = try JSONDecoder().decode([String: PeekReference].self, from: data)
        let fromSwift = Dictionary(uniqueKeysWithValues: PlantLayers.peekOffsets.map { ("s\($0.key)", $0.value) })
        XCTAssertEqual(Set(reference.keys), Set(fromSwift.keys))
        for (key, value) in reference {
            XCTAssertEqual(fromSwift[key]?.dx, value.dx, key)
            XCTAssertEqual(fromSwift[key]?.dy, value.dy, key)
        }
    }

    // MARK: 3. snapshot → 状態(GROWTH §4.1)

    private func paired(
        me: Bool,
        partner: Bool,
        mood: PlantMood,
        stage: Int = 4
    ) -> PairSnapshot {
        var snapshot = SnapshotFactory.paired(todayMeDone: me, todayPartnerDone: partner)
        snapshot.plantMood = mood
        snapshot.plantStage = stage
        return snapshot
    }

    func testDerivationFollowsTheGrowthTable() {
        let table: [(label: String, snapshot: PairSnapshot, expected: PlantCharacterState)] = [
            ("ふたりともまだ(normal)", paired(me: false, partner: false, mood: .normal),
             PlantCharacterState(stage: 4, expression: .normal)),
            ("自分だけ完了(fidget)", paired(me: true, partner: false, mood: .fidget),
             PlantCharacterState(stage: 4, meOpen: true, expression: .lookLeft)),
            ("相手だけ完了(fidget)", paired(me: false, partner: true, mood: .fidget),
             PlantCharacterState(stage: 4, partnerOpen: true, expression: .lookRight)),
            ("ふたりそろった(happy)", paired(me: true, partner: true, mood: .happy),
             PlantCharacterState(stage: 4, meOpen: true, partnerOpen: true, expression: .happy)),
            ("すやすや(sad)", paired(me: false, partner: false, mood: .sad),
             PlantCharacterState(stage: 4, expression: .sleep)),
        ]
        for row in table {
            XCTAssertEqual(PlantCharacterState(snapshot: row.snapshot), row.expected, row.label)
        }
    }

    func testSadOnlyMeansSleepingWhenNobodyHasCheckedIn() {
        // 「すやすや」は、どちらもまだのときだけ。誰かがチェックインしたら葉がひらき、顔はそちらを見る(閉じた葉は見つめない)
        XCTAssertEqual(PlantCharacterState(snapshot: paired(me: true, partner: false, mood: .sad)).expression, .lookLeft)
        XCTAssertEqual(PlantCharacterState(snapshot: paired(me: false, partner: true, mood: .sad)).expression, .lookRight)
        XCTAssertEqual(PlantCharacterState(snapshot: paired(me: true, partner: true, mood: .sad)).expression, .happy)
    }

    func testLeavesFollowTheCheckinFlagsEvenWhenTheMoodIsStale() {
        // 楽観更新(LocalEcho)で mood が古いまま todayMeDone だけが立った瞬間にも、自分の葉がすぐにひらく
        for staleMood in [PlantMood.normal, .sad] {
            let state = PlantCharacterState(snapshot: paired(me: true, partner: false, mood: staleMood))
            XCTAssertTrue(state.meOpen)
            XCTAssertFalse(state.partnerOpen)
            XCTAssertEqual(state.expression, .lookLeft)
        }
    }

    func testFoldedLeavesAreNeverShownAsDroopingForAnyMood() {
        // 罰なし: mood がどれでも、描くのはひらいた葉かたたんだ葉だけで、しおれた絵のレイヤーは存在しない
        for mood in [PlantMood.normal, .happy, .fidget, .sad] {
            for (me, partner) in [(false, false), (true, false), (false, true), (true, true)] {
                let layers = PlantLayers.stack(
                    for: PlantCharacterState(snapshot: paired(me: me, partner: partner, mood: mood, stage: 9)),
                    dark: false
                )
                XCTAssertTrue(layers.allSatisfy { PlantLayers.allLayerNames.contains($0.name) })
                XCTAssertFalse(layers.contains { $0.name.contains("sad") || $0.name.contains("wilt") || $0.name.contains("droop") })
            }
        }
    }

    func testSoloDerivation() {
        XCTAssertEqual(PlantCharacterState(snapshot: SnapshotFactory.solo()), PlantCharacterState(stage: 0, isSolo: true, soilGlow: false))
        XCTAssertEqual(
            PlantCharacterState(snapshot: SnapshotFactory.solo(todayMeDone: true)),
            PlantCharacterState(stage: 0, isSolo: true, soilGlow: true),
            "自分がチェックインすると土がほのかに光る"
        )
        // ペアが無ければ、段階・表情・相手の完了が何であっても土の中で眠る姿
        var odd = SnapshotFactory.solo()
        odd.plantStage = 7
        odd.plantMood = .happy
        odd.todayPartnerDone = true
        XCTAssertEqual(PlantCharacterState(snapshot: odd), PlantCharacterState(stage: 0, isSolo: true, soilGlow: false))
        XCTAssertEqual(PlantCharacterState.solo, PlantCharacterState(stage: 0, isSolo: true))
    }

    func testStageComesFromTheSnapshotAndIsClampedWhenDrawn() {
        let snapshot = paired(me: false, partner: false, mood: .normal, stage: 12)
        let state = PlantCharacterState(snapshot: snapshot)
        XCTAssertEqual(state.stage, 12, "状態は受け取った値のまま持つ")
        XCTAssertTrue(PlantLayers.stack(for: state, dark: false).contains { $0.name == "head_s9" }, "描くときに最大の段階にそろえる")
    }

    // MARK: 4. アセットカタログとの対応

    func testLayerNameListHas34DistinctEntries() {
        XCTAssertEqual(PlantLayers.allLayerNames.count, 34)
        XCTAssertEqual(Set(PlantLayers.allLayerNames).count, 34)
        XCTAssertEqual(PlantLayers.assetPrefix, "plant_")
        XCTAssertEqual(PlantLayers.canvasAspect, 0.75, accuracy: 1e-9)
    }

    func testEveryLayerExistsInTheCompiledCatalogWithTheCanvasSize() throws {
        for name in PlantLayers.allLayerNames {
            let image = try XCTUnwrap(UIImage(named: PlantLayers.assetPrefix + name), "plant_\(name) がアセットカタログに無い")
            XCTAssertEqual(Double(image.size.width / image.size.height), PlantLayers.canvasAspect, accuracy: 0.001, "\(name) の縦横比が 3:4 ではない: \(image.size)")
        }
    }

    func testEveryLayerRendersNonBlankAsVector() throws {
        // SVG を iOS が描けないと、レイヤーが空白になる(D1 のリスク)。1枚ずつ描いて、何かが塗られていることを確かめる
        for name in PlantLayers.allLayerNames {
            let view = Image(PlantLayers.assetPrefix + name)
                .resizable()
                .frame(width: 240, height: 320)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 1
            let image = try XCTUnwrap(renderer.uiImage, "\(name) を描けない")
            XCTAssertGreaterThan(paintedPixelCount(image), 50, "\(name) が空白に描かれた(SVG が iOS で描けていない?)")
        }
    }

    func testPetalLayersTintWithTheGivenColor() throws {
        // 花の塗りは template にして着色する(左右別の色にできる)。左を青・右を赤にすると、それぞれの側にその色が出る
        let view = PlantCharacterView(
            state: PlantCharacterState(stage: 8, meOpen: true, partnerOpen: true, expression: .happy),
            meFlowerColor: Color(rgb: 0x0000FF),
            partnerFlowerColor: Color(rgb: 0xFF0000)
        )
        .frame(width: 240, height: 320)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 1
        let image = try XCTUnwrap(renderer.uiImage)
        // 花は頭の上(y < 130)にある。顔の赤い口などを数えないよう、上の部分だけを見る
        let left = dominantColorCounts(image, xRange: 0..<120, yRange: 0..<130)
        let right = dominantColorCounts(image, xRange: 120..<240, yRange: 0..<130)
        XCTAssertGreaterThan(left.blue, 200, "左の花(自分)が青で着色されていない")
        XCTAssertGreaterThan(right.red, 200, "右の花(相手)が赤で着色されていない")
        XCTAssertLessThan(left.red, left.blue / 4, "左に相手の色が混ざっている")
        XCTAssertLessThan(right.blue, right.red / 4, "右に自分の色が混ざっている")
    }

    // MARK: 5. 正本との一致

    func testDefaultPetalColorMatchesTheSVGAssets() throws {
        XCTAssertEqual(PlantLayers.defaultPetalRGB, 0xFFB3C7)
        for stage in 6...9 {
            let svg = try String(
                data: SourceTree.lienData("assets/plant/svg/petal_s\(stage).svg"),
                encoding: .utf8
            ) ?? ""
            XCTAssertTrue(svg.contains("fill=\"#FFB3C7\""), "petal_s\(stage).svg の塗りが既定の花色 #FFB3C7 ではない")
        }
    }

    func testSharedFilesAreSafeToShareWithTheWidget() throws {
        // PlantLayers / PlantCharacterView はウィジェットとシェア画像でも使う。Foundation / SwiftUI 以外に依存させない
        let allowed: [String: Set<String>] = [
            "Lien/Core/DesignSystem/PlantLayers.swift": ["Foundation"],
            "Lien/Core/DesignSystem/PlantCharacterView.swift": ["SwiftUI"],
            // のぞきの判定(PlantCharacterState(snapshot:) が使う)。ウィジェットの進み具合のバー(T17a)でも使う(PB #57)
            "Lien/Core/PlantProgress.swift": ["Foundation"],
        ]
        for (path, imports) in allowed {
            let source = try SourceTree.text(path)
            let found = Set(source.split(separator: "\n").compactMap { line -> String? in
                let parts = line.split(separator: " ")
                return parts.count == 2 && parts[0] == "import" ? String(parts[1]) : nil
            })
            XCTAssertEqual(found, imports, "\(path) の import が \(imports) だけではない")
        }
    }

    func testWidgetTargetSharesThePlantFilesAndCatalog() throws {
        let yml = try SourceTree.text("project.yml")
        let widget = try XCTUnwrap(
            yml.components(separatedBy: "\n  LienWidget:").last?.components(separatedBy: "\n  LienNSE:").first,
            "project.yml に LienWidget が無い"
        )
        for path in [
            "Lien/Core/DesignSystem/PlantLayers.swift",
            "Lien/Core/DesignSystem/PlantCharacterView.swift",
            "Lien/Core/PlantProgress.swift",
            "../assets/plant/PlantAssets.xcassets",
        ] {
            XCTAssertTrue(widget.contains(path), "LienWidget の sources に \(path) が無い(ウィジェットでも描く — GROWTH §8.2)")
        }
    }

    // MARK: 描画の道具

    /// 画像の画素を RGBA8 で取り出す
    private func rgbaPixels(_ image: UIImage) -> (width: Int, height: Int, data: [UInt8])? {
        guard let cg = image.cgImage else { return nil }
        let width = cg.width
        let height = cg.height
        var data = [UInt8](repeating: 0, count: width * height * 4)
        let drawn: Bool = data.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return drawn ? (width, height, data) : nil
    }

    private func paintedPixelCount(_ image: UIImage) -> Int {
        guard let pixels = rgbaPixels(image) else { return 0 }
        var count = 0
        var i = 3
        while i < pixels.data.count {
            if pixels.data[i] > 16 { count += 1 }
            i += 4
        }
        return count
    }

    /// 指定した範囲(画素)で、青っぽい画素と赤っぽい画素の数(不透明で、その色が他の2色より十分強いもの)
    private func dominantColorCounts(_ image: UIImage, xRange: Range<Int>, yRange: Range<Int>) -> (blue: Int, red: Int) {
        guard let pixels = rgbaPixels(image) else { return (0, 0) }
        var blue = 0
        var red = 0
        for y in yRange where y < pixels.height {
            for x in xRange where x < pixels.width {
                let i = (y * pixels.width + x) * 4
                let r = Int(pixels.data[i])
                let g = Int(pixels.data[i + 1])
                let b = Int(pixels.data[i + 2])
                let a = Int(pixels.data[i + 3])
                guard a > 200 else { continue }
                if b > 150, r < 90, g < 90 { blue += 1 }
                if r > 150, g < 90, b < 90 { red += 1 }
            }
        }
        return (blue, red)
    }
}

// PlantCharacterView.swift の fileprivate な Color(rgb:) と同じ作り(テスト用)
private extension Color {
    init(rgb: UInt32) {
        self.init(
            .sRGB,
            red: Double((rgb >> 16) & 0xFF) / 255,
            green: Double((rgb >> 8) & 0xFF) / 255,
            blue: Double(rgb & 0xFF) / 255,
            opacity: 1
        )
    }
}
