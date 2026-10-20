// PaywallRenderTests.swift — ペイウォールを実際に描いて、白紙にならないことを確かめる(T33)
//
// ViewModel の表示テスト(PaywallViewModelTests)に加えて、3文脈の画面を ImageRenderer で描く。
// 文字・プラン・購入ボタンが載った画像が生成できれば、SwiftUI の組み立てが壊れていない
// (既存の HomeRenderChecksTests / PlantRenderTests と同じやり方。UIKit を使うので macOS の下見では走らせない)。

import SwiftUI
import XCTest
@testable import Lien

@MainActor
final class PaywallRenderTests: XCTestCase {
    private func render(_ context: PaywallContext) async throws -> CGImage {
        let entitlements = EntitlementStore()
        let model = PaywallViewModel(
            context: context,
            client: MockPurchasesClient(),
            entitlements: entitlements
        )
        await model.load()
        XCTAssertFalse(model.displayPackages.isEmpty, "プランが読み込めていない")
        XCTAssertNil(model.errorMessage)

        let view = PaywallView(model: model)
            .frame(width: 390, height: 844)
            .background(Color(uiColor: .systemBackground))
        let renderer = ImageRenderer(content: view)
        renderer.scale = 1
        guard let image = renderer.cgImage else {
            throw NSError(domain: "PaywallRenderTests", code: 1)
        }
        return image
    }

    func testThreeContextsRender() async throws {
        for context in [
            PaywallContext.milestone(days: 30),
            .albumLimit,
            .ticketEmpty,
        ] {
            let image = try await render(context)
            XCTAssertEqual(image.width, 390, "\(context.id)")
            XCTAssertEqual(image.height, 844, "\(context.id)")
        }
    }

    func testAppliedByPartnerRenders() async throws {
        let entitlements = EntitlementStore(pairPlan: .premium)
        let model = PaywallViewModel(
            context: .albumLimit,
            client: MockPurchasesClient(),
            entitlements: entitlements
        )
        await model.load()
        XCTAssertTrue(model.isAppliedByPartner)

        let view = PaywallView(model: model)
            .frame(width: 390, height: 844)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 1
        XCTAssertNotNil(renderer.cgImage)
    }
}
