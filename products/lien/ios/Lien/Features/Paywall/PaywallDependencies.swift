// PaywallDependencies.swift — ペイウォールを開くための依存の束(T33)
//
// ホーム(と、将来のアルバム)が「文脈」を渡すだけで、RevenueCat・プレミアム判定・
// ログインの user id の配線を知らずに済むようにする。AppModel が1つ作る。
// purchases が nil(課金を使わない組み立て・プレビュー)なら、ペイウォールは開かない。

import Foundation

@MainActor
struct PaywallDependencies {
    /// RevenueCat / メモリ / 利用不可のいずれか
    let purchases: PurchasesClient
    let entitlements: EntitlementStore
    /// RevenueCat にログインする Supabase の user id(Webhook の app_user_id と一致させる)
    let userIDProvider: @MainActor () -> String?
    /// 計測の受け口(REQUIREMENTS §7)。v1.0 は分析 SDK を入れていないので既定は何もしない
    let analytics: (String) -> Void

    init(
        purchases: PurchasesClient,
        entitlements: EntitlementStore,
        userIDProvider: @escaping @MainActor () -> String? = { nil },
        analytics: @escaping (String) -> Void = { _ in }
    ) {
        self.purchases = purchases
        self.entitlements = entitlements
        self.userIDProvider = userIDProvider
        self.analytics = analytics
    }

    func makeViewModel(context: PaywallContext) -> PaywallViewModel {
        PaywallViewModel(
            context: context,
            client: purchases,
            entitlements: entitlements,
            userIDProvider: userIDProvider,
            analytics: analytics
        )
    }
}
