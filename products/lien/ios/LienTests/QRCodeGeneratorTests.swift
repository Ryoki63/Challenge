// QRCodeGeneratorTests.swift — 招待 QR コード生成(T11)
//
// CoreImage の CIFilter.qrCodeGenerator はシミュレータでも動く(GPU 不要のソフトウェア描画)。

import CoreGraphics
import XCTest
@testable import Lien

final class QRCodeGeneratorTests: XCTestCase {
    func testGeneratesImageForInviteURL() {
        let image = QRCodeGenerator.generate(from: "lien://invite/AbCd2345")
        XCTAssertNotNil(image)
        XCTAssertEqual(image?.width, image?.height) // QR は正方形
        XCTAssertGreaterThan(image?.width ?? 0, 0)
    }

    func testGeneratesImageForWebURL() {
        // 実際に QR へ入れるのは webUrl(PairingView 参照)
        let image = QRCodeGenerator.generate(
            from: "https://ryoki63.github.io/Challenge/lien/i/?t=AbCd2345"
        )
        XCTAssertNotNil(image)
    }

    func testScaleMultipliesPixelSizeExactly() throws {
        let base = try XCTUnwrap(QRCodeGenerator.generate(from: "lien://invite/AbCd2345", scale: 1))
        let scaled = try XCTUnwrap(QRCodeGenerator.generate(from: "lien://invite/AbCd2345", scale: 4))
        // 整数倍拡大(にじみ禁止 — DESIGN §3.5 と同じ原則)
        XCTAssertEqual(scaled.width, base.width * 4)
        XCTAssertEqual(scaled.height, base.height * 4)
    }

    func testReturnsNilForEmptyStringOrInvalidScale() {
        XCTAssertNil(QRCodeGenerator.generate(from: ""))
        XCTAssertNil(QRCodeGenerator.generate(from: "lien://invite/AbCd2345", scale: 0))
    }
}
