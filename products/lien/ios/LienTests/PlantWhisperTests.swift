// PlantWhisperTests.swift — 今日のひとこと(タネの子の吹き出し)の選び方(issue #57 の P1 / docs/GROWTH.md §5.5)
//
// 検証対象(PlantWhisper.swift・Strings.Plant.Whisper):
//   - 状況ごとの候補(ふたりそろった・相手だけ・自分だけ・すやすや・まだ誰もしていない日の時間帯)と、段階の候補
//   - 日付で1つ選ぶ(同じ日の同じ状況なら同じ言葉・日が変われば別の言葉に回る)
//   - ソロには出さない
//   - 文言の約束: 30〜40本・主語は名前(左右を使わない)・短い・罰なし(カタログの lint も通る)

import XCTest
@testable import Lien

final class PlantWhisperTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        return calendar
    }

    private func date(day: Int, hour: Int) -> Date {
        let components = DateComponents(
            calendar: calendar, timeZone: calendar.timeZone, year: 2026, month: 6, day: day, hour: hour, minute: 15
        )
        return calendar.date(from: components) ?? Date()
    }

    private func snapshot(
        stage: Int = 2,
        meDone: Bool = false,
        partnerDone: Bool = false,
        mood: PlantMood = .normal,
        partnerName: String? = "ゆうき",
        pairId: String? = "pair-A"
    ) -> PairSnapshot {
        PairSnapshot(
            schemaVersion: PairSnapshot.currentSchemaVersion,
            pairId: pairId,
            updatedAt: date(day: 11, hour: 8),
            streakCurrent: 3,
            streakBest: 5,
            todayMeDone: meDone,
            todayPartnerDone: partnerDone,
            myPromiseTitle: "筋トレ",
            myPromiseEmoji: "💪",
            partnerName: partnerName,
            partnerPromiseTitle: "ランニング",
            partnerPromiseEmoji: "🏃",
            plantStage: stage,
            plantMood: mood,
            plantName: "みどり",
            hasPartnerPhotoToday: false
        )
    }

    // MARK: 時間帯

    func testTimeBandBoundaries() {
        let table: [(hour: Int, band: PlantWhisper.TimeBand)] = [
            (0, .night), (4, .night), (5, .morning), (10, .morning), (11, .daytime), (16, .daytime),
            (17, .evening), (21, .evening), (22, .night), (23, .night),
        ]
        for entry in table {
            XCTAssertEqual(PlantWhisper.TimeBand(hour: entry.hour), entry.band, "\(entry.hour)時")
        }
    }

    // MARK: 状況ごとの候補

    func testCandidatesFollowTheSituation() {
        let name = "ゆうき"
        XCTAssertEqual(
            PlantWhisper.candidates(for: snapshot(meDone: true, partnerDone: true), band: .morning),
            Strings.Plant.Whisper.bothDone(name)
        )
        XCTAssertEqual(
            PlantWhisper.candidates(for: snapshot(partnerDone: true), band: .evening),
            Strings.Plant.Whisper.partnerDone(name)
        )
        XCTAssertEqual(
            PlantWhisper.candidates(for: snapshot(meDone: true), band: .night),
            Strings.Plant.Whisper.meDone(name)
        )
        XCTAssertEqual(
            PlantWhisper.candidates(for: snapshot(mood: .sad), band: .morning),
            Strings.Plant.Whisper.sleepy,
            "すやすやの日(誰もまだ)は、時間帯より優先"
        )
        XCTAssertEqual(PlantWhisper.candidates(for: snapshot(), band: .morning), Strings.Plant.Whisper.morning)
        XCTAssertEqual(PlantWhisper.candidates(for: snapshot(), band: .daytime), Strings.Plant.Whisper.daytime)
        XCTAssertEqual(PlantWhisper.candidates(for: snapshot(), band: .evening), Strings.Plant.Whisper.evening)
        XCTAssertEqual(PlantWhisper.candidates(for: snapshot(), band: .night), Strings.Plant.Whisper.night)
    }

    func testSadMoodDoesNotOverrideAnActualCheckin() {
        // mood が古い sad のまま、完了のフラグだけが立った(楽観更新)→ 完了の状況を使う
        XCTAssertEqual(
            PlantWhisper.candidates(for: snapshot(meDone: true, mood: .sad), band: .morning),
            Strings.Plant.Whisper.meDone("ゆうき")
        )
    }

    func testStageLinesAreAddedForTheMatchingStages() {
        for stage in [1, 3, 5, 8, 9] {
            let lines = PlantWhisper.candidates(for: snapshot(stage: stage), band: .morning)
            XCTAssertEqual(lines, Strings.Plant.Whisper.morning + Strings.Plant.Whisper.stage(stage), "段階\(stage)")
            XCTAssertEqual(Strings.Plant.Whisper.stage(stage).count, 2)
        }
        for stage in [0, 2, 4, 6, 7] {
            XCTAssertEqual(
                PlantWhisper.candidates(for: snapshot(stage: stage), band: .morning),
                Strings.Plant.Whisper.morning,
                "段階\(stage)に専用の一言は無い"
            )
        }
        // 知らない段階は、みのりとして扱う
        XCTAssertEqual(
            PlantWhisper.candidates(for: snapshot(stage: 12), band: .morning),
            Strings.Plant.Whisper.morning + Strings.Plant.Whisper.stage(9)
        )
    }

    func testPartnerNameIsTheSubjectAndFallsBackWhenMissing() {
        let lines = PlantWhisper.candidates(for: snapshot(partnerDone: true, partnerName: "あき"), band: .morning)
        XCTAssertTrue(lines.contains("あきの葉、ひらいたよ"), "主語は名前(例「ゆうきの葉、ひらいたよ」— GROWTH §5.5)")
        let fallback = PlantWhisper.candidates(for: snapshot(partnerDone: true, partnerName: nil), band: .morning)
        XCTAssertTrue(fallback.contains("あいての葉、ひらいたよ"))
    }

    func testSoloHasNoWhisper() {
        XCTAssertTrue(PlantWhisper.candidates(for: snapshot(pairId: nil), band: .morning).isEmpty)
        XCTAssertNil(PlantWhisper.line(for: snapshot(pairId: nil), now: date(day: 11, hour: 8), calendar: calendar))
    }

    // MARK: 日付で1つ選ぶ

    func testTheSameDayAndSituationGiveTheSameWords() {
        let morning = date(day: 11, hour: 8)
        let first = PlantWhisper.line(for: snapshot(), now: morning, calendar: calendar)
        XCTAssertNotNil(first)
        for _ in 0..<5 {
            XCTAssertEqual(PlantWhisper.line(for: snapshot(), now: morning, calendar: calendar), first)
        }
        // 同じ日の同じ時間帯なら、時刻が違っても同じ(8:15 と 9:50)
        let later = date(day: 11, hour: 9)
        XCTAssertEqual(PlantWhisper.line(for: snapshot(), now: later, calendar: calendar), first)
    }

    func testDaysCycleThroughTheCandidates() {
        // 毎日、別の言葉に回る(候補が4つなら4日で一巡)
        let pool = PlantWhisper.candidates(for: snapshot(), band: .morning)
        XCTAssertEqual(pool.count, 4)
        var seen: [String] = []
        for day in 1...4 {
            seen.append(PlantWhisper.line(for: snapshot(), now: date(day: day, hour: 8), calendar: calendar) ?? "")
        }
        XCTAssertEqual(Set(seen), Set(pool), "4日で、候補を1つずつ")
        XCTAssertEqual(
            PlantWhisper.line(for: snapshot(), now: date(day: 5, hour: 8), calendar: calendar),
            PlantWhisper.line(for: snapshot(), now: date(day: 1, hour: 8), calendar: calendar),
            "一巡したら戻る"
        )
    }

    func testPlantDayNumberAdvancesByOnePerLocalDay() {
        let day1 = PlantDay.number(of: date(day: 11, hour: 0), calendar: calendar)
        XCTAssertEqual(PlantDay.number(of: date(day: 11, hour: 23), calendar: calendar), day1, "同じ日")
        XCTAssertEqual(PlantDay.number(of: date(day: 12, hour: 0), calendar: calendar), day1 + 1)
        XCTAssertEqual(PlantDay.number(of: date(day: 30, hour: 12), calendar: calendar), day1 + 19)
    }

    // MARK: 文言の約束

    /// 全候補(代表の名前で組み立てたもの)
    private var allLines: [String] {
        var lines: [String] = []
        for name in ["ゆうき", "あき", "🌱はな"] {
            lines += Strings.Plant.Whisper.bothDone(name)
            lines += Strings.Plant.Whisper.partnerDone(name)
            lines += Strings.Plant.Whisper.meDone(name)
        }
        lines += Strings.Plant.Whisper.sleepy
        lines += Strings.Plant.Whisper.morning + Strings.Plant.Whisper.daytime
        lines += Strings.Plant.Whisper.evening + Strings.Plant.Whisper.night
        for stage in 0...9 { lines += Strings.Plant.Whisper.stage(stage) }
        return lines
    }

    func testThereAreThirtyToFortyLinesInTotal() {
        // GROWTH §5.5: 30〜40本(仮)。名前を入れ替えた同じ文は1本と数える
        let representative = [
            Strings.Plant.Whisper.bothDone("ゆうき"), Strings.Plant.Whisper.partnerDone("ゆうき"),
            Strings.Plant.Whisper.meDone("ゆうき"), Strings.Plant.Whisper.sleepy, Strings.Plant.Whisper.morning,
            Strings.Plant.Whisper.daytime, Strings.Plant.Whisper.evening, Strings.Plant.Whisper.night,
            (0...9).flatMap { Strings.Plant.Whisper.stage($0) },
        ].flatMap { $0 }
        XCTAssertEqual(Set(representative).count, representative.count, "重複する文は無い")
        XCTAssertTrue((30...40).contains(representative.count), "\(representative.count)本")
    }

    func testLinesAreGentleShortAndNeverUseLeftOrRight() {
        for line in allLines {
            XCTAssertEqual(PunishmentFreeLint.violations(in: line), [], line)
            // 文章では左右を使わず、名前で呼ぶ(自分の画面でだけ左が自分 — GROWTH §4.5)
            XCTAssertFalse(line.contains("左") || line.contains("右"), line)
            // 吹き出しは2行まで(名前が8字でも収まる長さ)
            XCTAssertLessThanOrEqual(line.count, 26, line)
            XCTAssertFalse(line.isEmpty)
        }
    }
}
