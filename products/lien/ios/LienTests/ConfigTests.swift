// ConfigTests.swift — Supabase 接続情報の欠落の扱い(issue #28)
//
// 検証対象(Config.swift / AppServices+Live.swift):
//   - 雛形のまま・変数が展開されずに残った値・空白だけの値は「未設定」と同じ(Live に進まない)
//   - Config が無いときの既定の扱いはビルド構成で決まる(Debug = Stub / Release = 致命)
//   - 致命(.fatal)のときは Stub に落ちず、Config.MissingError を投げる(make はこれを fatalError にする)
//   - Config があれば、ポリシーに関係なく Live

import Foundation
import XCTest
@testable import Lien

/// Info.plist の値を差し込める Bundle(キーが無ければ nil)。
/// Bundle のサブクラスには保持プロパティを持たせない(`Bundle()` の初期化は別のインスタンスを返しうる)ので、
/// 差し込む値は static に置く。テストは直列に動き、`bundle(url:key:)` が毎回上書きする
private final class InfoBundle: Bundle, @unchecked Sendable {
    static var info: [String: Any] = [:]
    override func object(forInfoDictionaryKey key: String) -> Any? { Self.info[key] }
}

final class ConfigTests: XCTestCase {
    private func bundle(url: String?, key: String?) -> InfoBundle {
        InfoBundle.info = [:]
        if let url { InfoBundle.info[Config.supabaseURLInfoPlistKey] = url }
        if let key { InfoBundle.info[Config.supabaseAnonKeyInfoPlistKey] = key }
        return InfoBundle()
    }

    // MARK: 未設定とみなす値

    func testLoadsARealLookingConfig() {
        let config = Config.load(bundle: bundle(url: "https://abcdefghij.supabase.co", key: "sb_publishable_abc-DEF_123"))
        XCTAssertEqual(config?.supabaseURL.absoluteString, "https://abcdefghij.supabase.co")
        XCTAssertEqual(config?.supabaseAnonKey, "sb_publishable_abc-DEF_123")
    }

    func testMissingKeysAreUnset() {
        XCTAssertNil(Config.load(bundle: bundle(url: nil, key: nil)))
        XCTAssertNil(Config.load(bundle: bundle(url: "https://abcdefghij.supabase.co", key: nil)))
        XCTAssertNil(Config.load(bundle: bundle(url: nil, key: "anon-key")))
    }

    func testEmptyAndBlankValuesAreUnset() {
        XCTAssertNil(Config.load(bundle: bundle(url: "", key: "")))
        XCTAssertNil(Config.load(bundle: bundle(url: "   ", key: "anon-key")))
        XCTAssertNil(Config.load(bundle: bundle(url: "https://abcdefghij.supabase.co", key: "\n")))
    }

    func testExampleXcconfigPlaceholdersAreUnset() {
        // Secrets.example.xcconfig を編集せずにコピーしただけの状態は、Live に進ませない
        XCTAssertNil(Config.load(bundle: bundle(url: "https://YOUR-PROJECT-REF.supabase.co", key: "anon-key")))
        XCTAssertNil(Config.load(bundle: bundle(url: "https://abcdefghij.supabase.co", key: "YOUR_SUPABASE_ANON_KEY")))
    }

    func testUnexpandedBuildVariablesAreUnset() {
        // xcconfig に変数が無いと、Info.plist に $(SUPABASE_URL) という文字列がそのまま残る
        XCTAssertNil(Config.load(bundle: bundle(url: "$(SUPABASE_URL)", key: "$(SUPABASE_ANON_KEY)")))
    }

    func testIsUnsetMatchesTheSameRules() {
        XCTAssertTrue(Config.isUnset(""))
        XCTAssertTrue(Config.isUnset(" \t"))
        XCTAssertTrue(Config.isUnset("$(SUPABASE_URL)"))
        XCTAssertTrue(Config.isUnset("https://YOUR-PROJECT-REF.supabase.co"))
        XCTAssertFalse(Config.isUnset("https://abcdefghij.supabase.co"))
    }

    // MARK: 欠落時のポリシー

    func testDefaultPolicyFollowsBuildConfiguration() {
        #if DEBUG
        XCTAssertEqual(Config.MissingPolicy.buildDefault, .fallBackToStub, "Debug / CI は Stub に落ちてよい")
        #else
        XCTAssertEqual(Config.MissingPolicy.buildDefault, .fatal, "Release は黙って Stub に落ちない")
        #endif
    }

    func testFatalPolicyThrowsInsteadOfFallingBackToStub() {
        XCTAssertThrowsError(
            try AppServices.makeChecked(bundle: bundle(url: nil, key: nil), whenConfigMissing: .fatal)
        ) { error in
            XCTAssertEqual(error as? Config.MissingError, Config.MissingError())
        }
        XCTAssertThrowsError(
            try AppServices.makeChecked(bundle: bundle(url: "", key: ""), whenConfigMissing: .fatal)
        )
        XCTAssertThrowsError(
            try AppServices.makeChecked(
                bundle: bundle(url: "https://YOUR-PROJECT-REF.supabase.co", key: "YOUR_SUPABASE_ANON_KEY"),
                whenConfigMissing: .fatal
            ),
            "雛形のままも致命"
        )
    }

    func testStubPolicyFallsBackToStubServices() throws {
        let services = try AppServices.makeChecked(
            bundle: bundle(url: nil, key: nil),
            whenConfigMissing: .fallBackToStub
        )
        XCTAssertFalse(services.isLive)
        XCTAssertTrue(services.auth is StubAuthService)
    }

    func testPresentConfigBuildsLiveServicesUnderEveryPolicy() throws {
        let configured = bundle(url: "https://abcdefghij.supabase.co", key: "sb_publishable_abc")
        for policy in [Config.MissingPolicy.fallBackToStub, .fatal] {
            let services = try AppServices.makeChecked(bundle: configured, whenConfigMissing: policy)
            XCTAssertTrue(services.isLive, "接続情報があれば \(policy) でも Live")
            XCTAssertTrue(services.auth is SupabaseService)
        }
    }

    func testMissingMessageNamesTheKeysAndTheFix() {
        let message = Config.MissingError().description
        XCTAssertTrue(message.contains("SUPABASE_URL"))
        XCTAssertTrue(message.contains("SUPABASE_ANON_KEY"))
        XCTAssertTrue(message.contains("Secrets.xcconfig"), "ローカルでの直し方")
        XCTAssertTrue(message.contains("lien-release"), "TestFlight 用の経路")
    }
}
