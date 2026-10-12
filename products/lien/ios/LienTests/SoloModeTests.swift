// SoloModeTests.swift — ソロモード(ペア前でも約束とチェックインができる — issue #55 / REQUIREMENTS §3.2)
//
// 審査リジェクト対策(REVIEW-2026-10-12 §2 M4): 「2人いないと何もできない」にしない。
// 検証対象:
//   - ソロでもチェックインできる(サーバーは checkins に pair_id を持たず、写真なしのソロの
//     チェックインを受け付ける — checkin/core.ts)。リクエストに写真・アップロードURL要求は載らない
//   - 写真はペア後(ソロの添付は端末側で拒否し、サーバー往復をしない — サーバーは 400 no_pair)
//   - つつく・リアクション・ストリーク表示はペア後(ソロでは出さない)
//   - 当日取消はソロでもできる

import XCTest
@testable import Lien

// MARK: - モック(トップレベル)

/// 呼び出しを記録する checkin API(サーバー側の「ソロでも受け付ける」挙動を再現)
private final class RecordingCheckinAPI: CheckinAPIClient {
    private(set) var checkinCalls: [(dateLocal: String, photoPath: String?, requestPhotoUpload: Bool)] = []
    private(set) var cancelCalls: [String] = []
    private(set) var uploadCount = 0
    var snapshot: PairSnapshot

    init(snapshot: PairSnapshot) {
        self.snapshot = snapshot
    }

    func checkin(dateLocal: String, photoPath: String?, requestPhotoUpload: Bool) async throws -> CheckinResponse {
        checkinCalls.append((dateLocal, photoPath, requestPhotoUpload))
        if requestPhotoUpload, snapshot.pairId == nil {
            throw CheckinClientError.noPair // checkin/core.ts: ソロの署名URL要求は 400 no_pair
        }
        let already = snapshot.todayMeDone
        snapshot.todayMeDone = true
        return CheckinResponse(alreadyCheckedIn: already, snapshot: snapshot, photoUpload: nil)
    }

    func cancelCheckin(dateLocal: String) async throws -> CheckinCancelResponse {
        cancelCalls.append(dateLocal)
        let already = !snapshot.todayMeDone
        snapshot.todayMeDone = false
        return CheckinCancelResponse(alreadyCanceled: already, snapshot: snapshot)
    }

    func uploadPhoto(_ data: Data, to target: PhotoUploadTarget) async throws {
        uploadCount += 1
    }
}

private final class NeverCalledNudgeReact: NudgeSending, Reacting {
    private(set) var calls = 0
    func sendNudge(stamp: NudgeStamp) async throws { calls += 1 }
    func sendReaction(stamp: ReactionStamp) async throws { calls += 1 }
}

@MainActor
final class SoloModeTests: XCTestCase {
    private let fixedNow = Date(timeIntervalSince1970: 1_781_166_600)

    private struct Rig {
        let vm: HomeViewModel
        let api: RecordingCheckinAPI
        let service: CheckinService
        let temp: TempStore
        let nudgeReact: NeverCalledNudgeReact
    }

    private func makeRig(snapshot: PairSnapshot) throws -> Rig {
        let temp = TempStore()
        try temp.store.saveSnapshot(snapshot)
        let api = RecordingCheckinAPI(snapshot: snapshot)
        let service = CheckinService(
            api: api,
            queue: PendingOpsQueue(store: temp.store),
            now: { [fixedNow] in fixedNow }
        )
        let nudgeReact = NeverCalledNudgeReact()
        let vm = HomeViewModel(
            store: temp.store,
            checkinService: service,
            nudgeService: nudgeReact,
            reactionService: nudgeReact,
            reloadWidgets: {}
        )
        vm.load()
        return Rig(vm: vm, api: api, service: service, temp: temp, nudgeReact: nudgeReact)
    }

    // MARK: ソロでもチェックインできる

    func testSoloUserCanCheckInWithoutAPair() async throws {
        let rig = try makeRig(snapshot: SnapshotFactory.solo())
        defer { rig.temp.cleanup() }
        XCTAssertTrue(rig.vm.isSolo)
        XCTAssertTrue(rig.vm.canCheckin, "ペア前でも「できた!」を押せる")

        await rig.vm.performCheckin()

        XCTAssertEqual(rig.vm.snapshot?.todayMeDone, true)
        XCTAssertNil(rig.vm.checkinErrorMessage)
        XCTAssertEqual(rig.api.checkinCalls.count, 1)
        XCTAssertEqual(rig.temp.store.loadSnapshot()?.todayMeDone, true, "端末の snapshot(ウィジェット用)にも反映される")
        XCTAssertNil(rig.temp.store.loadSnapshot()?.pairId, "ソロのまま")
    }

    func testSoloCheckinRequestHasNoPhotoAndNoUploadRequest() async throws {
        let rig = try makeRig(snapshot: SnapshotFactory.solo())
        defer { rig.temp.cleanup() }

        await rig.vm.performCheckin()

        let call = try XCTUnwrap(rig.api.checkinCalls.first)
        XCTAssertNil(call.photoPath, "写真なしのチェックイン(サーバーはソロでも受け付ける)")
        XCTAssertFalse(call.requestPhotoUpload, "ソロは署名URLを要求しない(要求すると 400 no_pair)")
        XCTAssertEqual(call.dateLocal, DayBoundary.dateLocalString(for: fixedNow))
    }

    func testSoloUserCanCancelTodaysCheckin() async throws {
        let rig = try makeRig(snapshot: SnapshotFactory.solo(todayMeDone: true))
        defer { rig.temp.cleanup() }
        XCTAssertTrue(rig.vm.canCancelCheckin, "誤タップの取消はソロでもできる(§3.4)")

        await rig.vm.performCancel()

        XCTAssertEqual(rig.vm.snapshot?.todayMeDone, false)
        XCTAssertEqual(rig.api.cancelCalls.count, 1)
    }

    // MARK: 写真・つつく・リアクション・ストリークはペア後

    func testSoloHidesPhotoNudgeReactionAndStreak() async throws {
        let rig = try makeRig(snapshot: SnapshotFactory.solo(todayMeDone: true))
        defer { rig.temp.cleanup() }

        XCTAssertFalse(rig.vm.canAttachPhoto, "写真はペア後(§3.4 / DESIGN §5.6)")
        XCTAssertFalse(rig.vm.canNudge, "つつく相手がいない")
        XCTAssertFalse(rig.vm.canReact, "リアクションする相手がいない")
        XCTAssertFalse(rig.vm.showsStreak, "ふたりストリークはペア成立日から")
        XCTAssertEqual(rig.vm.plantAssetName, PlantSprite.soloAssetName, "ソロの鉢は土だけ(§3.9)")
        XCTAssertNil(rig.vm.partnerWaitingText)
        XCTAssertFalse(rig.vm.showsBothDoneCelebration)

        await rig.vm.sendNudge(stamp: .wave)
        await rig.vm.sendReaction(stamp: .heart)
        XCTAssertEqual(rig.nudgeReact.calls, 0, "ソロでは送信を試みない")
    }

    func testSoloPhotoAttachIsRefusedBeforeAnyRequest() async throws {
        let rig = try makeRig(snapshot: SnapshotFactory.solo(todayMeDone: true))
        defer { rig.temp.cleanup() }

        do {
            _ = try await rig.service.attachPhoto(current: rig.vm.snapshot!, imageData: Data([0x00]))
            XCTFail("ソロで写真を添付できてしまった")
        } catch {
            XCTAssertEqual(error as? CheckinClientError, .noPair)
        }
        XCTAssertTrue(rig.api.checkinCalls.isEmpty, "サーバーを呼ばない")
        XCTAssertEqual(rig.api.uploadCount, 0)

        await rig.vm.attachPhoto(Data([0x00]))
        XCTAssertNil(rig.vm.photoErrorMessage, "ボタン自体が出ないので VM も何もしない")
    }

    // MARK: ペア成立後に写真・つつくが使えるようになる

    func testPairingEnablesPhotoAndNudgeAfterSoloCheckin() async throws {
        let rig = try makeRig(snapshot: SnapshotFactory.solo(todayMeDone: true))
        defer { rig.temp.cleanup() }
        XCTAssertFalse(rig.vm.canAttachPhoto)

        // ペア成立(AppModel の同期が App Group を更新 → ホームが読み直す)
        try rig.temp.store.saveSnapshot(SnapshotFactory.paired(todayMeDone: true, todayPartnerDone: false))
        rig.vm.load()

        XCTAssertFalse(rig.vm.isSolo)
        XCTAssertTrue(rig.vm.canAttachPhoto, "ペア後は写真を添えられる")
        XCTAssertTrue(rig.vm.canNudge, "相手が未完ならつつける")
        XCTAssertTrue(rig.vm.showsStreak)
    }
}
