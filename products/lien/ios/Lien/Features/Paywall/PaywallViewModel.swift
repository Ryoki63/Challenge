// PaywallViewModel.swift — ペイウォールの状態(T33 / REQUIREMENTS §3.14)
//
// 表示の約束:
//   - 価格・トライアルは offerings から(コードに書かない)
//   - 相手がすでにプレミアムなら「適用済み」を出し、購入ボタンを出さない(誤課金防止)
//   - 閉じる・復元を常に置く(押し売りしない)
//   - 失敗しても画面は閉じない。文言で知らせて、もう一度試せる
//
// 計測(REQUIREMENTS §7): paywall_view(context) / paywall_purchase(context) / subscribe(context)。
// 分析 SDK は v1.0 では入れていないので、受け口(analytics)を注入する。今は何もしない実装を渡す。

import Foundation
import Observation

@MainActor
@Observable
final class PaywallViewModel {
    let context: PaywallContext

    private(set) var offerings: PaywallOfferings?
    private(set) var isLoading = false
    private(set) var isPurchasing = false
    private(set) var isRestoring = false
    private(set) var errorMessage: String?
    private(set) var noticeMessage: String?
    /// 購入が完了した(画面を閉じる導線を出す)
    private(set) var didPurchase = false
    var selectedPackageID: String?

    @ObservationIgnored private let client: PurchasesClient
    @ObservationIgnored private let entitlements: EntitlementStore
    @ObservationIgnored private let userIDProvider: @MainActor () -> String?
    @ObservationIgnored private let analytics: (String) -> Void
    @ObservationIgnored private var hasLoaded = false

    init(
        context: PaywallContext,
        client: PurchasesClient,
        entitlements: EntitlementStore,
        userIDProvider: @escaping @MainActor () -> String? = { nil },
        analytics: @escaping (String) -> Void = { _ in }
    ) {
        self.context = context
        self.client = client
        self.entitlements = entitlements
        self.userIDProvider = userIDProvider
        self.analytics = analytics
    }

    // MARK: - 表示

    var headline: String { context.headline }
    var message: String { context.message }
    var isPremium: Bool { entitlements.isPremium }
    var isAppliedByPartner: Bool { entitlements.isAppliedByPartner }

    var displayPackages: [PaywallPackage] { offerings?.displayPackages ?? [] }
    var trialDays: Int? { offerings?.trialDays }
    /// トライアルの注記。日数は offerings から(無ければ出さない)
    var trialNote: String? {
        guard let days = trialDays, days > 0 else { return nil }
        return Strings.Paywall.trialNote(days)
    }

    var selectedPackage: PaywallPackage? {
        guard let selectedPackageID else { return displayPackages.last }
        return displayPackages.first { $0.id == selectedPackageID } ?? displayPackages.last
    }

    var canPurchase: Bool {
        !isPurchasing && !isAppliedByPartner && !didPurchase && selectedPackage != nil
    }

    var purchaseButtonTitle: String {
        isPurchasing ? Strings.Paywall.purchasing : Strings.Paywall.purchaseButton
    }

    var restoreButtonTitle: String {
        isRestoring ? Strings.Paywall.restoring : Strings.Paywall.restoreButton
    }

    /// 月額・年額の見出し(価格そのものは StoreKit の表示を使う)
    func priceCaption(for package: PaywallPackage) -> String {
        switch package.kind {
        case .monthly: return "\(Strings.Paywall.monthlyPrefix) \(package.priceLabel)"
        case .yearly: return "\(Strings.Paywall.yearlyPrefix) \(package.priceLabel)"
        case .other: return package.priceLabel
        }
    }

    // MARK: - 読み込み

    func load() async {
        guard !hasLoaded else { return }
        hasLoaded = true
        isLoading = true
        defer { isLoading = false }

        analytics("paywall_view:\(context.analyticsName)")
        await ensureLoggedIn()
        await entitlements.refresh(using: client)
        do {
            let fetched = try await client.offerings()
            offerings = fetched
            selectedPackageID = fetched.yearly?.id ?? fetched.monthly?.id ?? fetched.packages.first?.id
        } catch {
            present(error)
        }
    }

    // MARK: - 購入・復元

    func purchase() async {
        guard let package = selectedPackage, canPurchase else { return }
        isPurchasing = true
        defer { isPurchasing = false }
        errorMessage = nil
        noticeMessage = nil
        analytics("paywall_purchase:\(context.analyticsName):\(package.kind.rawValue)")
        await ensureLoggedIn()
        do {
            let snapshot = try await client.purchase(packageID: package.id)
            entitlements.apply(snapshot)
            if snapshot.isActive {
                didPurchase = true
                noticeMessage = Strings.Paywall.purchaseDone
                analytics("subscribe:\(context.analyticsName)")
            } else {
                errorMessage = Strings.Paywall.errorMessage
            }
        } catch {
            present(error)
        }
    }

    func restore() async {
        guard !isRestoring else { return }
        isRestoring = true
        defer { isRestoring = false }
        errorMessage = nil
        noticeMessage = nil
        analytics("paywall_restore:\(context.analyticsName)")
        await ensureLoggedIn()
        do {
            let snapshot = try await client.restore()
            entitlements.apply(snapshot)
            if snapshot.isActive {
                didPurchase = true
                noticeMessage = Strings.Paywall.restoreDone
            } else {
                noticeMessage = Strings.Paywall.restoreNotFound
            }
        } catch {
            present(error)
        }
    }

    // MARK: - 失敗の文言

    private func present(_ error: Error) {
        guard let purchasesError = error as? PurchasesError else {
            errorMessage = Strings.Paywall.errorMessage
            return
        }
        switch purchasesError {
        case .unavailable:
            errorMessage = Strings.Paywall.unavailable
        case .cancelled:
            // 利用者が閉じただけ。責める文言を出さない
            errorMessage = nil
        case .pending:
            noticeMessage = Strings.Paywall.pending
        case .failed:
            errorMessage = Strings.Paywall.errorMessage
        }
    }

    private func ensureLoggedIn() async {
        guard let userID = userIDProvider(), !userID.isEmpty else { return }
        await client.logIn(userID: userID)
    }
}
