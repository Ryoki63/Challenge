// PartnerPhotoNetworkTests.swift — 相手の今日の写真の通信の層(PV / issue #59)
//
// URLProtocol スタブ(StubURLProtocol — TestSupport.swift)でネットワク無しに検証する:
//   - StoragePhotoURLSigner           : 署名付き URL の要求(URL・認証ヘッダ・本文)と応答・エラー
//   - URLSessionPartnerPhotoLoader    : ダウンロード(ステータス別の扱い・サイズ上限・JPEG だけ・縮小・キャッシュなし)
//   - PartnerPhotoImageDecoder        : ImageIO のデコード(向き・拡大しない・巨大な画素数の拒否)
//   - LivePartnerPhotoService         : 行 → 署名 → 取得のつなぎ(サムネ優先・原寸で代用・失効は1回だけ再署名)
//   - PartnerPhotoContractTests       : contracts/ の手書きフィクスチャ(PostgREST と Storage の応答)を本番の部品で読む
//
// フィクスチャは手書き(サーバーの Edge Function ではなく PostgREST / Storage の応答なので、generate.ts では作れない)。
// 本番の実応答との突き合わせは backend レーンの API E2E(#67)が行う(contracts/README.md)。

import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import Lien

private let baseURL = URL(string: "https://example.supabase.co")!

private func makeSession() -> URLSession {
    StubURLProtocol.reset()
    return StubURLProtocol.makeSession()
}

private func json(_ text: String) -> Data { Data(text.utf8) }

private func reply(_ status: Int, _ body: String) {
    StubURLProtocol.handler = { _ in (status, json(body)) }
}

private let tokenProvider: () async throws -> String = { "test-token" }

// MARK: - 署名付き URL(Storage)

final class StoragePhotoURLSignerTests: XCTestCase {
    private let fixedNow = PartnerPhotoFixtures.now
    private let thumbnailPath = PartnerPhotoFixtures.thumbnailPath()
    private let signedBody = """
    {"signedURL":"/object/sign/photos/pairs/1f0c5a4e-9d3b-4c1a-8f2e-7b6d5a4c3b2a/2026-06-11/b2222222-2222-4222-8222-222222222222/photo_thumb.jpg?token=signed-download-token-1"}
    """

    private func makeSigner(
        tokenProvider: @escaping () async throws -> String = tokenProvider
    ) -> StoragePhotoURLSigner {
        StoragePhotoURLSigner(
            baseURL: baseURL,
            apiKey: "test-anon-key",
            tokenProvider: tokenProvider,
            session: makeSession(),
            now: { [fixedNow] in fixedNow }
        )
    }

    func testRequestIsAnAuthenticatedPostToTheSignEndpointOfThePhotosBucket() async throws {
        let signer = makeSigner()
        reply(200, signedBody)

        let signed = try await signer.signedURL(forPath: thumbnailPath)

        let request = try XCTUnwrap(StubURLProtocol.captured.first)
        XCTAssertEqual(
            request.url?.absoluteString,
            "https://example.supabase.co/storage/v1/object/sign/photos/\(thumbnailPath)"
        )
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.header("Authorization"), "Bearer test-token", "利用者の JWT で作る(RLS が読めるかを決める)")
        XCTAssertEqual(request.header("apikey"), "test-anon-key")
        XCTAssertEqual(request.header("Content-Type"), "application/json")
        XCTAssertEqual(request.jsonObject?["expiresIn"] as? Int, 3600, "署名付き URL の寿命は 3600 秒")
        XCTAssertEqual(StubURLProtocol.captured.count, 1)

        XCTAssertEqual(
            signed.url.absoluteString,
            "https://example.supabase.co/storage/v1/object/sign/photos/\(thumbnailPath)?token=signed-download-token-1",
            "応答のルート相対の URL に {base}/storage/v1 を付けて絶対 URL にする"
        )
        XCTAssertEqual(signed.expiresAt, fixedNow.addingTimeInterval(3600))
    }

    func testAbsoluteURLHandlesEveryShapeOfTheSignedPath() throws {
        let base = URL(string: "https://example.supabase.co")!
        let relative = "/object/sign/photos/a/b.jpg?token=t"
        let expected = "https://example.supabase.co/storage/v1/object/sign/photos/a/b.jpg?token=t"

        XCTAssertEqual(StoragePhotoURLSigner.absoluteURL(baseURL: base, signedPath: relative)?.absoluteString, expected)
        XCTAssertEqual(
            StoragePhotoURLSigner.absoluteURL(baseURL: base, signedPath: "object/sign/photos/a/b.jpg?token=t")?.absoluteString,
            expected, "先頭の / が無くても同じ"
        )
        XCTAssertEqual(
            StoragePhotoURLSigner.absoluteURL(baseURL: base, signedPath: "/storage/v1/object/sign/photos/a/b.jpg?token=t")?.absoluteString,
            expected, "/storage/v1 が付いて返っても二重に付けない"
        )
        XCTAssertEqual(
            StoragePhotoURLSigner.absoluteURL(baseURL: URL(string: "https://example.supabase.co/")!, signedPath: relative)?.absoluteString,
            expected, "base の末尾のスラッシュ"
        )
        XCTAssertEqual(
            StoragePhotoURLSigner.absoluteURL(baseURL: base, signedPath: expected)?.absoluteString,
            expected, "同じホストの絶対 URL"
        )
    }

    func testAbsoluteURLRefusesOtherHostsAndGarbage() {
        let base = URL(string: "https://example.supabase.co")!
        XCTAssertNil(StoragePhotoURLSigner.absoluteURL(baseURL: base, signedPath: "https://evil.example.com/object/sign/photos/a.jpg?token=t"), "よそのホストへ読みに行かない")
        XCTAssertNil(StoragePhotoURLSigner.absoluteURL(baseURL: base, signedPath: "http://example.supabase.co/object/sign/photos/a.jpg?token=t"), "https から http へ落とさない")
        XCTAssertNil(StoragePhotoURLSigner.absoluteURL(baseURL: base, signedPath: ""))
        XCTAssertNil(StoragePhotoURLSigner.absoluteURL(baseURL: base, signedPath: "   "))
    }

    func testRefusesPathsThatBreakTheConventionWithoutSendingARequest() async throws {
        let signer = makeSigner()
        reply(200, signedBody)
        for path in ["", "../photo.jpg", "pairs//x.jpg", "a b", "pairs/x?y=1"] {
            do {
                _ = try await signer.signedURL(forPath: path)
                XCTFail("通ってしまった: \(path)")
            } catch {
                XCTAssertEqual(error as? PartnerPhotoError, .invalidPath, path)
            }
        }
        XCTAssertTrue(StubURLProtocol.captured.isEmpty, "不正なパスでは通信しない")
    }

    func testStatusCodesMapToTheErrors() async throws {
        let cases: [(status: Int, expected: PartnerPhotoError)] = [
            (401, .unauthorized), (403, .unauthorized), (404, .notFound),
            (400, .server(status: 400)), (500, .server(status: 500)), (503, .server(status: 503)),
        ]
        for entry in cases {
            let signer = makeSigner()
            reply(entry.status, #"{"statusCode":"404","error":"not_found","message":"Object not found"}"#)
            do {
                _ = try await signer.signedURL(forPath: thumbnailPath)
                XCTFail("\(entry.status) で成功してしまった")
            } catch {
                XCTAssertEqual(error as? PartnerPhotoError, entry.expected, "\(entry.status)")
            }
        }
    }

    func testUnreadableBodyIsAnInvalidResponse() async throws {
        for body in ["", "not json", "{}", #"{"signedURL":""}"#, #"{"signedURL":"https://evil.example.com/x?token=t"}"#, #"{"signedURL":42}"#] {
            let signer = makeSigner()
            reply(200, body)
            do {
                _ = try await signer.signedURL(forPath: thumbnailPath)
                XCTFail("読めない応答で成功してしまった: \(body)")
            } catch {
                XCTAssertEqual(error as? PartnerPhotoError, .invalidResponse, body)
            }
        }
    }

    func testToleratesTheAlternativeSpellingOfTheKey() async throws {
        let signer = makeSigner()
        reply(200, #"{"signedUrl":"/object/sign/photos/a/b.jpg?token=t"}"#)
        let signed = try await signer.signedURL(forPath: "a/b.jpg")
        XCTAssertEqual(signed.url.absoluteString, "https://example.supabase.co/storage/v1/object/sign/photos/a/b.jpg?token=t")
    }

    func testNetworkFailure() async throws {
        let signer = makeSigner()
        StubURLProtocol.handler = { _ in throw URLError(.notConnectedToInternet) }
        do {
            _ = try await signer.signedURL(forPath: thumbnailPath)
            XCTFail("オフラインで成功してしまった")
        } catch {
            XCTAssertEqual(error as? PartnerPhotoError, .network)
        }
    }

    func testTokenFailureIsPassedThroughWithoutARequest() async throws {
        let signer = makeSigner(tokenProvider: { throw AuthServiceError.notSignedIn })
        reply(200, signedBody)
        do {
            _ = try await signer.signedURL(forPath: thumbnailPath)
            XCTFail("未サインインで成功してしまった")
        } catch {
            XCTAssertEqual(error as? AuthServiceError, .notSignedIn)
        }
        XCTAssertTrue(StubURLProtocol.captured.isEmpty)
    }
}

// MARK: - ダウンロード

final class URLSessionPartnerPhotoLoaderTests: XCTestCase {
    private let url = URL(string: "https://example.supabase.co/storage/v1/object/sign/photos/a/photo_thumb.jpg?token=t")!

    private func makeLoader() -> URLSessionPartnerPhotoLoader {
        URLSessionPartnerPhotoLoader(session: makeSession())
    }

    private func serve(_ status: Int, _ body: Data) {
        StubURLProtocol.handler = { _ in (status, body) }
    }

    func testDownloadsAndShrinksAJPEG() async throws {
        let loader = makeLoader()
        serve(200, TestImages.jpegData(width: 2000, height: 1500))

        let image = try await loader.loadImage(from: url, limits: PartnerPhotoLimits(maxBytes: 1_000_000, maxPixelSize: 800))

        XCTAssertEqual(max(image.pixelWidth, image.pixelHeight), 800, "長辺を maxPixelSize に縮める")
        XCTAssertEqual(image.pixelWidth, 800)
        XCTAssertEqual(image.pixelHeight, 600, "縦横比は保つ")
    }

    func testDoesNotEnlargeASmallImage() async throws {
        let loader = makeLoader()
        serve(200, TestImages.jpegData(width: 300, height: 200))
        let image = try await loader.loadImage(from: url, limits: .thumbnail)
        XCTAssertEqual(image.pixelWidth, 300, "サムネ(512px)を 800px に引き伸ばさない")
        XCTAssertEqual(image.pixelHeight, 200)
    }

    func testTheDownloadCarriesNoCredentials() async throws {
        let loader = makeLoader()
        serve(200, TestImages.jpegData(width: 64, height: 48))
        _ = try await loader.loadImage(from: url, limits: .thumbnail)

        let request = try XCTUnwrap(StubURLProtocol.captured.first)
        XCTAssertEqual(request.method, "GET")
        XCTAssertEqual(request.url, url, "署名付き URL をそのまま取る")
        XCTAssertNil(request.header("Authorization"), "署名はクエリの token が担う。JWT を写真の取得に付けない")
        XCTAssertNil(request.header("apikey"))
    }

    func testStatusCodesMapToTheErrors() async throws {
        let cases: [(status: Int, expected: PartnerPhotoError)] = [
            (400, .expired), (401, .expired), (403, .expired), // 署名付き URL の失効・無効(署名からやり直す)
            (404, .notFound), (500, .server(status: 500)), (503, .server(status: 503)),
        ]
        for entry in cases {
            let loader = makeLoader()
            serve(entry.status, json(#"{"statusCode":"400","error":"InvalidJWT","message":"\"exp\" claim timestamp check failed"}"#))
            do {
                _ = try await loader.loadImage(from: url, limits: .thumbnail)
                XCTFail("\(entry.status) で成功してしまった")
            } catch {
                XCTAssertEqual(error as? PartnerPhotoError, entry.expected, "\(entry.status)")
            }
        }
    }

    func testNetworkFailure() async throws {
        let loader = makeLoader()
        StubURLProtocol.handler = { _ in throw URLError(.timedOut) }
        do {
            _ = try await loader.loadImage(from: url, limits: .thumbnail)
            XCTFail("通信できないのに成功してしまった")
        } catch {
            XCTAssertEqual(error as? PartnerPhotoError, .network)
        }
    }

    func testStopsWhenTheBodyExceedsTheByteLimit() async throws {
        let loader = makeLoader()
        let jpeg = TestImages.jpegData(width: 640, height: 480)
        XCTAssertGreaterThan(jpeg.count, 100)
        serve(200, jpeg)
        do {
            _ = try await loader.loadImage(from: url, limits: PartnerPhotoLimits(maxBytes: 100, maxPixelSize: 800))
            XCTFail("上限を超えたのに成功してしまった")
        } catch {
            XCTAssertEqual(error as? PartnerPhotoError, .tooLarge, "相手が大きなファイルを置いても、端末のメモリを使い切らない")
        }

        // 上限ちょうどなら通る
        serve(200, jpeg)
        let image = try await loader.loadImage(from: url, limits: PartnerPhotoLimits(maxBytes: jpeg.count, maxPixelSize: 800))
        XCTAssertEqual(image.pixelWidth, 640)
    }

    func testRejectsAnythingButJPEG() async throws {
        for body in [TestImages.pngData(width: 64, height: 48), Data("not an image".utf8), Data()] {
            let loader = makeLoader()
            serve(200, body)
            do {
                _ = try await loader.loadImage(from: url, limits: .thumbnail)
                XCTFail("JPEG でないのに成功してしまった")
            } catch {
                XCTAssertEqual(error as? PartnerPhotoError, .invalidImage)
            }
        }
    }

    func testRejectsAnImageWithTooManyPixels() async throws {
        let loader = makeLoader()
        serve(200, TestImages.jpegData(width: PartnerPhotoImageDecoder.maxSourceDimension + 1, height: 8))
        do {
            _ = try await loader.loadImage(from: url, limits: .original)
            XCTFail("大きすぎる画素数で成功してしまった")
        } catch {
            XCTAssertEqual(error as? PartnerPhotoError, .invalidImage, "アプリが上げる写真は長辺 2048px 以下。圧縮された巨大画像は展開しない")
        }

        serve(200, TestImages.jpegData(width: PartnerPhotoImageDecoder.maxSourceDimension, height: 8))
        let ok = try await loader.loadImage(from: url, limits: PartnerPhotoLimits(maxBytes: 1_000_000, maxPixelSize: 1600))
        XCTAssertEqual(ok.pixelWidth, 1600)
    }
}

final class PartnerPhotoImageDecoderTests: XCTestCase {
    func testAppliesTheExifOrientationToThePixels() throws {
        // 横長 200x100 を「90度回転して表示する」向き(6)で保存した JPEG は、縦長 100x200 として見える
        let data = TestImages.jpegData(width: 200, height: 100, orientation: 6)
        let image = try PartnerPhotoImageDecoder.decode(data, maxPixelSize: 800)
        XCTAssertEqual(image.pixelWidth, 100)
        XCTAssertEqual(image.pixelHeight, 200, "向きの情報を持たないビューアでも正しく見えるよう、画素に反映する")
        XCTAssertEqual(image.aspectRatio, 0.5, accuracy: 0.001)
    }

    func testUnreadableAndNonJPEGAreInvalid() {
        XCTAssertThrowsError(try PartnerPhotoImageDecoder.decode(Data(), maxPixelSize: 800)) {
            XCTAssertEqual($0 as? PartnerPhotoError, .invalidImage)
        }
        XCTAssertThrowsError(try PartnerPhotoImageDecoder.decode(TestImages.pngData(width: 8, height: 8), maxPixelSize: 800)) {
            XCTAssertEqual($0 as? PartnerPhotoError, .invalidImage)
        }
    }
}

// MARK: - 行 → 署名 → 取得(LivePartnerPhotoService)

/// 呼び出しを記録し、結果を順に返す署名役(最後の結果は繰り返す)
private final class ScriptedSigner: PhotoURLSigning {
    private(set) var paths: [String] = []
    var results: [Result<SignedPhotoURL, Error>]
    private var index = 0

    init(_ results: [Result<SignedPhotoURL, Error>]) {
        self.results = results
    }

    func signedURL(forPath path: String) async throws -> SignedPhotoURL {
        paths.append(path)
        let result = results[min(index, results.count - 1)]
        index += 1
        return try result.get()
    }

    static func url(_ token: String) -> SignedPhotoURL {
        SignedPhotoURL(
            url: URL(string: "https://example.supabase.co/storage/v1/object/sign/photos/x.jpg?token=\(token)")!,
            expiresAt: PartnerPhotoFixtures.now.addingTimeInterval(3600)
        )
    }
}

private final class ScriptedLoader: PartnerPhotoImageLoading {
    private(set) var calls: [(url: URL, limits: PartnerPhotoLimits)] = []
    var results: [Result<PartnerPhotoImage, Error>]
    private var index = 0

    init(_ results: [Result<PartnerPhotoImage, Error>]) {
        self.results = results
    }

    func loadImage(from url: URL, limits: PartnerPhotoLimits) async throws -> PartnerPhotoImage {
        calls.append((url, limits))
        let result = results[min(index, results.count - 1)]
        index += 1
        return try result.get()
    }
}

private final class ScriptedCheckins: PartnerCheckinResolving {
    var row: PartnerCheckin?
    var error: Error?
    private(set) var requestedDates: [String] = []

    func partnerCheckin(dateLocal: String) async throws -> PartnerCheckin? {
        requestedDates.append(dateLocal)
        if let error { throw error }
        return row
    }
}

final class LivePartnerPhotoServiceTests: XCTestCase {
    private let today = PartnerPhotoFixtures.today
    private let pairID = PartnerPhotoFixtures.pairID

    private struct Rig {
        let service: LivePartnerPhotoService
        let checkins: ScriptedCheckins
        let signer: ScriptedSigner
        let loader: ScriptedLoader
    }

    private func makeRig(
        row: PartnerCheckin? = PartnerCheckin(id: PartnerPhotoFixtures.partnerCheckinID, photoPath: PartnerPhotoFixtures.originalPath()),
        signs: [Result<SignedPhotoURL, Error>] = [.success(ScriptedSigner.url("t1"))],
        loads: [Result<PartnerPhotoImage, Error>] = [.success(TestImages.photoImage())]
    ) -> Rig {
        let checkins = ScriptedCheckins()
        checkins.row = row
        let signer = ScriptedSigner(signs)
        let loader = ScriptedLoader(loads)
        return Rig(
            service: LivePartnerPhotoService(checkins: checkins, signer: signer, loader: loader),
            checkins: checkins,
            signer: signer,
            loader: loader
        )
    }

    // MARK: サムネ

    func testLoadsTheThumbnailOfTodaysPhoto() async throws {
        let image = TestImages.photoImage(width: 80, height: 60)
        let rig = makeRig(loads: [.success(image)])

        let thumbnail = try await rig.service.loadThumbnail(pairID: pairID, dateLocal: today)

        XCTAssertEqual(rig.checkins.requestedDates, [today])
        XCTAssertEqual(rig.signer.paths, [PartnerPhotoFixtures.thumbnailPath()], "サムネ(photo_thumb.jpg)を署名する")
        XCTAssertEqual(rig.loader.calls.map { $0.limits }, [.thumbnail])
        XCTAssertEqual(rig.loader.calls.first?.url, ScriptedSigner.url("t1").url)
        XCTAssertEqual(thumbnail?.image, image)
        XCTAssertEqual(thumbnail?.reference, PartnerPhotoFixtures.reference(), "指し先は原寸のパス(タップで原寸を取る・通報が控える)")
    }

    func testPairIDMayBeUppercase() async throws {
        let rig = makeRig()
        let thumbnail = try await rig.service.loadThumbnail(pairID: pairID.uppercased(), dateLocal: today)
        XCTAssertNotNil(thumbnail)
        XCTAssertEqual(thumbnail?.reference.pairID, pairID)
    }

    func testNothingToShowWhenThereIsNoRowOrNoPhotoPath() async throws {
        for row in [nil, PartnerCheckin(id: PartnerPhotoFixtures.partnerCheckinID, photoPath: nil)] {
            let rig = makeRig(row: row)
            let thumbnail = try await rig.service.loadThumbnail(pairID: pairID, dateLocal: today)
            XCTAssertNil(thumbnail)
            XCTAssertTrue(rig.signer.paths.isEmpty, "photo_path が無ければ署名もしない")
            XCTAssertTrue(rig.loader.calls.isEmpty)
        }
    }

    func testPathsOfOtherPairsOtherDatesOrBrokenShapesAreNotShown() async throws {
        let bad = [
            PartnerPhotoFixtures.originalPath(pairID: PartnerPhotoFixtures.otherPairID), // 別のペア
            PartnerPhotoFixtures.originalPath(dateLocal: PartnerPhotoFixtures.tomorrow), // 別の日
            "pairs/\(pairID)/\(today)/../photo.jpg",
            "somewhere/else.jpg",
            "",
        ]
        for path in bad {
            let rig = makeRig(row: PartnerCheckin(id: PartnerPhotoFixtures.partnerCheckinID, photoPath: path))
            let thumbnail = try await rig.service.loadThumbnail(pairID: pairID, dateLocal: today)
            XCTAssertNil(thumbnail, path)
            XCTAssertTrue(rig.signer.paths.isEmpty, "規約に合わないパスは署名しない: \(path)")
        }
    }

    func testRowFailureIsPassedUp() async throws {
        let rig = makeRig()
        rig.checkins.error = NudgeReactClientError.server(code: "http_401")
        do {
            _ = try await rig.service.loadThumbnail(pairID: pairID, dateLocal: today)
            XCTFail("行が読めないのに成功してしまった")
        } catch {
            XCTAssertEqual(error as? NudgeReactClientError, .server(code: "http_401"))
        }
        XCTAssertTrue(rig.signer.paths.isEmpty)
    }

    // MARK: 署名付き URL の失効

    func testAnExpiredSignedURLIsSignedAgainOnce() async throws {
        let image = TestImages.photoImage()
        let rig = makeRig(
            signs: [.success(ScriptedSigner.url("old")), .success(ScriptedSigner.url("new"))],
            loads: [.failure(PartnerPhotoError.expired), .success(image)]
        )

        let thumbnail = try await rig.service.loadThumbnail(pairID: pairID, dateLocal: today)

        XCTAssertEqual(thumbnail?.image, image, "失効で弾かれても、署名からやり直して表示できる")
        XCTAssertEqual(rig.signer.paths, [PartnerPhotoFixtures.thumbnailPath(), PartnerPhotoFixtures.thumbnailPath()])
        XCTAssertEqual(
            rig.loader.calls.map { $0.url.absoluteString },
            [ScriptedSigner.url("old").url.absoluteString, ScriptedSigner.url("new").url.absoluteString],
            "2回目は作り直した URL で取る"
        )
    }

    func testExpiryIsRetriedOnlyOnce() async throws {
        let rig = makeRig(loads: [.failure(PartnerPhotoError.expired)])
        do {
            _ = try await rig.service.loadThumbnail(pairID: pairID, dateLocal: today)
            XCTFail("失効し続けているのに成功してしまった")
        } catch {
            XCTAssertEqual(error as? PartnerPhotoError, .expired)
        }
        XCTAssertEqual(rig.signer.paths.count, 2, "再署名は1回だけ(無限に繰り返さない)。原寸での代用もしない")
        XCTAssertEqual(rig.loader.calls.count, 2)
    }

    // MARK: サムネが無いとき

    func testFallsBackToTheOriginalWhenTheThumbnailIsMissing() async throws {
        let image = TestImages.photoImage(width: 90, height: 60)
        let rig = makeRig(
            signs: [.failure(PartnerPhotoError.notFound), .success(ScriptedSigner.url("orig"))],
            loads: [.success(image)]
        )

        let thumbnail = try await rig.service.loadThumbnail(pairID: pairID, dateLocal: today)

        XCTAssertEqual(thumbnail?.image, image)
        XCTAssertEqual(rig.signer.paths, [PartnerPhotoFixtures.thumbnailPath(), PartnerPhotoFixtures.originalPath()])
        XCTAssertEqual(rig.loader.calls.map { $0.limits }, [.thumbnailFromOriginal], "原寸を取って、サムネの大きさまで縮める")
    }

    func testFallsBackToTheOriginalWhenTheThumbnailIsUnreadable() async throws {
        for failure in [PartnerPhotoError.invalidImage, .tooLarge, .server(status: 400), .invalidResponse] {
            let rig = makeRig(loads: [.failure(failure), .success(TestImages.photoImage())])
            let thumbnail = try await rig.service.loadThumbnail(pairID: pairID, dateLocal: today)
            XCTAssertNotNil(thumbnail, "\(failure)")
            XCTAssertEqual(rig.signer.paths.last, PartnerPhotoFixtures.originalPath(), "\(failure)")
        }
    }

    func testDoesNotTryTheOriginalWhenTheNetworkIsDownOrAuthFails() async throws {
        let failures: [Error] = [PartnerPhotoError.network, PartnerPhotoError.unauthorized, AuthServiceError.notSignedIn, CancellationError()]
        for failure in failures {
            let rig = makeRig(signs: [.failure(failure)])
            do {
                _ = try await rig.service.loadThumbnail(pairID: pairID, dateLocal: today)
                XCTFail("成功してしまった: \(failure)")
            } catch {
                XCTAssertEqual(rig.signer.paths.count, 1, "原寸でも同じ失敗になるので試さない: \(failure)")
            }
        }
    }

    func testTheOriginalFallbackFailureIsPassedUp() async throws {
        let rig = makeRig(signs: [.failure(PartnerPhotoError.notFound), .failure(PartnerPhotoError.notFound)])
        do {
            _ = try await rig.service.loadThumbnail(pairID: pairID, dateLocal: today)
            XCTFail("どちらも無いのに成功してしまった")
        } catch {
            XCTAssertEqual(error as? PartnerPhotoError, .notFound)
        }
        XCTAssertEqual(rig.signer.paths.count, 2)
    }

    // MARK: 原寸

    func testLoadsTheOriginalForTheFullScreen() async throws {
        let image = TestImages.photoImage(width: 160, height: 120)
        let rig = makeRig(loads: [.success(image)])

        let loaded = try await rig.service.loadOriginal(of: PartnerPhotoFixtures.reference())

        XCTAssertEqual(loaded, image)
        XCTAssertEqual(rig.signer.paths, [PartnerPhotoFixtures.originalPath()], "原寸(photo.jpg)を署名する")
        XCTAssertEqual(rig.loader.calls.map { $0.limits }, [.original])
        XCTAssertTrue(rig.checkins.requestedDates.isEmpty, "指し先が分かっているので、行は読み直さない")
    }

    func testOriginalWithAnInvalidReferenceIsRefused() async throws {
        let rig = makeRig()
        let bad = PartnerPhotoReference(pairID: pairID, dateLocal: today, photoPath: "pairs/../x.jpg")
        do {
            _ = try await rig.service.loadOriginal(of: bad)
            XCTFail("不正な指し先で成功してしまった")
        } catch {
            XCTAssertEqual(error as? PartnerPhotoError, .invalidPath)
        }
        XCTAssertTrue(rig.signer.paths.isEmpty)
    }

    func testAnExpiredSignedURLForTheOriginalIsSignedAgain() async throws {
        // 全画面を開くのはサムネを取った後(ホームに長くいた後かもしれない)。失効しても署名からやり直す
        let image = TestImages.photoImage()
        let rig = makeRig(
            signs: [.success(ScriptedSigner.url("stale")), .success(ScriptedSigner.url("fresh"))],
            loads: [.failure(PartnerPhotoError.expired), .success(image)]
        )
        let loaded = try await rig.service.loadOriginal(of: PartnerPhotoFixtures.reference())
        XCTAssertEqual(loaded, image)
        XCTAssertEqual(rig.signer.paths.count, 2)
    }
}

// MARK: - 契約フィクスチャ(手書き: PostgREST と Storage の応答)

final class PartnerPhotoContractTests: XCTestCase {
    private let pairID = PartnerPhotoFixtures.pairID
    private let partnerCheckinID = PartnerPhotoFixtures.partnerCheckinID

    func testPartnerCheckinWithPhotoDecodes() throws {
        let rows = try JSONDecoder().decode([PartnerCheckinRow].self, from: ContractFixtures.data("partner-checkin.photo"))
        let row = try XCTUnwrap(rows.first)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(row.id, partnerCheckinID)
        XCTAssertEqual(row.photoPath, PartnerPhotoFixtures.originalPath())

        // photo_path は規約どおりで、snapshot.paired.json(同じ世界の応答)のペア・日付と一致する
        let path = try XCTUnwrap(PartnerPhotoPath(try XCTUnwrap(row.photoPath)))
        let snapshot = try ContractFixtures.decode(SnapshotResponse.self, from: "snapshot.paired").snapshot
        XCTAssertTrue(snapshot.hasPartnerPhotoToday)
        XCTAssertEqual(path.pairID, snapshot.pairId)
        XCTAssertEqual(path.dateLocal, PartnerPhotoFixtures.today)
        XCTAssertEqual(path.thumbnail, PartnerPhotoFixtures.thumbnailPath())
    }

    func testPartnerCheckinWithoutPhotoDecodes() throws {
        let rows = try JSONDecoder().decode([PartnerCheckinRow].self, from: ContractFixtures.data("partner-checkin.no-photo"))
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.id, partnerCheckinID)
        XCTAssertNil(rows.first?.photoPath, "photo_path が null の行 = 写真なし")
    }

    func testNoPartnerCheckinDecodesAsAnEmptyList() throws {
        let rows = try JSONDecoder().decode([PartnerCheckinRow].self, from: ContractFixtures.data("partner-checkin.none"))
        XCTAssertTrue(rows.isEmpty, "相手がまだチェックインしていない・RLS で読めない = 空の配列")
    }

    func testStorageSignResponseDecodesAndBuildsTheDownloadURL() throws {
        let response = try JSONDecoder().decode(StorageSignResponse.self, from: ContractFixtures.data("storage-sign.ok"))
        XCTAssertEqual(
            response.signedURL,
            "/object/sign/photos/\(PartnerPhotoFixtures.thumbnailPath())?token=signed-download-token-1"
        )
        let url = try XCTUnwrap(StoragePhotoURLSigner.absoluteURL(baseURL: baseURL, signedPath: response.signedURL))
        XCTAssertEqual(
            url.absoluteString,
            "https://example.supabase.co/storage/v1/object/sign/photos/\(PartnerPhotoFixtures.thumbnailPath())?token=signed-download-token-1"
        )
    }

    /// 本番の部品(PostgREST の読み・署名・ダウンロード・サービス)を、フィクスチャの応答でつないで通す
    func testWholeFlowThroughTheProductionPartsWithFixtureResponses() async throws {
        let session = makeSession()
        let jpeg = TestImages.jpegData(width: 400, height: 300)
        StubURLProtocol.handler = { request in
            guard let url = request.url else { return (404, Data()) }
            if url.path == "/rest/v1/checkins" {
                return (200, try ContractFixtures.data("partner-checkin.photo"))
            }
            if url.path.hasPrefix("/storage/v1/object/sign/photos/") {
                if request.httpMethod == "POST" { return (200, try ContractFixtures.data("storage-sign.ok")) }
                return (200, jpeg)
            }
            return (404, Data())
        }
        let me = UUID(uuidString: "a1111111-1111-4111-8111-111111111111")!
        let service = LivePartnerPhotoService(
            checkins: PostgRESTPartnerCheckinResolver(
                baseURL: baseURL, apiKey: "test-anon-key", tokenProvider: tokenProvider,
                currentUserID: { me }, session: session
            ),
            signer: StoragePhotoURLSigner(
                baseURL: baseURL, apiKey: "test-anon-key", tokenProvider: tokenProvider, session: session
            ),
            loader: URLSessionPartnerPhotoLoader(session: session)
        )

        let thumbnail = try await service.loadThumbnail(pairID: pairID, dateLocal: PartnerPhotoFixtures.today)

        let photo = try XCTUnwrap(thumbnail)
        XCTAssertEqual(photo.image.pixelWidth, 400)
        XCTAssertEqual(photo.reference, PartnerPhotoFixtures.reference())

        // 通信は3本: 相手の行(GET)→ サムネの署名(POST)→ 署名付き URL の取得(GET)
        let captured = StubURLProtocol.captured
        XCTAssertEqual(captured.map { $0.method }, ["GET", "POST", "GET"])
        XCTAssertEqual(captured[0].url?.path, "/rest/v1/checkins")
        XCTAssertEqual(captured[1].url?.path, "/storage/v1/object/sign/photos/\(PartnerPhotoFixtures.thumbnailPath())")
        XCTAssertEqual(
            captured[2].url?.absoluteString,
            "https://example.supabase.co/storage/v1/object/sign/photos/\(PartnerPhotoFixtures.thumbnailPath())?token=signed-download-token-1"
        )
        XCTAssertNil(captured[2].header("Authorization"), "写真の取得に JWT を付けない")
        XCTAssertEqual(captured[0].header("Authorization"), "Bearer test-token")
        XCTAssertEqual(captured[1].header("Authorization"), "Bearer test-token")
    }

    func testWholeFlowShowsNothingForARowWithoutAPhoto() async throws {
        let session = makeSession()
        StubURLProtocol.handler = { request in
            if request.url?.path == "/rest/v1/checkins" {
                return (200, try ContractFixtures.data("partner-checkin.no-photo"))
            }
            return (500, Data())
        }
        let me = UUID(uuidString: "a1111111-1111-4111-8111-111111111111")!
        let service = LivePartnerPhotoService(
            checkins: PostgRESTPartnerCheckinResolver(
                baseURL: baseURL, apiKey: "test-anon-key", tokenProvider: tokenProvider,
                currentUserID: { me }, session: session
            ),
            signer: StoragePhotoURLSigner(baseURL: baseURL, apiKey: "test-anon-key", tokenProvider: tokenProvider, session: session),
            loader: URLSessionPartnerPhotoLoader(session: session)
        )

        let thumbnail = try await service.loadThumbnail(pairID: pairID, dateLocal: PartnerPhotoFixtures.today)

        XCTAssertNil(thumbnail)
        XCTAssertEqual(StubURLProtocol.captured.count, 1, "photo_path が無ければ、行を読んだだけで終わる(署名もダウンロードもしない)")
    }
}
