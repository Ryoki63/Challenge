// ReleaseReadinessTests.swift — TestFlight / App Store に上げるための、同梱ファイルの前提(issue #28)
//
// 初回アップロードで弾かれる(ITMS エラー)・「ビルドは通るが push が来ない」型の事故を、CI で先に止める。
//   - AppIcon: 1024×1024 の単一サイズ・アルファチャンネルなし(App Store の要件)。assets/icon の正本と同一
//   - ExportOptions.plist: App Store Connect へ直接アップロード・自動署名・ビルド番号は CI が決める
//   - エンタイトルメント: アプリ本体に aps-environment(push)、3 ターゲットとも同じ App Group
//
// 署名・アップロードそのものは lien-release の担当(ここでは同梱ファイルの形だけを見る)。

import Foundation
import XCTest

final class ReleaseReadinessTests: XCTestCase {
    // MARK: AppIcon

    private let appIconSet = "Lien/Assets.xcassets/AppIcon.appiconset"

    /// PNG のヘッダと、含まれるチャンクの種類
    private struct PNGInfo {
        let width: Int
        let height: Int
        let bitDepth: Int
        let colorType: Int
        let chunkTypes: [String]
    }

    private func readPNG(_ data: Data) throws -> PNGInfo {
        let signature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        XCTAssertEqual(Array(data.prefix(8)), signature, "PNG ではありません")
        let bytes = [UInt8](data)
        func uint32(_ offset: Int) -> Int {
            (Int(bytes[offset]) << 24) | (Int(bytes[offset + 1]) << 16) | (Int(bytes[offset + 2]) << 8) | Int(bytes[offset + 3])
        }
        var offset = 8
        var chunkTypes: [String] = []
        var header: (Int, Int, Int, Int)?
        while offset + 8 <= bytes.count {
            let length = uint32(offset)
            let type = String(decoding: bytes[(offset + 4)..<(offset + 8)], as: UTF8.self)
            chunkTypes.append(type)
            if type == "IHDR", offset + 8 + 13 <= bytes.count {
                header = (uint32(offset + 8), uint32(offset + 12), Int(bytes[offset + 16]), Int(bytes[offset + 17]))
            }
            if type == "IEND" { break }
            offset += 12 + length
        }
        let (width, height, depth, colorType) = try XCTUnwrap(header, "IHDR がありません")
        return PNGInfo(width: width, height: height, bitDepth: depth, colorType: colorType, chunkTypes: chunkTypes)
    }

    func testAppIconSetIsASingle1024IOSIcon() throws {
        let contents = try SourceTree.json("\(appIconSet)/Contents.json")
        let images = try XCTUnwrap(contents["images"] as? [[String: Any]])
        XCTAssertEqual(images.count, 1, "iOS 17+ の単一サイズ(1024)。サイズ別の画像は持たない")
        let image = try XCTUnwrap(images.first)
        XCTAssertEqual(image["size"] as? String, "1024x1024")
        XCTAssertEqual(image["idiom"] as? String, "universal")
        XCTAssertEqual(image["platform"] as? String, "ios")
        let filename = try XCTUnwrap(image["filename"] as? String)
        XCTAssertFalse(try SourceTree.data("\(appIconSet)/\(filename)").isEmpty)
    }

    func testAppIconPNGIs1024SquareWithoutAnAlphaChannel() throws {
        let png = try readPNG(try SourceTree.data("\(appIconSet)/icon_1024.png"))
        XCTAssertEqual(png.width, 1024)
        XCTAssertEqual(png.height, 1024)
        XCTAssertEqual(png.bitDepth, 8)
        // カラータイプ 2 = RGB(アルファなし)。6 = RGBA・4 = グレー+アルファは App Store に弾かれる
        XCTAssertEqual(png.colorType, 2, "App Store のアイコンはアルファチャンネルなし(RGB)")
        XCTAssertFalse(png.chunkTypes.contains("tRNS"), "tRNS(透過指定)も不可")
    }

    func testAppIconIsTheSameAsTheSourceInAssetsIcon() throws {
        // 正本(assets/icon/icon_1024.png = v4 空色。D1)と、アプリが実際に同梱する画像が食い違わない
        let shipped = try SourceTree.data("\(appIconSet)/icon_1024.png")
        let source = try SourceTree.lienData("assets/icon/icon_1024.png")
        XCTAssertEqual(shipped, source, "AppIcon.appiconset/icon_1024.png は assets/icon/icon_1024.png のコピー")
    }

    // MARK: ExportOptions.plist

    func testExportOptionsUploadToAppStoreConnectWithAutomaticSigning() throws {
        let options = try SourceTree.plist("Config/ExportOptions.plist")
        XCTAssertEqual(options["method"] as? String, "app-store-connect")
        XCTAssertEqual(options["destination"] as? String, "upload", "書き出しと同時に App Store Connect へアップロード")
        XCTAssertEqual(options["signingStyle"] as? String, "automatic", "クラウド署名(ASC API キー)")
        XCTAssertEqual(
            options["manageAppVersionAndBuildNumber"] as? Bool, false,
            "ビルド番号は CI の run_number。Xcode に書き換えさせない"
        )
        XCTAssertEqual(options["uploadSymbols"] as? Bool, true)
        // チーム ID は lien-release が実行時に差し込む(コミットしない)
        XCTAssertEqual(options["teamID"] as? String, "REPLACE_WITH_APPLE_TEAM_ID")
    }

    // MARK: エンタイトルメント

    private let appGroupKey = "com.apple.security.application-groups"

    func testAppEntitlementsDeclareApsEnvironmentAndTheSharedAppGroup() throws {
        let entitlements = try SourceTree.plist("Lien/Lien.entitlements")
        // 配布(TestFlight / App Store)の書き出し時に Xcode が production へ差し替える。ソース側は development
        XCTAssertEqual(entitlements["aps-environment"] as? String, "development")
        XCTAssertEqual(entitlements[appGroupKey] as? [String], ["$(LIEN_APP_GROUP_ID)"])
    }

    func testExtensionsShareTheAppGroupButHaveNoPushEntitlement() throws {
        for path in ["LienWidget/LienWidget.entitlements", "LienNSE/LienNSE.entitlements"] {
            let entitlements = try SourceTree.plist(path)
            XCTAssertEqual(entitlements[appGroupKey] as? [String], ["$(LIEN_APP_GROUP_ID)"], path)
            XCTAssertNil(entitlements["aps-environment"], "\(path): push の登録はアプリ本体だけ")
        }
    }

    // MARK: ビルド設定

    func testMarketingVersionIsASemanticVersion() throws {
        let xcconfig = try SourceTree.text("Config/Base.xcconfig")
        let line = try XCTUnwrap(
            xcconfig.split(separator: "\n").first { $0.hasPrefix("MARKETING_VERSION") },
            "Base.xcconfig に MARKETING_VERSION がありません"
        )
        let value = line.split(separator: "=", maxSplits: 1).last?.trimmingCharacters(in: .whitespaces) ?? ""
        let pattern = try NSRegularExpression(pattern: #"^[0-9]+\.[0-9]+\.[0-9]+$"#)
        XCTAssertNotNil(
            pattern.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)),
            "MARKETING_VERSION は x.y.z 形式(現在: \(value))"
        )
    }
}
