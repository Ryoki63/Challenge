// PartnerPhotoTests.swift — 相手の今日の写真をホームに出す(PV / issue #59 / REQUIREMENTS §3.11)
//
// モック注入で、画面の状態(PartnerPhotoModel)を検証する。通信の層(PostgREST・Storage の署名・ダウンロード)は
// PartnerPhotoNetworkTests、契約フィクスチャとの突き合わせは PartnerPhotoContractTests。
//
// #59 の完了条件との対応:
//   ① hasPartnerPhotoToday=false なら取りに行かない
//   ② 行に photo_path が無ければ出さない
//   ③ 取得失敗・期限切れで植物だけに戻る(文言なし)
//   ④ ソロ・ペア解消後は出さない(持っている写真も消す)
//   ⑤ 署名付き URL・画像を App Group に書かない
// ほかに: 読み込み中の状態 / 同じ日・同じペアの写真は取り直さない / 日付またぎ / 同時の二重取得 / 原寸の全画面

import XCTest
@testable import Lien

/// モデルが見る時計(テストが進める)
private final class PhotoTestClock {
    var now: Date
    init(_ now: Date = PartnerPhotoFixtures.now) { self.now = now }
}

private struct SomeError: Error {}

/// 日付またぎの見張りの待ち時間を差し替える(1回目は wake() まで待つ。2回目以降は取り消されるまで待つ)
@MainActor
private final class WatchSleeper {
    private(set) var requested: [TimeInterval] = []
    private var continuation: CheckedContinuation<Void, Never>?

    func sleep(_ seconds: TimeInterval) async {
        requested.append(seconds)
        if requested.count == 1 {
            await withCheckedContinuation { continuation = $0 }
        } else {
            try? await Task.sleep(nanoseconds: 60_000_000_000)
        }
    }

    func wake() {
        continuation?.resume()
        continuation = nil
    }
}

// MARK: - パス

final class PartnerPhotoPathTests: XCTestCase {
    private let pair = PartnerPhotoFixtures.pairID
    private let user = PartnerPhotoFixtures.partnerUserID

    func testParsesTheCurrentPathConvention() throws {
        let raw = "pairs/\(pair)/2026-06-11/\(user)/photo.jpg"
        let path = try XCTUnwrap(PartnerPhotoPath(raw))
        XCTAssertEqual(path.original, raw)
        XCTAssertEqual(path.thumbnail, "pairs/\(pair)/2026-06-11/\(user)/photo_thumb.jpg", "サムネは同じ区画の photo_thumb.jpg")
        XCTAssertEqual(path.pairID, pair)
        XCTAssertEqual(path.dateLocal, "2026-06-11")
    }

    func testParsesTheLegacyPathWithoutTheUserSegment() throws {
        // #52 より前の既存分('pairs/<pair>/<date>/photo.jpg')も読める
        let path = try XCTUnwrap(PartnerPhotoPath("pairs/\(pair)/2026-06-11/photo.jpg"))
        XCTAssertEqual(path.thumbnail, "pairs/\(pair)/2026-06-11/photo_thumb.jpg")
        XCTAssertEqual(path.dateLocal, "2026-06-11")
    }

    func testPairIDIsLowercasedButThePathIsKeptAsGiven() throws {
        let upper = pair.uppercased()
        let path = try XCTUnwrap(PartnerPhotoPath("pairs/\(upper)/2026-06-11/\(user)/photo.jpg"))
        XCTAssertEqual(path.pairID, pair, "比較用の pair ID は小文字にそろえる")
        XCTAssertTrue(path.original.contains(upper), "Storage のパスは大文字小文字を区別するので、渡されたまま持つ")
    }

    func testRejectsPathsThatBreakTheConvention() {
        let invalid = [
            "",
            "photo.jpg",
            "pairs/\(pair)/2026-06-11/\(user)/photo_thumb.jpg", // 原寸の行にはサムネを置かない
            "pairs/\(pair)/2026-06-11/\(user)/photo.png",
            "other/\(pair)/2026-06-11/\(user)/photo.jpg",
            "pairs/not-a-uuid/2026-06-11/\(user)/photo.jpg",
            "pairs/\(pair)/2026-6-11/\(user)/photo.jpg",
            "pairs/\(pair)/20260611/\(user)/photo.jpg",
            "pairs/\(pair)/2026-06-1a/\(user)/photo.jpg",
            "pairs/\(pair)/2026-06-11/not-a-uuid/photo.jpg",
            "pairs/\(pair)/2026-06-11/\(user)/extra/photo.jpg",
            "pairs/\(pair)/2026-06-11/\(user)/../photo.jpg",
            "pairs/../2026-06-11/\(user)/photo.jpg",
            "/pairs/\(pair)/2026-06-11/\(user)/photo.jpg",
            "pairs/\(pair)/2026-06-11/\(user)/photo.jpg/",
            "pairs//2026-06-11/\(user)/photo.jpg",
            "pairs/\(pair)/2026-06-11/\(user)/photo.jpg?x=1",
        ]
        for raw in invalid {
            XCTAssertNil(PartnerPhotoPath(raw), raw)
        }
    }

    func testSafeObjectPathAcceptsOnlyPlainSegments() {
        XCTAssertTrue(PartnerPhotoPath.isSafeObjectPath("pairs/\(pair)/2026-06-11/\(user)/photo_thumb.jpg"))
        XCTAssertTrue(PartnerPhotoPath.isSafeObjectPath("a.b-c_d/E"))
        for bad in ["", "/a", "a/", "a//b", "a/./b", "a/../b", "..", "a b", "a?b", "a#b", "a%2Fb", "日本語/x", "a\\b", "a:b"] {
            XCTAssertFalse(PartnerPhotoPath.isSafeObjectPath(bad), bad)
        }
        XCTAssertFalse(PartnerPhotoPath.isSafeObjectPath(String(repeating: "a", count: 301)))
    }

    func testLimitsKeepTheThumbnailSmallAndTheOriginalForFullScreen() {
        XCTAssertLessThanOrEqual(PartnerPhotoLimits.thumbnail.maxBytes, 1024 * 1024, "サムネは 200KB 以下の契約。余裕を見ても 1MB 未満")
        XCTAssertGreaterThanOrEqual(PartnerPhotoLimits.thumbnail.maxBytes, PhotoProcessor.thumbMaxBytes)
        XCTAssertGreaterThanOrEqual(PartnerPhotoLimits.thumbnail.maxPixelSize, PhotoProcessor.thumbMaxPixelSize)
        XCTAssertLessThanOrEqual(PartnerPhotoLimits.original.maxPixelSize, PhotoProcessor.photoMaxPixelSize, "原寸は 2048px 以下。デコードは全画面ぶんで足りる")
        XCTAssertLessThan(PartnerPhotoLimits.thumbnailFromOriginal.maxPixelSize, PartnerPhotoLimits.original.maxPixelSize)
    }
}

// MARK: - 画面の状態(PartnerPhotoModel)

@MainActor
final class PartnerPhotoModelTests: XCTestCase {
    private struct Rig {
        let provider: MockPartnerPhotoProvider
        let clock: PhotoTestClock
        let model: PartnerPhotoModel
    }

    private func makeRig(actions: [PartnerPhotoAction] = []) -> Rig {
        let provider = MockPartnerPhotoProvider()
        let clock = PhotoTestClock()
        let model = PartnerPhotoModel(
            provider: provider,
            actions: actions,
            now: { clock.now },
            calendar: PartnerPhotoFixtures.tokyo
        )
        return Rig(provider: provider, clock: clock, model: model)
    }

    private func readyPhoto(_ model: PartnerPhotoModel) -> PartnerPhotoThumbnail? {
        if case .ready(let photo) = model.state { return photo }
        return nil
    }

    // MARK: ① 写真が無い日は取りに行かない

    func testDoesNotFetchWhenThePartnerHasNoPhotoToday() async {
        let rig = makeRig()
        rig.provider.thumbnailResult = .success(PartnerPhotoFixtures.thumbnail())

        await rig.model.update(with: PartnerPhotoFixtures.pairedSnapshot(hasPartnerPhotoToday: false))

        XCTAssertEqual(rig.model.state, .hidden)
        XCTAssertEqual(rig.provider.thumbnailCalls.count, 0, "hasPartnerPhotoToday=false なら取りに行かない")
    }

    func testNothingWithoutASnapshot() async {
        let rig = makeRig()
        await rig.model.update(with: nil)
        XCTAssertEqual(rig.model.state, .hidden)
        XCTAssertEqual(rig.provider.thumbnailCalls.count, 0)
    }

    // MARK: 写真あり(読み込み中 → 表示)

    func testShowsLoadingWhileFetchingAndThenTheThumbnail() async throws {
        let rig = makeRig()
        let photo = PartnerPhotoFixtures.thumbnail()
        rig.provider.thumbnailResult = .success(photo)
        rig.provider.holdThumbnail()

        rig.model.snapshotDidChange(PartnerPhotoFixtures.pairedSnapshot())
        XCTAssertEqual(rig.model.state, .loading, "取得中は枠だけ(同期的に決まる)")

        await waitUntil { rig.provider.thumbnailCalls.count == 1 }
        XCTAssertEqual(rig.model.state, .loading)

        rig.provider.release()
        await rig.model.fetchTask?.value
        XCTAssertEqual(rig.model.state, .ready(photo))
        let call = try XCTUnwrap(rig.provider.thumbnailCalls.first)
        XCTAssertEqual(call.pairID, PartnerPhotoFixtures.pairID)
        XCTAssertEqual(call.dateLocal, PartnerPhotoFixtures.today, "端末ローカルの今日の行を取る")
    }

    func testPairIDIsPassedInLowercase() async {
        let rig = makeRig()
        rig.provider.thumbnailResult = .success(PartnerPhotoFixtures.thumbnail())
        await rig.model.update(with: PartnerPhotoFixtures.pairedSnapshot(pairID: PartnerPhotoFixtures.pairID.uppercased()))
        XCTAssertEqual(rig.provider.thumbnailCalls.first?.pairID, PartnerPhotoFixtures.pairID)
        XCTAssertNotNil(readyPhoto(rig.model))
    }

    // MARK: ② photo_path が無い

    func testShowsNothingWhenTheRowHasNoPhoto() async {
        let rig = makeRig()
        rig.provider.thumbnailResult = .success(nil) // 行が無い・photo_path が無い・規約に合わない

        await rig.model.update(with: PartnerPhotoFixtures.pairedSnapshot())

        XCTAssertEqual(rig.provider.thumbnailCalls.count, 1)
        XCTAssertEqual(rig.model.state, .hidden, "photo_path が無ければ出さない(「写真なし」の文言も出さない)")
    }

    // MARK: ③ 失敗

    func testFailureHidesSilentlyAndTheNextUpdateRetries() async {
        let rig = makeRig()
        rig.provider.thumbnailResult = .failure(PartnerPhotoError.expired)
        let snapshot = PartnerPhotoFixtures.pairedSnapshot()

        await rig.model.update(with: snapshot)
        XCTAssertEqual(rig.model.state, .hidden, "失敗したら植物だけに戻る(文言なし)")

        rig.provider.thumbnailResult = .success(PartnerPhotoFixtures.thumbnail())
        await rig.model.update(with: snapshot)
        XCTAssertNotNil(readyPhoto(rig.model), "失敗は固定されない。次の機会に取り直す")
        XCTAssertEqual(rig.provider.thumbnailCalls.count, 2)
    }

    func testEveryKindOfFailureHidesTheCard() async {
        let errors: [Error] = [
            PartnerPhotoError.network, PartnerPhotoError.unauthorized, PartnerPhotoError.expired,
            PartnerPhotoError.notFound, PartnerPhotoError.server(status: 500), PartnerPhotoError.invalidImage,
            AuthServiceError.notSignedIn, SomeError(),
        ]
        for error in errors {
            let rig = makeRig()
            rig.provider.thumbnailResult = .failure(error)
            await rig.model.update(with: PartnerPhotoFixtures.pairedSnapshot())
            XCTAssertEqual(rig.model.state, .hidden, "\(error)")
        }
    }

    // MARK: ④ ソロ・ペア解消

    func testSoloNeverFetches() async {
        let rig = makeRig()
        rig.provider.thumbnailResult = .success(PartnerPhotoFixtures.thumbnail())
        await rig.model.update(with: PartnerPhotoFixtures.pairedSnapshot(pairID: nil, hasPartnerPhotoToday: true))
        XCTAssertEqual(rig.model.state, .hidden)
        XCTAssertEqual(rig.provider.thumbnailCalls.count, 0, "ペアが無ければ相手の写真は無い")
    }

    func testDissolvingThePairErasesThePhotoAndTheOpenViewer() async {
        let rig = makeRig()
        rig.provider.thumbnailResult = .success(PartnerPhotoFixtures.thumbnail())
        rig.provider.holdOriginal()
        await rig.model.update(with: PartnerPhotoFixtures.pairedSnapshot())
        rig.model.openViewer()
        XCTAssertTrue(rig.model.isViewerOpen)

        // ペア解消の同期: snapshot が pairId=null になる
        await rig.model.update(with: PartnerPhotoFixtures.pairedSnapshot(pairID: nil, hasPartnerPhotoToday: false))

        XCTAssertEqual(rig.model.state, .hidden)
        XCTAssertEqual(rig.model.viewer, .closed, "開いていた全画面も閉じる")
        rig.provider.release()

        // 新しいペアになっても、前のペアの写真は残っていない(取り直す)
        await rig.model.update(with: PartnerPhotoFixtures.pairedSnapshot(pairID: PartnerPhotoFixtures.otherPairID))
        XCTAssertEqual(rig.provider.thumbnailCalls.count, 2)
        XCTAssertEqual(rig.provider.thumbnailCalls.last?.pairID, PartnerPhotoFixtures.otherPairID)
    }

    // MARK: キャッシュ

    func testTheSamePhotoIsNotFetchedAgainOnTheSameDay() async {
        let rig = makeRig()
        let photo = PartnerPhotoFixtures.thumbnail()
        rig.provider.thumbnailResult = .success(photo)
        let snapshot = PartnerPhotoFixtures.pairedSnapshot()

        await rig.model.update(with: snapshot)
        await rig.model.update(with: snapshot)
        rig.clock.now = rig.clock.now.addingTimeInterval(60)
        await rig.model.update(with: snapshot)

        XCTAssertEqual(rig.provider.thumbnailCalls.count, 1, "同じ日・同じペアの写真は、キャッシュから出す")
        XCTAssertEqual(rig.model.state, .ready(photo))
    }

    func testThePhotoIsCheckedAgainAfterTheRevalidationInterval() async {
        let rig = makeRig()
        let first = PartnerPhotoFixtures.thumbnail(image: TestImages.photoImage(width: 64, height: 48))
        let replaced = PartnerPhotoFixtures.thumbnail(image: TestImages.photoImage(width: 48, height: 64))
        rig.provider.thumbnailResult = .success(first)
        let snapshot = PartnerPhotoFixtures.pairedSnapshot()
        await rig.model.update(with: snapshot)

        // 相手が同じ日に写真を貼り直した(同じパスへの上書き)。間隔を過ぎた次の機会に取り直す
        rig.provider.thumbnailResult = .success(replaced)
        rig.provider.holdThumbnail()
        rig.clock.now = rig.clock.now.addingTimeInterval(PartnerPhotoModel.revalidateInterval + 1)
        rig.model.snapshotDidChange(snapshot)
        XCTAssertEqual(rig.model.state, .ready(first), "取り直している間も、今の写真を出したままにする(枠に戻さない)")
        await waitUntil { rig.provider.thumbnailCalls.count == 2 }

        rig.provider.release()
        await rig.model.fetchTask?.value
        XCTAssertEqual(rig.model.state, .ready(replaced))
    }

    func testRevalidationKeepsThePhotoWhenOnlyTheNetworkFailed() async {
        let rig = makeRig()
        let photo = PartnerPhotoFixtures.thumbnail()
        rig.provider.thumbnailResult = .success(photo)
        let snapshot = PartnerPhotoFixtures.pairedSnapshot()
        await rig.model.update(with: snapshot)

        rig.provider.thumbnailResult = .failure(PartnerPhotoError.network)
        rig.clock.now = rig.clock.now.addingTimeInterval(PartnerPhotoModel.revalidateInterval + 1)
        await rig.model.update(with: snapshot)

        XCTAssertEqual(rig.model.state, .ready(photo), "オフラインで取り直せなかっただけなら、出している今日の写真はそのまま")
    }

    func testRevalidationDropsThePhotoWhenItIsNoLongerReadable() async {
        let rig = makeRig()
        rig.provider.thumbnailResult = .success(PartnerPhotoFixtures.thumbnail())
        let snapshot = PartnerPhotoFixtures.pairedSnapshot()
        await rig.model.update(with: snapshot)

        // ペア解消の同期より先に RLS が閉じた(署名を作れない)
        rig.provider.thumbnailResult = .failure(PartnerPhotoError.notFound)
        rig.clock.now = rig.clock.now.addingTimeInterval(PartnerPhotoModel.revalidateInterval + 1)
        await rig.model.update(with: snapshot)

        XCTAssertEqual(rig.model.state, .hidden, "読めなくなった写真は残さない")
    }

    // MARK: 日付またぎ

    func testThePhotoDisappearsWhenTheDateChanges() async {
        let rig = makeRig()
        rig.provider.thumbnailResult = .success(PartnerPhotoFixtures.thumbnail())
        let snapshot = PartnerPhotoFixtures.pairedSnapshot()
        await rig.model.update(with: snapshot)
        XCTAssertNotNil(readyPhoto(rig.model))

        // 日本時間 2026-06-12 00:30(同期はまだ。snapshot は昨日のまま)
        rig.clock.now = Date(timeIntervalSince1970: 1_781_166_600 + 7 * 3600)
        await rig.model.update(with: snapshot)

        XCTAssertEqual(rig.model.state, .hidden, "出すのは「今日の写真」だけ。日付が変わったら消える")
        XCTAssertEqual(rig.provider.thumbnailCalls.count, 1, "昨日の snapshot の値で、今日の写真を取りに行かない")
    }

    func testAStaleSnapshotFromYesterdayIsNotFetched() async {
        let rig = makeRig()
        rig.provider.thumbnailResult = .success(PartnerPhotoFixtures.thumbnail())
        let yesterday = PartnerPhotoFixtures.now.addingTimeInterval(-24 * 3600)

        await rig.model.update(with: PartnerPhotoFixtures.pairedSnapshot(hasPartnerPhotoToday: true, updatedAt: yesterday))

        XCTAssertEqual(rig.model.state, .hidden, "hasPartnerPhotoToday が昨日の値かもしれない間は出さない(枠だけ出てすぐ消えるのを避ける)")
        XCTAssertEqual(rig.provider.thumbnailCalls.count, 0)
    }

    func testTheNextDaysPhotoIsFetchedForTheNewDate() async {
        let rig = makeRig()
        rig.provider.thumbnailResult = .success(PartnerPhotoFixtures.thumbnail())
        await rig.model.update(with: PartnerPhotoFixtures.pairedSnapshot())

        let nextDay = Date(timeIntervalSince1970: 1_781_166_600 + 24 * 3600)
        rig.clock.now = nextDay
        rig.provider.thumbnailResult = .success(PartnerPhotoFixtures.thumbnail(dateLocal: PartnerPhotoFixtures.tomorrow))
        await rig.model.update(with: PartnerPhotoFixtures.pairedSnapshot(updatedAt: nextDay))

        XCTAssertEqual(rig.provider.thumbnailCalls.map { $0.dateLocal }, [PartnerPhotoFixtures.today, PartnerPhotoFixtures.tomorrow])
        XCTAssertEqual(readyPhoto(rig.model)?.reference.dateLocal, PartnerPhotoFixtures.tomorrow)
    }

    // MARK: 同時の取得

    func testOnlyOneFetchRunsForTheSamePhoto() async {
        let rig = makeRig()
        rig.provider.thumbnailResult = .success(PartnerPhotoFixtures.thumbnail())
        rig.provider.holdThumbnail()
        let snapshot = PartnerPhotoFixtures.pairedSnapshot()

        rig.model.snapshotDidChange(snapshot) // onAppear
        rig.model.snapshotDidChange(snapshot) // 同期の完了
        rig.model.snapshotDidChange(snapshot) // 前面復帰
        await waitUntil { rig.provider.thumbnailCalls.count >= 1 }
        rig.provider.release()
        await rig.model.fetchTask?.value

        XCTAssertEqual(rig.provider.thumbnailCalls.count, 1, "取得中の写真を、もう一度取りに行かない")
        XCTAssertNotNil(readyPhoto(rig.model))
    }

    func testWatchingTheClockErasesThePhotoWhenMidnightPasses() async {
        // 日本時間 2026-06-11 23:59:58.5(0:00 まで 1.5 秒)
        let almostMidnight = Date(timeIntervalSince1970: 1_781_189_998.5)
        let provider = MockPartnerPhotoProvider()
        provider.thumbnailResult = .success(PartnerPhotoFixtures.thumbnail())
        let clock = PhotoTestClock(almostMidnight)
        let sleeper = WatchSleeper()
        let model = PartnerPhotoModel(
            provider: provider,
            now: { clock.now },
            calendar: PartnerPhotoFixtures.tokyo,
            sleep: { seconds in await sleeper.sleep(seconds) }
        )
        await model.update(with: PartnerPhotoFixtures.pairedSnapshot(updatedAt: almostMidnight))
        XCTAssertNotNil(readyPhoto(model))

        let watcher = Task { await model.watchDayChanges() }
        await waitUntil { sleeper.requested.count == 1 }
        XCTAssertEqual(try XCTUnwrap(sleeper.requested.first), 2.5, accuracy: 0.001, "0:00 の1秒後まで待つ")
        XCTAssertNotNil(readyPhoto(model), "0:00 までは出ている")

        clock.now = Date(timeIntervalSince1970: 1_781_190_001) // 日本時間 6/12 0:00:01
        sleeper.wake()
        await waitUntil { sleeper.requested.count == 2 }

        XCTAssertEqual(model.state, .hidden, "前面に出したまま 0:00 を越えたら、昨日の写真が消える")
        XCTAssertEqual(provider.thumbnailCalls.count, 1, "昨日の snapshot の値で、新しい日の写真を取りに行かない")
        XCTAssertEqual(try XCTUnwrap(sleeper.requested.last), 86_400, accuracy: 2, "次の 0:00 の1秒後まで待ち直す")

        watcher.cancel()
        await watcher.value
    }

    func testTheResultOfASupersededFetchIsDropped() async {
        let rig = makeRig()
        rig.provider.thumbnailResult = .success(PartnerPhotoFixtures.thumbnail())
        rig.provider.holdThumbnail()
        rig.model.snapshotDidChange(PartnerPhotoFixtures.pairedSnapshot())
        let running = rig.model.fetchTask
        await waitUntil { rig.provider.thumbnailCalls.count == 1 }

        // 取得中にペアが解消された
        rig.model.snapshotDidChange(PartnerPhotoFixtures.pairedSnapshot(pairID: nil, hasPartnerPhotoToday: false))
        rig.provider.release()
        await running?.value

        XCTAssertEqual(rig.model.state, .hidden, "解消後に届いた古い取得の結果で、写真を出さない")
    }

    // MARK: 原寸の全画面

    func testViewerShowsTheThumbnailFirstAndThenTheOriginal() async throws {
        let rig = makeRig()
        let photo = PartnerPhotoFixtures.thumbnail()
        let original = TestImages.photoImage(width: 160, height: 120)
        rig.provider.thumbnailResult = .success(photo)
        rig.provider.originalResult = .success(original)
        rig.provider.holdOriginal()
        await rig.model.update(with: PartnerPhotoFixtures.pairedSnapshot())

        rig.model.openViewer()
        XCTAssertEqual(rig.model.viewer, .open(thumbnail: photo.image, original: nil), "原寸が届くまではサムネを大きく出す")
        XCTAssertTrue(rig.model.isViewerOpen)

        rig.provider.release()
        await rig.model.viewerTask?.value
        XCTAssertEqual(rig.model.viewer, .open(thumbnail: photo.image, original: original))
        XCTAssertEqual(rig.provider.originalCalls, [photo.reference], "原寸は、サムネの指し先(原寸のパス)で取る")

        rig.model.closeViewer()
        XCTAssertEqual(rig.model.viewer, .closed, "閉じたら原寸は手放す")
        XCTAssertFalse(rig.model.isViewerOpen)
    }

    func testViewerKeepsTheThumbnailWhenTheOriginalFails() async {
        let rig = makeRig()
        let photo = PartnerPhotoFixtures.thumbnail()
        rig.provider.thumbnailResult = .success(photo)
        rig.provider.originalResult = .failure(PartnerPhotoError.expired)
        await rig.model.update(with: PartnerPhotoFixtures.pairedSnapshot())

        rig.model.openViewer()
        await rig.model.viewerTask?.value

        XCTAssertEqual(rig.model.viewer, .open(thumbnail: photo.image, original: nil), "原寸が取れなくても文言は出さず、サムネのまま")
    }

    func testClosingTheViewerDiscardsALateOriginal() async {
        let rig = makeRig()
        rig.provider.thumbnailResult = .success(PartnerPhotoFixtures.thumbnail())
        rig.provider.originalResult = .success(TestImages.photoImage(width: 160, height: 120))
        rig.provider.holdOriginal()
        await rig.model.update(with: PartnerPhotoFixtures.pairedSnapshot())

        rig.model.openViewer()
        let running = rig.model.viewerTask
        await waitUntil { rig.provider.originalCalls.count == 1 }
        rig.model.closeViewer()
        rig.provider.release()
        await running?.value

        XCTAssertEqual(rig.model.viewer, .closed, "閉じたあとに届いた原寸で、全画面を開き直さない")
    }

    func testOpeningTheViewerWithoutAPhotoDoesNothing() async {
        let rig = makeRig()
        rig.model.openViewer()
        XCTAssertEqual(rig.model.viewer, .closed)
        XCTAssertEqual(rig.provider.originalCalls.count, 0)

        await rig.model.update(with: PartnerPhotoFixtures.pairedSnapshot(hasPartnerPhotoToday: false))
        rig.model.openViewer()
        XCTAssertEqual(rig.model.viewer, .closed)
    }

    func testTheViewerClosesWhenThePhotoGoesAway() async {
        let rig = makeRig()
        rig.provider.thumbnailResult = .success(PartnerPhotoFixtures.thumbnail())
        rig.provider.originalResult = .success(TestImages.photoImage())
        let snapshot = PartnerPhotoFixtures.pairedSnapshot()
        await rig.model.update(with: snapshot)
        rig.model.openViewer()
        await rig.model.viewerTask?.value
        XCTAssertTrue(rig.model.isViewerOpen)

        // 日付が変わった
        rig.clock.now = Date(timeIntervalSince1970: 1_781_166_600 + 7 * 3600)
        await rig.model.update(with: snapshot)

        XCTAssertEqual(rig.model.viewer, .closed, "昨日の写真を全画面に残さない")
    }

    // MARK: 長押しの取り付け口(T23)

    func testActionsAreHandedToTheView() {
        var received: [PartnerPhotoReference] = []
        let report = PartnerPhotoAction(id: "report", title: "通報", systemImage: "flag", isDestructive: true) {
            received.append($0)
        }
        let rig = makeRig(actions: [report])
        XCTAssertEqual(rig.model.actions.map(\.id), ["report"])
        XCTAssertTrue(rig.model.actions[0].isDestructive)

        rig.model.actions[0].perform(PartnerPhotoFixtures.reference())
        XCTAssertEqual(received, [PartnerPhotoFixtures.reference()], "通報は、写真の指し先(ペア・日付・パス)を受け取る")

        XCTAssertTrue(makeRig().model.actions.isEmpty, "既定は長押しなし")
    }
}

// MARK: - HomeViewModel との結線

@MainActor
final class HomeViewModelPartnerPhotoTests: XCTestCase {
    private final class EchoCheckinService: CheckinPerforming {
        func performCheckin(current: PairSnapshot) async throws -> PairSnapshot {
            var updated = current
            updated.todayMeDone = true
            return updated
        }
    }

    private struct Rig {
        let vm: HomeViewModel
        let provider: MockPartnerPhotoProvider
        let temp: TempStore
    }

    private func isShowingPhoto(_ vm: HomeViewModel) -> Bool {
        if case .ready? = vm.partnerPhoto?.state { return true }
        return false
    }

    private func makeRig(snapshot: PairSnapshot?, withPhotoModel: Bool = true) throws -> Rig {
        let temp = TempStore()
        if let snapshot { try temp.store.saveSnapshot(snapshot) }
        let provider = MockPartnerPhotoProvider()
        provider.thumbnailResult = .success(PartnerPhotoFixtures.thumbnail())
        let model = PartnerPhotoModel(
            provider: provider,
            now: { PartnerPhotoFixtures.now },
            calendar: PartnerPhotoFixtures.tokyo
        )
        let vm = HomeViewModel(
            store: temp.store,
            checkinService: EchoCheckinService(),
            partnerPhoto: withPhotoModel ? model : nil,
            reloadWidgets: {}
        )
        return Rig(vm: vm, provider: provider, temp: temp)
    }

    func testLoadHandsTheSnapshotToThePhotoModel() async throws {
        let rig = try makeRig(snapshot: PartnerPhotoFixtures.pairedSnapshot())
        defer { rig.temp.cleanup() }

        rig.vm.load()
        await rig.vm.partnerPhoto?.fetchTask?.value

        XCTAssertEqual(rig.provider.thumbnailCalls.count, 1)
        XCTAssertTrue(isShowingPhoto(rig.vm), "写真が出ていない: \(String(describing: rig.vm.partnerPhoto?.state))")
    }

    func testLoadWithoutAPhotoTodayFetchesNothing() throws {
        let rig = try makeRig(snapshot: PartnerPhotoFixtures.pairedSnapshot(hasPartnerPhotoToday: false))
        defer { rig.temp.cleanup() }

        rig.vm.load()

        XCTAssertEqual(rig.provider.thumbnailCalls.count, 0)
        XCTAssertEqual(rig.vm.partnerPhoto?.state, .hidden)
    }

    func testReloadingTheHomeDoesNotFetchAgain() async throws {
        let rig = try makeRig(snapshot: PartnerPhotoFixtures.pairedSnapshot())
        defer { rig.temp.cleanup() }

        rig.vm.load()
        await rig.vm.partnerPhoto?.fetchTask?.value
        rig.vm.load() // 前面復帰・同期の完了
        await rig.vm.partnerPhoto?.fetchTask?.value

        XCTAssertEqual(rig.provider.thumbnailCalls.count, 1, "同期のたびに写真を取り直さない")
    }

    func testMyOwnCheckinKeepsThePhotoWithoutFetchingAgain() async throws {
        let rig = try makeRig(snapshot: PartnerPhotoFixtures.pairedSnapshot())
        defer { rig.temp.cleanup() }
        rig.vm.load()
        await rig.vm.partnerPhoto?.fetchTask?.value

        await rig.vm.performCheckin()
        await rig.vm.partnerPhoto?.fetchTask?.value

        XCTAssertEqual(rig.vm.snapshot?.todayMeDone, true)
        XCTAssertEqual(rig.provider.thumbnailCalls.count, 1)
        XCTAssertTrue(isShowingPhoto(rig.vm), "チェックインで写真が消えた")
    }

    func testDissolvedPairInTheStoreErasesThePhoto() async throws {
        let rig = try makeRig(snapshot: PartnerPhotoFixtures.pairedSnapshot())
        defer { rig.temp.cleanup() }
        rig.vm.load()
        await rig.vm.partnerPhoto?.fetchTask?.value

        // ペア解消の同期が App Group の snapshot を solo にした
        try rig.temp.store.saveSnapshot(PartnerPhotoFixtures.pairedSnapshot(pairID: nil, hasPartnerPhotoToday: false))
        rig.vm.load()

        XCTAssertEqual(rig.vm.partnerPhoto?.state, .hidden)
    }

    func testWithoutAPhotoModelNothingHappens() throws {
        let rig = try makeRig(snapshot: PartnerPhotoFixtures.pairedSnapshot(), withPhotoModel: false)
        defer { rig.temp.cleanup() }
        rig.vm.load()
        XCTAssertNil(rig.vm.partnerPhoto, "Stub 構成は写真を扱わない")
        XCTAssertEqual(rig.provider.thumbnailCalls.count, 0)
    }
}

// MARK: - ⑤ App Group・ディスクに書かない

@MainActor
final class PartnerPhotoStorageTests: XCTestCase {
    func testNothingIsWrittenToTheAppGroupContainer() async throws {
        let temp = TempStore()
        defer { temp.cleanup() }
        try temp.store.saveSnapshot(PartnerPhotoFixtures.pairedSnapshot())
        let before = try listing(of: temp.directory)
        XCTAssertEqual(before, [AppGroupStore.snapshotFileName])

        let provider = MockPartnerPhotoProvider()
        provider.thumbnailResult = .success(PartnerPhotoFixtures.thumbnail())
        provider.originalResult = .success(TestImages.photoImage(width: 160, height: 120))
        let model = PartnerPhotoModel(
            provider: provider,
            now: { PartnerPhotoFixtures.now },
            calendar: PartnerPhotoFixtures.tokyo
        )
        let vm = HomeViewModel(
            store: temp.store,
            checkinService: LocalEchoCheckinService(),
            partnerPhoto: model,
            reloadWidgets: {}
        )

        vm.load()
        await model.fetchTask?.value
        model.openViewer()
        await model.viewerTask?.value
        model.closeViewer()
        await vm.performCheckin()

        XCTAssertEqual(try listing(of: temp.directory), before, "写真・署名付き URL のためのファイルは作らない")
        XCTAssertFalse(FileManager.default.fileExists(atPath: temp.store.photoThumbFileURL.path), "photo_thumb.jpg はウィジェット(v1.0.1)の置き場所。ホームの写真は書かない")
    }

    func testThePhotoSourcesNeverReachForPersistentStorage() throws {
        // 相手の写真は「見るだけ」で、端末に残さない。保存の手段をソースに持ち込んでいないことを固定する
        let files = [
            "Lien/Core/PartnerPhoto.swift",
            "Lien/Core/PartnerPhotoLoader.swift",
            "Lien/Core/PartnerPhotoService.swift",
            "Lien/Core/Api/StoragePhotoURLSigner.swift",
            "Lien/Features/Home/PartnerPhotoModel.swift",
            "Lien/Features/Home/PartnerPhotoView.swift",
        ]
        let forbidden = [
            "AppGroupStore", "containerURL", "FileManager", "UserDefaults", "URLCache.shared", "URLCache(",
            ".write(to", "createFile", "Keychain", "@AppStorage", "@SceneStorage",
        ]
        for file in files {
            let code = Self.strippingComments(try SourceTree.text(file))
            XCTAssertFalse(code.isEmpty, file)
            for token in forbidden {
                XCTAssertFalse(code.contains(token), "\(file) が保存の手段 \(token) を使っている")
            }
        }
    }

    func testDownloadsUseAnEphemeralSessionWithoutACache() {
        let session = URLSessionPartnerPhotoLoader.makeEphemeralSession()
        XCTAssertNil(session.configuration.urlCache, "URL キャッシュ(ディスク)を持たない")
        XCTAssertEqual(session.configuration.requestCachePolicy, .reloadIgnoringLocalAndRemoteCacheData)
    }

    // MARK: 道具

    /// コンテナ直下のファイル名(並べ替え済み)
    private func listing(of directory: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
    }

    /// 行コメント(// … 行末)とブロックコメント(/* … */)を取り除く(コメントに「使わない」と書いた語を拾わない)
    private static func strippingComments(_ source: String) -> String {
        var text = source
        if let block = try? NSRegularExpression(pattern: #"/\*.*?\*/"#, options: [.dotMatchesLineSeparators]) {
            text = block.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "")
        }
        if let line = try? NSRegularExpression(pattern: #"//[^\n]*"#) {
            text = line.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "")
        }
        return text
    }
}
