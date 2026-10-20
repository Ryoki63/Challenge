// RevenueCatPurchasesClient.swift — RevenueCat SDK の実装(T33 / REQUIREMENTS §3.14)
//
// 値の流れ: Secrets.xcconfig(gitignore 済み)→ Base.xcconfig → project.yml が Info.plist に埋め込み
//   → RevenueCatConfig が Bundle から読む。CI・API キー未設定のビルドではこの実装を使わず、
//   UnavailablePurchasesClient(AppServices)になる。**キーが無いだけで勝手に偽の価格を出さない**。
//
// 規約:
//   - Purchases.logIn(supabaseUserId) を必須にする(Webhook の app_user_id と一致させる。T33)
//   - 価格・トライアル日数は offerings / StoreProduct から取る(コードに書かない)
//   - entitlement の id は "premium"(RevenueCat ダッシュボードで作る。G6/T37)
//
// RevenueCat SDK は Lien ターゲットだけがリンクする(project.yml)。Widget / NSE には入れない。

import Foundation
import RevenueCat

/// RevenueCat SDK を使う実装。API キーがあるときだけ AppServices が作る
final class RevenueCatPurchasesClient: PurchasesClient, @unchecked Sendable {
    /// RevenueCat ダッシュボードの entitlement identifier(REQUIREMENTS §3.14 の「プレミアム」)
    static let entitlementID = "premium"

    private let apiKey: String
    private let entitlementID: String
    private let lock = NSLock()
    private var isConfigured = false

    init(apiKey: String, entitlementID: String = RevenueCatPurchasesClient.entitlementID) {
        self.apiKey = apiKey
        self.entitlementID = entitlementID
    }

    /// 最初の利用時に1回だけ configure する(configure はアプリで1回だけ — RevenueCat の規約)
    private func ensureConfigured() {
        lock.lock()
        defer { lock.unlock() }
        guard !isConfigured else { return }
        Purchases.configure(withAPIKey: apiKey)
        isConfigured = true
    }

    func logIn(userID: String) async {
        ensureConfigured()
        // 失敗しても購入画面は開ける(オフラインなど)。Webhook の紐付けは次の機会に retry する
        _ = try? await Purchases.shared.logIn(userID)
    }

    func offerings() async throws -> PaywallOfferings {
        ensureConfigured()
        do {
            let offerings = try await Purchases.shared.offerings()
            // current が未設定のダッシュボードでも、1つでも offering があれば表示する
            let offering = offerings.current ?? offerings.all.values.first
            let packages = offering?.availablePackages.map(Self.package) ?? []
            return PaywallOfferings(packages: packages)
        } catch {
            throw Self.map(error)
        }
    }

    func purchase(packageID: String) async throws -> PurchasesSnapshot {
        ensureConfigured()
        do {
            let offerings = try await Purchases.shared.offerings()
            let offering = offerings.current ?? offerings.all.values.first
            guard let package = offering?.availablePackages.first(where: { $0.identifier == packageID }) else {
                throw PurchasesError.failed("package not found")
            }
            let result = try await Purchases.shared.purchase(package: package)
            return Self.snapshot(from: result.customerInfo, entitlementID: entitlementID)
        } catch let error as PurchasesError {
            throw error
        } catch {
            throw Self.map(error)
        }
    }

    func restore() async throws -> PurchasesSnapshot {
        ensureConfigured()
        do {
            let info = try await Purchases.shared.restorePurchases()
            return Self.snapshot(from: info, entitlementID: entitlementID)
        } catch let error as PurchasesError {
            throw error
        } catch {
            throw Self.map(error)
        }
    }

    func currentEntitlement() async -> PurchasesSnapshot {
        ensureConfigured()
        guard let info = try? await Purchases.shared.customerInfo() else { return .none }
        return Self.snapshot(from: info, entitlementID: entitlementID)
    }

    // MARK: - SDK の型 → アプリの型

    static func package(_ package: Package) -> PaywallPackage {
        PaywallPackage(
            id: package.identifier,
            kind: kind(package.packageType),
            priceLabel: package.storeProduct.localizedPriceString,
            trialDays: trialDays(package.storeProduct.introductoryDiscount)
        )
    }

    static func kind(_ type: PackageType) -> PaywallPackage.Kind {
        switch type {
        case .monthly: return .monthly
        case .annual: return .yearly
        default: return .other
        }
    }

    /// 無料トライアルの日数。StoreProduct の introductoryDiscount から計算する
    /// (トライアル日数をコードに書かない。G6/T37 で変えてもアプリは追従する)
    static func trialDays(_ discount: StoreProductDiscount?) -> Int? {
        guard let discount, discount.paymentMode == .freeTrial else { return nil }
        let period = discount.subscriptionPeriod
        let daysPerUnit: Int
        switch period.unit {
        case .day: daysPerUnit = 1
        case .week: daysPerUnit = 7
        case .month: daysPerUnit = 30
        case .year: daysPerUnit = 365
        }
        let days = daysPerUnit * period.value * max(discount.numberOfPeriods, 1)
        return days > 0 ? days : nil
    }

    static func snapshot(from info: CustomerInfo, entitlementID: String) -> PurchasesSnapshot {
        guard let entitlement = info.entitlements[entitlementID], entitlement.isActive else {
            return .none
        }
        return PurchasesSnapshot(isActive: true, premiumUntil: entitlement.expirationDate)
    }

    static func map(_ error: Error) -> PurchasesError {
        if let code = error as? ErrorCode {
            switch code {
            case .purchaseCancelledError:
                return .cancelled
            case .paymentPendingError:
                return .pending
            default:
                return .failed(String(describing: code))
            }
        }
        return .failed(error.localizedDescription)
    }
}
