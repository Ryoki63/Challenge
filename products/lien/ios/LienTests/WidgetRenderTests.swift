// WidgetRenderTests.swift — ウィジェットの実描画の一覧画像と、見た目の約束の検査(issue #17 T17a)
//
// iOS が実際に描いたホーム S / M・ロック画面の円形とインラインを、ImageRenderer で PNG にして保存する(lien-ios の artifact)。
//
//   widget_01_small_light / _02_small_dark         ホーム S: 状態16通り(完了の4通り・すやすや・段階0・ふたば・みのり・花・のぞき・
//                                                   新しいキーが無い・長い名前・ストリーク 0・ソロ・データ無し)
//   widget_03_medium_light / _04_medium_dark       ホーム M: 同じ状態(植物を大きく。相手の写真は v1.0.1)
//   widget_05_lock_screen                          ロック画面の円形(相手の葉の開閉・段階0の芽・ソロ・データ無し)とインライン
//   widget_06_small_sizes / _07_medium_sizes       機種の大きさ(iPhone SE / 標準 / Pro Max)× 文字の大きさ(標準・xxLarge・最大 = 上限で止まる)
//
// 保存先は PlantRenderTests と同じ 2 か所: XCTAttachment(xcresult)と ios/build/plant-render/(artifact「plant-render-sheets」)。
// 中身は本物のウィジェットと同じ WidgetRootView(imageStyle: .widgetFullColor)。システムが足す内側の余白 16pt・背景・角丸・
// 円形の背景は、WidgetTestFrame / WidgetLockCircle が近似する(WidgetRenderSupport.swift)。ロック画面の単色化(vibrant)は白黒で近似する。
// 実機での見え方(色合い(accented)表示・ロック画面の実際の単色化・メモリ)は、T20 で確かめる。
//
// 画像は**目で見るためのもの**。それとは別に、画素で確かめられる約束はテストにしてある:
//   - どの状態・大きさ・文字サイズでも、内側の余白(システムの 16pt)に描き込まない
//   - 進み具合のバーが、内容の長さ(区間の中での位置)どおりに塗られる / 新しいキーが無いときは出ない
//   - ダークでは植物の背面にプレートが敷かれる
//   - ロック画面の円形: 葉の塗りが測った範囲(WidgetLeafFocus)に収まり、円の縁に付かず、開閉が形で見分けられる
// UIKit・SwiftUI の描画を使うので、macOS の下見(macos-check)では走らせない(check.sh の EXCLUDE_TESTS)。

import SwiftUI
import UIKit
import XCTest
@testable import Lien

// MARK: - テスト

@MainActor
final class WidgetRenderTests: XCTestCase {
    private enum RenderError: Error, CustomStringConvertible {
        case failed(String)

        var description: String {
            switch self {
            case .failed(let name): return "\(name) を描けない(ImageRenderer が画像を返さなかった)"
            }
        }
    }

    private let smallSizes = [CGSize(width: 141, height: 141), CGSize(width: 158, height: 158), CGSize(width: 170, height: 170)]
    private let mediumSizes = [CGSize(width: 292, height: 141), CGSize(width: 338, height: 158), CGSize(width: 364, height: 170)]

    /// 直接書き出す先(ios/build/plant-render/。gitignore 済み)
    private func outputDirectory(file: StaticString = #filePath) -> URL {
        SourceTree.iosRoot(from: file)
            .appendingPathComponent("build", isDirectory: true)
            .appendingPathComponent("plant-render", isDirectory: true)
    }

    /// view を @2x の PNG にして、XCTAttachment と ios/build/plant-render/ の両方へ保存する
    @discardableResult
    private func save(_ name: String, _ view: some View) throws -> UIImage {
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        guard let image = renderer.uiImage, let png = image.pngData() else {
            throw RenderError.failed(name)
        }
        XCTAssertGreaterThan(image.size.width, 200, "\(name) が小さすぎる: \(image.size)")
        XCTAssertGreaterThan(image.size.height, 100, "\(name) が小さすぎる: \(image.size)")

        let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
        attachment.name = name + ".png"
        attachment.lifetime = .keepAlways // 既定の deleteOnSuccess だと、テストが通ったときに消える
        add(attachment)

        // ホストのファイルとしても書く。失敗してもテストは落とさない(XCTAttachment が本線)
        let directory = outputDirectory()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? png.write(to: directory.appendingPathComponent(name + ".png"))
        return image
    }

    /// view を指定の倍率で描いて、画素にする
    private func pixels(_ view: some View, scale: CGFloat) throws -> RenderedPixels {
        let renderer = ImageRenderer(content: view)
        renderer.scale = scale
        let image = try XCTUnwrap(renderer.uiImage, "ImageRenderer が画像を返さなかった")
        return try XCTUnwrap(RenderedPixels(image), "画素を読めない")
    }

    // MARK: - 一覧画像

    func testRenderTheWidgetContactSheets() throws {
        let small = CGSize(width: 158, height: 158)
        let medium = CGSize(width: 338, height: 158)
        try save("widget_01_small_light", WidgetStatesSheet(title: "ホーム S(158×158)— ライト", layout: .small, size: small, dark: false, columns: 4))
        try save("widget_02_small_dark", WidgetStatesSheet(title: "ホーム S(158×158)— ダーク", layout: .small, size: small, dark: true, columns: 4))
        try save("widget_03_medium_light", WidgetStatesSheet(title: "ホーム M(338×158。相手の写真は v1.0.1)— ライト", layout: .medium, size: medium, dark: false, columns: 2))
        try save("widget_04_medium_dark", WidgetStatesSheet(title: "ホーム M(338×158)— ダーク", layout: .medium, size: medium, dark: true, columns: 2))
        try save("widget_05_lock_screen", WidgetLockScreenSheet())
        try save("widget_06_small_sizes", WidgetSizesSheet(title: "ホーム S — 機種の大きさ × 文字の大きさ", layout: .small, sizes: smallSizes))
        try save("widget_07_medium_sizes", WidgetSizesSheet(title: "ホーム M — 機種の大きさ × 文字の大きさ", layout: .medium, sizes: mediumSizes))
    }

    // MARK: - 余白に描き込まない

    func testNoWidgetDrawsIntoTheSystemMargins() throws {
        // 内側の余白(システムの 16pt)は、背景のまま。縁のにじみの分(1pt)だけ余裕を見て、各辺から 15pt の帯を調べる。
        // 状態(16通り)× 機種の大きさ(S・M 各3)× ライト/ダーク × 文字の大きさ(標準・最大。最大は xxLarge で止まる)
        let band = 15
        var checked = 0
        for dark in [false, true] {
            let background = dark ? 28 : 255 // Color(white: 0.11) = 28 / 白
            for textSize in [DynamicTypeSize.large, .accessibility5] {
                for (layout, sizes) in [(WidgetLayout.small, smallSizes), (.medium, mediumSizes)] {
                    for size in sizes {
                        for item in WidgetSamples.homeStates {
                            let frame = WidgetTestFrame(
                                content: WidgetContent(snapshot: item.snapshot), layout: layout, size: size,
                                dark: dark, textSize: textSize, cornerRadius: 0
                            )
                            let image = try pixels(frame, scale: 1)
                            var firstBad: (Int, Int)?
                            var bad = 0
                            for y in 0..<image.height {
                                for x in 0..<image.width {
                                    let inBand = x < band || x >= image.width - band || y < band || y >= image.height - band
                                    guard inBand else { continue }
                                    let p = image.pixel(x, y)
                                    if abs(p.r - background) > 3 || abs(p.g - background) > 3 || abs(p.b - background) > 3 {
                                        bad += 1
                                        if firstBad == nil { firstBad = (x, y) }
                                    }
                                }
                            }
                            XCTAssertEqual(
                                bad, 0,
                                "\(layout) \(Int(size.width))×\(Int(size.height)) \(dark ? "ダーク" : "ライト") \(textSize) 「\(item.label)」: 内側の余白に \(bad) 画素描き込んでいる(最初の画素 \(String(describing: firstBad)))"
                            )
                            checked += 1
                        }
                    }
                }
            }
        }
        XCTAssertEqual(checked, 2 * 2 * 6 * WidgetSamples.homeStates.count)
    }

    // MARK: - 進み具合のバー

    /// ホーム S(158×158・角丸なし・ライト)を倍率 2 で描く。内側は 16〜142pt。バーは内側の一番下(y 137〜142pt)
    private func smallPixels(_ snapshot: PairSnapshot?) throws -> RenderedPixels {
        try pixels(
            WidgetTestFrame(
                content: WidgetContent(snapshot: snapshot), layout: .small, size: CGSize(width: 158, height: 158), cornerRadius: 0
            ),
            scale: 2
        )
    }

    private let barY: CGFloat = 139.5

    func testTheProgressBarIsFilledToTheContentsFraction() throws {
        // 区間の 2/7(わかばの 9 回目): 内側(126pt)の左 36pt が塗り(x 16〜52)、その先は土台
        let image = try smallPixels(WidgetSamples.paired())
        let fill = image.pixel(atPoint: 28, barY)
        XCTAssertTrue(fill.g > fill.r + 20 && fill.g > fill.b + 40, "塗り(緑)が出ていない: \(fill)")
        let track = image.pixel(atPoint: 100, barY)
        XCTAssertTrue(abs(track.r - 219) <= 8 && abs(track.g - 219) <= 8 && abs(track.b - 219) <= 8, "土台(薄いグレー)が出ていない: \(track)")
        // 塗りの終わりのすぐ外は土台(52pt より先)
        let justAfter = image.pixel(atPoint: 56, barY)
        XCTAssertTrue(abs(justAfter.r - justAfter.b) <= 8 && justAfter.g < 240, "塗りが長すぎる: \(justAfter)")
    }

    func testTheProgressBarIsFullAtTheLastStageAndAbsentWithoutTheKeys() throws {
        // (ソロとデータ無しのバーが無いことは、WidgetContentTests の progress == nil で確かめる。画面の下に一言が出るので、画素では見ない)
        let full = try smallPixels(WidgetSamples.paired(stage: 9, grown: 128, floor: 100, next: nil))
        let end = full.pixel(atPoint: 136, barY)
        XCTAssertTrue(end.g > end.r + 20 && end.g > end.b + 40, "最後の段階は、バーがいっぱい: \(end)")

        // 新しいキーが無い snapshot: バーを出さない(土台も出ない = 背景のまま)
        let none = try smallPixels(WidgetSamples.paired(grown: nil, floor: nil, next: nil))
        for x in [20.0, 60.0, 100.0, 138.0] {
            let p = none.pixel(atPoint: CGFloat(x), barY)
            XCTAssertTrue(p.r >= 250 && p.g >= 250 && p.b >= 250, "バーが出ている(x=\(x)): \(p)")
        }
    }

    // MARK: - ダークのプレート・植物の描画

    func testThePlantIsDrawnAndDarkAddsTheCreamPlate() throws {
        // 内側(16〜142pt)の左に植物(3:4)。キャンバス(240×320)の (60, 40) は、段階3では絵が無く、ダークではプレート(クリーム色)
        let metrics = WidgetSmallMetrics(size: CGSize(width: 126, height: 126))
        let originX: CGFloat = 16
        let originY = 16 + (metrics.rowHeight - metrics.plantSize.height) / 2
        let unit = metrics.plantSize.width / 240
        let sampleX = originX + 60 * unit
        let sampleY = originY + 40 * unit

        let light = try smallPixels(WidgetSamples.paired())
        let lightPixel = light.pixel(atPoint: sampleX, sampleY)
        XCTAssertTrue(lightPixel.r >= 250 && lightPixel.g >= 250 && lightPixel.b >= 250, "ライトはプレート無し(背景の白): \(lightPixel)")

        let dark = try pixels(
            WidgetTestFrame(
                content: WidgetContent(snapshot: WidgetSamples.paired()), layout: .small,
                size: CGSize(width: 158, height: 158), dark: true, cornerRadius: 0
            ),
            scale: 2
        )
        let darkPixel = dark.pixel(atPoint: sampleX, sampleY)
        XCTAssertTrue(
            abs(darkPixel.r - 255) <= 8 && abs(darkPixel.g - 247) <= 8 && abs(darkPixel.b - 234) <= 8,
            "ダークは bg_plate(クリーム色 #FFF7EA)が敷かれる: \(darkPixel)"
        )

        // 植物が描けている: 植物の枠の中に、背景以外の画素が十分にある(レイヤーが空白で描けていない事故を防ぐ)
        var painted = 0
        let x0 = Int(originX * 2), x1 = Int((originX + metrics.plantSize.width) * 2)
        let y0 = Int(originY * 2), y1 = Int((originY + metrics.plantSize.height) * 2)
        for y in y0..<y1 {
            for x in x0..<x1 {
                let p = light.pixel(x, y)
                if p.r < 240 || p.g < 240 || p.b < 240 { painted += 1 }
            }
        }
        XCTAssertGreaterThan(painted, (x1 - x0) * (y1 - y0) / 6, "植物がほとんど描けていない")
    }

    func testEveryHomeStateDrawsSomethingInBothSizes() throws {
        for item in WidgetSamples.homeStates {
            for (layout, size) in [(WidgetLayout.small, CGSize(width: 158, height: 158)), (.medium, CGSize(width: 338, height: 158))] {
                let image = try pixels(
                    WidgetTestFrame(content: WidgetContent(snapshot: item.snapshot), layout: layout, size: size, cornerRadius: 0),
                    scale: 1
                )
                var painted = 0
                for y in 0..<image.height {
                    for x in 0..<image.width {
                        let p = image.pixel(x, y)
                        if p.r < 240 || p.g < 240 || p.b < 240 { painted += 1 }
                    }
                }
                XCTAssertGreaterThan(painted, 800, "\(layout) 「\(item.label)」がほとんど描けていない")
            }
        }
    }

    // MARK: - ロック画面・円形

    /// 葉(右 = 左右反転後)のレイヤー1枚を、キャンバス(240×320)の大きさで、倍率 4 で描いた塗りの範囲
    private func paintedBounds(ofLayer name: String) throws -> (minX: Double, maxX: Double, minY: Double, maxY: Double) {
        let view = Image(PlantLayers.assetPrefix + name)
            .resizable()
            .frame(width: 240, height: 320)
            .scaleEffect(x: -1, y: 1)
        let image = try pixels(view, scale: 4)
        return try XCTUnwrap(image.paintedBounds(), "\(name) が描けていない")
    }

    func testTheLeafFocusContainsThePaintedLayers() throws {
        for name in ["leaf_open", "leaf_folded", "nub_lit", "nub_closed"] {
            let bounds = try paintedBounds(ofLayer: name)
            let focus: WidgetLeafFocus = name.hasPrefix("nub_") ? .nub : .leaf
            XCTAssertGreaterThanOrEqual(bounds.minX, focus.minX - 0.5, "\(name) \(bounds)")
            XCTAssertLessThanOrEqual(bounds.maxX, focus.maxX + 0.5, "\(name) \(bounds)")
            XCTAssertGreaterThanOrEqual(bounds.minY, focus.minY - 0.5, "\(name) \(bounds)")
            XCTAssertLessThanOrEqual(bounds.maxY, focus.maxY + 0.5, "\(name) \(bounds)")
        }
        // 実際の描画が、測った値(WidgetLayoutTests の measured)と一致している: アセットが差し替わったら、ここで気づく
        let open = try paintedBounds(ofLayer: "leaf_open")
        XCTAssertEqual(open.minX, 113.5, accuracy: 1.5)
        XCTAssertEqual(open.maxX, 164, accuracy: 1.5)
        XCTAssertEqual(open.minY, 89, accuracy: 1.5)
        XCTAssertEqual(open.maxY, 148.5, accuracy: 1.5)
    }

    private func circularPixels(_ snapshot: PairSnapshot?) throws -> RenderedPixels {
        try pixels(
            WidgetLockCircularView(content: WidgetContent(snapshot: snapshot), imageStyle: .widgetFullColor)
                .frame(width: 76, height: 76),
            scale: 4
        )
    }

    func testTheLeafInTheCircleDoesNotTouchTheEdge() throws {
        // 円の縁(半径 38pt のうち外側 1.5pt)に、葉の塗りが掛からない(切り抜きで欠けていない)
        let states: [PairSnapshot] = [
            WidgetSamples.paired(partner: true), WidgetSamples.paired(me: true),
            WidgetSamples.paired(partner: true, stage: 0, grown: 0, floor: 0, next: 1),
            WidgetSamples.paired(stage: 0, grown: 0, floor: 0, next: 1),
            WidgetSamples.paired(partner: true, stage: 9, grown: 120, floor: 100, next: nil),
        ]
        for (index, snapshot) in states.enumerated() {
            let image = try circularPixels(snapshot)
            XCTAssertNotNil(image.paintedBounds(), "状態 \(index): 葉が描けていない")
            var touching = 0
            for y in 0..<image.height {
                for x in 0..<image.width {
                    let dx = (Double(x) + 0.5) / Double(image.scale) - 38
                    let dy = (Double(y) + 0.5) / Double(image.scale) - 38
                    if (dx * dx + dy * dy).squareRoot() >= 38 - 1.5, image.pixel(x, y).a > 10 { touching += 1 }
                }
            }
            XCTAssertEqual(touching, 0, "状態 \(index): 円の縁に \(touching) 画素掛かっている")
        }
    }

    func testOpenAndFoldedLeavesAreToldApartByShapeNotOnlyByColor() throws {
        // ひらく / たたむは、色でなく形で見分けられる(GROWTH §9.5 の基準8。ロック画面は白黒に変換される)
        let open = try XCTUnwrap(circularPixels(WidgetSamples.paired(partner: true)).paintedBounds())
        let folded = try XCTUnwrap(circularPixels(WidgetSamples.paired(me: true)).paintedBounds())
        let openWidth = open.maxX - open.minX
        let foldedWidth = folded.maxX - folded.minX
        XCTAssertGreaterThan(openWidth, foldedWidth + 5, "ひらいた葉は、たたんだ葉より横に広い(open \(openWidth) / folded \(foldedWidth))")
        // 同じ範囲(茎の位置)で見せる: 茎の左端がそろう
        XCTAssertEqual(open.minX, folded.minX, accuracy: 2.5)
    }
}
