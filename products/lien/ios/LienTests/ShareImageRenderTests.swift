// ShareImageRenderTests.swift — 生成画像のスナップショットテスト(T22 / REQUIREMENTS §3.13)
//
// 実際に ImageRenderer で描いたシェア画像を確かめる(iOS のシミュレータで動かす。macos-check では走らせない):
//
//   1. 大きさ: 縦 9:16 = 1080×1920、正方形 1:1 = 1080×1080
//   2. 中身: 空でない。ストリーク・2人のニックネーム・植物・アプリ名を変えると、それぞれの場所の画素が変わる
//      (「文字を入れたつもりで描けていない」を CI で止める)
//   3. スナップショット: 画像を 12×20 / 12×12 の平均色に縮めた指紋を、コミットした
//      LienTests/ShareImageSnapshots.json と比べる(±12。フォントのわずかな差では落とさない)
//   4. 目で見るための PNG を ios/build/plant-render/ と XCTAttachment に保存する(lien-ios の artifact)
//
// 初回(指紋のファイルが無いとき)は、指紋を ios/build/plant-render/ShareImageSnapshots.json に書いて通す。
// その JSON を確認して LienTests/ShareImageSnapshots.json にコミットすると、次からは比較になる。
//
// 写真が入らないことは ShareImageModelTests(内容に写真が無い)で確かめてある。

import CoreGraphics
import Foundation
import SwiftUI
import XCTest
@testable import Lien

// MARK: - 指紋

/// 画像を小さな格子の平均色に縮めたもの(±の許容で比べるスナップショット)
private struct ShareImageFingerprint: Codable, Equatable {
    let format: String
    let width: Int
    let height: Int
    let columns: Int
    let rows: Int
    /// RGB の順に並べた平均色(0…255)
    let cells: [Int]
}

private struct ShareImageGolden: Codable, Equatable {
    let snapshots: [ShareImageFingerprint]
}

private struct ShareImageGoldenFile {
    static func url(file: StaticString = #filePath) -> URL {
        SourceTree.iosRoot(from: file).appendingPathComponent("LienTests/ShareImageSnapshots.json")
    }
}

// MARK: - 画素

private struct Pixels {
    let width: Int
    let height: Int
    let data: [UInt8]

    init(_ image: CGImage) throws {
        width = image.width
        height = image.height
        var buffer = [UInt8](repeating: 0, count: width * height * 4)
        let width = self.width
        let height = self.height
        let drawn: Bool = buffer.withUnsafeMutableBytes { raw in
            guard let context = CGContext(
                data: raw.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { throw PixelError.failed }
        data = buffer
    }

    enum PixelError: Error { case failed }

    func rgba(x: Int, y: Int) -> (r: UInt8, g: UInt8, b: UInt8) {
        let i = (y * width + x) * 4
        return (data[i], data[i + 1], data[i + 2])
    }

    /// 画素の色が、左上の背景色から十分に違うか(空の画像を通さない)
    func drawnPixelCount(differentFrom background: (r: UInt8, g: UInt8, b: UInt8), tolerance: Int = 10) -> Int {
        var count = 0
        for y in 0..<height {
            for x in 0..<width {
                let p = rgba(x: x, y: y)
                if abs(Int(p.r) - Int(background.r)) > tolerance
                    || abs(Int(p.g) - Int(background.g)) > tolerance
                    || abs(Int(p.b) - Int(background.b)) > tolerance {
                    count += 1
                }
            }
        }
        return count
    }

    /// 2枚の違う画素の数と範囲
    func difference(from other: Pixels) -> Difference {
        var result = Difference()
        guard width == other.width, height == other.height else {
            result.count = Int.max
            return result
        }
        for y in 0..<height {
            for x in 0..<width {
                let a = rgba(x: x, y: y)
                let b = other.rgba(x: x, y: y)
                if abs(Int(a.r) - Int(b.r)) > 8
                    || abs(Int(a.g) - Int(b.g)) > 8
                    || abs(Int(a.b) - Int(b.b)) > 8 {
                    result.add(x: x, y: y)
                }
            }
        }
        return result
    }

    func fingerprint(format: ShareImageFormat, columns: Int, rows: Int) -> ShareImageFingerprint {
        var cells: [Int] = []
        cells.reserveCapacity(columns * rows * 3)
        for row in 0..<rows {
            let y0 = row * height / rows
            let y1 = max(y0 + 1, (row + 1) * height / rows)
            for column in 0..<columns {
                let x0 = column * width / columns
                let x1 = max(x0 + 1, (column + 1) * width / columns)
                var sumR = 0, sumG = 0, sumB = 0, count = 0
                for y in y0..<min(y1, height) {
                    for x in x0..<min(x1, width) {
                        let p = rgba(x: x, y: y)
                        sumR += Int(p.r)
                        sumG += Int(p.g)
                        sumB += Int(p.b)
                        count += 1
                    }
                }
                let n = max(count, 1)
                cells.append(sumR / n)
                cells.append(sumG / n)
                cells.append(sumB / n)
            }
        }
        return ShareImageFingerprint(
            format: format.rawValue,
            width: width,
            height: height,
            columns: columns,
            rows: rows,
            cells: cells
        )
    }
}

private struct Difference {
    var count = 0
    var minX = Int.max
    var maxX = -1
    var minY = Int.max
    var maxY = -1

    mutating func add(x: Int, y: Int) {
        count += 1
        minX = min(minX, x)
        maxX = max(maxX, x)
        minY = min(minY, y)
        maxY = max(maxY, y)
    }
}

// MARK: - テスト

@MainActor
final class ShareImageRenderTests: XCTestCase {
    private enum RenderError: Error, CustomStringConvertible {
        case failed(String)

        var description: String {
            switch self {
            case .failed(let name): return "\(name) を PNG にできない(ImageRenderer が画像を返さなかった)"
            }
        }
    }

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        return calendar
    }

    private func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 12))!
    }

    private var baseContent: ShareImageContent {
        ShareImageContent(
            myName: "ゆうき",
            partnerName: "あき",
            streakDays: 30,
            startedOn: date(2026, 9, 21),
            plantStage: 6,
            appName: "Lien"
        )
    }

    private var longNameContent: ShareImageContent {
        ShareImageContent(
            myName: "あいうえおかきく",
            partnerName: "さしすせそたちつ",
            streakDays: 365,
            startedOn: date(2025, 10, 21),
            plantStage: 9,
            appName: "Lien"
        )
    }

    /// 直接書き出す先(ios/build/plant-render/。gitignore 済み)
    private func outputDirectory(file: StaticString = #filePath) -> URL {
        SourceTree.iosRoot(from: file)
            .appendingPathComponent("build", isDirectory: true)
            .appendingPathComponent("plant-render", isDirectory: true)
    }

    private func render(_ content: ShareImageContent, _ format: ShareImageFormat) throws -> (image: CGImage, pixels: Pixels) {
        guard let image = ShareImageRenderer.render(content, format: format) else {
            throw RenderError.failed("\(format.rawValue)")
        }
        return (image, try Pixels(image))
    }

    @discardableResult
    private func save(_ name: String, _ image: CGImage, pngData: Data) throws -> Pixels {
        let attachment = XCTAttachment(data: pngData, uniformTypeIdentifier: "public.png")
        attachment.name = name + ".png"
        attachment.lifetime = .keepAlways // 通ったときも artifact に残す
        add(attachment)

        let directory = outputDirectory()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? pngData.write(to: directory.appendingPathComponent(name + ".png"))
        return try Pixels(image)
    }

    private func png(_ image: CGImage, name: String) throws -> Data {
        guard let data = ShareImageRenderer.pngData(image) else {
            throw RenderError.failed(name)
        }
        return data
    }

    // MARK: スナップショット(大きさ・指紋・artifact)

    func testGoldenSnapshotsForBothFormats() throws {
        var snapshots: [ShareImageFingerprint] = []

        // 縦(ストーリーズ 9:16)
        let story = try render(baseContent, .story)
        let storyPNG = try png(story.image, name: "share_01_story")
        let storyPixels = try save("share_01_story", story.image, pngData: storyPNG)
        XCTAssertEqual(storyPixels.width, 1080, "縦は 1080×1920(9:16)")
        XCTAssertEqual(storyPixels.height, 1920)
        snapshots.append(storyPixels.fingerprint(format: .story, columns: 12, rows: 20))

        // 正方形(1:1)
        let square = try render(baseContent, .square)
        let squarePNG = try png(square.image, name: "share_02_square")
        let squarePixels = try save("share_02_square", square.image, pngData: squarePNG)
        XCTAssertEqual(squarePixels.width, 1080, "正方形は 1080×1080(1:1)")
        XCTAssertEqual(squarePixels.height, 1080)
        snapshots.append(squarePixels.fingerprint(format: .square, columns: 12, rows: 12))

        // いちばん長いニックネーム(8文字+8文字)と 365日。文字が枠に収まっているかを目で見るため
        let longNames = try render(longNameContent, .story)
        let longNamesPNG = try png(longNames.image, name: "share_03_long_names")
        let longNamePixels = try save("share_03_long_names", longNames.image, pngData: longNamesPNG)
        XCTAssertEqual(longNamePixels.width, 1080)
        XCTAssertEqual(longNamePixels.height, 1920)
        snapshots.append(longNamePixels.fingerprint(format: .story, columns: 12, rows: 20))

        // 空でない(背景以外の画素が十分にある)
        for (pixels, name) in [(storyPixels, "story"), (squarePixels, "square"), (longNamePixels, "long names")] {
            let background = pixels.rgba(x: 0, y: 0)
            XCTAssertGreaterThan(
                pixels.drawnPixelCount(differentFrom: background),
                pixels.width * pixels.height / 10,
                "\(name) がほぼ空(植物も文字も描けていない)"
            )
        }

        try assertGolden(ShareImageGolden(snapshots: snapshots))
    }

    /// 初回の生成に頼らず、指紋のファイルがリポジトリにコミットされていること
    func testTheGoldenSnapshotFileIsCommitted() {
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: ShareImageGoldenFile.url().path),
            "LienTests/ShareImageSnapshots.json がありません。CI の artifact から指紋をコミットしてください"
        )
    }

    // MARK: 文字・植物・アプリ名が実際に描かれている

    func testTheStreakNamesPlantAndAppNameAreRendered() throws {
        let base = try render(baseContent, .story).pixels

        // ストリーク: 数字が変わると、上の方の画素が変わる
        let streakChanged = ShareImageContent(
            myName: baseContent.myName,
            partnerName: baseContent.partnerName,
            streakDays: baseContent.streakDays + 1,
            startedOn: baseContent.startedOn,
            plantStage: baseContent.plantStage,
            appName: baseContent.appName
        )
        let streakDiff = base.difference(from: try render(streakChanged, .story).pixels)
        XCTAssertGreaterThan(streakDiff.count, 300, "ストリークの数字が描かれていない")
        XCTAssertLessThan(streakDiff.maxY, 1920 * 55 / 100, "ストリークは画像の上の方にある")

        // 2人のニックネーム: 名前が変わると、真ん中より下の画素が変わる
        let namesChanged = ShareImageContent(
            myName: "はるか",
            partnerName: baseContent.partnerName,
            streakDays: baseContent.streakDays,
            startedOn: baseContent.startedOn,
            plantStage: baseContent.plantStage,
            appName: baseContent.appName
        )
        let namesDiff = base.difference(from: try render(namesChanged, .story).pixels)
        XCTAssertGreaterThan(namesDiff.count, 800, "ニックネームが描かれていない")
        XCTAssertGreaterThan(namesDiff.minY, 1920 * 50 / 100, "ニックネームは植物の下にある")
        XCTAssertLessThan(namesDiff.maxY, 1920 * 98 / 100)

        // 植物: 段階が変わると、真ん中の画素が変わる
        let plantChanged = ShareImageContent(
            myName: baseContent.myName,
            partnerName: baseContent.partnerName,
            streakDays: baseContent.streakDays,
            startedOn: baseContent.startedOn,
            plantStage: 9,
            appName: baseContent.appName
        )
        let plantDiff = base.difference(from: try render(plantChanged, .story).pixels)
        XCTAssertGreaterThan(plantDiff.count, 2000, "植物の現在の姿が描かれていない")
        XCTAssertGreaterThan(plantDiff.minY, 1920 * 15 / 100)
        XCTAssertLessThan(plantDiff.maxY, 1920 * 90 / 100)

        // アプリ名: 消すと、右下の隅だけが変わる(オーガニック流入装置 — §3.13)
        let withoutAppName = ShareImageContent(
            myName: baseContent.myName,
            partnerName: baseContent.partnerName,
            streakDays: baseContent.streakDays,
            startedOn: baseContent.startedOn,
            plantStage: baseContent.plantStage,
            appName: ""
        )
        let appDiff = base.difference(from: try render(withoutAppName, .story).pixels)
        XCTAssertGreaterThan(appDiff.count, 50, "アプリ名が描かれていない")
        XCTAssertGreaterThan(appDiff.minX, 1080 * 50 / 100, "アプリ名は右下の隅にある")
        XCTAssertGreaterThan(appDiff.minY, 1920 * 80 / 100)
    }

    func testSquareIsANotBlankSnapshot() throws {
        let square = try render(baseContent, .square).pixels
        let background = square.rgba(x: 0, y: 0)
        XCTAssertGreaterThan(
            square.drawnPixelCount(differentFrom: background),
            square.width * square.height / 10
        )
    }

    // MARK: 指紋の比較

    private func assertGolden(_ actual: ShareImageGolden) throws {
        let url = ShareImageGoldenFile.url()
        if !FileManager.default.fileExists(atPath: url.path) {
            // 初回だけ: 指紋を書いて通す。この JSON を LienTests/ にコミットすると、次から比較になる
            try writeGolden(actual)
            print(
                "ShareImageSnapshots.json が無いので、初回の指紋を \(outputDirectory().path)/ShareImageSnapshots.json に書きました。"
                    + " 確認して LienTests/ShareImageSnapshots.json にコミットしてください。"
            )
            return
        }

        let expected = try JSONDecoder().decode(ShareImageGolden.self, from: Data(contentsOf: url))
        XCTAssertEqual(actual.snapshots.count, expected.snapshots.count, "スナップショットの数が違う")
        for (a, e) in zip(actual.snapshots, expected.snapshots) {
            XCTAssertEqual(a.format, e.format)
            XCTAssertEqual(a.width, e.width, "\(a.format) の幅が違う")
            XCTAssertEqual(a.height, e.height, "\(a.format) の高さが違う")
            XCTAssertEqual(a.columns, e.columns)
            XCTAssertEqual(a.rows, e.rows)
            guard a.cells.count == e.cells.count else {
                XCTFail("\(a.format) の指紋の長さが違う(\(a.cells.count) != \(e.cells.count))")
                continue
            }
            for i in a.cells.indices {
                let delta = abs(a.cells[i] - e.cells[i])
                if delta > 12 {
                    XCTFail(
                        "\(a.format) のスナップショットが変わった: cell \(i / 3)(\(i % 3 == 0 ? "R" : i % 3 == 1 ? "G" : "B")) "
                            + "actual \(a.cells[i]) / expected \(e.cells[i])。"
                            + " 意図した変更なら ShareImageSnapshots.json を更新してください"
                    )
                    break
                }
            }
        }
    }

    private func writeGolden(_ golden: ShareImageGolden) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(golden)
        let directory = outputDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: directory.appendingPathComponent("ShareImageSnapshots.json"))

        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        attachment.name = "ShareImageSnapshots.json"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
