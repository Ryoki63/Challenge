// APNsEnvironment.swift — このビルドの APNs 環境(users.push_env)を署名の aps-environment から決める(issue #28)
//
// 以前は「DEBUG ビルド = sandbox / それ以外 = production」だった。ところが APNs の環境を決めるのは
// コンパイル設定ではなく、署名に含まれる aps-environment エンタイトルメント(= プロビジョニングプロファイル)。
// Xcode から Release 構成を development 署名で端末に入れると、Release なのに sandbox の APNs に登録されるため、
// production と誤判定して本番の APNs へ送り、400 BadDeviceToken でトークンを失う。
//
// 判定の順:
//   1. シミュレータ                       → sandbox(本物のトークンは来ない。production と誤認させない)
//   2. embedded.mobileprovision が無い    → production(TestFlight / App Store は配布時に再署名され、プロファイルを持たない)
//   3. プロファイルの Entitlements["aps-environment"]
//        "production"                     → production(Ad Hoc / Enterprise)
//        それ以外(development / 無い / 読めない)→ sandbox(Xcode 直インストールの development 署名)
//
// iOS にはアプリ自身の署名エンタイトルメントを読む公開 API が無い。同じ値を持つ embedded.mobileprovision
// (CMS 署名つきの plist。XML 部分は平文で入っている)から読む。
//
// このファイルは Foundation のみに依存する(テストは合成した profile の Data を渡す)。

import Foundation

extension PushEnvironment {
    /// プロビジョニングプロファイルの Entitlements に入っている APNs 環境のキー
    static let apsEnvironmentKey = "aps-environment"

    /// このビルドの APNs 環境。署名はプロセスの間変わらないので、最初に一度だけ決める
    static let current: PushEnvironment = resolve(
        embeddedProvisioningProfile: embeddedProvisioningProfile(),
        isSimulator: isSimulatorBuild
    )

    #if targetEnvironment(simulator)
    static let isSimulatorBuild = true
    #else
    static let isSimulatorBuild = false
    #endif

    /// 判定の本体(純粋関数)。profile は embedded.mobileprovision の中身(無ければ nil)
    static func resolve(embeddedProvisioningProfile profile: Data?, isSimulator: Bool) -> PushEnvironment {
        if isSimulator { return .sandbox }
        // プロファイルが無い = App Store 系(TestFlight を含む)の再署名済みビルド
        guard let profile else { return .production }
        return apsEnvironment(inProvisioningProfile: profile) == PushEnvironment.production.rawValue
            ? .production
            : .sandbox
    }

    /// embedded.mobileprovision から Entitlements["aps-environment"] を取り出す。
    /// 読めない・キーが無いときは nil
    static func apsEnvironment(inProvisioningProfile data: Data) -> String? {
        guard let plist = embeddedPropertyList(in: data) else { return nil }
        let entitlements = plist["Entitlements"] as? [String: Any]
        return entitlements?[apsEnvironmentKey] as? String
    }

    /// アプリバンドルの embedded.mobileprovision(無ければ nil)
    static func embeddedProvisioningProfile(bundle: Bundle = .main) -> Data? {
        guard let url = bundle.url(forResource: "embedded", withExtension: "mobileprovision") else { return nil }
        return try? Data(contentsOf: url)
    }

    /// CMS の封筒に包まれた XML plist を、`<?xml` から `</plist>` までの範囲で切り出して読む
    private static func embeddedPropertyList(in data: Data) -> [String: Any]? {
        guard
            let start = data.range(of: Data("<?xml".utf8)),
            let end = data.range(of: Data("</plist>".utf8), in: start.lowerBound..<data.endIndex)
        else { return nil }
        let xml = Data(data[start.lowerBound..<end.upperBound])
        let object = try? PropertyListSerialization.propertyList(from: xml, options: [], format: nil)
        return object as? [String: Any]
    }
}
