// PartnerPhotoRevalidationTests.swift — 相手の今日の写真の「取り直し」まわり(PV #59 の Opus レビューの仕上げ)
//
//   1. 通信の失敗のそろえ方     : 行の読み取り(NudgeReactClientError.network)・トークンの更新(URLError)の通信失敗を
//                                PartnerPhotoError.network にそろえる(それ以外はそのまま)
//   2. オフラインの取り直し     : 15 分たって取り直すとき、オフラインでも出している今日の写真を捨てない。
//                                モデルのテスト(モック)だけでなく、Live のサービス+URLProtocol スタブの結合で確かめる
//                                (モックでは `PartnerPhotoError.network` を直接返せるが、本番の部品がそれを返すとは限らなかった)
//   3. 読めなかった日の取り直し  : 行が無い・規約に合わない・署名が弾かれた・サーバーの失敗は、(ペア, 日付)ごとに
//                                数分間覚えて、同期のたびに通信しない(読み込みの枠が出ては消えない)。通信の失敗は覚えない
//   4. カードの大きさ           : 縦横比から、最大の大きさに収まる大きさを計算で決める(縦長で外枠だけが広がらない)
//
// 通信の層の個別のテストは PartnerPhotoNetworkTests、モデルの基本は PartnerPhotoTests。

import XCTest
@testable import Lien

// MARK: - 道具

private let baseURL = URL(string: "https://example.supabase.co")!
private let tokenProvider: () async throws -> String = { "test-token" }

private func makeSession() -> URLSession {
    StubURLProtocol.reset()
    return StubURLProtocol.makeSession()
}

/// モデルが見る時計(テストが進める)
private final class Clock {
    var now = PartnerPhotoFixtures.now
    func advance(_ seconds: TimeInterval) { now = now.addingTimeInterval(seconds) }
}

private struct SomeError: Error {}

// MARK: - 1. 通信の失敗のそろえ方

final class PartnerPhotoConnectivityTests: XCTestCase {
    func testConnectivityFailuresAreNormalizedToTheNetworkError() {
        let connectivity: [Error] = [
            NudgeReactClientError.network, // PostgREST の読み取りが応答なしで終わった
            URLError(.notConnectedToInternet), // トークンの更新(supabase-swift)がオフラインで落ちた
            URLError(.timedOut), URLError(.networkConnectionLost), URLError(.cannotFindHost),
        ]
        for error in connectivity {
            XCTAssertEqual(PartnerPhotoError.normalizingConnectivity(error) as? PartnerPhotoError, .network, "\(error)")
        }
        XCTAssertTrue(PartnerPhotoError.network.isConnectivityFailure)
    }

    func testOtherFailuresAreLeftAsTheyAre() {
        XCTAssertTrue(PartnerPhotoError.normalizingConnectivity(NudgeReactClientError.server(code: "http_500")) is NudgeReactClientError)
        XCTAssertTrue(PartnerPhotoError.normalizingConnectivity(AuthServiceError.notSignedIn) is AuthServiceError)
        XCTAssertEqual(PartnerPhotoError.normalizingConnectivity(PartnerPhotoError.notFound) as? PartnerPhotoError, .notFound)
        XCTAssertTrue(PartnerPhotoError.normalizingConnectivity(SomeError()) is SomeError)
        for error in [PartnerPhotoError.notFound, .unauthorized, .expired, .server(status: 500), .tooLarge, .invalidImage, .invalidResponse, .invalidPath] {
            XCTAssertFalse(error.isConnectivityFailure, "\(error) は読めなくなった側(通信の失敗ではない)")
        }
    }

    func testACancelledRequestIsACancellationNotAFailure() {
        XCTAssertTrue(PartnerPhotoError.normalizingConnectivity(URLError(.cancelled)) is CancellationError)
        XCTAssertTrue(PartnerPhotoError.normalizingConnectivity(CancellationError()) is CancellationError)
    }

    // MARK: Live のサービス(行の読み取り・トークンの更新の失敗がそろう)

    private final class OfflineCheckins: PartnerCheckinResolving {
        let error: Error
        init(_ error: Error) { self.error = error }
        func partnerCheckin(dateLocal: String) async throws -> PartnerCheckin? { throw error }
    }

    private final class FailingSigner: PhotoURLSigning {
        let error: Error
        init(_ error: Error) { self.error = error }
        func signedURL(forPath path: String) async throws -> SignedPhotoURL { throw error }
    }

    private final class UnusedLoader: PartnerPhotoImageLoading {
        func loadImage(from url: URL, limits: PartnerPhotoLimits) async throws -> PartnerPhotoImage {
            throw PartnerPhotoError.invalidImage
        }
    }

    private final class RowCheckins: PartnerCheckinResolving {
        func partnerCheckin(dateLocal: String) async throws -> PartnerCheckin? {
            PartnerCheckin(id: PartnerPhotoFixtures.partnerCheckinID, photoPath: PartnerPhotoFixtures.originalPath())
        }
    }

    func testTheServiceReportsAnOfflineRowReadAsTheNetworkError() async {
        let service = LivePartnerPhotoService(
            checkins: OfflineCheckins(NudgeReactClientError.network),
            signer: FailingSigner(PartnerPhotoError.notFound),
            loader: UnusedLoader()
        )
        do {
            _ = try await service.loadThumbnail(pairID: PartnerPhotoFixtures.pairID, dateLocal: PartnerPhotoFixtures.today)
            XCTFail("オフラインなのに成功してしまった")
        } catch {
            XCTAssertEqual(error as? PartnerPhotoError, .network, "モデルが「通信が切れていただけ」と読めるように、そろえて返す")
        }
    }

    func testTheServiceKeepsOtherRowFailuresAsTheyAre() async {
        let service = LivePartnerPhotoService(
            checkins: OfflineCheckins(NudgeReactClientError.server(code: "http_401")),
            signer: FailingSigner(PartnerPhotoError.notFound),
            loader: UnusedLoader()
        )
        do {
            _ = try await service.loadThumbnail(pairID: PartnerPhotoFixtures.pairID, dateLocal: PartnerPhotoFixtures.today)
            XCTFail("成功してしまった")
        } catch {
            XCTAssertEqual(error as? NudgeReactClientError, .server(code: "http_401"), "認証の失敗は通信の失敗ではない")
        }
    }

    func testTheServiceReportsAnOfflineTokenRefreshAsTheNetworkError() async {
        // 署名のためのトークンの更新(supabase-swift)がオフラインで URLError を投げた
        let service = LivePartnerPhotoService(
            checkins: RowCheckins(),
            signer: FailingSigner(URLError(.notConnectedToInternet)),
            loader: UnusedLoader()
        )
        do {
            _ = try await service.loadThumbnail(pairID: PartnerPhotoFixtures.pairID, dateLocal: PartnerPhotoFixtures.today)
            XCTFail("成功してしまった")
        } catch {
            XCTAssertEqual(error as? PartnerPhotoError, .network)
        }
        do {
            _ = try await service.loadOriginal(of: PartnerPhotoFixtures.reference())
            XCTFail("成功してしまった")
        } catch {
            XCTAssertEqual(error as? PartnerPhotoError, .network, "原寸もそろえる")
        }
    }
}

// MARK: - 2・3. モデル(モック)— 読めなかった日の取り直し

@MainActor
final class PartnerPhotoUnreadableDayTests: XCTestCase {
    private struct Rig {
        let provider: MockPartnerPhotoProvider
        let clock: Clock
        let model: PartnerPhotoModel
    }

    private func makeRig() -> Rig {
        let provider = MockPartnerPhotoProvider()
        let clock = Clock()
        let model = PartnerPhotoModel(
            provider: provider,
            now: { clock.now },
            calendar: PartnerPhotoFixtures.tokyo
        )
        return Rig(provider: provider, clock: clock, model: model)
    }

    private let interval = PartnerPhotoModel.unreadableRetryInterval

    // MARK: 読めなかった日は、数分間 取り直さない

    func testADayWithoutAReadablePhotoIsNotFetchedAgainWithinTheRetryInterval() async {
        // 同じ日にペアを組み直して、photo_path が前のペアのまま(サービスが nil を返す)など
        let rig = makeRig()
        rig.provider.thumbnailResult = .success(nil)
        let snapshot = PartnerPhotoFixtures.pairedSnapshot()

        await rig.model.update(with: snapshot)
        XCTAssertEqual(rig.provider.thumbnailCalls.count, 1)
        XCTAssertEqual(rig.model.state, .hidden)

        // onAppear・前面復帰・同期・自分の操作(apply)のたび
        for _ in 0..<4 {
            rig.clock.advance(20)
            rig.model.snapshotDidChange(snapshot)
            XCTAssertEqual(rig.model.state, .hidden, "読み込みの枠を出し直さない(レイアウトが跳ねない)")
        }
        XCTAssertEqual(rig.provider.thumbnailCalls.count, 1, "行の読み取りと署名・取得をやり直さない")
        XCTAssertNil(rig.model.fetchTask, "新しい取得は走らせていない")
    }

    func testTheDayIsTriedAgainAfterTheRetryInterval() async {
        let rig = makeRig()
        rig.provider.thumbnailResult = .success(nil)
        let snapshot = PartnerPhotoFixtures.pairedSnapshot()
        await rig.model.update(with: snapshot)

        // 直したあと(相手が貼り直した)でも、間隔の間は待つ
        rig.provider.thumbnailResult = .success(PartnerPhotoFixtures.thumbnail())
        rig.clock.advance(interval - 1)
        await rig.model.update(with: snapshot)
        XCTAssertEqual(rig.model.state, .hidden)
        XCTAssertEqual(rig.provider.thumbnailCalls.count, 1)

        rig.clock.advance(2) // 間隔を過ぎた
        await rig.model.update(with: snapshot)
        XCTAssertEqual(rig.provider.thumbnailCalls.count, 2, "間隔を過ぎた次の機会に取り直す")
        if case .ready = rig.model.state {} else { XCTFail("取り直して出るはず: \(rig.model.state)") }
    }

    func testEveryKindOfUnreadableFailureIsRememberedExceptConnectivity() async {
        let remembered: [Error] = [
            PartnerPhotoError.notFound, PartnerPhotoError.unauthorized, PartnerPhotoError.expired,
            PartnerPhotoError.server(status: 500), PartnerPhotoError.invalidImage, PartnerPhotoError.tooLarge,
            AuthServiceError.notSignedIn, NudgeReactClientError.server(code: "http_500"), SomeError(),
        ]
        for error in remembered {
            let rig = makeRig()
            rig.provider.thumbnailResult = .failure(error)
            let snapshot = PartnerPhotoFixtures.pairedSnapshot()
            await rig.model.update(with: snapshot)
            rig.clock.advance(30)
            rig.model.snapshotDidChange(snapshot)
            rig.model.snapshotDidChange(snapshot)
            XCTAssertEqual(rig.provider.thumbnailCalls.count, 1, "読めなかった日は取り直さない: \(error)")
            XCTAssertEqual(rig.model.state, .hidden, "\(error)")
        }
    }

    func testAConnectivityFailureIsNotRememberedSoTheNextChanceRetriesAtOnce() async {
        // 前面に戻った直後は電波がまだ戻っていないことがある。そのあとの同期(電波が戻った最初の機会)で、すぐ取り直したい
        let rig = makeRig()
        rig.provider.thumbnailResult = .failure(PartnerPhotoError.network)
        let snapshot = PartnerPhotoFixtures.pairedSnapshot()
        await rig.model.update(with: snapshot)
        XCTAssertEqual(rig.model.state, .hidden)

        rig.provider.thumbnailResult = .success(PartnerPhotoFixtures.thumbnail())
        await rig.model.update(with: snapshot) // 時刻は進めない
        XCTAssertEqual(rig.provider.thumbnailCalls.count, 2, "通信が切れていただけの失敗は覚えない")
        if case .ready = rig.model.state {} else { XCTFail("電波が戻ったら出るはず: \(rig.model.state)") }
    }

    // MARK: 忘れるとき

    func testTheUnreadableMemoryIsForgottenWhenThePairOrTheDayChanges() async {
        let rig = makeRig()
        rig.provider.thumbnailResult = .success(nil)
        await rig.model.update(with: PartnerPhotoFixtures.pairedSnapshot())
        XCTAssertEqual(rig.provider.thumbnailCalls.count, 1)

        // 別のペア(組み直し)は、前のペアで読めなかったことを引きずらない
        await rig.model.update(with: PartnerPhotoFixtures.pairedSnapshot(pairID: PartnerPhotoFixtures.otherPairID))
        XCTAssertEqual(rig.provider.thumbnailCalls.count, 2)
        XCTAssertEqual(rig.provider.thumbnailCalls.last?.pairID, PartnerPhotoFixtures.otherPairID)

        // 日付が変わった
        let nextDay = rig.clock.now.addingTimeInterval(24 * 3600)
        rig.clock.now = nextDay
        await rig.model.update(with: PartnerPhotoFixtures.pairedSnapshot(pairID: PartnerPhotoFixtures.otherPairID, updatedAt: nextDay))
        XCTAssertEqual(rig.provider.thumbnailCalls.count, 3)
        XCTAssertEqual(rig.provider.thumbnailCalls.last?.dateLocal, PartnerPhotoFixtures.tomorrow)
    }

    func testTheUnreadableMemoryIsForgottenWhenThereIsNoPhotoAnymore() async {
        let rig = makeRig()
        rig.provider.thumbnailResult = .success(nil)
        await rig.model.update(with: PartnerPhotoFixtures.pairedSnapshot())

        // 相手が写真を取り消した(hasPartnerPhotoToday=false)あと、また添えた
        await rig.model.update(with: PartnerPhotoFixtures.pairedSnapshot(hasPartnerPhotoToday: false))
        rig.provider.thumbnailResult = .success(PartnerPhotoFixtures.thumbnail())
        await rig.model.update(with: PartnerPhotoFixtures.pairedSnapshot())

        XCTAssertEqual(rig.provider.thumbnailCalls.count, 2, "新しい情報(写真の有無が変わった)で、取り直す")
        if case .ready = rig.model.state {} else { XCTFail("出るはず: \(rig.model.state)") }
    }

    func testASuccessfulFetchClearsTheMemoryAndTheCacheTakesOver() async {
        let rig = makeRig()
        rig.provider.thumbnailResult = .success(nil)
        let snapshot = PartnerPhotoFixtures.pairedSnapshot()
        await rig.model.update(with: snapshot)
        rig.clock.advance(interval + 1)
        rig.provider.thumbnailResult = .success(PartnerPhotoFixtures.thumbnail())
        await rig.model.update(with: snapshot)
        XCTAssertEqual(rig.provider.thumbnailCalls.count, 2)

        // 出せたあとは、キャッシュの間隔(15 分)で動く。読めなかった間隔には戻らない
        rig.clock.advance(60)
        await rig.model.update(with: snapshot)
        XCTAssertEqual(rig.provider.thumbnailCalls.count, 2)
        if case .ready = rig.model.state {} else { XCTFail("出たまま: \(rig.model.state)") }
    }

    // MARK: 再確認で読めなくなった

    func testRevalidationThatFindsTheDayUnreadableDropsThePhotoAndRemembersIt() async {
        let rig = makeRig()
        rig.provider.thumbnailResult = .success(PartnerPhotoFixtures.thumbnail())
        let snapshot = PartnerPhotoFixtures.pairedSnapshot()
        await rig.model.update(with: snapshot)

        rig.provider.thumbnailResult = .failure(PartnerPhotoError.notFound) // ペア解消の反映より先に RLS が閉じた
        rig.clock.advance(PartnerPhotoModel.revalidateInterval + 1)
        await rig.model.update(with: snapshot)
        XCTAssertEqual(rig.model.state, .hidden)

        rig.clock.advance(30)
        rig.model.snapshotDidChange(snapshot)
        XCTAssertEqual(rig.provider.thumbnailCalls.count, 2, "捨てた直後に、また取りに行かない")
        XCTAssertEqual(rig.model.state, .hidden)
    }

    func testRevalidationKeepsThePhotoWhileOfflineAndRetriesOnEveryChance() async {
        let rig = makeRig()
        let photo = PartnerPhotoFixtures.thumbnail()
        rig.provider.thumbnailResult = .success(photo)
        let snapshot = PartnerPhotoFixtures.pairedSnapshot()
        await rig.model.update(with: snapshot)

        rig.provider.thumbnailResult = .failure(PartnerPhotoError.network)
        rig.clock.advance(PartnerPhotoModel.revalidateInterval + 1)
        await rig.model.update(with: snapshot)
        await rig.model.update(with: snapshot)

        XCTAssertEqual(rig.model.state, .ready(photo), "オフラインの間は、出している今日の写真を捨てない")
        XCTAssertEqual(rig.provider.thumbnailCalls.count, 3, "通信の失敗は覚えない。次の機会にまた取り直す")

        // 電波が戻った: 差し替わった写真を拾う
        let replaced = PartnerPhotoFixtures.thumbnail(image: TestImages.photoImage(width: 48, height: 64))
        rig.provider.thumbnailResult = .success(replaced)
        await rig.model.update(with: snapshot)
        XCTAssertEqual(rig.model.state, .ready(replaced))
    }
}

// MARK: - 2. Live のサービス+URLProtocol スタブの結合 — オフラインの取り直し

@MainActor
final class PartnerPhotoOfflineRevalidationTests: XCTestCase {
    private let me = UUID(uuidString: "a1111111-1111-4111-8111-111111111111")!

    private struct Rig {
        let model: PartnerPhotoModel
        let clock: Clock
    }

    /// 本番の部品(PostgREST の読み・署名・ダウンロード・サービス)を、スタブのセッションでつなぐ。
    /// online が false の間は、`/rest/v1/checkins` が URLError.notConnectedToInternet で落ちる(機内モード相当)
    private func makeRig(
        online: @escaping () -> Bool,
        jpeg: @escaping () -> Data,
        token: @escaping () async throws -> String = tokenProvider
    ) -> Rig {
        let session = makeSession()
        StubURLProtocol.handler = { request in
            guard let url = request.url else { return (404, Data()) }
            if !online() { throw URLError(.notConnectedToInternet) }
            if url.path == "/rest/v1/checkins" {
                return (200, try ContractFixtures.data("partner-checkin.photo"))
            }
            if url.path.hasPrefix("/storage/v1/object/sign/photos/") {
                if request.httpMethod == "POST" { return (200, try ContractFixtures.data("storage-sign.ok")) }
                return (200, jpeg())
            }
            return (404, Data())
        }
        let service = LivePartnerPhotoService(
            checkins: PostgRESTPartnerCheckinResolver(
                baseURL: baseURL, apiKey: "test-anon-key", tokenProvider: token,
                currentUserID: { [me] in me }, session: session
            ),
            signer: StoragePhotoURLSigner(baseURL: baseURL, apiKey: "test-anon-key", tokenProvider: token, session: session),
            loader: URLSessionPartnerPhotoLoader(session: session)
        )
        let clock = Clock()
        let model = PartnerPhotoModel(provider: service, now: { clock.now }, calendar: PartnerPhotoFixtures.tokyo)
        return Rig(model: model, clock: clock)
    }

    private func readyWidth(_ model: PartnerPhotoModel) -> Int? {
        if case .ready(let photo) = model.state { return photo.image.pixelWidth }
        return nil
    }

    func testTheShownPhotoSurvivesAnOfflineRevalidationAndTheNextOnlineChanceReplacesIt() async {
        var online = true
        var jpeg = TestImages.jpegData(width: 400, height: 300)
        let rig = makeRig(online: { online }, jpeg: { jpeg })
        let snapshot = PartnerPhotoFixtures.pairedSnapshot()

        await rig.model.update(with: snapshot)
        XCTAssertEqual(readyWidth(rig.model), 400, "初回は出る")
        XCTAssertEqual(StubURLProtocol.captured.count, 3, "行 → 署名 → 取得")

        // 15 分たって取り直すとき、機内モード: 行の読み取りが落ちる(本番の部品の実際の失敗の仕方)
        online = false
        rig.clock.advance(PartnerPhotoModel.revalidateInterval + 1)
        await rig.model.update(with: snapshot)

        XCTAssertEqual(readyWidth(rig.model), 400, "オフラインで取り直せなかっただけなら、出している今日の写真は消さない")
        XCTAssertEqual(StubURLProtocol.captured.count, 4, "取り直そうとはした(行の読み取りが1本落ちた)")
        XCTAssertEqual(StubURLProtocol.captured.last?.url?.path, "/rest/v1/checkins")

        // 電波が戻った最初の機会(時刻は進めない)に、すぐ取り直す。相手が同じ日に貼り直した写真が出る
        online = true
        jpeg = TestImages.jpegData(width: 300, height: 400)
        await rig.model.update(with: snapshot)
        XCTAssertEqual(readyWidth(rig.model), 300, "通信の失敗は覚えていない")
    }

    func testAnOfflineTokenRefreshAlsoKeepsTheShownPhoto() async {
        // 行の読み取りより先に、トークンの更新(supabase-swift)が URLError で落ちる経路
        var offlineToken = false
        let rig = makeRig(
            online: { true },
            jpeg: { TestImages.jpegData(width: 400, height: 300) },
            token: {
                if offlineToken { throw URLError(.notConnectedToInternet) }
                return "test-token"
            }
        )
        let snapshot = PartnerPhotoFixtures.pairedSnapshot()
        await rig.model.update(with: snapshot)
        XCTAssertEqual(readyWidth(rig.model), 400)

        offlineToken = true
        rig.clock.advance(PartnerPhotoModel.revalidateInterval + 1)
        await rig.model.update(with: snapshot)

        XCTAssertEqual(readyWidth(rig.model), 400, "トークンの更新が通信で落ちただけでも、写真は消さない")
    }

    func testFirstLoadWhileOfflineShowsNothingAndTriesAgainOnTheNextChance() async {
        var online = false
        let rig = makeRig(online: { online }, jpeg: { TestImages.jpegData(width: 400, height: 300) })
        let snapshot = PartnerPhotoFixtures.pairedSnapshot()

        await rig.model.update(with: snapshot)
        XCTAssertEqual(rig.model.state, .hidden, "オフラインの初回は、何も出さない(文言も出さない)")

        online = true
        await rig.model.update(with: snapshot)
        XCTAssertEqual(readyWidth(rig.model), 400, "電波が戻った最初の機会に出る")
    }

    func testAPhotoPathLeftByAnotherPairIsTriedOnlyOnceWithinTheRetryInterval() async {
        // 同じ日にペアを組み直して、photo_path が前のペアの pair_id のまま(サムネも原寸も読めない)
        let session = makeSession()
        let stalePath = PartnerPhotoFixtures.originalPath(pairID: PartnerPhotoFixtures.otherPairID)
        let body = Data(#"[{"id":"\#(PartnerPhotoFixtures.partnerCheckinID)","photo_path":"\#(stalePath)"}]"#.utf8)
        StubURLProtocol.handler = { request in
            if request.url?.path == "/rest/v1/checkins" { return (200, body) }
            return (500, Data())
        }
        let service = LivePartnerPhotoService(
            checkins: PostgRESTPartnerCheckinResolver(
                baseURL: baseURL, apiKey: "test-anon-key", tokenProvider: tokenProvider,
                currentUserID: { [me] in me }, session: session
            ),
            signer: StoragePhotoURLSigner(baseURL: baseURL, apiKey: "test-anon-key", tokenProvider: tokenProvider, session: session),
            loader: URLSessionPartnerPhotoLoader(session: session)
        )
        let clock = Clock()
        let model = PartnerPhotoModel(provider: service, now: { clock.now }, calendar: PartnerPhotoFixtures.tokyo)
        let snapshot = PartnerPhotoFixtures.pairedSnapshot()

        await model.update(with: snapshot)
        for _ in 0..<5 {
            clock.advance(10)
            await model.update(with: snapshot)
        }

        XCTAssertEqual(model.state, .hidden)
        XCTAssertEqual(StubURLProtocol.captured.count, 1, "行を1回読んだだけ。同期のたびに読み取りをやり直さない")
    }
}

// MARK: - 4. カードの大きさ

final class PartnerPhotoCardLayoutTests: XCTestCase {
    private func fitted(_ width: Int, _ height: Int) -> CGSize {
        PartnerPhotoCardLayout.fittedSize(aspectRatio: CGFloat(width) / CGFloat(height))
    }

    func testLandscapeFillsTheMaximumWidth() {
        let size = fitted(512, 384)
        XCTAssertEqual(size.width, 260, accuracy: 0.001)
        XCTAssertEqual(size.height, 195, accuracy: 0.001)
    }

    func testPortraitIsNarrowerThanTheMaximumWidth() {
        // 縦長の写真は、枠も写真と同じ幅に。外枠だけが幅いっぱいの 260 のまま残らない(角丸が写真に掛かる・余白がタップできない)
        let size = fitted(384, 512)
        XCTAssertEqual(size.width, 225, accuracy: 0.001)
        XCTAssertEqual(size.height, 300, accuracy: 0.001)
        XCTAssertLessThan(size.width, PartnerPhotoCardLayout.maxWidth)
    }

    func testSquareAndExtremeShapesStayInsideTheMaximumAndKeepTheirRatio() {
        let square = fitted(100, 100)
        XCTAssertEqual(square.width, 260, accuracy: 0.001)
        XCTAssertEqual(square.height, 260, accuracy: 0.001)

        for (w, h) in [(1000, 100), (100, 1000), (4096, 3072), (3072, 4096), (1, 1), (2048, 2048)] {
            let size = fitted(w, h)
            XCTAssertLessThanOrEqual(size.width, PartnerPhotoCardLayout.maxWidth + 0.001, "\(w)x\(h)")
            XCTAssertLessThanOrEqual(size.height, PartnerPhotoCardLayout.maxHeight + 0.001, "\(w)x\(h)")
            XCTAssertEqual(size.width / size.height, CGFloat(w) / CGFloat(h), accuracy: 0.0001, "縦横比を保つ: \(w)x\(h)")
            let touchesAnEdge = abs(size.width - PartnerPhotoCardLayout.maxWidth) < 0.001
                || abs(size.height - PartnerPhotoCardLayout.maxHeight) < 0.001
            XCTAssertTrue(touchesAnEdge, "最大の大きさに収まる、いちばん大きい大きさ: \(w)x\(h)")
        }
    }

    func testBrokenAspectRatiosFallBackToASquare() {
        for ratio in [CGFloat(0), -1, .nan, .infinity] {
            let size = PartnerPhotoCardLayout.fittedSize(aspectRatio: ratio)
            XCTAssertEqual(size.width, size.height, accuracy: 0.001, "\(ratio)")
            XCTAssertEqual(size.width, 260, accuracy: 0.001, "\(ratio)")
        }
    }

    func testThePhotoImageReportsItsAspectRatio() {
        XCTAssertEqual(TestImages.photoImage(width: 384, height: 512).aspectRatio, 0.75, accuracy: 0.0001)
        XCTAssertEqual(PartnerPhotoCardLayout.fittedSize(aspectRatio: TestImages.photoImage(width: 384, height: 512).aspectRatio).width, 225, accuracy: 0.001)
    }
}
