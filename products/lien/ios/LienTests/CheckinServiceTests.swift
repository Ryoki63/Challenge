// CheckinServiceTests.swift — 実 API+オフラインキューのチェックインフロー(T14)
//
// 検証対象(CheckinService.swift):
//   - 成功: サーバー snapshot が正(楽観値を上書き)+キューは空
//   - オフライン: 楽観更新を維持して成功扱い+キュー残存 → 後の flush 成功でキューが空になり
//     サーバー snapshot が正になる(DESIGN §3.7)
//   - 4xx 拒否(409 no_promise 等): op 破棄+throw(楽観値を返さない)
//   - 当日取消: 成功/オフライン/未送信 checkin との相殺(API を呼ばない)
//   - 日付跨ぎ後の旧 cancel は flush で 400 破棄(キューに残り続けない)
//   - 写真添付: 縮小 → 署名URL取得 → 2本アップロード → photoPath 付き再送 / ソロは no_pair

import XCTest
@testable import Lien

// MARK: - モック API(トップレベル: テストクラスの @MainActor 隔離を継承させない)

private final class MockCheckinAPIClient: CheckinAPIClient {
    enum Mode {
        /// 成功(サーバー側状態を更新して snapshot を返す)
        case success
        /// 通信エラー(オフライン)
        case offline
        /// 拒否応答(4xx/409)
        case reject(CheckinClientError)
    }

    var mode: Mode = .success
    /// サーバー側の「自分視点 snapshot」。成功応答の基礎(streakCurrent で楽観値と区別する)
    var serverSnapshot: PairSnapshot
    /// cancel だけ別モードにしたいとき(nil なら mode と同じ)
    var cancelMode: Mode?

    private(set) var checkinCalls: [(dateLocal: String, photoPath: String?, requestPhotoUpload: Bool)] = []
    private(set) var cancelCalls: [String] = []
    private(set) var uploads: [(byteCount: Int, target: PhotoUploadTarget)] = []

    init(serverSnapshot: PairSnapshot) {
        self.serverSnapshot = serverSnapshot
    }

    func checkin(
        dateLocal: String,
        photoPath: String?,
        requestPhotoUpload: Bool
    ) async throws -> CheckinResponse {
        checkinCalls.append((dateLocal, photoPath, requestPhotoUpload))
        switch mode {
        case .offline: throw CheckinClientError.network
        case .reject(let error): throw error
        case .success:
            let already = serverSnapshot.todayMeDone
            serverSnapshot.todayMeDone = true
            var photoUpload: PhotoUploadURLs?
            if requestPhotoUpload {
                guard let pairId = serverSnapshot.pairId else { throw CheckinClientError.noPair }
                let dir = "pairs/\(pairId)/\(dateLocal)"
                photoUpload = PhotoUploadURLs(
                    photo: PhotoUploadTarget(path: "\(dir)/photo.jpg", token: "t1"),
                    thumb: PhotoUploadTarget(path: "\(dir)/photo_thumb.jpg", token: "t2")
                )
            }
            return CheckinResponse(
                alreadyCheckedIn: already,
                snapshot: serverSnapshot,
                photoUpload: photoUpload
            )
        }
    }

    func cancelCheckin(dateLocal: String) async throws -> CheckinCancelResponse {
        cancelCalls.append(dateLocal)
        switch cancelMode ?? mode {
        case .offline: throw CheckinClientError.network
        case .reject(let error): throw error
        case .success:
            let already = !serverSnapshot.todayMeDone
            serverSnapshot.todayMeDone = false
            return CheckinCancelResponse(alreadyCanceled: already, snapshot: serverSnapshot)
        }
    }

    func uploadPhoto(_ data: Data, to target: PhotoUploadTarget) async throws {
        switch mode {
        case .offline: throw CheckinClientError.network
        case .reject(let error): throw error
        case .success: uploads.append((data.count, target))
        }
    }
}

// MARK: - テスト本体

final class CheckinServiceTests: XCTestCase {
    /// 固定の「今日」(2026-06-11T08:30:00Z)。dateLocal は端末ローカル TZ(DayBoundary)で
    /// 導出するため、テストも同じ関数で today / yesterday を計算する(CI の TZ に依存しない)
    private let fixedNow = Date(timeIntervalSince1970: 1_781_166_600)
    private var today: String {
        DayBoundary.dateLocalString(for: fixedNow)
    }
    private var yesterday: String {
        let date = Calendar.current.date(byAdding: .day, value: -1, to: fixedNow) ?? fixedNow
        return DayBoundary.dateLocalString(for: date)
    }

    private func makeSnapshot(
        pairId: String? = "pair-1",
        todayMeDone: Bool = false,
        todayPartnerDone: Bool = false,
        streakCurrent: Int = 23,
        plantMood: PlantMood = .normal
    ) -> PairSnapshot {
        PairSnapshot(
            schemaVersion: PairSnapshot.currentSchemaVersion,
            pairId: pairId,
            updatedAt: fixedNow,
            streakCurrent: streakCurrent,
            streakBest: 40,
            todayMeDone: todayMeDone,
            todayPartnerDone: todayPartnerDone,
            myPromiseTitle: "筋トレ",
            myPromiseEmoji: "💪",
            partnerName: "ゆうき",
            partnerPromiseTitle: "ランニング",
            partnerPromiseEmoji: "🏃",
            plantStage: 3,
            plantMood: plantMood,
            plantName: "みどり",
            hasPartnerPhotoToday: false
        )
    }

    /// temp dir ストア+モック API+サービス一式
    private func makeService(
        serverSnapshot: PairSnapshot
    ) -> (service: CheckinService, api: MockCheckinAPIClient, queue: PendingOpsQueue, tempDir: URL) {
        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("CheckinServiceTests-\(UUID().uuidString)", isDirectory: true)
        let store = AppGroupStore(containerURL: tempDir)
        let queue = PendingOpsQueue(store: store)
        let api = MockCheckinAPIClient(serverSnapshot: serverSnapshot)
        let now = fixedNow
        let service = CheckinService(
            api: api,
            queue: queue,
            now: { now },
            processPhoto: { data in
                // テストでは ImageIO を使わない軽量スタブ(縮小済みとみなす)
                ProcessedPhoto(photo: data, thumb: Data(data.prefix(10)))
            }
        )
        return (service, api, queue, tempDir)
    }

    // MARK: チェックイン: 成功(サーバー snapshot が正)

    func testCheckinSuccessReturnsServerSnapshotAndEmptiesQueue() async throws {
        // サーバーは streakCurrent=24 を返す(楽観値 23 と区別できる)
        let server = makeSnapshot(todayMeDone: false, streakCurrent: 24)
        let (service, api, queue, tempDir) = makeService(serverSnapshot: server)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let result = try await service.performCheckin(current: makeSnapshot())

        XCTAssertEqual(api.checkinCalls.count, 1)
        XCTAssertEqual(api.checkinCalls[0].dateLocal, today)
        XCTAssertNil(api.checkinCalls[0].photoPath)
        XCTAssertFalse(api.checkinCalls[0].requestPhotoUpload)
        XCTAssertTrue(result.todayMeDone)
        XCTAssertEqual(result.streakCurrent, 24, "サーバー snapshot が正(楽観値を上書き)")
        XCTAssertTrue(queue.isEmpty, "送信成功で op はキューから消える")
    }

    // MARK: チェックイン: オフライン(楽観更新維持+キュー残存 → flush で同期)

    func testOfflineCheckinKeepsOptimisticUpdateAndQueuesOp() async throws {
        let (service, api, queue, tempDir) = makeService(serverSnapshot: makeSnapshot())
        defer { try? FileManager.default.removeItem(at: tempDir) }
        api.mode = .offline

        let result = try await service.performCheckin(
            current: makeSnapshot(todayPartnerDone: true)
        )

        XCTAssertTrue(result.todayMeDone, "オフラインでも完了扱い(楽観更新 — REQUIREMENTS §3.4)")
        XCTAssertEqual(result.plantMood, .happy, "両者完了の演出はローカルでも出す")
        XCTAssertEqual(result.streakCurrent, 23, "ストリーク数はローカルで触らない(DESIGN §5.4)")
        XCTAssertEqual(
            queue.load(),
            [.checkin(dateLocal: today, photoPath: nil)],
            "未送信 op がキューに残る"
        )

        // 接続回復 → flush 成功でキューが空になり、サーバー snapshot が正になる
        api.mode = .success
        api.serverSnapshot = makeSnapshot(todayMeDone: false, streakCurrent: 24)
        let flushed = await service.flushPendingOps()

        XCTAssertEqual(flushed?.todayMeDone, true)
        XCTAssertEqual(flushed?.streakCurrent, 24)
        XCTAssertTrue(queue.isEmpty)
        XCTAssertEqual(api.checkinCalls.count, 2, "(失敗1+再送1)")
        XCTAssertEqual(api.checkinCalls[1].dateLocal, today, "再送は同じ dateLocal(冪等 — DESIGN §5.5)")
    }

    func testFlushWithEmptyQueueDoesNothing() async {
        let (service, api, _, tempDir) = makeService(serverSnapshot: makeSnapshot())
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let flushed = await service.flushPendingOps()

        XCTAssertNil(flushed)
        XCTAssertEqual(api.checkinCalls.count, 0)
        XCTAssertEqual(api.cancelCalls.count, 0)
    }

    // MARK: チェックイン: 拒否応答(4xx/409)は op 破棄+throw

    func testRejectedCheckinThrowsAndDropsOp() async {
        let (service, api, queue, tempDir) = makeService(serverSnapshot: makeSnapshot())
        defer { try? FileManager.default.removeItem(at: tempDir) }
        api.mode = .reject(.noPromise)

        do {
            _ = try await service.performCheckin(current: makeSnapshot())
            XCTFail("409 no_promise は throw すべき")
        } catch let error as CheckinClientError {
            XCTAssertEqual(error, .noPromise)
        } catch {
            XCTFail("予期しないエラー型: \(error)")
        }
        XCTAssertTrue(queue.isEmpty, "拒否された op は再送しない(破棄)")
    }

    // MARK: 当日取消

    func testCancelSuccessReturnsServerSnapshot() async throws {
        let server = makeSnapshot(todayMeDone: true, streakCurrent: 24)
        let (service, api, queue, tempDir) = makeService(serverSnapshot: server)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let result = try await service.cancelCheckin(
            current: makeSnapshot(todayMeDone: true, todayPartnerDone: true, plantMood: .happy)
        )

        XCTAssertEqual(api.cancelCalls, [today], "取消は今日の dateLocal で送る(当日のみ — §3.4)")
        XCTAssertFalse(result.todayMeDone)
        XCTAssertEqual(result.streakCurrent, 24, "サーバー snapshot が正")
        XCTAssertTrue(queue.isEmpty)
    }

    func testOfflineCancelKeepsOptimisticUpdateAndQueuesOp() async throws {
        let (service, api, queue, tempDir) = makeService(serverSnapshot: makeSnapshot())
        defer { try? FileManager.default.removeItem(at: tempDir) }
        api.mode = .offline

        let result = try await service.cancelCheckin(
            current: makeSnapshot(todayMeDone: true, todayPartnerDone: true, plantMood: .happy)
        )

        XCTAssertFalse(result.todayMeDone, "オフラインでも取消は即時反映")
        XCTAssertEqual(result.plantMood, .fidget, "ふたり達成 → 相手待ちの表情へ戻す")
        XCTAssertEqual(queue.load(), [.checkinCancel(dateLocal: today)])
    }

    func testCancelOffsetsPendingCheckinWithoutAPICall() async throws {
        let (service, api, queue, tempDir) = makeService(serverSnapshot: makeSnapshot())
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // オフラインでチェックイン(キューに残る)→ そのまま取消
        api.mode = .offline
        _ = try await service.performCheckin(current: makeSnapshot())
        XCTAssertEqual(api.checkinCalls.count, 1)

        let result = try await service.cancelCheckin(current: makeSnapshot(todayMeDone: true))

        XCTAssertFalse(result.todayMeDone)
        XCTAssertTrue(queue.isEmpty, "未送信 checkin と相殺(両方消える)")
        XCTAssertEqual(api.cancelCalls.count, 0, "サーバーは元から未記録なので cancel を送らない")
    }

    func testStaleCancelIsDroppedOnFlushAfterDayBoundary() async {
        // 日付跨ぎで前日の cancel が残った → サーバーは 400 date_local_not_today
        // → flush は op を破棄して以後のリトライループに陥らない(snapshot 自己修復に委ねる)
        let (service, api, queue, tempDir) = makeService(serverSnapshot: makeSnapshot())
        defer { try? FileManager.default.removeItem(at: tempDir) }
        queue.enqueue(.checkinCancel(dateLocal: yesterday)) // 前日分
        api.mode = .reject(.notToday)

        let flushed = await service.flushPendingOps()

        XCTAssertNil(flushed, "拒否のみで snapshot は得られない")
        XCTAssertTrue(queue.isEmpty, "400 の op は破棄(再送しても結果不変)")
        XCTAssertEqual(api.cancelCalls, [yesterday])
    }

    // MARK: flush の順序と部分成功

    func testFlushStopsOnNetworkErrorAndKeepsRemainingOps() async {
        let (service, api, queue, tempDir) = makeService(serverSnapshot: makeSnapshot())
        defer { try? FileManager.default.removeItem(at: tempDir) }
        // 前日 checkin(成功する)+ 今日 cancel(オフラインで中断)
        queue.enqueue(.checkin(dateLocal: yesterday, photoPath: nil))
        queue.enqueue(.checkinCancel(dateLocal: today))
        api.cancelMode = .offline

        let flushed = await service.flushPendingOps()

        XCTAssertNotNil(flushed, "成功した checkin の snapshot は得られる")
        XCTAssertEqual(api.checkinCalls.count, 1)
        XCTAssertEqual(
            queue.load(),
            [.checkinCancel(dateLocal: today)],
            "通信エラーの op は残す(次回 flush で再送 — DESIGN §3.7)"
        )
    }

    // MARK: 写真添付(DESIGN §5.6)

    func testAttachPhotoUploadsBothObjectsThenResendsWithPhotoPath() async throws {
        let server = makeSnapshot(todayMeDone: true, streakCurrent: 24)
        let (service, api, _, tempDir) = makeService(serverSnapshot: server)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let imageData = Data(repeating: 0xAB, count: 100)
        let result = try await service.attachPhoto(
            current: makeSnapshot(todayMeDone: true),
            imageData: imageData
        )

        // 1回目: 署名URL要求 / 2回目: photoPath 付き再送
        XCTAssertEqual(api.checkinCalls.count, 2)
        XCTAssertTrue(api.checkinCalls[0].requestPhotoUpload)
        XCTAssertNil(api.checkinCalls[0].photoPath)
        XCTAssertFalse(api.checkinCalls[1].requestPhotoUpload)
        XCTAssertEqual(api.checkinCalls[1].photoPath, "pairs/pair-1/\(today)/photo.jpg")

        // 原寸+サムネの2本(processPhoto スタブ: 原寸 100B / サムネ 10B)
        XCTAssertEqual(api.uploads.count, 2)
        XCTAssertEqual(api.uploads[0].target.path, "pairs/pair-1/\(today)/photo.jpg")
        XCTAssertEqual(api.uploads[0].byteCount, 100)
        XCTAssertEqual(api.uploads[1].target.path, "pairs/pair-1/\(today)/photo_thumb.jpg")
        XCTAssertEqual(api.uploads[1].byteCount, 10)

        XCTAssertEqual(result.streakCurrent, 24, "最終応答のサーバー snapshot を返す")
    }

    func testAttachPhotoOnSoloThrowsNoPair() async {
        let (service, api, _, tempDir) = makeService(serverSnapshot: makeSnapshot(pairId: nil))
        defer { try? FileManager.default.removeItem(at: tempDir) }

        do {
            _ = try await service.attachPhoto(
                current: makeSnapshot(pairId: nil, todayMeDone: true),
                imageData: Data([0x01])
            )
            XCTFail("ソロは no_pair で拒否すべき(写真の置き場所が無い — DESIGN §5.6)")
        } catch let error as CheckinClientError {
            XCTAssertEqual(error, .noPair)
        } catch {
            XCTFail("予期しないエラー型: \(error)")
        }
        XCTAssertEqual(api.checkinCalls.count, 0, "API を呼ぶ前にクライアント側で拒否")
    }

    func testAttachPhotoOfflineThrowsWithoutQueueing() async {
        // 写真はオンライン専用(バイナリをキューに持たない)。失敗は throw → ユーザー再試行
        let (service, api, queue, tempDir) = makeService(serverSnapshot: makeSnapshot())
        defer { try? FileManager.default.removeItem(at: tempDir) }
        api.mode = .offline

        do {
            _ = try await service.attachPhoto(
                current: makeSnapshot(todayMeDone: true),
                imageData: Data([0x01])
            )
            XCTFail("オフラインの写真添付は throw すべき")
        } catch let error as CheckinClientError {
            XCTAssertEqual(error, .network)
        } catch {
            XCTFail("予期しないエラー型: \(error)")
        }
        XCTAssertTrue(queue.isEmpty, "写真 op はキューに積まない")
    }
}
