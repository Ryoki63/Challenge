// WidgetLayoutTests.swift — ウィジェットの寸法の計算(WidgetMetrics)の検証(issue #17 T17a)
//
// 実機の大きさの目安(ポイント。システムの内側の余白 16pt を除いた、描ける範囲):
//   ホーム S: iPhone SE 109 / 標準 126 / Pro Max 138(正方形)   ホーム M: 260×109 / 306×126 / 332×138
//   ロック画面・円形: 約 76 の円
// 寸法が負にならない・植物が 3:4 を保つ・右の列に最小の幅が残る・円形の中で葉が欠けない、を確かめる。
// Foundation だけで書いてあるので、macOS の下見(scripts/macos-check)でも走る。

import XCTest
@testable import Lien

final class WidgetLayoutTests: XCTestCase {
    private let squares: [CGFloat] = [109, 126, 138]

    // MARK: - ホーム S

    func testSmallPlantKeepsThreeByFour() {
        for side in squares {
            let metrics = WidgetSmallMetrics(size: CGSize(width: side, height: side))
            XCTAssertEqual(metrics.plantSize.width / metrics.plantSize.height, 0.75, accuracy: 0.0001, "side \(side)")
        }
    }

    func testSmallRowAndFooterFillTheHeightExactly() {
        for side in squares {
            let metrics = WidgetSmallMetrics(size: CGSize(width: side, height: side))
            let total = metrics.rowHeight + WidgetSmallMetrics.captionHeight + WidgetSmallMetrics.barHeight + 2 * WidgetSmallMetrics.gap
            XCTAssertEqual(total, side, accuracy: 0.0001, "side \(side): 上の段 + 一言の行 + バー + 余白 = 内側の高さ")
            XCTAssertLessThanOrEqual(metrics.plantSize.height, metrics.rowHeight + 0.0001, "植物は上の段に収まる")
        }
    }

    func testSmallKeepsRoomForTheStreakAndTheTwoChips() {
        for side in squares {
            let metrics = WidgetSmallMetrics(size: CGSize(width: side, height: side))
            XCTAssertGreaterThanOrEqual(metrics.columnWidth, WidgetSmallMetrics.minColumnWidth - 0.0001, "side \(side)")
            // 植物 + 余白 + 右の列 = 内側の幅
            XCTAssertEqual(
                metrics.plantSize.width + WidgetSmallMetrics.columnGap + metrics.columnWidth, side, accuracy: 0.0001, "side \(side)"
            )
        }
    }

    func testSmallPlantIsAsBigAsTheRoomAllows() {
        // 狭い機種(内側 109)は、右の列の最小幅が先に効いて植物を削る / 標準(126)・大きい機種(138)は、植物の幅の上限(54%)まで
        let narrow = WidgetSmallMetrics(size: CGSize(width: 109, height: 109))
        XCTAssertEqual(
            narrow.plantSize.width, 109 - WidgetSmallMetrics.columnGap - WidgetSmallMetrics.minColumnWidth, accuracy: 0.0001
        )
        XCTAssertLessThan(narrow.plantSize.width, 109 * WidgetSmallMetrics.plantWidthShare)
        for side in [CGFloat(126), 138] {
            let metrics = WidgetSmallMetrics(size: CGSize(width: side, height: side))
            XCTAssertEqual(metrics.plantSize.width, side * WidgetSmallMetrics.plantWidthShare, accuracy: 0.0001, "side \(side)")
        }
        // 機種が大きいほど、植物も大きい(逆転しない)
        let widths = squares.map { WidgetSmallMetrics(size: CGSize(width: $0, height: $0)).plantSize.width }
        XCTAssertEqual(widths, widths.sorted())
    }

    func testSmallNeverGoesNegative() {
        for size in [CGSize.zero, CGSize(width: 10, height: 10), CGSize(width: 60, height: 20), CGSize(width: 0, height: 126), CGSize(width: 126, height: 0)] {
            let metrics = WidgetSmallMetrics(size: size)
            XCTAssertGreaterThanOrEqual(metrics.rowHeight, 0)
            XCTAssertGreaterThanOrEqual(metrics.plantSize.width, 0)
            XCTAssertGreaterThanOrEqual(metrics.plantSize.height, 0)
            XCTAssertGreaterThanOrEqual(metrics.columnWidth, 0)
        }
    }

    // MARK: - ホーム M

    func testMediumPlantFillsTheHeightAtThreeByFour() {
        for (width, height) in [(260.0, 109.0), (306.0, 126.0), (332.0, 138.0)] {
            let metrics = WidgetMediumMetrics(size: CGSize(width: width, height: height))
            XCTAssertEqual(metrics.plantSize.height, height, accuracy: 0.0001, "植物は高さいっぱい(Sより大きい)")
            XCTAssertEqual(metrics.plantSize.width / metrics.plantSize.height, 0.75, accuracy: 0.0001)
            XCTAssertGreaterThan(metrics.columnWidth, 120, "右の列に、ストリークと2人の状態と呼び名が入る幅がある")
            XCTAssertEqual(metrics.plantSize.width + WidgetMediumMetrics.columnGap + metrics.columnWidth, width, accuracy: 0.0001)
        }
    }

    func testMediumPlantIsBiggerThanTheSmallOne() {
        let small = WidgetSmallMetrics(size: CGSize(width: 126, height: 126))
        let medium = WidgetMediumMetrics(size: CGSize(width: 306, height: 126))
        XCTAssertGreaterThan(medium.plantSize.height, small.plantSize.height, "M は「植物を大きく」")
    }

    func testMediumNeverGoesNegative() {
        for size in [CGSize.zero, CGSize(width: 40, height: 126), CGSize(width: 306, height: 0)] {
            let metrics = WidgetMediumMetrics(size: size)
            XCTAssertGreaterThanOrEqual(metrics.plantSize.width, 0)
            XCTAssertGreaterThanOrEqual(metrics.plantSize.height, 0)
            XCTAssertGreaterThanOrEqual(metrics.columnWidth, 0)
            XCTAssertLessThanOrEqual(metrics.plantSize.width, size.width + 0.0001, "狭いときも、枠からはみ出さない")
        }
    }

    // MARK: - ロック画面・円形: 相手の葉

    /// 実際に描いた葉(右 = 左右反転後)の塗りの範囲(キャンバス座標 240×320)。4x で描いて、不透明な画素を数えた測定値:
    ///   leaf_open  x 113.5〜164 / y 89〜148.5   leaf_folded x 113.5〜152.75 / y 79〜148.5
    ///   nub_lit    x 115〜150 / y 101〜142        nub_closed  x 121.25〜138.75 / y 117.75〜142.5
    private let measured: [(layer: String, minX: Double, maxX: Double, minY: Double, maxY: Double)] = [
        ("leaf_open", 113.5, 164, 89, 148.5),
        ("leaf_folded", 113.5, 152.75, 79, 148.5),
        ("nub_lit", 115, 150, 101, 142),
        ("nub_closed", 121.25, 138.75, 117.75, 142.5),
    ]

    func testTheFocusContainsEveryLayerItIsUsedFor() {
        for item in measured {
            let leaf = WidgetContent.PartnerLeaf(layerName: item.layer, isOpen: true, isNub: item.layer.hasPrefix("nub_"))
            let focus = WidgetLeafFocus.focus(for: leaf)
            XCTAssertLessThanOrEqual(focus.minX, item.minX, item.layer)
            XCTAssertGreaterThanOrEqual(focus.maxX, item.maxX, item.layer)
            XCTAssertLessThanOrEqual(focus.minY, item.minY, item.layer)
            XCTAssertGreaterThanOrEqual(focus.maxY, item.maxY, item.layer)
        }
    }

    func testTheLeafStaysInsideTheCircle() {
        // 直径 76 の円に、葉の塗りの四隅(測定値)が収まる(切り抜きで欠けない)。直径が違う機種でも比率は同じ
        for diameter in [72.0, 76.0, 80.0] {
            for item in measured {
                let leaf = WidgetContent.PartnerLeaf(layerName: item.layer, isOpen: true, isNub: item.layer.hasPrefix("nub_"))
                let focus = WidgetLeafFocus.focus(for: leaf)
                let scale = focus.scale(fittingDiameter: diameter)
                let shift = focus.offset(scale: scale)
                for (x, y) in [(item.minX, item.minY), (item.maxX, item.minY), (item.minX, item.maxY), (item.maxX, item.maxY)] {
                    // キャンバス全体(中心 (120, 160))を拡大して shift だけずらしたあとの、円の中心からの位置
                    let px = (x - PlantLayers.canvasWidth / 2) * scale + shift.dx
                    let py = (y - PlantLayers.canvasHeight / 2) * scale + shift.dy
                    let distance = (px * px + py * py).squareRoot()
                    XCTAssertLessThanOrEqual(distance, diameter / 2, "\(item.layer) 直径 \(diameter): 四隅 (\(x), \(y)) が円から出る")
                }
            }
        }
    }

    func testTheFocusCenterLandsOnTheCircleCenter() {
        for focus in [WidgetLeafFocus.leaf, .nub] {
            let scale = focus.scale(fittingDiameter: 76)
            let shift = focus.offset(scale: scale)
            let cx = (focus.midX - PlantLayers.canvasWidth / 2) * scale + shift.dx
            let cy = (focus.midY - PlantLayers.canvasHeight / 2) * scale + shift.dy
            XCTAssertEqual(cx, 0, accuracy: 0.0001)
            XCTAssertEqual(cy, 0, accuracy: 0.0001)
        }
    }

    func testTheLeafFillsMostOfTheCircleButNotAll() {
        let focus = WidgetLeafFocus.leaf
        let scale = focus.scale(fittingDiameter: 76)
        let longest = max(focus.width, focus.height) * scale
        XCTAssertGreaterThan(longest, 76 * 0.7, "ロック画面で読めるよう、円の大部分に大きく出す")
        XCTAssertLessThan(longest, 76 * 0.9, "円の縁に付かない")
    }

    func testEachLeafKindUsesItsOwnFocus() {
        XCTAssertEqual(WidgetLeafFocus.focus(for: WidgetContent.PartnerLeaf(layerName: "leaf_open", isOpen: true, isNub: false)), .leaf)
        XCTAssertEqual(WidgetLeafFocus.focus(for: WidgetContent.PartnerLeaf(layerName: "leaf_folded", isOpen: false, isNub: false)), .leaf)
        XCTAssertEqual(WidgetLeafFocus.focus(for: WidgetContent.PartnerLeaf(layerName: "nub_lit", isOpen: true, isNub: true)), .nub)
        XCTAssertEqual(WidgetLeafFocus.focus(for: WidgetContent.PartnerLeaf(layerName: "nub_closed", isOpen: false, isNub: true)), .nub)
        // 開いた葉と畳んだ葉は、同じ範囲で見せる(茎の位置が動かない = 形の違いだけで、開閉を見分けられる)
        XCTAssertEqual(WidgetLeafFocus.leaf.midX, 139)
    }
}
