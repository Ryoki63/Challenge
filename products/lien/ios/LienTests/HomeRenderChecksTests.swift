// HomeRenderChecksTests.swift — ホームの見た目を、実際に描いて画素で確かめる(PV #59・PB #57 の Opus レビューの仕上げ)
//
// 計算(WhisperBubbleMetrics・PartnerPhotoCardLayout)の単体テストは別にある(PartnerPhotoRevalidationTests・PlantExperiencePolishTests)。
// ここは、その計算を View に当てた結果が、見た目の約束を守っているかを ImageRenderer の画素で確かめる。
// UIKit の色・アセットカタログ・描画を使う View を描くので、macOS の下見(macos-check)では走らせない(check.sh の EXCLUDE_TESTS)。
//
//   1. 吹き出しの余白   : 最大2行の吹き出しが、文字を大きくしても、ホームの ScrollView の上端(= 内容の上の余白 24pt の上)に
//                        食い込んで切れない。上の端の数行が台紙のままであること
//   2. 相手の写真のカード: 縦長の写真でも、枠は写真と同じ大きさで(外枠だけが幅いっぱいにならない)、四隅が角丸で透明になる
//   3. チケット残数バッジ: 0枚でもバッジが描ける(消えない)。文字を大きくしても白紙にならない(T19a #19)
//
// 描いた画像は、PlantRenderTests と同じく XCTAttachment と ios/build/plant-render/ に保存する(lien-ios の artifact「plant-render-sheets」)。
// 保存名は photo_ / bubble_ / ticket_ で始まる(PlantRenderTests の plant_ と区別)。

import ImageIO
import SwiftUI
import UniformTypeIdentifiers
import XCTest
@testable import Lien

// MARK: - 画素を読む道具

/// RGBA8 に描き直した画像(左上が原点の行順)
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
                data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { throw NSError(domain: "HomeRenderChecks", code: 1) }
        data = buffer
    }

    func rgba(x: Int, y: Int) -> (r: UInt8, g: UInt8, b: UInt8, a: UInt8) {
        let i = (y * width + x) * 4
        return (data[i], data[i + 1], data[i + 2], data[i + 3])
    }

    func alpha(x: Int, y: Int) -> UInt8 { rgba(x: x, y: y).a }

    /// 行 y が、台紙の色(background)だけでできているか
    func rowIsBackground(_ y: Int, _ background: (r: UInt8, g: UInt8, b: UInt8)) -> Bool {
        (0..<width).allSatisfy { x in
            let p = rgba(x: x, y: y)
            return p.r == background.r && p.g == background.g && p.b == background.b
        }
    }

    /// 最初に、台紙の色でない画素が現れる行(無ければ nil)
    func firstRowDiffering(from background: (r: UInt8, g: UInt8, b: UInt8)) -> Int? {
        (0..<height).first { !rowIsBackground($0, background) }
    }
}

@MainActor
private func renderPixels(_ view: some View, scale: CGFloat = 1) throws -> (image: CGImage, pixels: Pixels) {
    let renderer = ImageRenderer(content: view)
    renderer.scale = scale
    guard let image = renderer.cgImage else { throw NSError(domain: "HomeRenderChecks", code: 2) }
    return (image, try Pixels(image))
}

// MARK: - 1. 吹き出しの余白

@MainActor
final class WhisperBubbleRenderTests: XCTestCase {
    private let whisper = "あなたの葉が ひらくのも、たのしみにしてるよ" // 2行になる、いちばん長いひとこと

    /// ホームの ScrollView と同じ上の余白だけを残して、植物まわりを描く(台紙は単色)
    private func home(size: DynamicTypeSize, dark: Bool) -> some View {
        PlantHeroView(
            state: PlantCharacterState(stage: 9, meOpen: true, partnerOpen: true, expression: .happy),
            sways: false,
            plantName: "みどり",
            gaugeText: "ふたりで 128回 そろったよ",
            whisper: whisper,
            canWhisper: true
        )
        .frame(width: 320)
        .padding(.top, LienSpacing.l) // HomeView の ScrollView の内容の余白
        .background(dark ? Color.black : Color.white)
        .environment(\.dynamicTypeSize, size)
        .environment(\.colorScheme, dark ? .dark : .light)
    }

    func testTheBubbleDoesNotRunIntoTheTopEdgeAtAnyTextSize() throws {
        let sizes: [DynamicTypeSize] = [.xSmall, .large, .xxxLarge, .accessibility1, .accessibility3, .accessibility5]
        for dark in [false, true] {
            let background: (r: UInt8, g: UInt8, b: UInt8) = dark ? (0, 0, 0) : (255, 255, 255)
            for size in sizes {
                let (image, pixels) = try renderPixels(home(size: size, dark: dark), scale: 2)
                let name = "bubble_\(dark ? "dark" : "light")_\(size)"
                save(name, image)

                // 吹き出しが描けている(台紙以外の画素が、上の端より下に現れる)
                let first = try XCTUnwrap(pixels.firstRowDiffering(from: background), "\(name): 何も描けていない")
                // @2x なので、上の端から 2pt(= 4 画素)以上あけて始まる。0 なら ScrollView の上端で切れている
                XCTAssertGreaterThanOrEqual(first, 4, "\(name): 吹き出しが上の端(行 \(first))に食い込んでいる — 余白が足りない")
            }
        }
    }

    private func save(_ name: String, _ image: CGImage) {
        HomeRenderOutput.save(name, image, to: self)
    }
}

// MARK: - 2. 相手の写真のカード

@MainActor
final class PartnerPhotoCardRenderTests: XCTestCase {
    func testEachShapeIsClippedToItsOwnSizeWithRoundedCorners() throws {
        for (width, height) in [(512, 384), (384, 512), (512, 512), (1000, 300), (300, 1000)] {
            let image = TestImages.photoImage(width: width, height: height)
            let size = PartnerPhotoCardLayout.fittedSize(aspectRatio: image.aspectRatio)
            let (cg, pixels) = try renderPixels(PartnerPhotoThumbnailImage(image: image))
            let label = "\(width)x\(height)"

            // 描いた大きさ == 写真の大きさ(縦長で、外枠だけが幅いっぱいの 260 のまま残らない)
            XCTAssertEqual(CGFloat(cg.width), size.width.rounded(), accuracy: 1, "\(label): 幅")
            XCTAssertEqual(CGFloat(cg.height), size.height.rounded(), accuracy: 1, "\(label): 高さ")

            // 四隅は角丸で切り抜かれて透明、辺の中ほど・中央は写真
            let w = pixels.width
            let h = pixels.height
            for (x, y) in [(0, 0), (w - 1, 0), (0, h - 1), (w - 1, h - 1)] {
                XCTAssertEqual(pixels.alpha(x: x, y: y), 0, "\(label): 四隅 (\(x), \(y)) が角丸で透明になっていない")
            }
            XCTAssertEqual(pixels.alpha(x: w / 2, y: 0), 255, "\(label): 上の辺の中ほどは写真")
            XCTAssertEqual(pixels.alpha(x: 0, y: h / 2), 255, "\(label): 左の辺の中ほどは写真(左に透明な余白が無い)")
            XCTAssertEqual(pixels.alpha(x: w - 1, y: h / 2), 255, "\(label): 右の辺の中ほどは写真(右に透明な余白が無い)")
            XCTAssertEqual(pixels.alpha(x: w / 2, y: h / 2), 255, "\(label): 中央は写真")
        }
    }

    /// 目で見る一覧(縦長・横長・正方形・細長い写真のカード。台紙は灰色)
    func testRenderTheCardsForALookInTheArtifact() throws {
        let shapes = [(512, 384), (384, 512), (512, 512), (1000, 300), (300, 1000)]
        let sheet = HStack(alignment: .top, spacing: 16) {
            ForEach(shapes.indices, id: \.self) { index in
                VStack(spacing: 4) {
                    PartnerPhotoThumbnailImage(image: TestImages.photoImage(width: shapes[index].0, height: shapes[index].1))
                    Text("\(shapes[index].0)×\(shapes[index].1)").font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
        .padding(16)
        .background(Color(white: 0.8))
        let (image, _) = try renderPixels(sheet, scale: 2)
        HomeRenderOutput.save("photo_01_partner_photo_cards", image, to: self)
    }
}

// MARK: - 3. お休みチケットの残数バッジ(T19a #19)

@MainActor
final class TicketBalanceBadgeRenderTests: XCTestCase {
    /// 0枚でもバッジを出す(罰なし — REQUIREMENTS §3.5)。文字を大きくしても、何かが描けていること
    func testTheZeroBadgeStillDrawsAtAccessibilitySizes() throws {
        let background: (r: UInt8, g: UInt8, b: UInt8) = (255, 255, 255)
        for size in [DynamicTypeSize.large, .accessibility5] {
            // 台紙を白で塗る(バッジの外側も白。透明のままだと「何か描けている」を判定できない)
            let view = ZStack {
                Color.white
                TicketBalanceBadge(balance: 0)
                    .padding(LienSpacing.m)
            }
            .frame(width: 360, height: 220)
            .environment(\.dynamicTypeSize, size)
            .environment(\.colorScheme, .light)
            let (image, pixels) = try renderPixels(view, scale: 2)
            let name = "ticket_zero_\(size)"
            HomeRenderOutput.save(name, image, to: self)
            XCTAssertNotNil(
                pixels.firstRowDiffering(from: background),
                "\(name): 0枚のバッジが描けていない(白紙)"
            )
        }
    }

    /// 目で見る一覧(0 / 1 / 2 / 5枚)。0枚が消えていないことを artifact でも確かめられる
    func testRenderTheBalancesForALookInTheArtifact() throws {
        let sheet = VStack(alignment: .leading, spacing: LienSpacing.s) {
            ForEach([0, 1, 2, 5], id: \.self) { balance in
                HStack(spacing: LienSpacing.s) {
                    TicketBalanceBadge(balance: balance)
                    Text("balance=\(balance)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(LienSpacing.m)
        .background(Color.white)
        let (image, _) = try renderPixels(sheet, scale: 2)
        HomeRenderOutput.save("ticket_01_balances", image, to: self)
    }
}

// MARK: - 保存(PlantRenderTests と同じ 2 か所)

private enum HomeRenderOutput {
    /// XCTAttachment(xcresult)と ios/build/plant-render/(ホストのファイル)の両方へ保存する。保存に失敗してもテストは落とさない
    @MainActor
    static func save(_ name: String, _ image: CGImage, to testCase: XCTestCase, file: StaticString = #filePath) {
        guard let png = pngData(image) else { return }
        let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
        attachment.name = name + ".png"
        attachment.lifetime = .keepAlways
        testCase.add(attachment)

        let directory = SourceTree.iosRoot(from: file)
            .appendingPathComponent("build", isDirectory: true)
            .appendingPathComponent("plant-render", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? png.write(to: directory.appendingPathComponent(name + ".png"))
    }

    /// CGImage → PNG(ImageIO。UIKit に依存しない)
    private static func pngData(_ image: CGImage) -> Data? {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output as CFMutableData, UTType.png.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? (output as Data) : nil
    }
}
