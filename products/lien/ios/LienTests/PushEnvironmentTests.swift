// PushEnvironmentTests.swift — push_env を署名の aps-environment から決める判定(issue #28)
//
// 検証対象(APNsEnvironment.swift):
//   - embedded.mobileprovision が無い = TestFlight / App Store → production
//   - development 署名(Xcode 直インストール)→ sandbox。**Release 構成で入れた端末でも** sandbox
//     (以前の DEBUG 判定では Release = production と誤判定していた)
//   - Ad Hoc / Enterprise(aps-environment = production)→ production
//   - 読めない・キーが無い profile は sandbox(profile があるのは開発・配布用の署名のとき)
//   - シミュレータは常に sandbox
//
// profile は CMS の封筒を模して、XML plist の前後に UTF-8 として不正なバイト列を付けた Data で合成する。

import Foundation
import XCTest
@testable import Lien

final class PushEnvironmentTests: XCTestCase {
    /// embedded.mobileprovision を模した Data(wrap = true で CMS の封筒のように前後へバイナリを付ける)
    private func makeProfile(entitlements: [String: Any]?, wrap: Bool = true) throws -> Data {
        var dict: [String: Any] = ["Name": "iOS Team Provisioning Profile: *", "TeamName": "Example"]
        if let entitlements { dict["Entitlements"] = entitlements }
        let xml = try PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0)
        guard wrap else { return xml }
        var data = Data([0x30, 0x82, 0x0A, 0x1B, 0x06, 0x09, 0x2A, 0x86, 0xFF, 0xFE, 0x00, 0x80])
        data.append(xml)
        data.append(Data([0x00, 0xA0, 0x81, 0xFF, 0x30, 0x82, 0x01]))
        return data
    }

    // MARK: プロファイルが無い(App Store 系)

    func testNoProfileMeansTestFlightOrAppStoreSoProduction() {
        XCTAssertEqual(PushEnvironment.resolve(embeddedProvisioningProfile: nil, isSimulator: false), .production)
    }

    func testSimulatorIsAlwaysSandbox() throws {
        XCTAssertEqual(PushEnvironment.resolve(embeddedProvisioningProfile: nil, isSimulator: true), .sandbox)
        let production = try makeProfile(entitlements: ["aps-environment": "production"])
        XCTAssertEqual(PushEnvironment.resolve(embeddedProvisioningProfile: production, isSimulator: true), .sandbox)
    }

    // MARK: プロファイルの aps-environment

    func testDevelopmentSigningIsSandboxEvenForAReleaseBuild() throws {
        // Xcode から Release 構成を development 署名で入れた端末。コンパイル設定は見ない
        let profile = try makeProfile(entitlements: ["aps-environment": "development"])
        XCTAssertEqual(PushEnvironment.resolve(embeddedProvisioningProfile: profile, isSimulator: false), .sandbox)
    }

    func testProductionProfileIsProduction() throws {
        // Ad Hoc / Enterprise 配布
        let profile = try makeProfile(entitlements: ["aps-environment": "production"])
        XCTAssertEqual(PushEnvironment.resolve(embeddedProvisioningProfile: profile, isSimulator: false), .production)
    }

    func testProfileWithoutApsEnvironmentIsSandbox() throws {
        let noAps = try makeProfile(entitlements: ["com.apple.developer.team-identifier": "ABCDE12345"])
        XCTAssertEqual(PushEnvironment.resolve(embeddedProvisioningProfile: noAps, isSimulator: false), .sandbox)
        let noEntitlements = try makeProfile(entitlements: nil)
        XCTAssertEqual(PushEnvironment.resolve(embeddedProvisioningProfile: noEntitlements, isSimulator: false), .sandbox)
    }

    func testUnreadableProfileIsSandbox() {
        XCTAssertEqual(PushEnvironment.resolve(embeddedProvisioningProfile: Data(), isSimulator: false), .sandbox)
        XCTAssertEqual(
            PushEnvironment.resolve(embeddedProvisioningProfile: Data([0x00, 0x01, 0xFF]), isSimulator: false),
            .sandbox
        )
    }

    // MARK: plist の取り出し

    func testExtractsApsEnvironmentWithAndWithoutTheCMSEnvelope() throws {
        let wrapped = try makeProfile(entitlements: ["aps-environment": "development"])
        let bare = try makeProfile(entitlements: ["aps-environment": "development"], wrap: false)
        XCTAssertEqual(PushEnvironment.apsEnvironment(inProvisioningProfile: wrapped), "development")
        XCTAssertEqual(PushEnvironment.apsEnvironment(inProvisioningProfile: bare), "development")
    }

    func testNonStringApsEnvironmentAndTruncatedPlistAreNil() throws {
        let notString = try makeProfile(entitlements: ["aps-environment": 1])
        XCTAssertNil(PushEnvironment.apsEnvironment(inProvisioningProfile: notString))

        var truncated = Data([0x30, 0x82])
        truncated.append(Data("<?xml version=\"1.0\"?><plist><dict><key>Entitlements</key>".utf8))
        XCTAssertNil(PushEnvironment.apsEnvironment(inProvisioningProfile: truncated), "</plist> が無い")
    }

    func testBundleWithoutAProfileReturnsNil() {
        // テストバンドルにも embedded.mobileprovision は入らない(無署名ビルド)
        XCTAssertNil(PushEnvironment.embeddedProvisioningProfile(bundle: Bundle(for: PushEnvironmentTests.self)))
    }

    // MARK: このビルド

    func testCurrentEnvironmentIsDecidedBySigningNotBuildConfiguration() {
        #if targetEnvironment(simulator)
        XCTAssertEqual(PushEnvironment.current, .sandbox, "CI(シミュレータ)は Debug でも Release でも sandbox")
        #else
        XCTAssertEqual(
            PushEnvironment.current,
            PushEnvironment.resolve(
                embeddedProvisioningProfile: PushEnvironment.embeddedProvisioningProfile(),
                isSimulator: false
            )
        )
        #endif
    }
}
