// PrivacyManifestTests.swift — PrivacyInfo.xcprivacy(アプリ・ウィジェット・NSE)の整合性(issue #28)
//
// App Store Connect は、必須理由 API(UserDefaults・ファイルのタイムスタンプなど)を使うバイナリに、
// 宣言(NSPrivacyAccessedAPITypes)が無いとアップロードを弾く(ITMS-91053)。ここでは
//   1. 各マニフェストの形(トラッキングなし・収集データの用途・理由コードの語彙)
//   2. 各ターゲットの Swift ソースが使っている必須理由 API が、そのターゲットのマニフェストで宣言済みであること
// を検査する。2 は、API を使うコードを足したのに宣言を忘れる事故を CI で止めるためのもの。
//
// 依存パッケージ(supabase-swift など)が使う API は、このソース走査には含まれない。
// それは lien-release の dry-run が archive の中身から棚卸しする(ios/scripts/scan_required_reason_apis.py)。
//
// 分析 SDK を入れない(REQUIREMENTS §7 / D6)ので、収集データの用途に分析・広告があってはならない。

import Foundation
import XCTest

final class PrivacyManifestTests: XCTestCase {
    // MARK: 語彙(Apple の「Describing use of required reason API」)

    private enum Category {
        static let userDefaults = "NSPrivacyAccessedAPICategoryUserDefaults"
        static let fileTimestamp = "NSPrivacyAccessedAPICategoryFileTimestamp"
        static let systemBootTime = "NSPrivacyAccessedAPICategorySystemBootTime"
        static let diskSpace = "NSPrivacyAccessedAPICategoryDiskSpace"
        static let activeKeyboards = "NSPrivacyAccessedAPICategoryActiveKeyboards"
    }

    /// カテゴリごとの、承認された理由コード
    private static let allowedReasons: [String: Set<String>] = [
        Category.userDefaults: ["CA92.1", "1C8F.1", "C56D.1", "AC6B.1"],
        Category.fileTimestamp: ["DDA9.1", "C617.1", "3B52.1", "0A2A.1"],
        Category.systemBootTime: ["35F9.1", "8FFB.1", "3D61.1"],
        Category.diskSpace: ["85F4.1", "E174.1", "7D9E.1", "B728.1"],
        Category.activeKeyboards: ["3EC4.1", "54BD.1"],
    ]

    /// カテゴリごとの、ソース上でその API を使っている印(正規表現)
    private static let usagePatterns: [String: [String]] = [
        Category.userDefaults: [
            #"\bUserDefaults\b"#, #"\bNSUserDefaults\b"#, #"@AppStorage\b"#, #"@SceneStorage\b"#,
        ],
        Category.fileTimestamp: [
            #"\bcreationDate\b"#, #"\bmodificationDate\b"#, #"\bfileModificationDate\b"#, #"\bfileCreationDate\b"#,
            #"\bcontentModificationDateKey\b"#, #"\bcreationDateKey\b"#,
            #"\bNSFileCreationDate\b"#, #"\bNSFileModificationDate\b"#,
            #"\battributesOfItem\b"#, #"\b[fl]?stat\("#, #"\bgetattrlist"#,
        ],
        Category.systemBootTime: [#"\bsystemUptime\b"#, #"\bmach_absolute_time\b"#],
        Category.diskSpace: [
            #"\bvolumeAvailableCapacity"#, #"\bvolumeTotalCapacity"#, #"\bsystemFreeSize\b"#, #"\bsystemSize\b"#,
            #"\bNSFileSystemFreeSize\b"#, #"\bNSFileSystemSize\b"#, #"\bstatv?fs\("#,
        ],
        Category.activeKeyboards: [#"\bactiveInputModes\b"#],
    ]

    private static let allowedCollectedTypes: Set<String> = [
        "NSPrivacyCollectedDataTypeName", "NSPrivacyCollectedDataTypeEmailAddress",
        "NSPrivacyCollectedDataTypePhoneNumber", "NSPrivacyCollectedDataTypePhysicalAddress",
        "NSPrivacyCollectedDataTypeOtherUserContactInfo", "NSPrivacyCollectedDataTypeHealth",
        "NSPrivacyCollectedDataTypeFitness", "NSPrivacyCollectedDataTypePaymentInfo",
        "NSPrivacyCollectedDataTypeCreditInfo", "NSPrivacyCollectedDataTypeOtherFinancialInfo",
        "NSPrivacyCollectedDataTypePreciseLocation", "NSPrivacyCollectedDataTypeCoarseLocation",
        "NSPrivacyCollectedDataTypeSensitiveInfo", "NSPrivacyCollectedDataTypeContacts",
        "NSPrivacyCollectedDataTypeEmailsOrTextMessages", "NSPrivacyCollectedDataTypePhotosorVideos",
        "NSPrivacyCollectedDataTypeAudioData", "NSPrivacyCollectedDataTypeGameplayContent",
        "NSPrivacyCollectedDataTypeCustomerSupport", "NSPrivacyCollectedDataTypeOtherUserContent",
        "NSPrivacyCollectedDataTypeBrowsingHistory", "NSPrivacyCollectedDataTypeSearchHistory",
        "NSPrivacyCollectedDataTypeUserID", "NSPrivacyCollectedDataTypeDeviceID",
        "NSPrivacyCollectedDataTypePurchaseHistory", "NSPrivacyCollectedDataTypeProductInteraction",
        "NSPrivacyCollectedDataTypeAdvertisingData", "NSPrivacyCollectedDataTypeOtherUsageData",
        "NSPrivacyCollectedDataTypeCrashData", "NSPrivacyCollectedDataTypePerformanceData",
        "NSPrivacyCollectedDataTypeOtherDiagnosticData", "NSPrivacyCollectedDataTypeEnvironmentScanning",
        "NSPrivacyCollectedDataTypeHands", "NSPrivacyCollectedDataTypeHead",
        "NSPrivacyCollectedDataTypeOtherDataTypes",
    ]

    /// 本アプリの収集データの用途は「アプリの機能」だけ(分析・広告・パーソナライズなし)
    private static let appFunctionality = "NSPrivacyCollectedDataTypePurposeAppFunctionality"

    // MARK: ターゲットとマニフェスト・ソースの対応(project.yml の sources と同じ)

    private struct BundleSpec {
        let name: String
        let manifest: String
        /// ios/ からの相対ディレクトリ(再帰)
        let directories: [String]
        /// ソース共有している個別ファイル(ios/ からの相対パス)
        let sharedFiles: [String]
    }

    private static let bundles: [BundleSpec] = [
        BundleSpec(
            name: "Lien",
            manifest: "Lien/PrivacyInfo.xcprivacy",
            directories: ["Lien"],
            sharedFiles: []
        ),
        BundleSpec(
            name: "LienWidget",
            manifest: "LienWidget/PrivacyInfo.xcprivacy",
            directories: ["LienWidget"],
            sharedFiles: [
                "Lien/Core/Models/PairSnapshot.swift",
                "Lien/Core/AppGroupStore.swift",
                "Lien/Core/Strings.swift",
            ]
        ),
        BundleSpec(
            name: "LienNSE",
            manifest: "LienNSE/PrivacyInfo.xcprivacy",
            directories: ["LienNSE"],
            sharedFiles: [
                "Lien/Core/Models/PairSnapshot.swift",
                "Lien/Core/AppGroupStore.swift",
            ]
        ),
    ]

    // MARK: 1. マニフェストの形

    func testEveryManifestDeclaresNoTracking() throws {
        for bundle in Self.bundles {
            let manifest = try SourceTree.plist(bundle.manifest)
            XCTAssertEqual(manifest["NSPrivacyTracking"] as? Bool, false, "\(bundle.name): トラッキングなし(ATT を使わない)")
            XCTAssertEqual(
                (manifest["NSPrivacyTrackingDomains"] as? [Any])?.count, 0,
                "\(bundle.name): トラッキングドメインなし"
            )
            XCTAssertNotNil(manifest["NSPrivacyCollectedDataTypes"] as? [Any], "\(bundle.name): 収集データの配列がある(空でも必須)")
            XCTAssertNotNil(manifest["NSPrivacyAccessedAPITypes"] as? [Any], "\(bundle.name): 必須理由 API の配列がある(空でも必須)")
        }
    }

    func testCollectedDataIsLimitedToAppFunctionalityAndNeverTracks() throws {
        for bundle in Self.bundles {
            let manifest = try SourceTree.plist(bundle.manifest)
            let entries = try XCTUnwrap(manifest["NSPrivacyCollectedDataTypes"] as? [[String: Any]], bundle.name)
            var seenTypes = Set<String>()
            for entry in entries {
                let type = try XCTUnwrap(entry["NSPrivacyCollectedDataType"] as? String, bundle.name)
                XCTAssertTrue(Self.allowedCollectedTypes.contains(type), "\(bundle.name): 未知のデータ種別 \(type)")
                XCTAssertTrue(seenTypes.insert(type).inserted, "\(bundle.name): \(type) が重複")
                XCTAssertNotNil(entry["NSPrivacyCollectedDataTypeLinked"] as? Bool, "\(bundle.name): \(type) の Linked")
                XCTAssertEqual(entry["NSPrivacyCollectedDataTypeTracking"] as? Bool, false, "\(bundle.name): \(type) はトラッキングに使わない")
                XCTAssertEqual(
                    entry["NSPrivacyCollectedDataTypePurposes"] as? [String], [Self.appFunctionality],
                    "\(bundle.name): \(type) の用途はアプリの機能のみ(分析 SDK なし — D6)"
                )
            }
        }
    }

    func testAppDeclaresTheV10CollectedData() throws {
        // review-notes §2.1 の収集データ(ニックネーム・写真・約束や記録・匿名ユーザー ID・プッシュトークン)
        let manifest = try SourceTree.plist("Lien/PrivacyInfo.xcprivacy")
        let entries = try XCTUnwrap(manifest["NSPrivacyCollectedDataTypes"] as? [[String: Any]])
        let types = Set(entries.compactMap { $0["NSPrivacyCollectedDataType"] as? String })
        XCTAssertEqual(types, [
            "NSPrivacyCollectedDataTypeName",
            "NSPrivacyCollectedDataTypePhotosorVideos",
            "NSPrivacyCollectedDataTypeOtherUserContent",
            "NSPrivacyCollectedDataTypeUserID",
            "NSPrivacyCollectedDataTypeDeviceID",
        ])
    }

    func testAccessedAPIReasonsAreApprovedCodes() throws {
        for bundle in Self.bundles {
            for (category, reasons) in try declaredAPIs(of: bundle) {
                let allowed = try XCTUnwrap(Self.allowedReasons[category], "\(bundle.name): 未知のカテゴリ \(category)")
                XCTAssertFalse(reasons.isEmpty, "\(bundle.name): \(category) の理由が空")
                for reason in reasons {
                    XCTAssertTrue(allowed.contains(reason), "\(bundle.name): \(category) に承認されていない理由 \(reason)")
                }
            }
        }
    }

    // MARK: 2. ソースが使っている必須理由 API は、宣言されている

    func testEveryRequiredReasonAPIUsedInSourceIsDeclared() throws {
        for bundle in Self.bundles {
            let declared = Set(try declaredAPIs(of: bundle).keys)
            let used = try usedAPIs(of: bundle)
            for (category, hits) in used.sorted(by: { $0.key < $1.key }) {
                XCTAssertTrue(
                    declared.contains(category),
                    "\(bundle.name): \(category) を使っているのに \(bundle.manifest) で宣言していません(\(hits.sorted().joined(separator: ", ")))"
                )
            }
        }
    }

    func testTheSourceScanSeesTheKnownUserDefaultsUse() throws {
        // 走査が空振りして「使っていない」で通る事故の防止: PushTokenSync の UserDefaults 実装が拾えていること
        let used = try usedAPIs(of: Self.bundles[0])
        let hits = try XCTUnwrap(used[Category.userDefaults], "Lien のソース走査が UserDefaults の使用を拾えていません")
        XCTAssertTrue(hits.contains { $0.hasPrefix("Lien/Core/PushTokenSync.swift") }, "\(hits)")
    }

    func testExtensionsUseNoRequiredReasonAPIs() throws {
        // ウィジェットと NSE は App Group のファイルを読み書きするだけ。使うようになったら宣言を足す
        for bundle in Self.bundles.dropFirst() {
            let used = try usedAPIs(of: bundle)
            let declared = try declaredAPIs(of: bundle)
            XCTAssertTrue(used.isEmpty, "\(bundle.name): \(used)")
            XCTAssertTrue(declared.isEmpty, "\(bundle.name): 使っていない API を宣言している")
        }
    }

    func testScannerRecognizesEachCategory() {
        let samples: [(String, String)] = [
            (Category.userDefaults, "let d = UserDefaults.standard"),
            (Category.userDefaults, "@AppStorage(\"k\") var x = 1"),
            (Category.fileTimestamp, "let m = attrs[.modificationDate]"),
            (Category.fileTimestamp, "try fm.attributesOfItem(atPath: p)"),
            (Category.fileTimestamp, "stat(path, &st)"),
            (Category.systemBootTime, "ProcessInfo.processInfo.systemUptime"),
            (Category.systemBootTime, "mach_absolute_time()"),
            (Category.diskSpace, "url.resourceValues(forKeys: [.volumeAvailableCapacityKey])"),
            (Category.diskSpace, "statfs(path, &s)"),
            (Category.activeKeyboards, "UITextInputMode.activeInputModes"),
        ]
        for (category, source) in samples {
            XCTAssertEqual(Self.categories(in: source), [category], source)
        }
        // コメントに書いただけでは使用と数えない
        XCTAssertTrue(Self.categories(in: "// UserDefaults は使わない\n/* systemUptime */").isEmpty)
        // 似た名前は拾わない
        XCTAssertTrue(Self.categories(in: "let userDefaultsLedger = 1; var restat = 2").isEmpty)
    }

    // MARK: - 走査

    /// マニフェストが宣言している必須理由 API(カテゴリ → 理由コード)
    private func declaredAPIs(of bundle: BundleSpec) throws -> [String: [String]] {
        let manifest = try SourceTree.plist(bundle.manifest)
        let entries = try XCTUnwrap(manifest["NSPrivacyAccessedAPITypes"] as? [[String: Any]], bundle.name)
        var result: [String: [String]] = [:]
        for entry in entries {
            let category = try XCTUnwrap(entry["NSPrivacyAccessedAPIType"] as? String, bundle.name)
            result[category] = entry["NSPrivacyAccessedAPITypeReasons"] as? [String] ?? []
        }
        return result
    }

    /// ターゲットのソースが使っている必須理由 API(カテゴリ → 「ファイル:パターン」の一覧)
    private func usedAPIs(of bundle: BundleSpec) throws -> [String: [String]] {
        var paths = Set(bundle.sharedFiles)
        for directory in bundle.directories {
            paths.formUnion(try SourceTree.swiftFiles(under: directory))
        }
        XCTAssertFalse(paths.isEmpty, "\(bundle.name): ソースが見つかりません")

        var result: [String: [String]] = [:]
        for path in paths.sorted() {
            let code = Self.strippingComments(try SourceTree.text(path))
            for (category, patterns) in Self.usagePatterns {
                for pattern in patterns where Self.matches(pattern, in: code) {
                    result[category, default: []].append("\(path):\(pattern)")
                }
            }
        }
        return result
    }

    private static func categories(in source: String) -> Set<String> {
        let code = strippingComments(source)
        var found = Set<String>()
        for (category, patterns) in usagePatterns where patterns.contains(where: { matches($0, in: code) }) {
            found.insert(category)
        }
        return found
    }

    private static func matches(_ pattern: String, in text: String) -> Bool {
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            XCTFail("正規表現が不正: \(pattern)")
            return false
        }
        return regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    /// 行コメント(// … 行末)とブロックコメント(/* … */)を取り除く
    private static func strippingComments(_ source: String) -> String {
        var text = source
        let block = try? NSRegularExpression(pattern: #"/\*.*?\*/"#, options: [.dotMatchesLineSeparators])
        text = block?.stringByReplacingMatches(
            in: text, range: NSRange(text.startIndex..., in: text), withTemplate: ""
        ) ?? text
        let line = try? NSRegularExpression(pattern: #"//[^\n]*"#)
        text = line?.stringByReplacingMatches(
            in: text, range: NSRange(text.startIndex..., in: text), withTemplate: ""
        ) ?? text
        return text
    }
}
