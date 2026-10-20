// PaywallViewModelTests.swift — ペイウォールの表示・購入・復元(T33 / REQUIREMENTS §3.14)
//
// 完了条件の「ペイウォール表示テスト」: 3文脈(節目・アルバム30日超・チケット切れ)の見出しが
// それぞれ出ること、価格・トライアルが offerings から出ること、相手がプレミアムなら購入させないこと。
// 購入・復元は MockPurchasesClient で、RevenueCat の API キー無しに検証する(CI で緑)。

import XCTest
@testable import Lien

@MainActor
final class PaywallViewModelTests: XCTestCase {
    private final class Recorder {
        var events: [String] = []
    }

    private func makeModel(
        context: PaywallContext = .ticketEmpty,
        client: PurchasesClient,
        entitlements: EntitlementStore? = nil,
        userID: String? = "a1111111-1111-4111-8111-111111111111",
        recorder: Recorder = Recorder()
    ) -> PaywallViewModel {
        PaywallViewModel(
            context: context,
            client: client,
            entitlements: entitlements ?? EntitlementStore(),
            userIDProvider: { userID },
            analytics: { recorder.events.append($0) }
        )
    }

    // MARK: - 3文脈の表示

    func testThreeContextsHaveTheirOwnHeadlines() {
        XCTAssertEqual(
            PaywallContext.milestone(days: 30).headline,
            "30日、ふたりで続いたね"
        )
        XCTAssertEqual(
            PaywallContext.albumLimit.headline,
            Strings.Paywall.albumHeadline
        )
        XCTAssertEqual(
            PaywallContext.ticketEmpty.headline,
            Strings.Paywall.ticketEmptyHeadline
        )
        // 3つとも違う見出し(出し分けが効いている)
        let headlines = [
            PaywallContext.milestone(days: 30).headline,
            PaywallContext.albumLimit.headline,
            PaywallContext.ticketEmpty.headline,
        ]
        XCTAssertEqual(Set(headlines).count, 3)
    }

    func testContextAnalyticsNames() {
        XCTAssertEqual(PaywallContext.milestone(days: 7).analyticsName, "milestone")
        XCTAssertEqual(PaywallContext.albumLimit.analyticsName, "album_limit")
        XCTAssertEqual(PaywallContext.ticketEmpty.analyticsName, "ticket_empty")
        XCTAssertEqual(PaywallContext.milestone(days: 7).id, "milestone:7")
    }

    // MARK: - 読み込み

    func testLoadShowsOfferingsFromClientAndLogsIn() async {
        let client = MockPurchasesClient()
        let recorder = Recorder()
        let model = makeModel(client: client, recorder: recorder)

        await model.load()

        XCTAssertEqual(model.displayPackages.count, 2)
        XCTAssertEqual(model.selectedPackage?.kind, .yearly, "年額を推す(REQUIREMENTS §3.14)")
        XCTAssertEqual(model.selectedPackage?.priceLabel, "¥2,400")
        XCTAssertEqual(model.trialDays, 17)
        XCTAssertEqual(model.trialNote, "17日間 無料で試せます")
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(recorder.events, ["paywall_view:ticket_empty"])

        let loggedIn = await client.loggedInUserID
        XCTAssertEqual(loggedIn, "a1111111-1111-4111-8111-111111111111")
    }

    func testPriceIsNotHardcoded() async {
        // 価格を変えた offerings を返すと、そのまま表示に反映される(コードに 700 円を書かない)
        let client = MockPurchasesClient(packages: [
            PaywallPackage(id: "m", kind: .monthly, priceLabel: "¥800", trialDays: nil),
            PaywallPackage(id: "y", kind: .yearly, priceLabel: "¥3,000", trialDays: 10),
        ])
        let model = makeModel(client: client)
        await model.load()
        XCTAssertEqual(model.selectedPackage?.priceLabel, "¥3,000")
        XCTAssertEqual(model.trialNote, "10日間 無料で試せます")
    }

    func testUnavailableClientShowsGentleUnavailableMessage() async {
        let model = makeModel(client: UnavailablePurchasesClient())
        await model.load()
        XCTAssertEqual(model.errorMessage, Strings.Paywall.unavailable)
        XCTAssertEqual(model.displayPackages.count, 0)
        XCTAssertFalse(model.canPurchase)
    }

    // MARK: - 購入

    func testPurchaseSucceedsAndTurnsPremiumOn() async {
        let client = MockPurchasesClient()
        let entitlements = EntitlementStore()
        let recorder = Recorder()
        let model = makeModel(client: client, entitlements: entitlements, recorder: recorder)

        await model.load()
        await model.purchase()

        XCTAssertTrue(entitlements.isPremium)
        XCTAssertTrue(model.didPurchase)
        XCTAssertEqual(model.noticeMessage, Strings.Paywall.purchaseDone)
        XCTAssertNil(model.errorMessage)
        let purchased = await client.purchasedPackageIDs
        XCTAssertEqual(purchased, ["lien.premium.yearly"])
        XCTAssertTrue(recorder.events.contains("subscribe:ticket_empty"))
    }

    func testPurchaseFailureKeepsTheScreenOpenWithAnError() async {
        let client = MockPurchasesClient(purchaseError: .failed("network"))
        let entitlements = EntitlementStore()
        let model = makeModel(client: client, entitlements: entitlements)

        await model.load()
        await model.purchase()

        XCTAssertFalse(entitlements.isPremium)
        XCTAssertFalse(model.didPurchase)
        XCTAssertEqual(model.errorMessage, Strings.Paywall.errorMessage)
    }

    func testCancelledPurchaseDoesNotShowAnError() async {
        let client = MockPurchasesClient(purchaseError: .cancelled)
        let model = makeModel(client: client)

        await model.load()
        await model.purchase()

        XCTAssertNil(model.errorMessage, "利用者が閉じただけ。責める文言を出さない")
        XCTAssertFalse(model.didPurchase)
    }

    func testPendingPurchaseExplainsThatItIsPending() async {
        let client = MockPurchasesClient(purchaseError: .pending)
        let model = makeModel(client: client)

        await model.load()
        await model.purchase()

        XCTAssertEqual(model.noticeMessage, Strings.Paywall.pending)
        XCTAssertNil(model.errorMessage)
    }

    // MARK: - 相手がすでにプレミアム(誤課金防止 — REQUIREMENTS §3.14)

    func testPartnerPremiumHidesPurchase() async {
        let entitlements = EntitlementStore(pairPlan: .premium)
        let client = MockPurchasesClient()
        let model = makeModel(client: client, entitlements: entitlements)

        await model.load()

        XCTAssertTrue(model.isPremium)
        XCTAssertTrue(model.isAppliedByPartner)
        XCTAssertFalse(model.canPurchase, "相手がプレミアムなら購入させない")
    }

    func testAppliedByPartnerDoesNotCallPurchase() async {
        let entitlements = EntitlementStore(pairPlan: .premium)
        let client = MockPurchasesClient()
        let model = makeModel(client: client, entitlements: entitlements)

        await model.load()
        await model.purchase()

        let purchased = await client.purchasedPackageIDs
        XCTAssertEqual(purchased, [], "適用済みのペアでは購入しない")
    }

    // MARK: - 復元

    func testRestoreFindsAPurchase() async {
        let premiumUntil = Date(timeIntervalSince1970: 1_800_000_000)
        let client = MockPurchasesClient(premiumUntil: premiumUntil)
        let entitlements = EntitlementStore()
        let model = makeModel(client: client, entitlements: entitlements)

        await model.load()
        await model.restore()

        XCTAssertTrue(entitlements.isPremium)
        XCTAssertEqual(model.noticeMessage, Strings.Paywall.restoreDone)
        XCTAssertTrue(model.didPurchase)
        let count = await client.restoreCount
        XCTAssertEqual(count, 1)
    }

    func testRestoreWithNothingToRestore() async {
        let client = MockPurchasesClient()
        let model = makeModel(client: client)

        await model.load()
        await model.restore()

        XCTAssertEqual(model.noticeMessage, Strings.Paywall.restoreNotFound)
        XCTAssertFalse(model.didPurchase)
    }

    // MARK: - プレミアム判定

    func testEntitlementStoreBounds() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let store = EntitlementStore(premiumUntil: now.addingTimeInterval(60), now: { now })
        XCTAssertTrue(store.hasOwnSubscription)
        XCTAssertTrue(store.isPremium)
        XCTAssertFalse(store.isAppliedByPartner)

        let expired = EntitlementStore(premiumUntil: now.addingTimeInterval(-60), now: { now })
        XCTAssertFalse(expired.hasOwnSubscription)
        XCTAssertFalse(expired.isPremium)

        let partner = EntitlementStore(pairPlan: .premium, now: { now })
        XCTAssertTrue(partner.isPremium)
        XCTAssertTrue(partner.isAppliedByPartner)
    }

    func testSnapshotPairPlanDefaultsToFree() async throws {
        // 古いサーバー(キーが無い)は free。未知の値も free(課金していない側に倒す)
        let withoutKey = """
        {"schemaVersion":1,"updatedAt":"2026-06-11T08:30:00Z"}
        """
        let missing = try PairSnapshot.makeJSONDecoder()
            .decode(PairSnapshot.self, from: Data(withoutKey.utf8))
        XCTAssertEqual(missing.pairPlan, .free)

        let unknown = """
        {"schemaVersion":1,"updatedAt":"2026-06-11T08:30:00Z","pairPlan":"platinum"}
        """
        let unknownPlan = try PairSnapshot.makeJSONDecoder()
            .decode(PairSnapshot.self, from: Data(unknown.utf8))
        XCTAssertEqual(unknownPlan.pairPlan, .free, "未知の値は free")
    }
}
