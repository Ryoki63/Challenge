// SnapshotSynchronizerTests.swift — GET /snapshot の反映(DESIGN §4 自己修復 / issue #55)
//
// 検証対象(SnapshotSynchronizer.swift):
//   - サーバーの snapshot を App Group へ反映する(solo → paired も paired → solo も)
//   - 端末の方が新しい可能性があるときは上書きしない(未送信キューあり / 取得中に端末が更新された)
//   - 取得失敗では端末の snapshot をそのまま残す
//   - 表示が変わるときだけウィジェットを reload する(updatedAt だけの差では reload しない)

import XCTest
@testable import Lien

// MARK: - モック(トップレベル)

final class MockSnapshotClient: SnapshotClient {
    var result: Result<PairSnapshot, Error>
    private(set) var callCount = 0
    /// 取得中に実行される(ホームの保存や NSE の書き込みが割り込む状況を模す)
    var onFetch: (() -> Void)?
    /// 応答を遅らせる秒数(同時実行の検証用)
    var delay: TimeInterval = 0

    init(result: Result<PairSnapshot, Error>) {
        self.result = result
    }

    func fetchSnapshot() async throws -> PairSnapshot {
        callCount += 1
        onFetch?()
        if delay > 0 {
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        }
        return try result.get()
    }
}

@MainActor
final class SnapshotSynchronizerTests: XCTestCase {
    private func makeSynchronizer(
        client: SnapshotClient,
        store: AppGroupStore?,
        reloads: ReloadCounter,
        hasPendingOps: @escaping () -> Bool = { false }
    ) -> SnapshotSynchronizer {
        SnapshotSynchronizer(
            client: client,
            store: store,
            hasPendingOps: hasPendingOps,
            reloadWidgets: { reloads.value += 1 }
        )
    }

    // MARK: 反映

    func testAppliesServerSnapshotAndReloadsWidgets() async throws {
        let temp = TempStore()
        defer { temp.cleanup() }
        let reloads = ReloadCounter()
        let server = SnapshotFactory.paired(todayMeDone: true)
        let sync = makeSynchronizer(client: MockSnapshotClient(result: .success(server)), store: temp.store, reloads: reloads)

        let outcome = await sync.sync()

        XCTAssertEqual(outcome, .applied(server))
        XCTAssertEqual(temp.store.loadSnapshot(), server)
        XCTAssertEqual(reloads.value, 1)
    }

    func testInviterLearnsPairWasFormed() async throws {
        let temp = TempStore()
        defer { temp.cleanup() }
        let reloads = ReloadCounter()
        // 招待した側(ソロ)が、相手の受諾後の同期でペア成立を知る
        try temp.store.saveSnapshot(SnapshotFactory.solo())
        let server = SnapshotFactory.paired()
        let sync = makeSynchronizer(client: MockSnapshotClient(result: .success(server)), store: temp.store, reloads: reloads)

        _ = await sync.sync()

        XCTAssertNotNil(temp.store.loadSnapshot()?.pairId)
        XCTAssertEqual(AppRouter.phase(hasSession: true, snapshot: temp.store.loadSnapshot()), .paired)
    }

    func testPairDissolutionIsReflectedAsSolo() async throws {
        let temp = TempStore()
        defer { temp.cleanup() }
        let reloads = ReloadCounter()
        // ペア解消(paired → solo)も同じ経路で反映される
        try temp.store.saveSnapshot(SnapshotFactory.paired())
        let server = SnapshotFactory.solo()
        let sync = makeSynchronizer(client: MockSnapshotClient(result: .success(server)), store: temp.store, reloads: reloads)

        _ = await sync.sync()

        XCTAssertNil(temp.store.loadSnapshot()?.pairId)
        XCTAssertEqual(AppRouter.phase(hasSession: true, snapshot: temp.store.loadSnapshot()), .solo)
    }

    func testNewDayResetsTodayStateFromServer() async throws {
        let temp = TempStore()
        defer { temp.cleanup() }
        let reloads = ReloadCounter()
        // 日付跨ぎ: 端末は昨日の「完了」のまま。サーバーは今日の状態(未完)を返す
        try temp.store.saveSnapshot(SnapshotFactory.paired(todayMeDone: true, todayPartnerDone: true))
        let server = SnapshotFactory.paired(todayMeDone: false, todayPartnerDone: false)
        let sync = makeSynchronizer(client: MockSnapshotClient(result: .success(server)), store: temp.store, reloads: reloads)

        _ = await sync.sync()

        XCTAssertEqual(temp.store.loadSnapshot()?.todayMeDone, false)
        XCTAssertEqual(temp.store.loadSnapshot()?.todayPartnerDone, false)
    }

    // MARK: ウィジェット reload の抑制

    func testNoWidgetReloadWhenOnlyUpdatedAtDiffers() async throws {
        let temp = TempStore()
        defer { temp.cleanup() }
        let reloads = ReloadCounter()
        let local = SnapshotFactory.paired(updatedAt: SnapshotFactory.fixedDate)
        try temp.store.saveSnapshot(local)
        let server = SnapshotFactory.paired(updatedAt: SnapshotFactory.fixedDate.addingTimeInterval(60))
        let sync = makeSynchronizer(client: MockSnapshotClient(result: .success(server)), store: temp.store, reloads: reloads)

        let outcome = await sync.sync()

        XCTAssertEqual(outcome, .applied(server))
        XCTAssertEqual(reloads.value, 0, "表示が変わらない同期でウィジェットの reload 予算を使わない(DESIGN §3.5)")
    }

    func testHasVisibleChangeComparesEverythingExceptUpdatedAt() {
        let base = SnapshotFactory.paired()
        var sameButNewer = base
        sameButNewer.updatedAt = base.updatedAt.addingTimeInterval(10)
        XCTAssertFalse(SnapshotSynchronizer.hasVisibleChange(from: base, to: sameButNewer))

        var changed = base
        changed.streakCurrent += 1
        XCTAssertTrue(SnapshotSynchronizer.hasVisibleChange(from: base, to: changed))
        XCTAssertTrue(SnapshotSynchronizer.hasVisibleChange(from: nil, to: base))
    }

    // MARK: 端末の方が新しい可能性があるとき

    func testPendingOpsSkipOverwriteSoOptimisticStateIsKept() async throws {
        let temp = TempStore()
        defer { temp.cleanup() }
        let reloads = ReloadCounter()
        // オフラインで記録したチェックイン(未送信)があるとき、サーバーの「未完」で巻き戻さない
        let local = SnapshotFactory.paired(todayMeDone: true)
        try temp.store.saveSnapshot(local)
        let server = SnapshotFactory.paired(todayMeDone: false)
        let sync = makeSynchronizer(
            client: MockSnapshotClient(result: .success(server)),
            store: temp.store,
            reloads: reloads,
            hasPendingOps: { true }
        )

        let outcome = await sync.sync()

        XCTAssertEqual(outcome, .skippedPendingOps)
        XCTAssertEqual(temp.store.loadSnapshot(), local)
        XCTAssertEqual(reloads.value, 0)
    }

    func testResultIsDiscardedWhenLocalSnapshotChangedDuringFetch() async throws {
        let temp = TempStore()
        defer { temp.cleanup() }
        let reloads = ReloadCounter()
        // 取得中にホーム(チェックイン完了)や NSE が新しい状態を保存した: 古い取得結果で上書きしない
        try temp.store.saveSnapshot(SnapshotFactory.paired(todayMeDone: false))
        let client = MockSnapshotClient(result: .success(SnapshotFactory.paired(todayMeDone: false)))
        let newer = SnapshotFactory.paired(todayMeDone: true, updatedAt: SnapshotFactory.fixedDate.addingTimeInterval(5))
        let store = temp.store
        client.onFetch = { try? store.saveSnapshot(newer) }
        let sync = makeSynchronizer(client: client, store: temp.store, reloads: reloads)

        let outcome = await sync.sync()

        XCTAssertEqual(outcome, .skippedLocalChanged)
        XCTAssertEqual(temp.store.loadSnapshot(), newer)
    }

    // MARK: 失敗

    func testFailureKeepsLocalSnapshot() async throws {
        let temp = TempStore()
        defer { temp.cleanup() }
        let reloads = ReloadCounter()
        let local = SnapshotFactory.paired()
        try temp.store.saveSnapshot(local)

        let cases: [(Error, SnapshotSynchronizer.Failure)] = [
            (SnapshotClientError.network, .network),
            (SnapshotClientError.unauthorized, .unauthorized),
            (SnapshotClientError.userNotFound, .userNotFound),
            (SnapshotClientError.server(code: "internal_error"), .server),
            // トークン取得の失敗(未サインイン等)は一時エラー扱い
            (AuthServiceError.notSignedIn, .network),
        ]
        for (error, expected) in cases {
            let sync = makeSynchronizer(client: MockSnapshotClient(result: .failure(error)), store: temp.store, reloads: reloads)
            let outcome = await sync.sync()
            XCTAssertEqual(outcome, .failed(expected), "\(error)")
            XCTAssertEqual(temp.store.loadSnapshot(), local, "失敗では端末の snapshot を残す")
        }
        XCTAssertEqual(reloads.value, 0)
    }

    func testStoreNilStillReturnsFetchedSnapshot() async {
        let reloads = ReloadCounter()
        let server = SnapshotFactory.solo()
        let sync = makeSynchronizer(client: MockSnapshotClient(result: .success(server)), store: nil, reloads: reloads)
        let outcome = await sync.sync()
        XCTAssertEqual(outcome, .applied(server))
        XCTAssertEqual(reloads.value, 0)
    }

    // MARK: スタブ構成の「同期」

    func testStubClientReturnsLocalSnapshotUnchanged() async throws {
        let temp = TempStore()
        defer { temp.cleanup() }
        let local = SnapshotFactory.paired(todayMeDone: true)
        try temp.store.saveSnapshot(local)
        let client = StubSnapshotClient(store: temp.store)

        let fetched = try await client.fetchSnapshot()
        XCTAssertEqual(fetched, local, "スタブ構成の同期は端末内の状態を巻き戻さない")
    }

    func testStubClientReturnsEmptySoloWhenNothingStored() async throws {
        let temp = TempStore()
        defer { temp.cleanup() }
        let client = StubSnapshotClient(store: temp.store, now: { SnapshotFactory.fixedDate })
        let fetched = try await client.fetchSnapshot()
        XCTAssertEqual(fetched, PairSnapshot.emptySolo(updatedAt: SnapshotFactory.fixedDate))
        XCTAssertNil(fetched.pairId)
        XCTAssertNil(fetched.myPromiseTitle)
    }
}
