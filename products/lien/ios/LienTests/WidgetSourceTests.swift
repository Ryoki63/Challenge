// WidgetSourceTests.swift — ウィジェットの作りを、ソースで固定するテスト(issue #17 T17a)
//
// LienWidget ターゲット(WidgetKit の拡張)は、LienTests からは直接呼べない。そこで、見た目と判断は Lien/Core/Widget/(アプリ本体とソース共有)に
// 置いて単体テストと一覧画像で確かめ、WidgetKit との接ぎ手(LienWidget/)の約束は、ここでソースを読んで確かめる:
//   - v1.0 のファミリーは4つ(ホーム S・M、ロック画面の円形・インライン)
//   - 植物は必ず imageStyle: .widgetFullColor で描く(iOS 18 の「色合い(accented)」表示で単色にならないように)
//   - 共有するファイルが依存してよいフレームワーク(WidgetKit のファミリーは持ち込まない)
//   - ユーザー向けの文言は Strings に置く(ウィジェットのソースに日本語の文言を書かない — DESIGN §3.8)
//   - ウィジェットは自分では reload しない(reload のトリガーは NSE とアプリ本体だけ — DESIGN §3.5)
// ソースを読むだけなので、macOS の下見(scripts/macos-check)でも走る。

import XCTest
@testable import Lien

final class WidgetSourceTests: XCTestCase {
    // MARK: - 道具

    /// コメントを除いたソース(`//` から行末・`/* … */`)。文字列リテラルの中の `//` は、このテストの対象のソースには無い(URL なし)
    private func code(_ path: String) throws -> String {
        var text = try SourceTree.text(path)
        text = text.replacingOccurrences(of: #"/\*[\s\S]*?\*/"#, with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: #"//[^\n]*"#, with: "", options: .regularExpression)
        return text
    }

    private func imports(_ path: String) throws -> Set<String> {
        let source = try SourceTree.text(path)
        return Set(source.split(separator: "\n").compactMap { line -> String? in
            let parts = line.split(separator: " ")
            return parts.count == 2 && parts[0] == "import" ? String(parts[1]) : nil
        })
    }

    private let sharedDirectory = "Lien/Core/Widget"
    private let viewsDirectory = "Lien/Core/Widget/Views"

    // MARK: - ファミリー

    func testAllWidgetFamiliesShareTheHomeDeepLink() throws {
        let source = try code("LienWidget/LienWidgetEntryView.swift")
        XCTAssertTrue(source.contains("Group {"))
        XCTAssertTrue(source.contains(".widgetURL(WidgetHomeLink.url)"))
        XCTAssertEqual(source.components(separatedBy: ".widgetURL(").count - 1, 1)
        XCTAssertTrue(source.contains("}\n        .widgetURL(WidgetHomeLink.url)"))
        XCTAssertEqual(WidgetHomeLink.url.absoluteString, "lien://home")
        XCTAssertNil(DeepLinkHandler.inviteToken(from: WidgetHomeLink.url))
    }

    func testRootViewForwardsURLsToTheAppModel() throws {
        let source = try code("Lien/App/RootView.swift")
        XCTAssertTrue(source.contains(".onOpenURL { url in"))
        XCTAssertTrue(source.contains("model.handleDeepLink(url)"))
    }

    func testTheWidgetSupportsExactlyTheFourV10Families() throws {
        let source = try code("LienWidget/LienWidgetBundle.swift")
        let block = try XCTUnwrap(
            source.range(of: #"static let supportedFamilies: \[WidgetFamily\] = \[[^\]]*\]"#, options: .regularExpression)
                .map { String(source[$0]) },
            "supportedFamilies が見つからない"
        )
        let families = Set(block.components(separatedBy: ".").dropFirst().map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " ,\n]")) })
        XCTAssertEqual(
            families, ["systemSmall", "systemMedium", "accessoryCircular", "accessoryInline"],
            "v1.0: ホーム S・M(写真は v1.0.1)とロック画面の円形・インライン(REQUIREMENTS §3.10)"
        )
        XCTAssertTrue(source.contains(".supportedFamilies(Self.supportedFamilies)"), "ウィジェットの設定が supportedFamilies を使う")
    }

    func testEveryFamilyMapsToItsOwnLayout() throws {
        let source = try code("LienWidget/LienWidgetEntryView.swift")
        for (family, layout) in [("systemMedium", "medium"), ("accessoryCircular", "lockCircular"), ("accessoryInline", "lockInline")] {
            XCTAssertTrue(
                source.range(of: "case \\.\(family):\\s*self = \\.\(layout)\\b", options: .regularExpression) != nil,
                "\(family) → \(layout) の対応が無い"
            )
        }
        XCTAssertTrue(
            source.range(of: #"default:\s*self = \.small\b"#, options: .regularExpression) != nil,
            "ホーム S(と想定外のファミリー)は small"
        )
    }

    // MARK: - 色合い(accented)表示

    func testTheWidgetDrawsThePlantWithTheFullColorStyle() throws {
        let entry = try code("LienWidget/LienWidgetEntryView.swift")
        XCTAssertTrue(entry.contains("imageStyle: .widgetFullColor"), "ウィジェットは WidgetRootView に imageStyle: .widgetFullColor を渡す")
    }

    func testEveryPlantAndImageInTheWidgetViewsKeepsFullColor() throws {
        for path in try SourceTree.swiftFiles(under: viewsDirectory) {
            let source = try code(path)
            // PlantCharacterView(...) は、すべて imageStyle を受け取る(同じ文の中で渡している)
            var searchStart = source.startIndex
            while let range = source.range(of: "PlantCharacterView(", range: searchStart..<source.endIndex) {
                let window = String(source[range.upperBound...].prefix(160))
                XCTAssertTrue(
                    window.contains("imageStyle: imageStyle"),
                    "\(path): PlantCharacterView(...) に imageStyle が渡っていない(色合い表示で単色になる)"
                )
                searchStart = range.upperBound
            }
            // ビューが直接 Image を作るときは、すべて WidgetImageStyle.fullColor を通す(定義の WidgetAccent.swift は除く)。
            // 植物のレイヤー(アセット)も、完了のチェック(SF Symbols)も同じ
            if !path.hasSuffix("/WidgetAccent.swift") {
                let created = source.components(separatedBy: "Image(").count - 1
                let wrapped = source.components(separatedBy: "WidgetImageStyle.fullColor(Image(").count - 1
                let wrappedAcrossLines = source.components(separatedBy: "WidgetImageStyle.fullColor(\n").count - 1
                XCTAssertEqual(
                    created, wrapped + wrappedAcrossLines,
                    "\(path): Image(...) \(created) 個のうち、WidgetImageStyle.fullColor を通しているのは \(wrapped + wrappedAcrossLines) 個(色合い表示で単色になる)"
                )
            }
        }
        let accent = try code("\(viewsDirectory)/WidgetAccent.swift")
        XCTAssertTrue(accent.contains("widgetAccentedRenderingMode(.fullColor)"))
        XCTAssertTrue(accent.contains("#available(iOS 18.0"), "iOS 18 より前では何もしない(最小は iOS 17)")
    }

    func testPlantCharacterViewDoesNotDependOnWidgetKit() throws {
        // シェア画像・アプリ本体でも使うので、WidgetKit の API は持ち込まない(装飾は PlantImageStyle として外から渡す)
        XCTAssertEqual(try imports("Lien/Core/DesignSystem/PlantCharacterView.swift"), ["SwiftUI"])
        let source = try code("Lien/Core/DesignSystem/PlantCharacterView.swift")
        XCTAssertFalse(source.contains("widgetAccented"))
        XCTAssertTrue(source.contains("imageStyle.apply("), "各レイヤーの Image が imageStyle を通る")
    }

    // MARK: - 共有するファイルの依存

    func testTheSharedLogicFilesOnlyDependOnFoundation() throws {
        for path in ["WidgetContent.swift", "WidgetTimelinePlan.swift", "WidgetMetrics.swift"] {
            XCTAssertEqual(try imports("\(sharedDirectory)/\(path)"), ["Foundation"], "\(path)(純粋関数。macOS の下見でも走る)")
        }
    }

    func testTheSharedViewFilesOnlyUseSwiftUIAndWidgetKit() throws {
        let files = try SourceTree.swiftFiles(under: viewsDirectory)
        XCTAssertGreaterThanOrEqual(files.count, 6, "ビューのファイルが読めていない: \(files)")
        for path in files {
            let found = try imports(path)
            XCTAssertTrue(found.isSubset(of: ["SwiftUI", "WidgetKit"]), "\(path) の import: \(found)")
            XCTAssertTrue(found.contains("SwiftUI"), path)
        }
    }

    func testTheSharedFilesDoNotKnowWidgetKitFamiliesOrTheEnvironment() throws {
        // accessory 系の WidgetFamily は macOS の SDK に無く(下見の型検査が通らない)、テストの一覧画像も描けなくなる。
        // ファミリーは LienWidget(接ぎ手)だけが知り、共有の側は WidgetLayout を受け取る
        var paths = try SourceTree.swiftFiles(under: sharedDirectory)
        paths.append("Lien/Core/DesignSystem/PlantCharacterView.swift")
        for path in paths {
            let source = try code(path)
            XCTAssertFalse(source.contains("WidgetFamily"), "\(path) が WidgetFamily を使っている")
            XCTAssertFalse(source.contains("widgetFamily"), "\(path) が widgetFamily を読んでいる(一覧画像で描けなくなる)")
            XCTAssertFalse(source.contains("accessoryCircular"), path)
        }
    }

    // MARK: - 文言

    func testTheWidgetSourcesHaveNoJapaneseUserFacingText() throws {
        // ユーザー向け文言は Strings.swift(DESIGN §3.8)。ウィジェットのソースに日本語の文字列リテラルを書かない
        // (絵文字・SF Symbols の名前・アセット名は文言ではない)
        var paths = try SourceTree.swiftFiles(under: sharedDirectory)
        paths += try SourceTree.swiftFiles(under: "LienWidget")
        XCTAssertGreaterThanOrEqual(paths.count, 10)
        for path in paths {
            var source = try code(path)
            // ギャラリーの見本(placeholder / preview)の snapshot は、画面に出る見本のデータ。文言ではない
            if path == "LienWidget/LienWidgetBundle.swift", let sample = source.range(of: #"static (let|var) widgetSample"#, options: .regularExpression) {
                source = String(source[..<sample.lowerBound])
            }
            // 「・」は、約束の絵文字が無いときの占位の点(文言ではない。ホームの TodayChip と同じ)
            let literals = source.matches(of: #""[^"\n]*""#).filter { $0 != "\"・\"" }
            for literal in literals {
                XCTAssertNil(
                    literal.range(of: #"[\u3040-\u30FF\u3400-\u9FFF\uFF00-\uFFEF]"#, options: .regularExpression),
                    "\(path): 日本語の文言をソースに直書きしている(Strings.swift に置く): \(literal)"
                )
            }
        }
    }

    // MARK: - reload・書き込み

    func testTheWidgetNeverReloadsOrWritesByItself() throws {
        // reload のトリガーは NSE とアプリ本体だけ(WidgetKit の reload 予算 — DESIGN §3.5)。ウィジェットは読み取り専用(§3.4)
        var paths = try SourceTree.swiftFiles(under: sharedDirectory)
        paths += try SourceTree.swiftFiles(under: "LienWidget")
        for path in paths {
            let source = try code(path)
            XCTAssertFalse(source.contains("reloadAllTimelines"), "\(path)")
            XCTAssertFalse(source.contains("reloadTimelines"), "\(path)")
            XCTAssertFalse(source.contains("saveSnapshot"), "\(path)")
            XCTAssertFalse(source.contains("eraseAll"), "\(path)")
            XCTAssertFalse(source.contains("URLSession"), "\(path): ウィジェットはネットワークに出ない(App Group の読み取りだけ)")
        }
    }

    func testTheTimelineIsTwoEntriesWithAtEndPolicy() throws {
        let source = try code("LienWidget/LienWidgetBundle.swift")
        XCTAssertTrue(source.contains("WidgetTimelinePlan.steps("), "タイムラインは WidgetTimelinePlan(今と翌日 0:00)で作る")
        XCTAssertTrue(source.contains("policy: .atEnd"), "DESIGN §3.5: policy は .atEnd")
    }

    func testTheWidgetRetriesShortlyWhileTheSnapshotIsLockedByDataProtection() throws {
        // 再起動後の最初のアンロックの前は、App Group のファイルが読めない。そのとき「はじめよう」を翌日 0:00 まで出しつづけない
        let source = try code("LienWidget/LienWidgetBundle.swift")
        XCTAssertTrue(source.contains("snapshotFileIsLocked()"), "読めない間かどうかを AppGroupStore で見る")
        XCTAssertTrue(source.contains("WidgetTimelinePlan.lockedRetryInterval"), "読み直しの間隔は計画の定数")
        XCTAssertTrue(source.contains("policy: .after("), "読めない間だけ、短く読み直す")
        XCTAssertGreaterThanOrEqual(WidgetTimelinePlan.lockedRetryInterval, 60, "短すぎると reload の予算を使い果たす")
        XCTAssertLessThanOrEqual(WidgetTimelinePlan.lockedRetryInterval, 600, "長すぎると、アンロックしたあとも「はじめよう」が残る")
    }

    func testTheGallerySampleIsBuiltFreshEveryTime() throws {
        // ギャラリーの見本は、updatedAt が今であること(前の日の snapshot として、見本の完了を戻されない)
        let source = try code("LienWidget/LienWidgetBundle.swift")
        XCTAssertTrue(source.contains("static var widgetSample: PairSnapshot {"), "見本は計算プロパティ(呼ぶたびに now)")
        XCTAssertTrue(source.contains("updatedAt: .now"))
    }
}

private extension String {
    /// 正規表現に一致する部分をすべて返す
    func matches(of pattern: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        return regex.matches(in: self, range: NSRange(startIndex..., in: self)).compactMap { match in
            Range(match.range, in: self).map { String(self[$0]) }
        }
    }
}
