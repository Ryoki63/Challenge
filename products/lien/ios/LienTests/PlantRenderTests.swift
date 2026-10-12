// PlantRenderTests.swift — 植物の実描画の一覧画像(issue #56 / GROWTH §9.5 の承認ゲート)
//
// iOS が実際に SVG レイヤーを重ねて描いた結果を、ImageRenderer で PNG にして保存する。
// 下書きのプレビュー(Chrome の描画)と見比べて、受け入れ基準 10「iOS で描いたものと下書きに目立つ差がない」を確かめるためのもの。
//
//   plant_01_states_light / plant_02_states_dark   全段階(0〜9)× 今日の状態6通り(ふたりともまだ・自分だけ・相手だけ・
//                                                    ふたりそろった・すやすや・段階アップ)
//   plant_03_sizes_light / plant_04_sizes_dark     毎朝の既定を 40 / 60 / 80pt(高さ)で。ソロ+段階0〜9+段階9(ひらいた葉)
//   plant_05_expressions_light / _06_..._dark      表情6種・ソロ・ソロでチェックイン・段階0・のぞき・知らない段階
//   plant_07_flower_colors                         花の色(左=自分・右=相手で別の色に着色できること)
//
// 保存先は2つ(どちらかが失敗しても残るように):
//   1. XCTAttachment(.keepAlways)— xcresult に入る。lien-ios が xcrun xcresulttool export attachments で取り出して artifact にする
//   2. ios/build/plant-render/<名前>.png — ホストのファイルとして書く(build/ は gitignore 済み。シミュレータはホストのファイルを書ける)。
//      lien-ios がそのまま artifact(plant-render-sheets)にする
//
// ここでは画像の中身の良し悪しは判定しない(承認は人が一覧画像を見て行う)。描けたこと・空でないことだけを確かめる。
// 1枚ごとのレイヤーが空白でないこと・着色が効くことは PlantLayersTests が確かめる。

import SwiftUI
import UIKit
import XCTest
@testable import Lien

private func rgb(_ value: UInt32) -> Color {
    Color(
        .sRGB,
        red: Double((value >> 16) & 0xFF) / 255,
        green: Double((value >> 8) & 0xFF) / 255,
        blue: Double(value & 0xFF) / 255,
        opacity: 1
    )
}

private let stageNames = ["たね", "ふたば", "めばえ", "わかば", "よりそい", "つぼみ", "いろづき", "ほころび", "ふたりざき", "みのり"]

// MARK: - 一覧のパーツ

/// 植物1体(3:4)+ラベル
private struct PlantCell: View {
    let state: PlantCharacterState
    var height: CGFloat = 128
    var label: String?
    var meColor: Color = PlantCharacterView.defaultFlowerColor
    var partnerColor: Color = PlantCharacterView.defaultFlowerColor

    var body: some View {
        VStack(spacing: 2) {
            PlantCharacterView(state: state, meFlowerColor: meColor, partnerFlowerColor: partnerColor)
                .frame(width: height * 0.75, height: height)
            if let label {
                Text(label)
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .frame(width: max(height * 0.75, 60))
            }
        }
    }
}

/// 一覧の台紙(ライト / ダークの背景と環境)
private struct Sheet<Content: View>: View {
    let title: String
    let dark: Bool
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
            content
        }
        .padding(16)
        .background(dark ? Color(white: 0.09) : Color(white: 0.97))
        .environment(\.colorScheme, dark ? .dark : .light)
    }
}

/// 全段階 × 今日の状態
private struct StatesSheet: View {
    let dark: Bool

    private let rows: [(label: String, me: Bool, partner: Bool, expression: PlantExpression)] = [
        ("ふたりともまだ(朝)", false, false, .normal),
        ("自分だけ完了", true, false, .lookLeft),
        ("相手だけ完了", false, true, .lookRight),
        ("ふたりそろった", true, true, .happy),
        ("すやすや", false, false, .sleep),
        ("段階アップ", true, true, .wow),
    ]

    var body: some View {
        Sheet(title: "全段階 × 今日の状態(左の葉 = 自分 / 右の葉 = 相手)— \(dark ? "ダーク" : "ライト")", dark: dark) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 4) {
                    Color.clear.frame(width: 92, height: 12)
                    ForEach(0..<10, id: \.self) { stage in
                        Text("\(stage) \(stageNames[stage])")
                            .font(.system(size: 10, weight: .semibold))
                            .frame(width: 96)
                    }
                }
                ForEach(rows.indices, id: \.self) { index in
                    let row = rows[index]
                    HStack(spacing: 4) {
                        Text(row.label)
                            .font(.system(size: 10))
                            .frame(width: 92, alignment: .leading)
                        ForEach(0..<10, id: \.self) { stage in
                            PlantCell(
                                state: PlantCharacterState(
                                    stage: stage, meOpen: row.me, partnerOpen: row.partner, expression: row.expression
                                )
                            )
                        }
                    }
                }
            }
        }
    }
}

/// 毎朝の既定を 40 / 60 / 80pt で(どの段階も、1つ前と見分けられるか)
private struct SizesSheet: View {
    let dark: Bool
    private let heights: [CGFloat] = [40, 60, 80]

    var body: some View {
        Sheet(title: "高さ 40 / 60 / 80pt — ソロ・段階0〜9(朝の既定)・段階9(ひらいた葉)— \(dark ? "ダーク" : "ライト")", dark: dark) {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(heights, id: \.self) { height in
                    HStack(alignment: .bottom, spacing: 8) {
                        Text("\(Int(height))pt")
                            .font(.system(size: 10))
                            .frame(width: 34, alignment: .leading)
                        PlantCell(state: .solo, height: height)
                        ForEach(0..<10, id: \.self) { stage in
                            PlantCell(state: .morning(stage: stage), height: height)
                        }
                        PlantCell(
                            state: PlantCharacterState(stage: 9, meOpen: true, partnerOpen: true, expression: .normal),
                            height: height
                        )
                    }
                }
            }
        }
    }
}

/// 表情・ソロ・段階0・のぞき・知らない段階
private struct ExpressionsSheet: View {
    let dark: Bool

    private let items: [(String, PlantCharacterState)] = [
        ("ふつう", PlantCharacterState(stage: 3)),
        ("にっこり(ふたりそろった)", PlantCharacterState(stage: 3, meOpen: true, partnerOpen: true, expression: .happy)),
        ("自分の葉を見る", PlantCharacterState(stage: 3, meOpen: true, expression: .lookLeft)),
        ("相手の葉を見る", PlantCharacterState(stage: 3, partnerOpen: true, expression: .lookRight)),
        ("すやすや", PlantCharacterState(stage: 3, expression: .sleep)),
        ("おどろき(段階アップ)", PlantCharacterState(stage: 3, meOpen: true, partnerOpen: true, expression: .wow)),
        ("ソロ(ペア前)", .solo),
        ("ソロ: 自分がチェックイン", PlantCharacterState(stage: 0, isSolo: true, soilGlow: true)),
        ("段階0: 自分の芽が光る", PlantCharacterState(stage: 0, meOpen: true, expression: .lookLeft)),
        ("段階0: ふたりの芽が光る", PlantCharacterState(stage: 0, meOpen: true, partnerOpen: true, expression: .happy)),
        ("段階1の朝(葉は2枚ともたたむ)", PlantCharacterState(stage: 1)),
        ("みのり: 段階アップ", PlantCharacterState(stage: 9, meOpen: true, partnerOpen: true, expression: .wow)),
        ("のぞき: わかば", PlantCharacterState(stage: 3, meOpen: true, expression: .lookLeft, peek: true)),
        ("のぞき: よりそい", PlantCharacterState(stage: 4, expression: .normal, peek: true)),
        ("のぞき: ほころび", PlantCharacterState(stage: 7, partnerOpen: true, expression: .lookRight, peek: true)),
        ("のぞき: ふたりざき", PlantCharacterState(stage: 8, meOpen: true, partnerOpen: true, expression: .happy, peek: true)),
        ("知らない段階(12)→みのり", PlantCharacterState(stage: 12)),
        ("段階2の朝", PlantCharacterState(stage: 2)),
    ]

    var body: some View {
        Sheet(title: "表情6種・ソロ・段階0・のぞき・知らない段階 — \(dark ? "ダーク" : "ライト")", dark: dark) {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(0..<(items.count + 5) / 6, id: \.self) { row in
                    HStack(alignment: .top, spacing: 8) {
                        ForEach(row * 6..<min(row * 6 + 6, items.count), id: \.self) { index in
                            PlantCell(state: items[index].1, height: 168, label: items[index].0)
                        }
                    }
                }
            }
        }
    }
}

/// 花の色(左 = 自分・右 = 相手で別の色に着色できる — v1.1 の色えらびの下地)
private struct FlowerColorsSheet: View {
    private let combos: [(String, Color, Color)] = [
        ("既定 × 既定", PlantCharacterView.defaultFlowerColor, PlantCharacterView.defaultFlowerColor),
        ("ピンク × 青", rgb(0xFFB3C7), rgb(0xA9D8FF)),
        ("黄 × ライラック", rgb(0xFFDD73), rgb(0xD9C2FF)),
        ("白 × ピンク", rgb(0xFFFFFF), rgb(0xFFB3C7)),
        ("青 × 黄", rgb(0xA9D8FF), rgb(0xFFDD73)),
    ]

    var body: some View {
        Sheet(title: "花の色(自分 × 相手)— ふたりざき(段階8)・いろづき(段階6)・みのり(段階9)", dark: false) {
            VStack(alignment: .leading, spacing: 10) {
                ForEach([8, 6, 9], id: \.self) { stage in
                    HStack(alignment: .top, spacing: 8) {
                        ForEach(combos.indices, id: \.self) { index in
                            PlantCell(
                                state: PlantCharacterState(stage: stage, meOpen: true, partnerOpen: true, expression: .happy),
                                height: 168,
                                label: "段階\(stage): " + combos[index].0,
                                meColor: combos[index].1,
                                partnerColor: combos[index].2
                            )
                        }
                    }
                }
            }
        }
    }
}

// MARK: - テスト

@MainActor
final class PlantRenderTests: XCTestCase {
    private enum RenderError: Error, CustomStringConvertible {
        case failed(String)

        var description: String {
            switch self {
            case .failed(let name): return "\(name) を PNG にできない(ImageRenderer が画像を返さなかった)"
            }
        }
    }

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

    func testRenderContactSheets() throws {
        try save("plant_01_states_light", StatesSheet(dark: false))
        try save("plant_02_states_dark", StatesSheet(dark: true))
        try save("plant_03_sizes_light", SizesSheet(dark: false))
        try save("plant_04_sizes_dark", SizesSheet(dark: true))
        try save("plant_05_expressions_light", ExpressionsSheet(dark: false))
        try save("plant_06_expressions_dark", ExpressionsSheet(dark: true))
        try save("plant_07_flower_colors", FlowerColorsSheet())
    }

    func testRenderedSheetsAreNotBlank() throws {
        // 空のシート(どのレイヤーも描けなかった)を「保存できた」だけで通さない: 台紙の色以外の画素が十分にある
        let image = try save("plant_00_check_morning_strip", Sheet(title: "check", dark: false) {
            HStack(spacing: 4) {
                ForEach(0..<10, id: \.self) { stage in
                    PlantCell(state: .morning(stage: stage), height: 96)
                }
            }
        })
        let cg = try XCTUnwrap(image.cgImage)
        let width = cg.width
        let height = cg.height
        var data = [UInt8](repeating: 0, count: width * height * 4)
        let drawn: Bool = data.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        XCTAssertTrue(drawn)
        let background = (data[0], data[1], data[2])
        var differing = 0
        var index = 0
        while index < data.count {
            if data[index] != background.0 || data[index + 1] != background.1 || data[index + 2] != background.2 {
                differing += 1
            }
            index += 4
        }
        XCTAssertGreaterThan(differing, width * height / 10, "台紙の色以外の画素が少なすぎる(植物が描けていない?)")
    }
}
