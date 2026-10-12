// AppRouterTests.swift — ルート画面系統の導出(AppRouter。純粋関数 — issue #55)
//
//   セッション無し → onboarding / 約束なし → promiseSetup / ソロ → solo / ペア → paired
// 旧 LienApp.initialPhase のテスト(OnboardingViewModelTests.testInitialPhaseDerivation)の後継。

import XCTest
@testable import Lien

final class AppRouterTests: XCTestCase {
    // MARK: セッション無し → onboarding

    func testNoSessionAlwaysRoutesToOnboarding() {
        XCTAssertEqual(AppRouter.phase(hasSession: false, snapshot: nil), .onboarding)
        // snapshot が残っていても(サインアウト・再インストール後の App Group など)オンボから
        XCTAssertEqual(AppRouter.phase(hasSession: false, snapshot: SnapshotFactory.solo()), .onboarding)
        XCTAssertEqual(AppRouter.phase(hasSession: false, snapshot: SnapshotFactory.paired()), .onboarding)
    }

    // MARK: 約束なし → promiseSetup

    func testSessionWithoutSnapshotRoutesToPromiseSetup() {
        XCTAssertEqual(AppRouter.phase(hasSession: true, snapshot: nil), .promiseSetup)
    }

    func testSessionWithSnapshotButNoPromiseRoutesToPromiseSetup() {
        XCTAssertEqual(
            AppRouter.phase(hasSession: true, snapshot: SnapshotFactory.noPromise()),
            .promiseSetup
        )
    }

    func testBlankPromiseTitleIsTreatedAsNoPromise() {
        var snapshot = SnapshotFactory.solo()
        snapshot.myPromiseTitle = "  \n"
        XCTAssertEqual(AppRouter.phase(hasSession: true, snapshot: snapshot), .promiseSetup)
    }

    func testPairedSnapshotWithoutPromiseStillRoutesToPromiseSetup() {
        // 約束はユーザーに属する(§3.3)。ペアがあっても自分の約束が無ければ先に約束設定
        var snapshot = SnapshotFactory.paired()
        snapshot.myPromiseTitle = nil
        snapshot.myPromiseEmoji = nil
        XCTAssertEqual(AppRouter.phase(hasSession: true, snapshot: snapshot), .promiseSetup)
    }

    // MARK: ソロ / ペア → ホーム

    func testSoloWithPromiseRoutesToSolo() {
        XCTAssertEqual(AppRouter.phase(hasSession: true, snapshot: SnapshotFactory.solo()), .solo)
        XCTAssertTrue(AppPhase.solo.isHome)
    }

    func testPairedWithPromiseRoutesToPaired() {
        XCTAssertEqual(AppRouter.phase(hasSession: true, snapshot: SnapshotFactory.paired()), .paired)
        XCTAssertTrue(AppPhase.paired.isHome)
    }

    func testOnlySoloAndPairedAreHome() {
        XCTAssertFalse(AppPhase.onboarding.isHome)
        XCTAssertFalse(AppPhase.promiseSetup.isHome)
    }

    // MARK: 遷移の連鎖(同期・保存のたびに再導出される)

    func testPairDissolutionFallsBackFromPairedToSolo() {
        // ペア解消(paired → solo)も同じ導出で扱える(snapshot の pairId が null に戻る)
        var snapshot = SnapshotFactory.paired()
        XCTAssertEqual(AppRouter.phase(hasSession: true, snapshot: snapshot), .paired)
        snapshot.pairId = nil
        XCTAssertEqual(AppRouter.phase(hasSession: true, snapshot: snapshot), .solo)
    }

    func testPromiseSavedMovesFromPromiseSetupToSolo() {
        var snapshot = SnapshotFactory.noPromise()
        XCTAssertEqual(AppRouter.phase(hasSession: true, snapshot: snapshot), .promiseSetup)
        snapshot.myPromiseTitle = "筋トレ"
        snapshot.myPromiseEmoji = "💪"
        XCTAssertEqual(AppRouter.phase(hasSession: true, snapshot: snapshot), .solo)
    }
}
