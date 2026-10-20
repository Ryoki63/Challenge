import XCTest
@testable import Lien

private final class ConditionalSnapshotClient: SnapshotClient {
    var snapshot = SnapshotFactory.paired(todayPartnerDone: true)
    var revision = "revision-1"
    var requests: [String?] = []
    var failFirst = false
    var onFetch: (() -> Void)?

    func fetchSnapshot() async throws -> PairSnapshot { snapshot }

    func fetchChanges(etag: String?) async throws -> SnapshotChanges {
        requests.append(etag)
        onFetch?()
        if failFirst, requests.count == 1 { throw SnapshotClientError.network }
        return etag == revision ? .unchanged(confirmedAt: snapshot.updatedAt) : .snapshot(snapshot, etag: revision)
    }
}

@MainActor
final class SnapshotRecoveryTests: XCTestCase {
    func testUnchangedResponsePreventsDelayedIntermediatePushRollback() async throws {
        let temp = TempStore()
        defer { temp.cleanup() }
        let client = ConditionalSnapshotClient()
        let reloads = ReloadCounter()
        let sync = SnapshotSynchronizer(client: client, store: temp.store, reloadWidgets: { reloads.value += 1 })
        _ = await sync.sync()
        var delayed = client.snapshot
        delayed.todayPartnerDone = false
        delayed.updatedAt = delayed.updatedAt.addingTimeInterval(5)
        client.snapshot.updatedAt = client.snapshot.updatedAt.addingTimeInterval(10)
        _ = await sync.sync()
        let object = try JSONSerialization.jsonObject(with: PairSnapshot.makeJSONEncoder().encode(delayed))
        _ = try PushSnapshotWriter(store: temp.store, reloadWidgets: { reloads.value += 1 }).receive(["lien": ["snapshot": object]])
        XCTAssertEqual(temp.store.loadSnapshot(), client.snapshot)
        XCTAssertEqual(SnapshotCheckpoint.load(from: temp.store)?.snapshot, client.snapshot)
        XCTAssertEqual(reloads.value, 1)
    }

    func testRelaunchRepairsMissedPushFromPreviousCheckpoint() async throws {
        let temp = TempStore()
        defer { temp.cleanup() }
        let client = ConditionalSnapshotClient()
        let reloads = ReloadCounter()
        let first = SnapshotSynchronizer(client: client, store: temp.store, reloadWidgets: { reloads.value += 1 })
        _ = await first.sync()
        client.snapshot.todayPartnerDone = false
        client.revision = "revision-2"
        let relaunched = SnapshotSynchronizer(client: client, store: temp.store, reloadWidgets: { reloads.value += 1 })
        let outcome = await relaunched.sync()
        XCTAssertEqual(outcome, .applied(client.snapshot))
        XCTAssertEqual(client.requests[1], "revision-1")
        XCTAssertEqual(temp.store.loadSnapshot(), client.snapshot)
        XCTAssertEqual(SnapshotCheckpoint.load(from: temp.store)?.etag, "revision-2")
        _ = await relaunched.sync()
        XCTAssertEqual(client.requests[2], "revision-2")
        XCTAssertEqual(reloads.value, 2)
    }

    func testRelaunchRequestsChangesFromLastPersistedSyncWithoutDuplicateReload() async throws {
        let temp = TempStore()
        defer { temp.cleanup() }
        let client = ConditionalSnapshotClient()
        let reloads = ReloadCounter()
        let first = SnapshotSynchronizer(client: client, store: temp.store, reloadWidgets: { reloads.value += 1 })
        let firstOutcome = await first.sync()
        XCTAssertEqual(firstOutcome, .applied(client.snapshot))
        let relaunched = SnapshotSynchronizer(client: client, store: temp.store, reloadWidgets: { reloads.value += 1 })
        let secondOutcome = await relaunched.sync()
        XCTAssertEqual(secondOutcome, .applied(client.snapshot))
        XCTAssertEqual(client.requests.count, 2)
        XCTAssertNil(client.requests[0])
        XCTAssertEqual(client.requests[1], "revision-1")
        XCTAssertEqual(reloads.value, 1)
    }

    func testTransientFailureRetriesOnceWithoutAdvancingCheckpointOrDuplicatingDisplay() async throws {
        let temp = TempStore()
        defer { temp.cleanup() }
        let client = ConditionalSnapshotClient()
        client.failFirst = true
        let reloads = ReloadCounter()
        var waits = 0
        let sync = SnapshotSynchronizer(client: client, store: temp.store, reloadWidgets: { reloads.value += 1 }, retryDelay: {
            XCTAssertNil(SnapshotCheckpoint.load(from: temp.store))
            waits += 1
        })
        let outcome = await sync.sync()
        XCTAssertEqual(outcome, .applied(client.snapshot))
        XCTAssertEqual(client.requests.count, 2)
        XCTAssertEqual(waits, 1)
        XCTAssertEqual(reloads.value, 1)
        XCTAssertEqual(SnapshotCheckpoint.load(from: temp.store)?.etag, "revision-1")
    }

    func testRepeatedNetworkFailureStopsAfterTwoAttempts() async {
        let client = MockSnapshotClient(result: .failure(SnapshotClientError.network))
        let sync = SnapshotSynchronizer(client: client, store: nil, retryDelay: {})
        let outcome = await sync.sync()
        XCTAssertEqual(outcome, .failed(.network))
        XCTAssertEqual(client.callCount, 2)
    }

    func testAuthenticationFailureDoesNotRetry() async {
        let client = MockSnapshotClient(result: .failure(SnapshotClientError.unauthorized))
        let sync = SnapshotSynchronizer(client: client, store: nil, retryDelay: { XCTFail("認証エラーは再試行しない") })
        let outcome = await sync.sync()
        XCTAssertEqual(outcome, .failed(.unauthorized))
        XCTAssertEqual(client.callCount, 1)
    }

    func testLocalChangeInvalidatesCheckpointAndRequestsFullRepair() async throws {
        let temp = TempStore()
        defer { temp.cleanup() }
        let client = ConditionalSnapshotClient()
        let sync = SnapshotSynchronizer(client: client, store: temp.store)
        _ = await sync.sync()
        try temp.store.saveSnapshot(SnapshotFactory.solo())
        _ = await sync.sync()
        XCTAssertNil(client.requests.last!)
        XCTAssertEqual(temp.store.loadSnapshot(), client.snapshot)
    }

    func testConcurrentPushDoesNotAdvanceCheckpointToDiscardedResponse() async throws {
        let temp = TempStore()
        defer { temp.cleanup() }
        let client = ConditionalSnapshotClient()
        client.onFetch = {
            do { try temp.store.saveSnapshot(SnapshotFactory.solo()) }
            catch { XCTFail("割込みの書き込みに失敗: \(error)") }
        }
        let sync = SnapshotSynchronizer(client: client, store: temp.store)
        let outcome = await sync.sync()
        XCTAssertEqual(outcome, .skippedLocalChanged)
        XCTAssertNil(SnapshotCheckpoint.load(from: temp.store))
    }

    func testStorageFailureRetriesAndOnlyThenRecordsCheckpoint() async throws {
        let temp = TempStore()
        defer { temp.cleanup() }
        try Data().write(to: temp.directory)
        let client = ConditionalSnapshotClient()
        let reloads = ReloadCounter()
        let sync = SnapshotSynchronizer(client: client, store: temp.store, reloadWidgets: { reloads.value += 1 }, retryDelay: {
            XCTAssertNil(SnapshotCheckpoint.load(from: temp.store))
            try FileManager.default.removeItem(at: temp.directory)
        })
        let outcome = await sync.sync()
        XCTAssertEqual(outcome, .applied(client.snapshot))
        XCTAssertEqual(client.requests.count, 2)
        XCTAssertEqual(reloads.value, 1)
        temp.store.eraseAll()
        XCTAssertNil(SnapshotCheckpoint.load(from: temp.store))
    }

    func testSessionEndingDuringRetryCannotRestoreOldSnapshot() async {
        let client = MockSnapshotClient(result: .failure(SnapshotClientError.network))
        var active = true
        let sync = SnapshotSynchronizer(client: client, store: nil, canApply: { active }, retryDelay: { active = false })
        let outcome = await sync.sync()
        XCTAssertEqual(outcome, .skippedSessionEnded)
        XCTAssertEqual(client.callCount, 1)
    }
}
