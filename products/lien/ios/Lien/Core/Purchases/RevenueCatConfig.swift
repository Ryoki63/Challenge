// RevenueCatConfig.swift — Info.plist の REVENUECAT_API_KEY を読む(T33)
//
// 値の流れ: Secrets.xcconfig(gitignore 済み)→ Base.xcconfig → project.yml が Info.plist に埋め込み
//   → 本構造体が Bundle から読む。未設定・雛形のまま・変数未展開は nil。
// RevenueCat SDK を import しない(API キーの有無だけで Live / 利用不可を切り替えられるようにする)。

import Foundation

enum RevenueCatConfig {
    static let apiKeyInfoPlistKey = "REVENUECAT_API_KEY"

    static func apiKey(bundle: Bundle = .main) -> String? {
        guard
            let value = bundle.object(forInfoDictionaryKey: apiKeyInfoPlistKey) as? String,
            !Config.isUnset(value)
        else { return nil }
        return value
    }
}
