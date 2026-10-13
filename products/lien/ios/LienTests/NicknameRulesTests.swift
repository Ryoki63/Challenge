// NicknameRulesTests.swift — ニックネームの検証(オンボーディングと設定のプロフィール編集で共通。REQUIREMENTS §3.1・§3.15)
//
// DB の check 制約 `char_length(nickname) <= 8`(Unicode コードポイント数)と同じ数え方であること、
// 前後の空白を除いてから見ること、空白だけは空として扱うこと。

import XCTest
@testable import Lien

final class NicknameRulesTests: XCTestCase {
    func testMaxLengthIsEight() {
        XCTAssertEqual(NicknameRules.maxLength, 8)
    }

    func testEmptyAndWhitespaceOnlyAreEmpty() {
        XCTAssertEqual(NicknameRules.validate(""), .empty)
        XCTAssertEqual(NicknameRules.validate("   "), .empty)
        XCTAssertEqual(NicknameRules.validate("\n\t "), .empty)
        XCTAssertEqual(NicknameRules.validate("\u{3000}"), .empty, "全角の空白も空白")
    }

    func testBoundaryAtEightCharacters() {
        XCTAssertNil(NicknameRules.validate("あ"))
        XCTAssertNil(NicknameRules.validate("あいうえおかきく"), "8字は有効")
        XCTAssertEqual(NicknameRules.validate("あいうえおかきくけ"), .tooLong, "9字は超過")
    }

    func testSurroundingWhitespaceIsNotCounted() {
        XCTAssertNil(NicknameRules.validate("  あいうえおかきく \n"))
        XCTAssertEqual(NicknameRules.trimmed("  あいうえおかきく \n"), "あいうえおかきく")
        XCTAssertEqual(NicknameRules.trimmed("あ い"), "あ い", "途中の空白は残す")
    }

    func testCountsUnicodeScalarsLikeTheDatabase() {
        // 肌色修飾つきの絵文字は 1 書記素 = 2 スカラー。DB の char_length はスカラー数
        XCTAssertNil(NicknameRules.validate(String(repeating: "👍🏻", count: 4)), "8 スカラーまで")
        XCTAssertEqual(NicknameRules.validate(String(repeating: "👍🏻", count: 5)), .tooLong, "10 スカラー")
        // 1 つの書記素でも、スカラーが多ければ超過する(家族の絵文字は 5 スカラー)
        XCTAssertNil(NicknameRules.validate("👨\u{200D}👩\u{200D}👧"))
        XCTAssertEqual(NicknameRules.validate("👨\u{200D}👩\u{200D}👧👨\u{200D}👩\u{200D}👧"), .tooLong)
    }
}
