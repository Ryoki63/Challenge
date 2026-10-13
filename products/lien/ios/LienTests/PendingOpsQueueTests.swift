// PendingOpsQueueTests.swift — オフラインキューの正規化+永続化(T14 / DESIGN §3.7)
//
// 検証対象(PendingOps.swift):
//   - 積む/読む round-trip(App Group = temp dir ストアの pending_ops.json)
//   - 同日 checkin の重複マージ(photoPath は新しい非 nil が勝ち、nil なら昇格維持)
//   - 同日 checkin → cancel の相殺(両方消える)
//   - cancel の同日重複は1件に集約
//   - 日付跨ぎ: 日付が違う op 同士は干渉しない
//   - 壊れた JSON は空キュー扱い(クラッシュしない・以後の enqueue は正常)

import XCTest
@testable import Lien

final class PendingOpsQueueTests: XCTestCase {
    /// temp dir ストア(各テストで defer により削除 — AppGroupStoreTests と同じイディオム)
    private func makeTempStore() -> (store: AppGroupStore, tempDir: URL) {
        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("PendingOpsTests-\(UUID().uuidString)", isDirectory: true)
        return (AppGroupStore(containerURL: tempDir), tempDir)
    }

    // MARK: 積む/読む(永続化 round-trip)

    func testEnqueuePersistsAcrossQueueInstances() {
        let (store, tempDir) = makeTempStore()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let queue = PendingOpsQueue(store: store)
        XCTAssertTrue(queue.isEmpty)
        queue.enqueue(.checkin(dateLocal: "2026-06-11", photoPath: nil))
        queue.enqueue(.checkinCancel(dateLocal: "2026-06-10"))

        // 別インスタンス(= アプリ再起動相当)から同じ内容が読める
        let reloaded = PendingOpsQueue(store: store)
        XCTAssertEqual(reloaded.load(), [
            .checkin(dateLocal: "2026-06-11", photoPath: nil),
            .checkinCancel(dateLocal: "2026-06-10"),
        ])
    }

    func testReplaceAllWithEmptyRemovesFile() {
        let (store, tempDir) = makeTempStore()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let queue = PendingOpsQueue(store: store)
        queue.enqueue(.checkin(dateLocal: "2026-06-11", photoPath: nil))
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.pendingOpsFileURL.path))

        queue.replaceAll([])
        XCTAssertTrue(queue.isEmpty)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: store.pendingOpsFileURL.path),
            "全送信成功(空キュー)はファイルごと破棄(AppGroupStore.clearPendingOps)"
        )
    }

    // MARK: 同日 checkin のマージ(photoPath 昇格)

    func testSameDayCheckinMergesAndPromotesPhotoPath() {
        let (store, tempDir) = makeTempStore()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let queue = PendingOpsQueue(store: store)

        // nil → nil: 1件のまま
        queue.enqueue(.checkin(dateLocal: "2026-06-11", photoPath: nil))
        queue.enqueue(.checkin(dateLocal: "2026-06-11", photoPath: nil))
        XCTAssertEqual(queue.load(), [.checkin(dateLocal: "2026-06-11", photoPath: nil)])

        // 写真付きで再 enqueue → photoPath 昇格
        queue.enqueue(.checkin(dateLocal: "2026-06-11", photoPath: "pairs/p1/2026-06-11/user-a/photo.jpg"))
        XCTAssertEqual(queue.load(), [
            .checkin(dateLocal: "2026-06-11", photoPath: "pairs/p1/2026-06-11/user-a/photo.jpg"),
        ])

        // photoPath nil の再 enqueue では昇格済みの写真を失わない
        queue.enqueue(.checkin(dateLocal: "2026-06-11", photoPath: nil))
        XCTAssertEqual(queue.load(), [
            .checkin(dateLocal: "2026-06-11", photoPath: "pairs/p1/2026-06-11/user-a/photo.jpg"),
        ])

        // 新しい photoPath は差し替え(その日1枚 — REQUIREMENTS §3.4。実際は同じパスへの上書きだが、ここでは別の文字列で差し替えを確かめる)
        queue.enqueue(.checkin(dateLocal: "2026-06-11", photoPath: "pairs/p1/2026-06-11/user-a/photo2.jpg"))
        XCTAssertEqual(queue.load(), [
            .checkin(dateLocal: "2026-06-11", photoPath: "pairs/p1/2026-06-11/user-a/photo2.jpg"),
        ])
    }

    // MARK: 同日 checkin → cancel の相殺

    func testSameDayCancelOffsetsPendingCheckin() {
        let (store, tempDir) = makeTempStore()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let queue = PendingOpsQueue(store: store)

        queue.enqueue(.checkin(dateLocal: "2026-06-11", photoPath: nil))
        XCTAssertTrue(queue.containsCheckin(dateLocal: "2026-06-11"))

        queue.enqueue(.checkinCancel(dateLocal: "2026-06-11"))
        XCTAssertTrue(queue.isEmpty, "未送信 checkin と当日 cancel は相殺(両方消える)")
    }

    func testCancelWithoutPendingCheckinIsQueuedOnce() {
        let (store, tempDir) = makeTempStore()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let queue = PendingOpsQueue(store: store)

        queue.enqueue(.checkinCancel(dateLocal: "2026-06-11"))
        queue.enqueue(.checkinCancel(dateLocal: "2026-06-11"))
        XCTAssertEqual(
            queue.load(),
            [.checkinCancel(dateLocal: "2026-06-11")],
            "同日 cancel は1件に集約(サーバーは冪等だが無駄送信しない)"
        )
    }

    func testCheckinAfterPendingCancelKeepsBothInOrder() {
        let (store, tempDir) = makeTempStore()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let queue = PendingOpsQueue(store: store)

        // 送信済みチェックインの取消がオフラインで残っている → さらにチェックインし直し
        queue.enqueue(.checkinCancel(dateLocal: "2026-06-11"))
        queue.enqueue(.checkin(dateLocal: "2026-06-11", photoPath: nil))

        XCTAssertEqual(queue.load(), [
            .checkinCancel(dateLocal: "2026-06-11"),
            .checkin(dateLocal: "2026-06-11", photoPath: nil),
        ], "cancel → checkin の順送信が正しい網結果(取消してから再チェックイン)")
    }

    // MARK: 日付跨ぎ(日付が違う op は干渉しない)

    func testOpsAcrossDifferentDatesDoNotInterfere() {
        let (store, tempDir) = makeTempStore()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let queue = PendingOpsQueue(store: store)

        // 前日のチェックインが未送信のまま日付が変わった
        queue.enqueue(.checkin(dateLocal: "2026-06-10", photoPath: nil))
        // 翌日の取消は前日の checkin と相殺**しない**(取り消しは当日中のみ — §3.4)
        queue.enqueue(.checkinCancel(dateLocal: "2026-06-11"))
        // 翌日のチェックインは前日の checkin とマージしない
        queue.enqueue(.checkin(dateLocal: "2026-06-11", photoPath: nil))

        XCTAssertEqual(queue.load(), [
            .checkin(dateLocal: "2026-06-10", photoPath: nil),
            .checkinCancel(dateLocal: "2026-06-11"),
            .checkin(dateLocal: "2026-06-11", photoPath: nil),
        ])
        XCTAssertTrue(queue.containsCheckin(dateLocal: "2026-06-10"))
        XCTAssertTrue(queue.containsCheckin(dateLocal: "2026-06-11"))
        XCTAssertFalse(queue.containsCheckin(dateLocal: "2026-06-12"))
    }

    // MARK: 端末の記録を消したあとの書き戻し(アカウントの削除・サインアウト — T23 #23)

    func testInvalidateClearsTheQueueAndRefusesWritesFromARunStartedBefore() {
        let (store, tempDir) = makeTempStore()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let queue = PendingOpsQueue(store: store)
        queue.enqueue(.checkin(dateLocal: "2026-06-10", photoPath: nil))
        queue.enqueue(.checkin(dateLocal: "2026-06-11", photoPath: nil))
        let generation = queue.generation // 再送の開始時に控える値

        queue.invalidate() // 再送の最中に、サインアウトで端末の記録を消した

        XCTAssertTrue(queue.isEmpty, "キューは捨てる")
        XCTAssertNotEqual(queue.generation, generation)
        let written = queue.replaceAll(
            [.checkin(dateLocal: "2026-06-11", photoPath: nil)],
            ifGeneration: generation
        )
        XCTAssertFalse(written, "消す前に始めた再送は、あとから古いキューを書き戻さない")
        XCTAssertTrue(queue.isEmpty)
    }

    func testReplaceAllWithTheCurrentGenerationWritesAsBefore() {
        let (store, tempDir) = makeTempStore()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let queue = PendingOpsQueue(store: store)
        queue.enqueue(.checkin(dateLocal: "2026-06-10", photoPath: nil))
        queue.enqueue(.checkin(dateLocal: "2026-06-11", photoPath: nil))

        let written = queue.replaceAll(
            [.checkin(dateLocal: "2026-06-11", photoPath: nil)],
            ifGeneration: queue.generation
        )

        XCTAssertTrue(written)
        XCTAssertEqual(queue.load(), [.checkin(dateLocal: "2026-06-11", photoPath: nil)])
        // 世代を渡さない書き方(従来)も同じ
        XCTAssertTrue(queue.replaceAll([]))
        XCTAssertTrue(queue.isEmpty)
    }

    func testNewRunsAfterInvalidateWriteNormally() {
        let (store, tempDir) = makeTempStore()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let queue = PendingOpsQueue(store: store)
        queue.invalidate()

        // 次のアカウントの操作は、新しい世代で普通に積める・書ける
        queue.enqueue(.checkin(dateLocal: "2026-06-11", photoPath: nil))
        XCTAssertTrue(queue.replaceAll([], ifGeneration: queue.generation))
        XCTAssertTrue(queue.isEmpty)
    }

    // MARK: 壊れた JSON への耐性

    func testCorruptedFileIsTreatedAsEmptyQueue() throws {
        let (store, tempDir) = makeTempStore()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        try Data("{{not json".utf8).write(to: store.pendingOpsFileURL)

        let queue = PendingOpsQueue(store: store)
        XCTAssertEqual(queue.load(), [], "壊れた JSON は空キュー扱い(クラッシュしない)")

        // 以後の enqueue は正常に上書きされる
        queue.enqueue(.checkin(dateLocal: "2026-06-11", photoPath: nil))
        XCTAssertEqual(queue.load(), [.checkin(dateLocal: "2026-06-11", photoPath: nil)])
    }
}
