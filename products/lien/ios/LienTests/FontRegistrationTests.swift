// FontRegistrationTests.swift — 丸ゴシックの書体が登録されているか(2026-11-11 UI 改修)
//
// SwiftUI の Font.custom は、書体が見つからないと黙ってシステムの書体で描く(落ちない)。
// そのため、同梱漏れ・UIAppFonts の書き忘れ・PostScript 名の誤りは、画面を見ないと気づけない。ここで先に落とす。

import UIKit
import XCTest
@testable import Lien

final class FontRegistrationTests: XCTestCase {
    func testTheAppBundleRegistersTheFontFiles() throws {
        let listed = try XCTUnwrap(Bundle.main.object(forInfoDictionaryKey: "UIAppFonts") as? [String])
        XCTAssertEqual(Set(listed), Set(LienTypeface.files))
        for file in LienTypeface.files {
            let name = (file as NSString).deletingPathExtension
            XCTAssertNotNil(Bundle.main.url(forResource: name, withExtension: "ttf"), "\(file) がアプリに同梱されていない")
        }
    }

    func testThePostScriptNamesResolve() {
        for name in [LienTypeface.regular, LienTypeface.bold] {
            XCTAssertNotNil(UIFont(name: name, size: 17), "\(name) が読めない(UIAppFonts か PostScript 名を確かめる)")
        }
    }

    func testTheWidgetRegistersTheSameFonts() throws {
        // ウィジェットの Info.plist は project.yml から作られる。アプリと同じ書体を登録しているかをソースで確かめる
        let yml = try SourceTree.text("project.yml")
        let widget = try XCTUnwrap(yml.range(of: "\n  LienWidget:\n"))
        let rest = yml[widget.upperBound...]
        let end = rest.range(of: "\n  LienNSE:\n")?.lowerBound ?? rest.endIndex
        let block = String(rest[..<end])
        XCTAssertTrue(block.contains("UIAppFonts:"))
        for file in LienTypeface.files {
            XCTAssertTrue(block.contains("- \(file)"), "LienWidget の UIAppFonts に \(file) が無い")
        }
        XCTAssertTrue(block.contains("../assets/fonts/ZenMaruGothic"), "LienWidget に書体のフォルダが入っていない")
    }

    func testTheLicenseShipsWithTheFonts() throws {
        // SIL OFL 1.1: 書体を配るときは、ライセンス文を一緒に配る
        let license = try SourceTree.lienData("assets/fonts/ZenMaruGothic/OFL.txt")
        let text = try XCTUnwrap(String(data: license, encoding: .utf8))
        XCTAssertTrue(text.contains("SIL OPEN FONT LICENSE"))
    }
}
