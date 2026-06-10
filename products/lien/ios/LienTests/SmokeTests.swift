// SmokeTests.swift — ビルド/テスト基盤の疎通確認用の自明テスト(T06)
// 実質的な単体テスト(日付処理・スナップショット解釈・送信キュー)は T07 以降で追加する。

import XCTest
@testable import Lien

final class SmokeTests: XCTestCase {
    func testAppPhaseHasThreeStates() {
        XCTAssertEqual(AppPhase.allCases.count, 3)
        XCTAssertEqual(AppPhase.onboarding.rawValue, "onboarding")
        XCTAssertEqual(AppPhase.solo.rawValue, "solo")
        XCTAssertEqual(AppPhase.paired.rawValue, "paired")
    }
}
