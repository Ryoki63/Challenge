// AppGroupStoreTests.swift — App Group ストアの往復検証(temp dir 注入。T07)

import XCTest
@testable import Lien

final class AppGroupStoreTests: XCTestCase {
    private var tempDir: URL!
    private var store: AppGroupStore!

    override func setUpWithError() throws {
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("AppGroupStoreTests-\(UUID().uuidString)", isDirectory: true)
        store = AppGroupStore(containerURL: tempDir)
    }

    override func tearDownWithError() throws {
        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
    }

    private func makeSnapshot(streak: Int = 23) -> PairSnapshot {
        PairSnapshot(
            schemaVersion: PairSnapshot.currentSchemaVersion,
            pairId: "1f0c5a4e-9d3b-4c1a-8f2e-7b6d5a4c3b2a",
            updatedAt: Date(timeIntervalSince1970: 1_781_166_600), // 2026-06-11T08:30:00Z
            streakCurrent: streak,
            streakBest: 40,
            todayMeDone: true,
            todayPartnerDone: false,
            myPromiseTitle: "筋トレ",
            myPromiseEmoji: "💪",
            partnerName: "ゆうき",
            partnerPromiseTitle: "ランニング",
            partnerPromiseEmoji: "🏃",
            plantStage: 3,
            plantMood: .fidget,
            plantName: "みどり",
            hasPartnerPhotoToday: false
        )
    }

    // MARK: - pair_snapshot.json

    func testLoadSnapshotReturnsNilWhenFileMissing() {
        XCTAssertNil(store.loadSnapshot())
    }

    func testSaveAndLoadSnapshotRoundTrip() throws {
        let original = makeSnapshot()
        try store.saveSnapshot(original)

        let loaded = try XCTUnwrap(store.loadSnapshot())
        XCTAssertEqual(loaded, original)

        // ファイル名は契約どおり pair_snapshot.json(DESIGN §3.4)
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: tempDir.appendingPathComponent("pair_snapshot.json").path
            )
        )
    }

    func testSaveSnapshotOverwritesPrevious() throws {
        try store.saveSnapshot(makeSnapshot(streak: 1))
        try store.saveSnapshot(makeSnapshot(streak: 2))
        XCTAssertEqual(store.loadSnapshot()?.streakCurrent, 2)
    }

    func testSaveSnapshotDataValidatesAndWrites() throws {
        let json = """
        { "schemaVersion": 1, "updatedAt": "2026-06-11T08:30:00Z", "streakCurrent": 7 }
        """
        let saved = try store.saveSnapshotData(Data(json.utf8))
        XCTAssertEqual(saved.streakCurrent, 7)
        XCTAssertEqual(store.loadSnapshot()?.streakCurrent, 7)
    }

    func testSaveSnapshotDataRejectsCorruptPayloadAndKeepsExisting() throws {
        // 正常な snapshot を保存しておく
        try store.saveSnapshot(makeSnapshot(streak: 23))

        // 壊れたペイロード(updatedAt 欠落 / JSON 破損)は throw し、既存ファイルを潰さない
        XCTAssertThrowsError(try store.saveSnapshotData(Data("{ \"schemaVersion\": 1 }".utf8)))
        XCTAssertThrowsError(try store.saveSnapshotData(Data("not-json".utf8)))
        XCTAssertEqual(store.loadSnapshot()?.streakCurrent, 23)
    }

    func testLoadSnapshotReturnsNilForCorruptFile() throws {
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        try Data("garbage".utf8).write(to: store.snapshotFileURL, options: [.atomic])
        XCTAssertNil(store.loadSnapshot())
    }

    // MARK: - pending_ops.json(型の確定は T14。ここでは汎用 API の往復のみ)

    func testPendingOpsRoundTripAndClear() throws {
        XCTAssertNil(store.loadPendingOps([String].self))

        try store.savePendingOps(["op-1", "op-2"])
        XCTAssertEqual(store.loadPendingOps([String].self), ["op-1", "op-2"])

        try store.clearPendingOps()
        XCTAssertNil(store.loadPendingOps([String].self))

        // 2回連続で呼んでもエラーにならない(冪等)
        XCTAssertNoThrow(try store.clearPendingOps())
    }

    func testSnapshotAndPendingOpsAreSeparateFiles() throws {
        try store.saveSnapshot(makeSnapshot())
        try store.savePendingOps(["op-1"])
        XCTAssertNotEqual(store.snapshotFileURL, store.pendingOpsFileURL)
        XCTAssertNotNil(store.loadSnapshot())
        XCTAssertEqual(store.loadPendingOps([String].self), ["op-1"])
    }
}
