// CheckinAPIClientTests.swift — checkin / checkin-cancel 応答のデコード+契約整合(T14)
//
// JSON フィクスチャはサーバー実装(checkin/core.ts CheckinResult / checkin-cancel/core.ts
// CheckinCancelResult)の応答形と一字一句揃える。サーバー側の契約が変わったら
// このテストとモデル(CheckinAPIClient.swift)の両方を直すこと(T11/T12 と同じ方針)。

import XCTest
@testable import Lien

final class CheckinAPIClientTests: XCTestCase {
    /// checkin/core.ts が返す snapshot 部分(_shared/snapshot.ts buildPairSnapshot の形)
    private let snapshotJSON = """
        {
          "schemaVersion": 1,
          "pairId": "pair-1",
          "updatedAt": "2026-06-10T03:00:00.000Z",
          "streakCurrent": 6,
          "streakBest": 6,
          "todayMeDone": true,
          "todayPartnerDone": false,
          "myPromiseTitle": "筋トレ",
          "myPromiseEmoji": "💪",
          "partnerName": "ゆうき",
          "partnerPromiseTitle": "ランニング",
          "partnerPromiseEmoji": "🏃",
          "plantStage": 3,
          "plantMood": "fidget",
          "plantName": "みどり",
          "hasPartnerPhotoToday": false
        }
        """

    // MARK: CheckinResponse

    func testDecodeCheckinResponseWithoutPhotoUpload() throws {
        // requestPhotoUpload なしの応答は photoUpload キー自体が無い(checkin/core.ts)
        let json = """
            { "alreadyCheckedIn": false, "snapshot": \(snapshotJSON) }
            """
        let response = try PairSnapshot.makeJSONDecoder()
            .decode(CheckinResponse.self, from: Data(json.utf8))

        XCTAssertFalse(response.alreadyCheckedIn)
        XCTAssertNil(response.photoUpload)
        XCTAssertEqual(response.snapshot.pairId, "pair-1")
        XCTAssertEqual(response.snapshot.streakCurrent, 6)
        XCTAssertTrue(response.snapshot.todayMeDone)
        XCTAssertEqual(response.snapshot.plantMood, .fidget)
        XCTAssertEqual(
            response.snapshot.updatedAt,
            Date(timeIntervalSince1970: 1_781_060_400), // 2026-06-10T03:00:00Z
            "ISO8601(小数秒あり)をデコードできる"
        )
    }

    func testDecodeCheckinResponseWithPhotoUpload() throws {
        // requestPhotoUpload: true の応答(checkin/core.ts PhotoUploadUrls)
        let json = """
            {
              "alreadyCheckedIn": true,
              "snapshot": \(snapshotJSON),
              "photoUpload": {
                "photo": { "path": "pairs/pair-1/2026-06-10/photo.jpg", "token": "tok-1" },
                "thumb": { "path": "pairs/pair-1/2026-06-10/photo_thumb.jpg", "token": "tok-2" }
              }
            }
            """
        let response = try PairSnapshot.makeJSONDecoder()
            .decode(CheckinResponse.self, from: Data(json.utf8))

        XCTAssertTrue(response.alreadyCheckedIn)
        XCTAssertEqual(
            response.photoUpload,
            PhotoUploadURLs(
                photo: PhotoUploadTarget(path: "pairs/pair-1/2026-06-10/photo.jpg", token: "tok-1"),
                thumb: PhotoUploadTarget(path: "pairs/pair-1/2026-06-10/photo_thumb.jpg", token: "tok-2")
            )
        )
    }

    // MARK: CheckinCancelResponse

    func testDecodeCheckinCancelResponse() throws {
        let json = """
            { "alreadyCanceled": true, "snapshot": \(snapshotJSON) }
            """
        let response = try PairSnapshot.makeJSONDecoder()
            .decode(CheckinCancelResponse.self, from: Data(json.utf8))

        XCTAssertTrue(response.alreadyCanceled)
        XCTAssertEqual(response.snapshot.partnerName, "ゆうき")
    }

    // MARK: エラーコードのマップ(出典: checkin / checkin-cancel の core.ts / index.ts)

    func testServerErrorCodeMapping() {
        XCTAssertEqual(CheckinClientError(serverCode: "invalid_date_local"), .invalidDateLocal)
        XCTAssertEqual(CheckinClientError(serverCode: "date_local_out_of_range"), .dateOutOfRange)
        XCTAssertEqual(CheckinClientError(serverCode: "date_local_not_today"), .notToday)
        XCTAssertEqual(CheckinClientError(serverCode: "no_promise"), .noPromise)
        XCTAssertEqual(CheckinClientError(serverCode: "no_pair"), .noPair)
        XCTAssertEqual(CheckinClientError(serverCode: "invalid_photo_path"), .invalidPhotoPath)
        XCTAssertEqual(CheckinClientError(serverCode: "user_not_found"), .userNotFound)
        XCTAssertEqual(CheckinClientError(serverCode: "unauthorized"), .unauthorized)
        XCTAssertEqual(
            CheckinClientError(serverCode: "internal_error"),
            .server(code: "internal_error")
        )
    }

    func testOnlyNetworkErrorIsRetryable() {
        XCTAssertTrue(CheckinClientError.network.isRetryable)
        XCTAssertFalse(CheckinClientError.notToday.isRetryable, "400 は再送しても結果不変 → 破棄")
        XCTAssertFalse(CheckinClientError.noPromise.isRetryable)
        XCTAssertFalse(CheckinClientError.server(code: "internal_error").isRetryable)
    }

    // MARK: 署名付きアップロードURLの組み立て(storage-js uploadToSignedUrl と同形)

    func testSignedUploadURLBuilding() throws {
        let url = EdgeFunctionCheckinClient.signedUploadURL(
            baseURL: try XCTUnwrap(URL(string: "https://example.supabase.co")),
            target: PhotoUploadTarget(path: "pairs/pair-1/2026-06-10/photo.jpg", token: "tok-1")
        )
        XCTAssertEqual(
            url?.absoluteString,
            "https://example.supabase.co/storage/v1/object/upload/sign/photos/pairs/pair-1/2026-06-10/photo.jpg?token=tok-1"
        )
    }
}
