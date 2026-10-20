// PairSnapshotTests.swift — App Group 共有契約(DESIGN §3.4)のデコード/エンコード検証(T07)
// 成長ルール v2 の新キー3つ(plantGrownDays / plantStageFloor / plantNextStageAt)は省略可: 無いとき nil(ゲージを出さない)、
// あるときは値を読み、書き出して読み戻しても一致する(PB #57)。
// お休みチケットの残数(ticketBalance)も省略可: 無い・null・型違いは nil(バッジを出さない)、0 は 0 のまま保持する(T19a #19)

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
        XCTAssertNil(snapshot.ticketBalance, "キーが無い例(古いサーバー)は nil")
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
        XCTAssertNil(snapshot.plantGrownDays, "新キーは 0 で埋めない(ゲージが「0回」と出てちらつく)")
        XCTAssertNil(snapshot.plantStageFloor)
        XCTAssertNil(snapshot.plantNextStageAt)
        XCTAssertEqual(snapshot.plantMood, .normal)
        XCTAssertFalse(snapshot.hasPartnerPhotoToday)
        XCTAssertNil(snapshot.ticketBalance, "残数も 0 で埋めない(誤った「0枚」を出さない)")
    }

    func testDecodeFailsWithoutUpdatedAt() {
        XCTAssertThrowsError(try decode("{ \"schemaVersion\": 1 }"))
    }

    func testDecodeFailsWithoutSchemaVersion() {
        XCTAssertThrowsError(try decode("{ \"updatedAt\": \"2026-06-11T00:00:00Z\" }"))
    }

    // MARK: - 成長ルール v2 の新キー(省略可 — PB #57)

    /// 新キーつきの JSON(DESIGN §3.4 の例: 段階3・成長9回・下限7・次の段階14)
    private var withGrowthKeysJSON: String {
        designExampleJSON.replacingOccurrences(
            of: "\"plantStage\": 3,",
            with: "\"plantStage\": 3, \"plantGrownDays\": 9, \"plantStageFloor\": 7, \"plantNextStageAt\": 14,"
        )
    }

    func testDecodeWithoutGrowthKeysLeavesThemNil() throws {
        // 古いサーバー・古いキャッシュ(§3.4 の元の例には、新キーが無い): ゲージを出さない
        let snapshot = try decode(designExampleJSON)
        XCTAssertNil(snapshot.plantGrownDays)
        XCTAssertNil(snapshot.plantStageFloor)
        XCTAssertNil(snapshot.plantNextStageAt)
        XCTAssertNil(PlantProgress(snapshot: snapshot), "新キーが無ければ、進み具合も無い")
        XCTAssertNil(GrowthGauge.text(for: snapshot))
        XCTAssertEqual(snapshot.plantStage, 3, "段階そのものは読める")
    }

    func testDecodeGrowthKeys() throws {
        let snapshot = try decode(withGrowthKeysJSON)
        XCTAssertEqual(snapshot.plantGrownDays, 9)
        XCTAssertEqual(snapshot.plantStageFloor, 7)
        XCTAssertEqual(snapshot.plantNextStageAt, 14)
        XCTAssertEqual(GrowthGauge.text(for: snapshot), "わかばになってから 2回そろったよ")
    }

    func testNextStageAtNullMeansTheLastStageNotAMissingKey() throws {
        // サーバーは、最後の段階(みのり)とソロで plantNextStageAt を省略せず null で返す(DESIGN §3.4)
        let json = designExampleJSON.replacingOccurrences(
            of: "\"plantStage\": 3,",
            with: "\"plantStage\": 9, \"plantGrownDays\": 128, \"plantStageFloor\": 100, \"plantNextStageAt\": null,"
        )
        let snapshot = try decode(json)
        XCTAssertEqual(snapshot.plantGrownDays, 128)
        XCTAssertEqual(snapshot.plantStageFloor, 100)
        XCTAssertNil(snapshot.plantNextStageAt)
        XCTAssertEqual(GrowthGauge.text(for: snapshot), "ふたりで 128回 そろったよ", "回数と下限があって次が null = 次の段階が無い")
    }

    func testWrongTypedGrowthKeysAreIgnoredWithoutBreakingTheSnapshot() throws {
        // 表示だけの新キー: 型が違っても、snapshot 全体(チェックイン状態など)を壊さない
        let json = designExampleJSON.replacingOccurrences(
            of: "\"plantStage\": 3,",
            with: "\"plantStage\": 3, \"plantGrownDays\": \"many\", \"plantStageFloor\": [], \"plantNextStageAt\": {},"
        )
        let snapshot = try decode(json)
        XCTAssertNil(snapshot.plantGrownDays)
        XCTAssertNil(snapshot.plantStageFloor)
        XCTAssertNil(snapshot.plantNextStageAt)
        XCTAssertEqual(snapshot.streakCurrent, 23)
        XCTAssertTrue(snapshot.todayMeDone)
    }

    func testEncodeDecodeRoundTripWithGrowthKeys() throws {
        let original = try decode(withGrowthKeysJSON)
        let data = try PairSnapshot.makeJSONEncoder().encode(original)
        let decoded = try PairSnapshot.makeJSONDecoder().decode(PairSnapshot.self, from: data)
        XCTAssertEqual(decoded, original)
        XCTAssertEqual(decoded.plantGrownDays, 9)
        XCTAssertEqual(decoded.plantStageFloor, 7)
        XCTAssertEqual(decoded.plantNextStageAt, 14)
    }

    func testEncodeWithoutGrowthKeysDoesNotInventThem() throws {
        // キーが無い snapshot を書き出して「0回」などに変えない(往復しても、キーは無いまま)
        let original = try decode(designExampleJSON)
        let text = try XCTUnwrap(String(data: try PairSnapshot.makeJSONEncoder().encode(original), encoding: .utf8))
        XCTAssertFalse(text.contains("plantGrownDays"))
        XCTAssertFalse(text.contains("plantStageFloor"))
        XCTAssertFalse(text.contains("plantNextStageAt"))
        let decoded = try PairSnapshot.makeJSONDecoder().decode(PairSnapshot.self, from: Data(text.utf8))
        XCTAssertEqual(decoded, original)
        XCTAssertNil(decoded.plantGrownDays)
    }

    func testEncodeWritesAnExplicitNullNextStageForTheLastStage() throws {
        // サーバーの形(DESIGN §3.4「キーは省略せず null で出す」)と同じに書く。往復しても同じ
        var snapshot = try decode(designExampleJSON)
        snapshot.plantStage = 9
        snapshot.plantGrownDays = 128
        snapshot.plantStageFloor = 100
        snapshot.plantNextStageAt = nil
        let data = try PairSnapshot.makeJSONEncoder().encode(snapshot)
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertTrue(text.contains("\"plantNextStageAt\":null"), text)
        XCTAssertTrue(text.contains("\"plantGrownDays\":128"))
        let decoded = try PairSnapshot.makeJSONDecoder().decode(PairSnapshot.self, from: data)
        XCTAssertEqual(decoded, snapshot)
    }

    func testMemberwiseInitWithoutGrowthArgumentsKeepsExistingCallSitesWorking() {
        // 新キーは引数の既定値が nil(これまでの組み立て方がそのまま通る)
        let snapshot = PairSnapshot(
            schemaVersion: 1, pairId: nil, updatedAt: Date(), streakCurrent: 0, streakBest: 0,
            todayMeDone: false, todayPartnerDone: false, myPromiseTitle: nil, myPromiseEmoji: nil,
            partnerName: nil, partnerPromiseTitle: nil, partnerPromiseEmoji: nil, plantStage: 0,
            plantMood: .normal, plantName: nil, hasPartnerPhotoToday: false
        )
        XCTAssertNil(snapshot.plantGrownDays)
        XCTAssertNil(snapshot.plantStageFloor)
        XCTAssertNil(snapshot.plantNextStageAt)
        XCTAssertNil(snapshot.ticketBalance, "残数も引数の既定値が nil(これまでの組み立て方がそのまま通る)")
    }

    // MARK: - お休みチケットの残数(省略可 — T19a #19 / DESIGN §3.4)

    /// 残数つきの JSON(ペアの snapshot: 2枚)
    private var withTicketBalanceJSON: String {
        designExampleJSON.replacingOccurrences(
            of: "\"hasPartnerPhotoToday\": false",
            with: "\"hasPartnerPhotoToday\": false, \"ticketBalance\": 2"
        )
    }

    func testDecodeWithoutTicketBalanceLeavesItNil() throws {
        // キーが無い古いサーバー・古いキャッシュ: バッジを出さない(0 で埋めない — 誤った「0枚」を見せない)
        let snapshot = try decode(designExampleJSON)
        XCTAssertNil(snapshot.ticketBalance)
    }

    func testDecodeTicketBalanceKeepsZeroAsAValue() throws {
        // 0 は有効な残数(0枚でもバッジを出す — REQUIREMENTS §3.5)。nil と区別する
        for (raw, expected) in [("2", 2), ("0", 0), ("5", 5)] {
            let json = designExampleJSON.replacingOccurrences(
                of: "\"hasPartnerPhotoToday\": false",
                with: "\"hasPartnerPhotoToday\": false, \"ticketBalance\": \(raw)"
            )
            let snapshot = try decode(json)
            XCTAssertEqual(snapshot.ticketBalance, expected, "ticketBalance = \(raw)")
            XCTAssertNotNil(snapshot.ticketBalance, "0 も nil にしない")
        }
    }

    func testDecodeNullTicketBalanceAsNil() throws {
        // ソロ・サーバーが残数を読めていないときは null(キーは省略しない — DESIGN §3.4)。バッジを出さない
        let json = designExampleJSON.replacingOccurrences(
            of: "\"hasPartnerPhotoToday\": false",
            with: "\"hasPartnerPhotoToday\": false, \"ticketBalance\": null"
        )
        XCTAssertNil(try decode(json).ticketBalance)
    }

    func testWrongTypedTicketBalanceIsIgnoredWithoutBreakingTheSnapshot() throws {
        // 表示だけのキー: 型が違っても、snapshot 全体(チェックイン状態など)を壊さず nil として扱う
        let json = designExampleJSON.replacingOccurrences(
            of: "\"hasPartnerPhotoToday\": false",
            with: "\"hasPartnerPhotoToday\": false, \"ticketBalance\": \"two\""
        )
        let snapshot = try decode(json)
        XCTAssertNil(snapshot.ticketBalance)
        XCTAssertEqual(snapshot.streakCurrent, 23)
        XCTAssertTrue(snapshot.todayMeDone)
    }

    func testEncodeDecodeRoundTripWithTicketBalance() throws {
        let original = try decode(withTicketBalanceJSON)
        let data = try PairSnapshot.makeJSONEncoder().encode(original)
        let decoded = try PairSnapshot.makeJSONDecoder().decode(PairSnapshot.self, from: data)
        XCTAssertEqual(decoded, original)
        XCTAssertEqual(decoded.ticketBalance, 2)
    }

    func testEncodeWritesAnExplicitNullTicketBalance() throws {
        // サーバーの形(DESIGN §3.4「キーは省略せず null で出す」)と同じに書く。ソロ・欠落でもキーを残す
        let snapshot = try decode(designExampleJSON)
        let data = try PairSnapshot.makeJSONEncoder().encode(snapshot)
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertTrue(text.contains("\"ticketBalance\":null"), text)
        let decoded = try PairSnapshot.makeJSONDecoder().decode(PairSnapshot.self, from: data)
        XCTAssertNil(decoded.ticketBalance)
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

    func testResettingForNewDayKeepsTheGrowthKeys() throws {
        // 翌日 0:00 のウィジェットのエントリ: 段階と同じく、成長回数なども持ち越す(植物は縮まない)
        let snapshot = try decode(withGrowthKeysJSON)
        let reset = snapshot.resettingForNewDay()
        XCTAssertEqual(reset.plantGrownDays, 9)
        XCTAssertEqual(reset.plantStageFloor, 7)
        XCTAssertEqual(reset.plantNextStageAt, 14)
    }

    func testResettingForNewDayKeepsTheTicketBalance() throws {
        // チケットは翌日も同じ残数(0:10 の自動消費はサーバーが snapshot で知らせる)
        var snapshot = try decode(designExampleJSON)
        snapshot.ticketBalance = 1
        XCTAssertEqual(snapshot.resettingForNewDay().ticketBalance, 1)
        snapshot.ticketBalance = 0
        XCTAssertEqual(snapshot.resettingForNewDay().ticketBalance, 0, "0 を nil に落とさない")
    }


    // MARK: - ペアのプラン pairPlan(省略可 — T33 / REQUIREMENTS §3.14)

    func testDecodePairPlan() throws {
        XCTAssertEqual(try decode(designExampleJSON).pairPlan, .free, "キーが無い古いサーバーは free")
        let premium = designExampleJSON.replacingOccurrences(
            of: "\"hasPartnerPhotoToday\": false",
            with: "\"hasPartnerPhotoToday\": false, \"pairPlan\": \"premium\""
        )
        XCTAssertEqual(try decode(premium).pairPlan, .premium)
        let unknown = designExampleJSON.replacingOccurrences(
            of: "\"hasPartnerPhotoToday\": false",
            with: "\"hasPartnerPhotoToday\": false, \"pairPlan\": \"platinum\""
        )
        XCTAssertEqual(try decode(unknown).pairPlan, .free, "未知の値は free(課金していない側に倒す)")
    }

    func testEncodePairPlanRoundTrip() throws {
        var snapshot = try decode(designExampleJSON)
        snapshot.pairPlan = .premium
        let data = try PairSnapshot.makeJSONEncoder().encode(snapshot)
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertTrue(text.contains("\"pairPlan\":\"premium\""), text)
        XCTAssertEqual(try PairSnapshot.makeJSONDecoder().decode(PairSnapshot.self, from: data).pairPlan, .premium)
    }
}
