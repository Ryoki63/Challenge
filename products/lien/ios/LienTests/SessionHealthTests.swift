// SessionHealthTests.swift — ログイン状態(セッション)が使えなくなったことの判定(T23 #23)
//
// 検証対象(SessionHealth.swift): snapshot の取得が 401 / user_not_found で連続したときだけ「失われた」とする。
// 通信の失敗・サーバーの 5xx はセッションの良し悪しとは関係ないので、数えも消しもしない。

import XCTest
@testable import Lien

final class SessionHealthTests: XCTestCase {
    private let rejected: SnapshotSynchronizer.Outcome = .failed(.unauthorized)
    private let userGone: SnapshotSynchronizer.Outcome = .failed(.userNotFound)
    private let ok: SnapshotSynchronizer.Outcome = .applied(SnapshotFactory.solo())

    func testThreeConsecutiveRejectionsMeanTheSessionIsLost() {
        var monitor = SessionHealthMonitor()
        XCTAssertEqual(monitor.record(rejected), .suspect, "1 回では決めない(認証サーバーの一時的な不調でも 401 になる)")
        XCTAssertEqual(monitor.record(rejected), .suspect)
        XCTAssertEqual(monitor.record(rejected), .lost, "3 回続いたら確認を出す")
        XCTAssertEqual(monitor.record(rejected), .lost, "その後も失われたまま")
    }

    func testUserNotFoundCountsLikeUnauthorized() {
        var monitor = SessionHealthMonitor()
        monitor.record(userGone)
        monitor.record(rejected)
        XCTAssertEqual(monitor.record(userGone), .lost, "401 と 404 user_not_found は同じ「使えない」の合図")
    }

    func testASuccessfulSyncResetsTheCount() {
        var monitor = SessionHealthMonitor()
        monitor.record(rejected)
        monitor.record(rejected)
        XCTAssertEqual(monitor.record(ok), .healthy, "サーバーが答えたら健全")
        XCTAssertEqual(monitor.consecutiveRejections, 0)
        XCTAssertEqual(monitor.record(rejected), .suspect, "数え直し")
    }

    func testEveryServerAnsweredOutcomeResetsTheCount() {
        let answered: [SnapshotSynchronizer.Outcome] = [
            .applied(SnapshotFactory.solo()), .skippedPendingOps, .skippedLocalChanged, .skippedSessionEnded,
        ]
        for outcome in answered {
            var monitor = SessionHealthMonitor()
            monitor.record(rejected)
            monitor.record(rejected)
            XCTAssertEqual(monitor.record(outcome), .healthy, "\(outcome)")
            XCTAssertEqual(monitor.consecutiveRejections, 0)
        }
    }

    func testNetworkAndServerFailuresNeitherCountNorReset() {
        var monitor = SessionHealthMonitor()
        monitor.record(rejected)
        monitor.record(rejected)

        for inconclusive in [SnapshotSynchronizer.Outcome.failed(.network), .failed(.server), .failed(.storage)] {
            XCTAssertEqual(monitor.record(inconclusive), .suspect, "判断を保留(数えも消しもしない)")
            XCTAssertEqual(monitor.consecutiveRejections, 2)
        }
        XCTAssertEqual(monitor.record(rejected), .lost, "保留をはさんでも、拒否が続いていればそのまま数える")
    }

    func testNetworkFailuresAloneNeverRaiseSuspicion() {
        var monitor = SessionHealthMonitor()
        for _ in 0..<10 {
            XCTAssertEqual(monitor.record(.failed(.network)), .healthy, "オフラインが続いても、セッションは疑わない")
        }
        XCTAssertEqual(monitor.consecutiveRejections, 0)
    }

    func testResetStartsOver() {
        var monitor = SessionHealthMonitor()
        monitor.record(rejected)
        monitor.record(rejected)
        XCTAssertEqual(monitor.record(rejected), .lost)

        monitor.reset() // 確認の「あとで」
        XCTAssertEqual(monitor.consecutiveRejections, 0)
        XCTAssertEqual(monitor.record(rejected), .suspect, "また 3 回続くまで、確認は出ない")
    }

    func testThresholdIsConfigurableAndAtLeastOne() {
        var strict = SessionHealthMonitor(threshold: 1)
        XCTAssertEqual(strict.record(rejected), .lost)

        var clamped = SessionHealthMonitor(threshold: 0)
        XCTAssertEqual(clamped.threshold, 1, "0 以下は 1 に丸める")
        XCTAssertEqual(clamped.record(rejected), .lost)

        XCTAssertEqual(SessionHealthMonitor.defaultThreshold, 3)
    }
}
