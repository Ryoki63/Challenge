// MockPurchasesClient.swift — テスト・プレビュー用のメモリ実装(T33)
//
// RevenueCat SDK も API キーも使わず、購入画面の表示・購入・復元の流れを再現する。
// CI(Secrets.xcconfig が無い)と SwiftUI プレビューはこれを使う。
// 価格は fixtures(テストが渡す)で、コードに「700円」を書かない。

import Foundation

actor MockPurchasesClient: PurchasesClient {
    private var packages: [PaywallPackage]
    private var currentPremiumUntil: Date?
    private var offeringsError: PurchasesError?
    private var purchaseError: PurchasesError?
    private var restoreError: PurchasesError?
    /// 購入が成功したときに返す期限(テストで固定する)
    private let purchaseResult: PurchasesSnapshot

    private(set) var loggedInUserID: String?
    private(set) var purchasedPackageIDs: [String] = []
    private(set) var restoreCount = 0

    init(
        packages: [PaywallPackage] = MockPurchasesClient.defaultPackages,
        premiumUntil: Date? = nil,
        offeringsError: PurchasesError? = nil,
        purchaseError: PurchasesError? = nil,
        restoreError: PurchasesError? = nil,
        purchaseResult: PurchasesSnapshot = PurchasesSnapshot(
            premiumUntil: Date(timeIntervalSince1970: 1_800_000_000)
        )
    ) {
        self.packages = packages
        self.currentPremiumUntil = premiumUntil
        self.offeringsError = offeringsError
        self.purchaseError = purchaseError
        self.restoreError = restoreError
        self.purchaseResult = purchaseResult
    }

    /// プレビュー・テストの既定プラン(実際の価格は G6/T37 で RevenueCat に設定する)
    static let defaultPackages: [PaywallPackage] = [
        PaywallPackage(id: "lien.premium.monthly", kind: .monthly, priceLabel: "¥700", trialDays: 17),
        PaywallPackage(id: "lien.premium.yearly", kind: .yearly, priceLabel: "¥2,400", trialDays: 17),
    ]

    func logIn(userID: String) async {
        loggedInUserID = userID
    }

    func offerings() async throws -> PaywallOfferings {
        if let offeringsError { throw offeringsError }
        return PaywallOfferings(packages: packages)
    }

    func purchase(packageID: String) async throws -> PurchasesSnapshot {
        if let purchaseError { throw purchaseError }
        purchasedPackageIDs.append(packageID)
        currentPremiumUntil = purchaseResult.premiumUntil
        return purchaseResult
    }

    func restore() async throws -> PurchasesSnapshot {
        restoreCount += 1
        if let restoreError { throw restoreError }
        return PurchasesSnapshot(premiumUntil: currentPremiumUntil)
    }

    func currentEntitlement() async -> PurchasesSnapshot {
        PurchasesSnapshot(premiumUntil: currentPremiumUntil)
    }

    // MARK: - テストからの操作

    func setOfferings(_ packages: [PaywallPackage]) {
        self.packages = packages
    }

    func setPremiumUntil(_ date: Date?) {
        currentPremiumUntil = date
    }
}

/// API キーが無いときの実装。購入画面は開けるが、プランは出さず「いまは購入できません」を出す。
/// 本番で API キーの設定を忘れた場合に、偽の価格を見せないための実装(T33)
struct UnavailablePurchasesClient: PurchasesClient {
    func logIn(userID: String) async {}
    func offerings() async throws -> PaywallOfferings { throw PurchasesError.unavailable }
    func purchase(packageID: String) async throws -> PurchasesSnapshot {
        throw PurchasesError.unavailable
    }
    func restore() async throws -> PurchasesSnapshot { throw PurchasesError.unavailable }
    func currentEntitlement() async -> PurchasesSnapshot { .none }
}
