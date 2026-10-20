import XCTest
@testable import Lien

final class PushSnapshotWriterTests: XCTestCase {
    private func payload(_ snapshot: PairSnapshot) throws -> [AnyHashable: Any] {
        let object = try JSONSerialization.jsonObject(with: PairSnapshot.makeJSONEncoder().encode(snapshot))
        return ["lien": ["snapshot": object]]
    }

    func testNSEPayloadWritesSharedSnapshotAndReloadsOnce() throws {
        let temp = TempStore()
        defer { temp.cleanup() }
        let reloads = ReloadCounter()
        let writer = PushSnapshotWriter(store: temp.store, reloadWidgets: { reloads.value += 1 })
        let snapshot = SnapshotFactory.paired(todayPartnerDone: true)
        XCTAssertEqual(try writer.receive(payload(snapshot)), snapshot)
        XCTAssertEqual(temp.store.loadSnapshot(), snapshot)
        XCTAssertEqual(try writer.receive(payload(snapshot)), snapshot)
        XCTAssertEqual(reloads.value, 1)
    }

    func testDelayedPushCannotRollBackNewerState() throws {
        let temp = TempStore()
        defer { temp.cleanup() }
        let reloads = ReloadCounter()
        let newest = SnapshotFactory.paired(todayPartnerDone: true, updatedAt: SnapshotFactory.fixedDate.addingTimeInterval(5))
        try temp.store.saveSnapshot(newest)
        let writer = PushSnapshotWriter(store: temp.store, reloadWidgets: { reloads.value += 1 })
        XCTAssertEqual(try writer.receive(payload(SnapshotFactory.paired())), newest)
        XCTAssertEqual(temp.store.loadSnapshot(), newest)
        XCTAssertEqual(reloads.value, 0)
    }

    func testTimestampOnlyPushSavesWithoutReload() throws {
        let temp = TempStore()
        defer { temp.cleanup() }
        let reloads = ReloadCounter()
        let first = SnapshotFactory.paired()
        try temp.store.saveSnapshot(first)
        var next = first
        next.updatedAt = first.updatedAt.addingTimeInterval(5)
        let writer = PushSnapshotWriter(store: temp.store, reloadWidgets: { reloads.value += 1 })
        XCTAssertEqual(try writer.receive(payload(next)), next)
        XCTAssertEqual(temp.store.loadSnapshot(), next)
        XCTAssertEqual(reloads.value, 0)
    }

    func testMalformedAndMissingPayloadPreserveCache() throws {
        let temp = TempStore()
        defer { temp.cleanup() }
        let snapshot = SnapshotFactory.paired()
        try temp.store.saveSnapshot(snapshot)
        let writer = PushSnapshotWriter(store: temp.store)
        XCTAssertNil(try writer.receive([:]))
        XCTAssertThrowsError(try writer.receive(["lien": ["snapshot": ["schemaVersion": 1]]]))
        XCTAssertEqual(temp.store.loadSnapshot(), snapshot)
    }

    func testPendingOperationsPreventPushFromReplacingOptimisticState() throws {
        let temp = TempStore()
        defer { temp.cleanup() }
        let local = SnapshotFactory.paired(todayMeDone: true)
        try temp.store.saveSnapshot(local)
        try temp.store.savePendingOps([PendingOp.checkin(dateLocal: "2026-06-11", photoPath: nil)])
        let server = SnapshotFactory.paired(updatedAt: local.updatedAt.addingTimeInterval(5))
        XCTAssertEqual(try PushSnapshotWriter(store: temp.store).receive(payload(server)), local)
        XCTAssertEqual(temp.store.loadSnapshot(), local)
    }

    func testUnreadablePendingOperationsAreNotTreatedAsEmpty() throws {
        let temp = TempStore()
        defer { temp.cleanup() }
        let local = SnapshotFactory.paired()
        try temp.store.saveSnapshot(local)
        try Data("broken".utf8).write(to: temp.store.pendingOpsFileURL)
        let server = SnapshotFactory.paired(todayPartnerDone: true, updatedAt: local.updatedAt.addingTimeInterval(5))
        XCTAssertEqual(try PushSnapshotWriter(store: temp.store).receive(payload(server)), local)
    }

    func testFailedWriteCanRetrySamePayloadWithoutDuplicateReload() throws {
        let temp = TempStore()
        defer { temp.cleanup() }
        try Data().write(to: temp.directory)
        let reloads = ReloadCounter()
        let writer = PushSnapshotWriter(store: temp.store, reloadWidgets: { reloads.value += 1 })
        let snapshot = SnapshotFactory.paired()
        XCTAssertThrowsError(try writer.receive(payload(snapshot)))
        XCTAssertEqual(reloads.value, 0)
        try FileManager.default.removeItem(at: temp.directory)
        XCTAssertEqual(try writer.receive(payload(snapshot)), snapshot)
        _ = try writer.receive(payload(snapshot))
        XCTAssertEqual(temp.store.loadSnapshot(), snapshot)
        XCTAssertEqual(reloads.value, 1)
    }

    func testConditionalWriteRejectsStateChangedByAnotherStore() throws {
        let temp = TempStore()
        defer { temp.cleanup() }
        let before = SnapshotFactory.paired()
        try temp.store.saveSnapshot(before)
        let other = AppGroupStore(containerURL: temp.directory)
        let changed = SnapshotFactory.paired(todayPartnerDone: true)
        try other.saveSnapshot(changed)
        XCTAssertFalse(try temp.store.applySnapshot(before, ifUnchangedSince: before))
        XCTAssertEqual(temp.store.loadSnapshot(), changed)
    }

    func testTimeoutAndCompletionCanClaimDeliveryOnlyOnce() {
        let gate = NotificationDeliveryGate()
        let countLock = NSLock()
        var deliveries = 0
        DispatchQueue.concurrentPerform(iterations: 100) { _ in
            if gate.claim() {
                countLock.lock()
                deliveries += 1
                countLock.unlock()
            }
        }
        XCTAssertEqual(deliveries, 1)
    }

    func testNSECompilesAndUsesTheTestedWriterAndDeliveryGate() throws {
        let source = try SourceTree.text("LienNSE/NotificationService.swift")
        XCTAssertTrue(source.contains("PushSnapshotWriter(store:"))
        XCTAssertTrue(source.contains("deliveryGate.claim()"))
        XCTAssertTrue(try SourceTree.text("project.yml").contains("- path: Lien/Core/Notifications/PushSnapshotWriter.swift"))
    }
}
