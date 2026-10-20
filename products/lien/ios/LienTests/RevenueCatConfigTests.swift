// RevenueCatConfigTests.swift — REVENUECAT_API_KEY の読み取り(T33)
//
// 空・変数未展開・Secrets.example の雛形のままは nil(RevenueCat を構成しない)。
// 実値が入っているときだけ返す。

import Foundation
import XCTest
@testable import Lien

/// Info.plist の値を差し込める Bundle(ConfigTests と同じ方式)
private final class RevenueCatInfoBundle: Bundle, @unchecked Sendable {
    static var info: [String: Any] = [:]
    override func object(forInfoDictionaryKey key: String) -> Any? { Self.info[key] }
}

final class RevenueCatConfigTests: XCTestCase {
    private func bundle(_ value: String?) -> RevenueCatInfoBundle {
        RevenueCatInfoBundle.info = [:]
        if let value {
            RevenueCatInfoBundle.info[RevenueCatConfig.apiKeyInfoPlistKey] = value
        }
        return RevenueCatInfoBundle()
    }

    func testReadsARealLookingPublicKey() {
        XCTAssertEqual(
            RevenueCatConfig.apiKey(bundle: bundle("appl_abcdefghijklmnopqrstuvwxyz")),
            "appl_abcdefghijklmnopqrstuvwxyz"
        )
    }

    func testMissingEmptyAndUnexpandedValuesAreNil() {
        XCTAssertNil(RevenueCatConfig.apiKey(bundle: bundle(nil)))
        XCTAssertNil(RevenueCatConfig.apiKey(bundle: bundle("")))
        XCTAssertNil(RevenueCatConfig.apiKey(bundle: bundle("  ")))
        XCTAssertNil(RevenueCatConfig.apiKey(bundle: bundle("$(REVENUECAT_API_KEY)")))
    }

    func testExamplePlaceholderIsNil() {
        // Secrets.example.xcconfig をコピーしただけで実値を入れていない状態
        XCTAssertNil(RevenueCatConfig.apiKey(bundle: bundle("YOUR_REVENUECAT_PUBLIC_SDK_KEY")))
    }
}
