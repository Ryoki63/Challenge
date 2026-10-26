// LienAvatarTests.swift — プロフィールのアイコン(タネの子のイラスト12種)の取り決め
//
// 検証すること:
//   1. id と並び順が assets/avatar/avatars.json(正本)と同じ。アセットカタログの imageset も、その12個ぴったり。
//      id はサーバー(users.avatar_emoji)に保存されるので、並べ替え・改名は止める(足すのは末尾だけ)
//   2. 読み上げの名前(displayName)が avatars.json の name_ja と同じ。ただし「サボテン」だけは Strings の禁止語
//      (「サボ」= サボる)に当たるので「カクタス」(理由は Strings.Avatar.cactus)
//   3. 12枚すべてがコンパイル済みのアセットカタログに実在し、色つきのベクターとして描ける
//      (空白にならない・単色のシルエットにならない・円の外は透明 = マスクが要らない)
//   4. サーバーに保存された値の読み替え: id はそのまま / 旧版の絵文字は近いイラスト / 対応が無いもの・空・知らない値は
//      既定の「ふたば」
//   5. 選ぶ画面(AvatarPicker)は、選ぶと輪が付いて見た目が変わる
//   6. アセットカタログはアプリ本体だけに入れる(ウィジェット・NSE は相手のアバターを描かない)
//
// 画面全体の見た目は UIReviewRenderTests で目で見る(ios/build/ui-review/ の avatar-picker.png・onboarding-filled.png・
// profile-edit*.png・settings-profile-row*.png。コミットしない)。

import SwiftUI
import UIKit
import XCTest
@testable import Lien

@MainActor
final class LienAvatarTests: XCTestCase {
    // MARK: 正本(avatars.json)

    private struct Entry {
        let id: String
        let nameJa: String
    }

    private func catalogEntries() throws -> [Entry] {
        let object = try JSONSerialization.jsonObject(with: try SourceTree.lienData("assets/avatar/avatars.json"))
        let rows = try XCTUnwrap(object as? [[String: String]], "avatars.json が {id, name_ja} の配列ではない")
        return try rows.map { row in
            Entry(
                id: try XCTUnwrap(row["id"], "avatars.json に id が無い行がある"),
                nameJa: try XCTUnwrap(row["name_ja"], "avatars.json に name_ja が無い行がある")
            )
        }
    }

    private func catalogDirectory() -> URL {
        SourceTree.lienRoot().appendingPathComponent("assets/avatar/AvatarAssets.xcassets", isDirectory: true)
    }

    // MARK: 1. id と並び順

    func testTheIdsAndTheOrderMatchAvatarsJson() throws {
        let entries = try catalogEntries()
        XCTAssertEqual(LienAvatar.allCases.map(\.rawValue), entries.map(\.id), "id と並び順は avatars.json(正本)と同じ")
        XCTAssertEqual(Set(LienAvatar.allCases.map(\.id)).count, LienAvatar.allCases.count, "id は重複しない")
        XCTAssertEqual(LienAvatar.allCases.map(\.assetName), entries.map { "avatar_\($0.id)" })
    }

    func testTheStoredIdsAreFrozen() {
        // サーバーに保存される値なので、並べ替え・改名はここで止める。新しいアバターは末尾に足す(その場合もこの12個は変えない)
        let frozen = [
            "sprout", "cactus", "star", "mushroom", "clover", "moon",
            "tulip", "sunflower", "acorn", "sakura", "strawberry", "drop",
        ]
        XCTAssertEqual(Array(LienAvatar.allCases.map(\.rawValue).prefix(frozen.count)), frozen)
        XCTAssertEqual(LienAvatar.defaultAvatar, .sprout, "初めて選ぶときの絵は先頭の「ふたば」")
        XCTAssertEqual(LienAvatar.defaultAvatar, LienAvatar.allCases.first)
    }

    func testTheAssetCatalogHasExactlyOneColorVectorImagesetPerAvatar() throws {
        let entries = try catalogEntries()
        let directory = catalogDirectory()
        let imagesets = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasSuffix(".imageset") }
            .sorted()
        XCTAssertEqual(imagesets, entries.map { "avatar_\($0.id).imageset" }.sorted(), "imageset が avatars.json と食い違う")

        for entry in entries {
            let imageset = directory.appendingPathComponent("avatar_\(entry.id).imageset", isDirectory: true)
            let data = try Data(contentsOf: imageset.appendingPathComponent("Contents.json"))
            let contents = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            let properties = try XCTUnwrap(contents["properties"] as? [String: Any], "\(entry.id): properties が無い")
            // original でないと、アクセント色の単色に塗りつぶされる。ベクターのままでないと、大きく出したときにぼやける
            XCTAssertEqual(properties["template-rendering-intent"] as? String, "original", "\(entry.id): 色つきのまま描く設定ではない")
            XCTAssertEqual(properties["preserves-vector-representation"] as? Bool, true, "\(entry.id): ベクターのまま保持する設定ではない")
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: imageset.appendingPathComponent("avatar_\(entry.id).svg").path),
                "\(entry.id): SVG が imageset に無い"
            )
        }
    }

    // MARK: 2. 読み上げの名前

    func testDisplayNamesMatchAvatarsJsonExceptTheOneTheStringsLintRejects() throws {
        let entries = try catalogEntries()
        XCTAssertEqual(entries.count, LienAvatar.allCases.count)
        for (avatar, entry) in zip(LienAvatar.allCases, entries) {
            XCTAssertFalse(avatar.displayName.isEmpty, "\(avatar.rawValue) の名前が空")
            if avatar == .cactus {
                // avatars.json は「サボテン」だが、Strings の禁止語(「サボ」= サボる。責める言葉を避ける)に当たるので「カクタス」にしてある
                XCTAssertEqual(entry.nameJa, "サボテン", "avatars.json の cactus の名前が変わった。読み上げの名前を見直す")
                XCTAssertEqual(avatar.displayName, "カクタス")
            } else {
                XCTAssertEqual(avatar.displayName, entry.nameJa, "\(avatar.rawValue) の名前が avatars.json と違う")
            }
        }
        XCTAssertEqual(
            Set(LienAvatar.allCases.map(\.displayName)).count,
            LienAvatar.allCases.count,
            "読み上げの名前が重なっていると、VoiceOver で聞き分けられない"
        )
    }

    // MARK: 3. 描画

    func testEveryAvatarExistsInTheCompiledCatalogAsASquare() throws {
        for avatar in LienAvatar.allCases {
            let image = try XCTUnwrap(UIImage(named: avatar.assetName), "\(avatar.assetName) がアセットカタログに無い")
            XCTAssertEqual(image.size.width, image.size.height, accuracy: 0.001, "\(avatar.assetName) が正方形ではない: \(image.size)")
        }
    }

    func testEveryAvatarRendersAsAColorIllustrationInsideATransparentCircle() throws {
        let side = 120
        for avatar in LienAvatar.allCases {
            let renderer = ImageRenderer(content: AvatarImage(avatar: avatar, size: CGFloat(side)))
            renderer.scale = 1
            let image = try XCTUnwrap(renderer.uiImage, "\(avatar.rawValue) を描けない")
            let pixels = try XCTUnwrap(Pixels(image), "\(avatar.rawValue) の画素を取り出せない")
            XCTAssertEqual(pixels.width, side)
            XCTAssertEqual(pixels.height, side)

            // 円の外(四隅)は透明 = アプリ側でマスクしなくてよい。円の中心は塗られている
            for (x, y) in [(1, 1), (side - 2, 1), (1, side - 2), (side - 2, side - 2)] {
                XCTAssertEqual(pixels.alpha(x, y), 0, "\(avatar.rawValue): 四隅(\(x), \(y))が透明ではない")
            }
            XCTAssertGreaterThan(pixels.alpha(side / 2, side / 2), 240, "\(avatar.rawValue): 中心が塗られていない")

            // 円の面積(π × 60² ≒ 11,300)ほどが塗られている。空白(SVG が描けていない)でも、四角いままでもない
            let painted = pixels.paintedCount
            XCTAssertGreaterThan(painted, 9_500, "\(avatar.rawValue) が空白に近い(SVG が iOS で描けていない?): \(painted)")
            XCTAssertLessThan(painted, 12_500, "\(avatar.rawValue) が円より広く塗られている: \(painted)")

            // 色つきのイラスト。テンプレート描画になっていると、1色のシルエットになる
            XCTAssertGreaterThan(pixels.distinctColorCount, 12, "\(avatar.rawValue) が単色に近い(テンプレート描画になっていない?)")
        }
    }

    // MARK: 4. 保存された値の読み替え

    func testStoredIdsResolveToThemselves() {
        for avatar in LienAvatar.allCases {
            XCTAssertEqual(LienAvatar(stored: avatar.rawValue), avatar)
            XCTAssertEqual(LienAvatar.resolve(avatar.rawValue), avatar)
        }
    }

    /// 旧版のパレット(絵文字24種)。イラストに替わる前の版がサーバーの avatar_emoji に保存した値の、全種類。
    /// ⭐️ と ☕️ は異体字セレクタ(U+FE0F)つきで保存されていた
    private let legacyPalette = [
        "🌱", "🌷", "🌻", "🍀", "🐶", "🐱", "🐰", "🐻",
        "🐼", "🦊", "🐧", "🐥", "🍎", "🍓", "🍵", "🌙",
        "\u{2B50}\u{FE0F}", "🎵", "📚", "🏃", "💪", "🧸", "\u{2615}\u{FE0F}", "💛",
    ]

    /// 近いイラストがある旧版の絵文字
    private var legacyMapped: [String: LienAvatar] {
        [
            "🌱": .sprout,
            "🌷": .tulip,
            "🌻": .sunflower,
            "🍀": .clover,
            "\u{2B50}\u{FE0F}": .star,
            "🌙": .moon,
            "🍓": .strawberry,
        ]
    }

    func testLegacyEmojiResolveToTheClosestIllustration() {
        XCTAssertEqual(legacyPalette.count, 24)
        XCTAssertEqual(Set(legacyPalette).count, 24)
        for emoji in legacyPalette {
            if let expected = legacyMapped[emoji] {
                XCTAssertEqual(LienAvatar(stored: emoji), expected, "\(emoji) は \(expected.rawValue) として読む")
                XCTAssertEqual(LienAvatar.resolve(emoji), expected)
            } else {
                // 動物・食べ物・物など、近いイラストが無いもの → 既定の「ふたば」で表示する(読み替えるだけで、保存はしない)
                XCTAssertNil(LienAvatar(stored: emoji), "\(emoji) には近いイラストが無い")
                XCTAssertEqual(LienAvatar.resolve(emoji), .defaultAvatar)
            }
        }
        XCTAssertEqual(legacyMapped.count, 7, "近いイラストがある旧版の絵文字は7種")
    }

    func testTheStarEmojiResolvesWithAndWithoutTheVariationSelector() {
        // ⭐ は U+2B50。旧パレットの ⭐️ は U+2B50 + U+FE0F。どちらで保存されていても「ほし」
        XCTAssertEqual(LienAvatar(stored: "\u{2B50}"), .star)
        XCTAssertEqual(LienAvatar(stored: "\u{2B50}\u{FE0F}"), .star)
        XCTAssertEqual(LienAvatar(stored: "🌱\u{FE0F}"), .sprout, "他の絵文字でも、異体字セレクタの有無で結果が変わらない")
    }

    func testUnreadableStoredValuesFallBackToTheDefaultAvatar() {
        // 空(オンボーディング前や未取得)・知らない値(E2E の目印 🧪、別の版が入れた値)・大文字小文字違いの id・空白つきの id
        for stored in ["", " ", "🧪", "unknown", "SPROUT", "Sprout", " sprout", "sprout ", "avatar_sprout"] {
            XCTAssertNil(LienAvatar(stored: stored), "「\(stored)」は読み替えない")
            XCTAssertEqual(LienAvatar.resolve(stored), .defaultAvatar, "「\(stored)」は既定の絵で表示する")
        }
    }

    // MARK: 5. 選ぶ画面

    private func renderPicker(selection: LienAvatar, width: CGFloat) throws -> Pixels {
        let view = AvatarPicker(selection: .constant(selection))
            .frame(width: width, height: 320, alignment: .top)
            .background(Color.white)
            .environment(\.colorScheme, .light)
            .tint(LienColors.accent)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 1
        let image = try XCTUnwrap(renderer.uiImage, "AvatarPicker を描けない")
        return try XCTUnwrap(Pixels(image), "AvatarPicker の画素を取り出せない")
    }

    func testThePickerDrawsAllTwelveAvatarsAndSelectingOneChangesTheLook() throws {
        let first = try renderPicker(selection: .sprout, width: 340)
        let second = try renderPicker(selection: .drop, width: 340)
        XCTAssertEqual(first.width, second.width)
        XCTAssertEqual(first.height, second.height)

        // 12枚が並んでいる = 絵が塗られた面積が、1枚(≒ 11,300 × (60/120)² ≒ 2,800 @ 60pt)の12倍ほどある
        let perAvatar = 2_000
        XCTAssertGreaterThan(first.paintedCount, perAvatar * 12, "12枚が並んでいない(描かれていない絵がある?)")

        // 選ぶ絵が替わると、輪とチェックの位置が替わって、画素が変わる(輪は絵1枚の周りを1周するので、数百画素にはなる)
        XCTAssertGreaterThan(first.differingPixelCount(from: second), 400, "選んだ絵に輪が付いていない(選択が見た目に出ていない?)")
    }

    // MARK: 6. ターゲット

    func testTheAvatarCatalogIsInTheAppTargetOnly() throws {
        let yml = try SourceTree.text("project.yml")
        let path = "../assets/avatar/AvatarAssets.xcassets"
        let appBlock = try XCTUnwrap(yml.components(separatedBy: "\n  LienWidget:").first, "project.yml に LienWidget が無い")
        XCTAssertTrue(appBlock.contains(path), "Lien の sources に \(path) が無い(選ぶ画面・設定の行で描く)")
        let rest = String(yml.dropFirst(appBlock.count))
        XCTAssertFalse(rest.contains(path), "ウィジェット・NSE・テストに入れていない(相手のアバターは描かない)はず")
    }
}

// MARK: - 描画の道具

private struct Pixels {
    let width: Int
    let height: Int
    private let bytes: [UInt8]

    /// 画像の画素を RGBA8(premultiplied)で取り出す
    init?(_ image: UIImage) {
        guard let cg = image.cgImage else { return nil }
        let width = cg.width
        let height = cg.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let drawn: Bool = bytes.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        self.width = width
        self.height = height
        self.bytes = bytes
    }

    func alpha(_ x: Int, _ y: Int) -> UInt8 {
        bytes[(y * width + x) * 4 + 3]
    }

    /// 透明でない(アルファが 16 より大きい)画素の数
    var paintedCount: Int {
        var count = 0
        var index = 3
        while index < bytes.count {
            if bytes[index] > 16 { count += 1 }
            index += 4
        }
        return count
    }

    /// 不透明な画素の色を、各チャンネル 4bit に丸めたときの色の種類の数(単色のシルエットなら 1〜2)
    var distinctColorCount: Int {
        var seen = Set<Int>()
        var index = 0
        while index < bytes.count {
            if bytes[index + 3] >= 250 {
                let red = Int(bytes[index] >> 4)
                let green = Int(bytes[index + 1] >> 4)
                let blue = Int(bytes[index + 2] >> 4)
                seen.insert((red << 8) | (green << 4) | blue)
            }
            index += 4
        }
        return seen.count
    }

    /// もう1枚(同じ大きさ)と比べて、色が目に見えて違う画素の数
    func differingPixelCount(from other: Pixels) -> Int {
        guard width == other.width, height == other.height else { return Int.max }
        var count = 0
        var index = 0
        while index < bytes.count {
            let difference = abs(Int(bytes[index]) - Int(other.bytes[index]))
                + abs(Int(bytes[index + 1]) - Int(other.bytes[index + 1]))
                + abs(Int(bytes[index + 2]) - Int(other.bytes[index + 2]))
            if difference > 48 { count += 1 }
            index += 4
        }
        return count
    }
}
