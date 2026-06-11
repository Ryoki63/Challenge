// PhotoProcessorTests.swift — 写真縮小の契約(T14 / DESIGN §5.6, §3.4)
//
// 検証対象(PhotoProcessor.swift):
//   - サムネは **200KB 以下**(NSE が相手ウィジェット用に DL する上限 — T17 との契約。
//     これを破ると相手側の写真表示が落ちる)
//   - 原寸は長辺 2048px 以下に縮小される(拡大はしない)
//   - 出力はどちらも画像としてデコード可能(JPEG)
//   - 画像でないデータは unreadableImage

import XCTest
import CoreGraphics
import ImageIO
@testable import Lien

final class PhotoProcessorTests: XCTestCase {
    /// 決定的な擬似乱数ノイズ画像(JPEG)を作る。ノイズは圧縮が効きにくく、
    /// 「大きい写真 → 反復圧縮で 200KB 以下」の経路を確実に踏ませる
    private func makeNoisyJPEG(width: Int, height: Int) throws -> Data {
        var seed: UInt64 = 0x5DEECE66D
        func nextByte() -> UInt8 {
            // LCG(検証の再現性のため Foundation の乱数は使わない)
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return UInt8(truncatingIfNeeded: seed >> 33)
        }
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for i in stride(from: 0, to: pixels.count, by: 4) {
            pixels[i] = nextByte() // R
            pixels[i + 1] = nextByte() // G
            pixels[i + 2] = nextByte() // B
            pixels[i + 3] = 255 // A(不透過)
        }
        let data = Data(pixels)
        let provider = try XCTUnwrap(CGDataProvider(data: data as CFData))
        let image = try XCTUnwrap(CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        ))
        let output = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(
            output as CFMutableData, "public.jpeg" as CFString, 1, nil
        ))
        CGImageDestinationAddImage(
            destination, image,
            [kCGImageDestinationLossyCompressionQuality: 0.95] as CFDictionary
        )
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return output as Data
    }

    private func imageSize(of data: Data) throws -> (width: Int, height: Int) {
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        let props = try XCTUnwrap(
            CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        )
        return (
            width: try XCTUnwrap(props[kCGImagePropertyPixelWidth] as? Int),
            height: try XCTUnwrap(props[kCGImagePropertyPixelHeight] as? Int)
        )
    }

    // MARK: 本体

    func testLargeNoisyPhotoIsDownscaledAndThumbStaysUnder200KB() throws {
        // 3000×2250 のノイズ JPEG(原寸縮小・サムネ反復圧縮の両経路を踏む)
        let original = try makeNoisyJPEG(width: 3000, height: 2250)

        let processed = try PhotoProcessor.process(original)

        // 原寸: 長辺 2048px 以下
        let photoSize = try imageSize(of: processed.photo)
        XCTAssertLessThanOrEqual(max(photoSize.width, photoSize.height), PhotoProcessor.photoMaxPixelSize)
        XCTAssertGreaterThan(min(photoSize.width, photoSize.height), 0)

        // サムネ: 200KB 以下(NSE 契約 — DESIGN §3.4)+長辺 512px 以下
        XCTAssertLessThanOrEqual(
            processed.thumb.count,
            PhotoProcessor.thumbMaxBytes,
            "photo_thumb.jpg は 200KB 以下(T17 NSE との契約)"
        )
        let thumbSize = try imageSize(of: processed.thumb)
        XCTAssertLessThanOrEqual(max(thumbSize.width, thumbSize.height), PhotoProcessor.thumbMaxPixelSize)

        // どちらも画像としてデコード可能(imageSize が throw しなかった時点で担保)
        XCTAssertFalse(processed.photo.isEmpty)
        XCTAssertFalse(processed.thumb.isEmpty)
    }

    func testSmallImageIsNotUpscaled() throws {
        let original = try makeNoisyJPEG(width: 320, height: 240)

        let processed = try PhotoProcessor.process(original)

        let photoSize = try imageSize(of: processed.photo)
        XCTAssertLessThanOrEqual(photoSize.width, 320, "拡大はしない")
        XCTAssertLessThanOrEqual(photoSize.height, 240)
        XCTAssertLessThanOrEqual(processed.thumb.count, PhotoProcessor.thumbMaxBytes)
    }

    func testNonImageDataThrowsUnreadable() {
        let notAnImage = Data("これは画像ではありません".utf8)
        XCTAssertThrowsError(try PhotoProcessor.process(notAnImage)) { error in
            XCTAssertEqual(error as? PhotoProcessor.ProcessError, .unreadableImage)
        }
        XCTAssertThrowsError(try PhotoProcessor.process(Data())) { error in
            XCTAssertEqual(error as? PhotoProcessor.ProcessError, .unreadableImage)
        }
    }
}
