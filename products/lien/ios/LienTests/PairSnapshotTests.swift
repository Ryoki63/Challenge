// PairSnapshotTests.swift — App Group 共有契約(DESIGN §3.4)のデコード/エンコード検証(T07)

import XCTest
@testable import Lien

final class PairSnapshotTests: XCTestCase {
    /// DESIGN §3.4 の JSON 例をフィクスチャ化(schemaVersion = 1。キー名は一字一句契約どおり)
    private let designExampleJSON = """
    {
      "schemaVersion": 1,
      "pairId": "1f0c5a4e-9d3b-4c1a-8f2e-7b6d5a4c3b2a",
      "updatedAt": "2026-06-11T08:30:00Z",
      "streakCurrent": 23,
      "streakBest": 40,
      "todayMeDone": true,
      "todayPartnerDone": false,
      "myPromiseTitle": "筋トレ", "myPromiseEmoji": "💪",
      "partnerName": "ゆうき",
      "partnerPromiseTitle": "ランニング", "partnerPromiseEmoji": "🏃",
      "plantStage": 3,
      "plantMood": "normal",
      "plantName": "みどり",
      "hasPartnerPhotoToday": false
    }
    """

    private func decode(_ json: String) throws -> PairSnapshot {
        try PairSnapshot.makeJSONDecoder()
            .decode(PairSnapshot.self, from: Data(json.utf8))
    }

    // MARK: - §3.4 の例のデコード

    func testDecodeDesignExample() throws {
        let snapshot = try decode(designExampleJSON)

        XCTAssertEqual(snapshot.schemaVersion, 1)
        XCTAssertEqual(snapshot.pairId, "1f0c5a4e-9d3b-4c1a-8f2e-7b6d5a4c3b2a")
        XCTAssertEqual(
            snapshot.updatedAt,
            Date(timeIntervalSince1970: 1_781_166_600) // 2026-06-11T08:30:00Z
        )
        XCTAssertEqual(snapshot.streakCurrent, 23)
        XCTAssertEqual(snapshot.streakBest, 40)
        XCTAssertTrue(snapshot.todayMeDone)
        XCTAssertFalse(snapshot.todayPartnerDone)
        XCTAssertEqual(snapshot.myPromiseTitle, "筋トレ")
        XCTAssertEqual(snapshot.myPromiseEmoji, "💪")
        XCTAssertEqual(snapshot.partnerName, "ゆうき")
        XCTAssertEqual(snapshot.partnerPromiseTitle, "ランニング")
        XCTAssertEqual(snapshot.partnerPromiseEmoji, "🏃")
        XCTAssertEqual(snapshot.plantStage, 3)
        XCTAssertEqual(snapshot.plantMood, .normal)
        XCTAssertEqual(snapshot.plantName, "みどり")
        XCTAssertFalse(snapshot.hasPartnerPhotoToday)
    }

    // MARK: - 防御的デコード(境界の耐性)

    func testDecodeNullPairIdAsSolo() throws {
        let json = designExampleJSON.replacingOccurrences(
            of: "\"1f0c5a4e-9d3b-4c1a-8f2e-7b6d5a4c3b2a\"",
            with: "null"
        )
        let snapshot = try decode(json)
        XCTAssertNil(snapshot.pairId, "pairId は null(ソロ状態)を許容する(§3.4)")
    }

    func testDecodeIgnoresUnknownKeys() throws {
        let json = designExampleJSON.replacingOccurrences(
            of: "\"schemaVersion\": 1,",
            with: "\"schemaVersion\": 1, \"futureKey\": {\"nested\": true}, \"anotherNew\": 42,"
        )
        let snapshot = try decode(json)
        XCTAssertEqual(snapshot.streakCurrent, 23, "未知キーがあってもデコードできる(前方互換)")
    }

    func testDecodeUnknownPlantMoodFallsBackToNormal() throws {
        let json = designExampleJSON.replacingOccurrences(
            of: "\"plantMood\": \"normal\"",
            with: "\"plantMood\": \"sparkle_dance\""
        )
        let snapshot = try decode(json)
        XCTAssertEqual(snapshot.plantMood, .normal, "未知の plantMood は .normal にフォールバック")
    }

    func testDecodeAllKnownPlantMoods() throws {
        for (raw, expected): (String, PlantMood) in [
            ("normal", .normal), ("happy", .happy), ("fidget", .fidget), ("sad", .sad),
        ] {
            let json = designExampleJSON.replacingOccurrences(
                of: "\"plantMood\": \"normal\"",
                with: "\"plantMood\": \"\(raw)\""
            )
            XCTAssertEqual(try decode(json).plantMood, expected)
        }
    }

    func testDecodeUpdatedAtWithFractionalSeconds() throws {
        let json = designExampleJSON.replacingOccurrences(
            of: "2026-06-11T08:30:00Z",
            with: "2026-06-11T08:30:00.123Z"
        )
        let snapshot = try decode(json)
        XCTAssertEqual(
            snapshot.updatedAt.timeIntervalSince1970,
            1_781_166_600.123,
            accuracy: 0.001,
            "小数秒つき ISO8601 も受け付ける"
        )
    }

    func testDecodeMinimalJSONUsesDefaults() throws {
        // schemaVersion / updatedAt 以外の欠落はデフォルトで埋める(防御的デコード)
        let snapshot = try decode("""
        { "schemaVersion": 1, "updatedAt": "2026-06-11T00:00:00Z" }
        """)
        XCTAssertNil(snapshot.pairId)
        XCTAssertEqual(snapshot.streakCurrent, 0)
        XCTAssertEqual(snapshot.streakBest, 0)
        XCTAssertFalse(snapshot.todayMeDone)
        XCTAssertFalse(snapshot.todayPartnerDone)
        XCTAssertEqual(snapshot.plantStage, 0)
        XCTAssertEqual(snapshot.plantMood, .normal)
        XCTAssertFalse(snapshot.hasPartnerPhotoToday)
    }

    func testDecodeFailsWithoutUpdatedAt() {
        XCTAssertThrowsError(try decode("{ \"schemaVersion\": 1 }"))
    }

    func testDecodeFailsWithoutSchemaVersion() {
        XCTAssertThrowsError(try decode("{ \"updatedAt\": \"2026-06-11T00:00:00Z\" }"))
    }

    // MARK: - エンコード(往復)

    func testEncodeDecodeRoundTrip() throws {
        let original = try decode(designExampleJSON)
        let data = try PairSnapshot.makeJSONEncoder().encode(original)
        let decoded = try PairSnapshot.makeJSONDecoder().decode(PairSnapshot.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    func testEncodeWritesExplicitNullPairId() throws {
        var snapshot = try decode(designExampleJSON)
        snapshot.pairId = nil
        let data = try PairSnapshot.makeJSONEncoder().encode(snapshot)
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertTrue(text.contains("\"pairId\":null"), "§3.4 の \"uuid | null\" 契約どおり null を明示する")
    }

    // MARK: - 日付跨ぎ用のリセット(DESIGN §3.5)

    func testResettingForNewDayClearsTodayState() throws {
        var snapshot = try decode(designExampleJSON)
        snapshot.todayMeDone = true
        snapshot.todayPartnerDone = true
        snapshot.hasPartnerPhotoToday = true
        snapshot.plantMood = .happy

        let reset = snapshot.resettingForNewDay()

        XCTAssertFalse(reset.todayMeDone)
        XCTAssertFalse(reset.todayPartnerDone)
        XCTAssertFalse(reset.hasPartnerPhotoToday)
        XCTAssertEqual(reset.plantMood, .normal)
        // 今日の状態以外は維持する
        XCTAssertEqual(reset.streakCurrent, snapshot.streakCurrent)
        XCTAssertEqual(reset.streakBest, snapshot.streakBest)
        XCTAssertEqual(reset.pairId, snapshot.pairId)
        XCTAssertEqual(reset.plantStage, snapshot.plantStage)
        XCTAssertEqual(reset.partnerName, snapshot.partnerName)
    }
}
