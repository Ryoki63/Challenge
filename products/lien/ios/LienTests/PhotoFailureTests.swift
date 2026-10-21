// PhotoFailureTests.swift — 写真取込の異常入力と保存失敗で既存状態が壊れないこと(issue #307)
//
// 検証対象:
//   - 破損 JPEG / 非画像(PCM WAV)を製品の PhotoProcessor が unreadableImage で拒否する
//   - CheckinService が縮小段階で失敗したとき、API を呼ばずキューにも積まない
//   - AppGroupStore のアトミック書込みが失敗しても、既存の pair_snapshot.json の bytes が変わらない
//   - HomeViewModel が写真添付失敗後も約束・履歴・旧写真 marker を保持し、再試行できる
//
// fixture の出所: solo-company PR #310 / docs/qa/evidence/307/run-2026-10-21-submission/
//   truncated-photo.jpg (32B, SHA-256 6bfe5b21973943d397719ea0e49a6af3ac63bd29e3491aaae833c4db572540da)
//   valid-audio-not-image.wav (PCM WAV の先頭 44B。画像デコーダには渡せない)
// 実データ・実アカウント・本番 Storage は使わない。

import XCTest
import CoreGraphics
import Foundation
import ImageIO
@testable import Lien

/// 呼ばれたら失敗させる API(異常入力が API 到達前に止まることを数える)
private final class NeverCalledCheckinAPI: CheckinAPIClient {
    private(set) var checkinCallCount = 0
    private(set) var uploadCallCount = 0

    func checkin(
        dateLocal: String,
        photoPath: String?,
        requestPhotoUpload: Bool
    ) async throws -> CheckinResponse {
        checkinCallCount += 1
        throw CheckinClientError.server(code: "must_not_call")
    }

    func cancelCheckin(dateLocal: String) async throws -> CheckinCancelResponse {
        throw CheckinClientError.server(code: "must_not_call")
    }

    func uploadPhoto(_ data: Data, to target: PhotoUploadTarget) async throws {
        uploadCallCount += 1
        throw CheckinClientError.server(code: "must_not_call")
    }
}

/// 実画像を処理して成功する写真添付サービス(再試行の検証用)
private final class FlakyPhotoService: CheckinPerforming, PhotoAttaching {
    private(set) var attachCallCount = 0

    func performCheckin(current: PairSnapshot) async throws -> PairSnapshot {
        current
    }

    func attachPhoto(current: PairSnapshot, imageData: Data) async throws -> PairSnapshot {
        attachCallCount += 1
        // 製品と同じく、まず画像処理を通す(破損入力はここで throw する)
        _ = try PhotoProcessor.process(imageData)
        var updated = current
        updated.hasPartnerPhotoToday = true
        updated.streakCurrent = current.streakCurrent + 1
        updated.updatedAt = current.updatedAt.addingTimeInterval(60)
        return updated
    }
}

@MainActor
final class PhotoFailureTests: XCTestCase {
    private let truncatedJPEG = Data([
        0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0x4A, 0x46, 0x49, 0x46, 0x00, 0x01,
        0x01, 0x00, 0x00, 0x48, 0x00, 0x48, 0x00, 0x00, 0xFF, 0xE1, 0x00, 0x4C,
        0x45, 0x78, 0x69, 0x66, 0x00, 0x00, 0x4D, 0x4D,
    ])

    /// PCM WAV の先頭 44 bytes(RIFF/WAVE/fmt/data)。画像フォーマットではない
    private let wavHeader = Data([
        0x52, 0x49, 0x46, 0x46, 0x64, 0x06, 0x00, 0x00, 0x57, 0x41, 0x56, 0x45,
        0x66, 0x6D, 0x74, 0x20, 0x10, 0x00, 0x00, 0x00, 0x01, 0x00, 0x01, 0x00,
        0x40, 0x1F, 0x00, 0x00, 0x80, 0x3E, 0x00, 0x00, 0x02, 0x00, 0x10, 0x00,
        0x64, 0x61, 0x74, 0x61, 0x40, 0x06, 0x00, 0x00,
    ])

    private func makeTempDir(_ name: String) -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
    }

    private func makeSnapshot(
        hasPartnerPhotoToday: Bool = true,
        streakCurrent: Int = 23
    ) -> PairSnapshot {
        PairSnapshot(
            schemaVersion: PairSnapshot.currentSchemaVersion,
            pairId: "pair-307",
            updatedAt: Date(timeIntervalSince1970: 1_781_166_600),
            streakCurrent: streakCurrent,
            streakBest: 40,
            todayMeDone: true,
            todayPartnerDone: false,
            myPromiseTitle: "筋トレ",
            myPromiseEmoji: "💪",
            partnerName: "ゆうき",
            partnerPromiseTitle: "ランニング",
            partnerPromiseEmoji: "🏃",
            plantStage: 3,
            plantMood: .normal,
            plantName: "みどり",
            hasPartnerPhotoToday: hasPartnerPhotoToday
        )
    }

    /// PhotoProcessor が通る最小の有効 JPEG(JPEG エンコードは CoreGraphics に任せる)
    private func makeValidJPEG() throws -> Data {
        let width = 32
        let height = 24
        var pixels = [UInt8](repeating: 0x80, count: width * height * 4)
        for i in stride(from: 3, to: pixels.count, by: 4) { pixels[i] = 0xFF }
        let provider = try XCTUnwrap(CGDataProvider(data: Data(pixels) as CFData))
        let image = try XCTUnwrap(CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        ))
        let output = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(
            output as CFMutableData, "public.jpeg" as CFString, 1, nil
        ))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return output as Data
    }

    // MARK: 受入条件① 破損画像・非対応形式

    func testTruncatedJPEGIsRejectedAsUnreadable() {
        XCTAssertThrowsError(try PhotoProcessor.process(truncatedJPEG)) { error in
            XCTAssertEqual(error as? PhotoProcessor.ProcessError, .unreadableImage)
        }
    }

    func testPCMWAVIsRejectedAsUnsupportedImage() {
        XCTAssertThrowsError(try PhotoProcessor.process(wavHeader)) { error in
            XCTAssertEqual(error as? PhotoProcessor.ProcessError, .unreadableImage)
        }
    }

    func testCorruptPhotoStopsBeforeAnyAPICallOrQueueWrite() async throws {
        let tempDir = makeTempDir("PhotoFailure-Checkin")
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let store = AppGroupStore(containerURL: tempDir)
        let queue = PendingOpsQueue(store: store)
        let api = NeverCalledCheckinAPI()
        let service = CheckinService(api: api, queue: queue)

        do {
            _ = try await service.attachPhoto(
                current: makeSnapshot(),
                imageData: truncatedJPEG
            )
            XCTFail("破損 JPEG は縮小段階で拒否すべき")
        } catch {
            XCTAssertEqual(error as? PhotoProcessor.ProcessError, .unreadableImage)
        }

        XCTAssertEqual(api.checkinCallCount, 0, "縮小失敗後に署名 URL を取りに行かない")
        XCTAssertEqual(api.uploadCallCount, 0, "壊れた画像をアップロードしない")
        XCTAssertTrue(queue.isEmpty, "写真バイナリはキューに積まない")
    }

    // MARK: 受入条件① ローカル書込み失敗

    func testSnapshotWriteFailureLeavesPreviousBytesUntouched() throws {
        let tempDir = makeTempDir("PhotoFailure-Store")
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: tempDir.path
            )
            try? FileManager.default.removeItem(at: tempDir)
        }
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let store = AppGroupStore(containerURL: tempDir)
        let original = makeSnapshot(streakCurrent: 23)
        try store.saveSnapshot(original)
        let before = try Data(contentsOf: store.snapshotFileURL)

        try FileManager.default.setAttributes(
            [.posixPermissions: 0o555], ofItemAtPath: tempDir.path
        )
        var changed = original
        changed.streakCurrent = 24

        XCTAssertThrowsError(try store.saveSnapshot(changed), "書込み不能なら throw する")
        XCTAssertEqual(
            try Data(contentsOf: store.snapshotFileURL), before,
            "アトミック書込みの失敗で既存 snapshot の bytes を書き換えない"
        )
        XCTAssertEqual(store.loadSnapshot(), original, "約束・履歴・旧写真 marker が残る")
    }

    // MARK: 受入条件② 失敗後の保持と再試行

    func testPhotoFailureKeepsStateAndRetrySucceeds() async throws {
        let tempDir = makeTempDir("PhotoFailure-VM")
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let store = AppGroupStore(containerURL: tempDir)
        let baseline = makeSnapshot(hasPartnerPhotoToday: true, streakCurrent: 23)
        try store.saveSnapshot(baseline)

        let service = FlakyPhotoService()
        let viewModel = HomeViewModel(store: store, checkinService: service, reloadWidgets: {})
        viewModel.load()
        XCTAssertTrue(viewModel.canAttachPhoto)

        // 1回目: 破損 JPEG → 製品の画像処理で失敗
        await viewModel.attachPhoto(truncatedJPEG)

        XCTAssertEqual(service.attachCallCount, 1)
        XCTAssertEqual(viewModel.snapshot, baseline, "画面の約束・履歴・旧写真 marker を変えない")
        XCTAssertEqual(store.loadSnapshot(), baseline, "端末の保存済み snapshot も変えない")
        XCTAssertNotNil(viewModel.photoErrorMessage, "責めない定型文言を出す")
        XCTAssertFalse(viewModel.isAttachingPhoto, "失敗後は操作可能に戻る")
        XCTAssertTrue(viewModel.canAttachPhoto, "再試行の導線が残る")

        // 2回目: 有効 JPEG → 同じ画面から再試行できる
        let valid = try makeValidJPEG()
        await viewModel.attachPhoto(valid)

        XCTAssertEqual(service.attachCallCount, 2)
        XCTAssertNil(viewModel.photoErrorMessage)
        XCTAssertNotNil(viewModel.photoAttachedNote)
        XCTAssertTrue(viewModel.snapshot?.hasPartnerPhotoToday == true)
        XCTAssertEqual(viewModel.snapshot?.streakCurrent, 24)
        XCTAssertEqual(store.loadSnapshot()?.streakCurrent, 24, "成功時だけ保存する")
    }
}
