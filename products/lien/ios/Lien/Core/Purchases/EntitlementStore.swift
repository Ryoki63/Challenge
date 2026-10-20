// EntitlementStore.swift — プレミアム判定の唯一の場所(T33 / REQUIREMENTS §3.14)
//
// 判定(REQUIREMENTS §3.14):
//   isPremium = 自分の購読が有効 ∪ snapshot.pairPlan == "premium"
// - 課金した本人だけでなく、ペアの相手にも恩恵が及ぶ(ただ乗りは意図的に許容)
// - 両方課金しても重複しない。**自分の購読が無いのに pairPlan が premium** のときは
//   「相手がすでにプレミアムなのでこのペアは適用済み」と表示して、誤課金を防ぐ
//
// 期限はサーバーの users.premium_until と RevenueCat の customerInfo の両方から来る。
// 表示のたびに now で判定する(期限切れの購読を有効のまま見せない)。

import Foundation
import Observation

@MainActor
@Observable
final class EntitlementStore {
    /// 自分の購読の期限(RevenueCat の customerInfo / 購入結果)。nil = 購読していない
    private(set) var premiumUntil: Date?
    /// RevenueCat の entitlement が有効か(期限の無い購読もありうるので、期限とは別に持つ)
    private(set) var hasActiveSubscription = false
    /// サーバーが導出したペアのプラン(snapshot.pairPlan)。無い snapshot は .free
    private(set) var pairPlan: PairPlan = .free

    private let now: () -> Date

    init(premiumUntil: Date? = nil, pairPlan: PairPlan = .free, now: @escaping () -> Date = Date.init) {
        self.premiumUntil = premiumUntil
        self.hasActiveSubscription = premiumUntil != nil
        self.pairPlan = pairPlan
        self.now = now
    }

    /// 自分の購読が有効か(期限切れは false)
    var hasOwnSubscription: Bool {
        if hasActiveSubscription, premiumUntil == nil { return true } // 期限の無い購読
        guard let premiumUntil else { return false }
        return premiumUntil > now()
    }

    /// プレミアムか(自分の購読 ∪ ペアのプラン)
    var isPremium: Bool {
        hasOwnSubscription || pairPlan == .premium
    }

    /// 相手の購読でペアがプレミアムになっている(自分の購読は無い)。誤課金防止の表示に使う
    var isAppliedByPartner: Bool {
        !hasOwnSubscription && pairPlan == .premium
    }

    /// 購入・復元の結果を反映する
    func apply(_ snapshot: PurchasesSnapshot) {
        hasActiveSubscription = snapshot.isActive
        premiumUntil = snapshot.premiumUntil
    }

    /// snapshot の pairPlan を反映する(同期のたびに AppModel が呼ぶ)
    func update(pairPlan: PairPlan) {
        self.pairPlan = pairPlan
    }

    /// RevenueCat のキャッシュから自分の購読を読み直す(起動時・購入画面を開くとき)
    func refresh(using client: PurchasesClient) async {
        apply(await client.currentEntitlement())
    }
}
