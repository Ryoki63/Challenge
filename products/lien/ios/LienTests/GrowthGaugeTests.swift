// GrowthGaugeTests.swift — 成長の進み具合(PlantProgress)・ゲージの文(GrowthGauge)・のぞきの判定・VoiceOver の読み上げ文(issue #57)
//
// 検証対象(docs/GROWTH.md §3.3・§3.4・§5.1・§5.4):
//   - ゲージの文: 区間が短い間は「あと○回で」/ 長い区間(7回以上)の前半は「○○になってから N回そろったよ」・後半は「あと○回で」/
//     次の段階が無い・アプリが知らない段階 / ソロ・新しいキーが無い・値が食い違うときは出さない
//   - のぞきを出す回数: 11・18・26・38・56・83回(区間の半分以上)から、次の段階まで
//   - VoiceOver: 「みどり、わかば。あなた: 完了、ゆうき: まだ。ふたりそろって あと3回で よりそい」
//   - 揺れ(sways): 描いている状態(自分 / 相手の葉を見る顔)から決まる
//
// 閾値は、サーバーの PLANT_STAGE_THRESHOLDS(DESIGN §5.4)と同じ [0,1,3,7,14,21,30,45,66,100] で snapshot を組み立てる
// (サーバーが段階・下限・次の段階を数える手順の写し。アプリは閾値表を持たない)。

import XCTest
@testable import Lien

final class GrowthGaugeTests: XCTestCase {
    /// サーバーの閾値配列(DESIGN §5.4。添字 = 段階)
    private let thresholds = [0, 1, 3, 7, 14, 21, 30, 45, 66, 100]

    /// 成長回数 grown から、サーバーと同じ手順で段階・下限・次の段階を決めた snapshot
    private func snapshot(
        grown: Int,
        meDone: Bool = false,
        partnerDone: Bool = false,
        plantName: String? = "みどり",
        partnerName: String? = "ゆうき",
        mood: PlantMood = .normal,
        pairId: String? = "pair-1"
    ) -> PairSnapshot {
        let stage = thresholds.lastIndex { $0 <= grown } ?? 0
        let next = stage + 1 < thresholds.count ? thresholds[stage + 1] : nil
        return PairSnapshot(
            schemaVersion: PairSnapshot.currentSchemaVersion,
            pairId: pairId,
            updatedAt: Date(timeIntervalSince1970: 1_781_166_600),
            streakCurrent: 5,
            streakBest: 9,
            todayMeDone: meDone,
            todayPartnerDone: partnerDone,
            myPromiseTitle: "筋トレ",
            myPromiseEmoji: "💪",
            partnerName: partnerName,
            partnerPromiseTitle: "ランニング",
            partnerPromiseEmoji: "🏃",
            plantStage: stage,
            plantGrownDays: grown,
            plantStageFloor: thresholds[stage],
            plantNextStageAt: next,
            plantMood: mood,
            plantName: plantName,
            hasPartnerPhotoToday: false
        )
    }

    private func gauge(_ grown: Int) -> String? {
        GrowthGauge.text(for: snapshot(grown: grown))
    }

    // MARK: ゲージの文(GROWTH §5.1)

    func testShortIntervalsAlwaysShowTheRemainingCount() {
        // 段階0(0 → 1): まだ1回もそろっていない
        XCTAssertEqual(gauge(0), "ふたりそろって あと1回で ふたば")
        // 段階1(1 → 3)
        XCTAssertEqual(gauge(1), "ふたりそろって あと2回で めばえ")
        XCTAssertEqual(gauge(2), "ふたりそろって あと1回で めばえ", "§4.2: 2回目のゲージ「あと1回で めばえ」")
        // 段階2(3 → 7): 区間が4回 → §4.2「あと3回 / 2回 / 1回で わかば」(4〜6回目)
        XCTAssertEqual(gauge(3), "ふたりそろって あと4回で わかば")
        XCTAssertEqual(gauge(4), "ふたりそろって あと3回で わかば")
        XCTAssertEqual(gauge(5), "ふたりそろって あと2回で わかば")
        XCTAssertEqual(gauge(6), "ふたりそろって あと1回で わかば")
    }

    func testLongIntervalShowsCountSinceStageInTheFirstHalfAndRemainingInTheSecondHalf() {
        // 段階3 わかば(7 → 14。区間7回。半分以上 = 4回目から)
        XCTAssertEqual(gauge(7), "ふたりそろって あと7回で よりそい", "段階に入った直後(0回)は『0回そろったよ』と言わない")
        XCTAssertEqual(gauge(8), "わかばになってから 1回そろったよ")
        XCTAssertEqual(gauge(9), "わかばになってから 2回そろったよ")
        XCTAssertEqual(gauge(10), "わかばになってから 3回そろったよ", "§5.1 の例そのまま(前半 = 半分未満)")
        XCTAssertEqual(gauge(11), "ふたりそろって あと3回で よりそい", "11回から後半(のぞきも同じ回数から)")
        XCTAssertEqual(gauge(12), "ふたりそろって あと2回で よりそい")
        XCTAssertEqual(gauge(13), "ふたりそろって あと1回で よりそい")
        // 段階4 よりそい(14 → 21)
        XCTAssertEqual(gauge(14), "ふたりそろって あと7回で つぼみ")
        XCTAssertEqual(gauge(17), "よりそいになってから 3回そろったよ")
        XCTAssertEqual(gauge(18), "ふたりそろって あと3回で つぼみ")
        // 段階5 つぼみ(21 → 30。区間9回。半分は 4.5 → 5回目から = 26)
        XCTAssertEqual(gauge(25), "つぼみになってから 4回そろったよ")
        XCTAssertEqual(gauge(26), "ふたりそろって あと4回で いろづき")
        // 段階6 いろづき(30 → 45。区間15回。8回目から = 38)
        XCTAssertEqual(gauge(37), "いろづきになってから 7回そろったよ")
        XCTAssertEqual(gauge(38), "ふたりそろって あと7回で ほころび")
        // 段階7 ほころび(45 → 66。区間21回。11回目から = 56)
        XCTAssertEqual(gauge(55), "ほころびになってから 10回そろったよ")
        XCTAssertEqual(gauge(56), "ふたりそろって あと10回で ふたりざき")
        // 段階8 ふたりざき(66 → 100。区間34回。ちょうど半分の 17回目から = 83)
        XCTAssertEqual(gauge(82), "ふたりざきになってから 16回そろったよ")
        XCTAssertEqual(gauge(83), "ふたりそろって あと17回で みのり", "ちょうど半分で後半(「半分を超えたら」ではなく「半分以上」)")
        XCTAssertEqual(gauge(99), "ふたりそろって あと1回で みのり")
    }

    func testLastStageShowsTheTotalCount() {
        XCTAssertEqual(gauge(100), "ふたりで 100回 そろったよ")
        XCTAssertEqual(gauge(128), "ふたりで 128回 そろったよ", "§5.1 の例そのまま(次の段階が無い = v1.0 のみのり以降)")
    }

    func testUnknownStageFromTheServerShowsTheNextTreat() {
        // 1.0.1 の花壇の段階(10 以降)をサーバーが返した古いアプリ: 次の段階の名前を知らない
        var unknown = snapshot(grown: 128)
        unknown.plantStage = 10
        unknown.plantStageFloor = 125
        unknown.plantNextStageAt = 150
        XCTAssertEqual(GrowthGauge.text(for: unknown), "あと22回で つぎの おたのしみ")

        // 次の段階の回数が無い未知の段階は、総回数の文
        unknown.plantNextStageAt = nil
        XCTAssertEqual(GrowthGauge.text(for: unknown), "ふたりで 128回 そろったよ")
    }

    func testGaugeIsHiddenForSoloMissingKeysAndInconsistentValues() {
        // ソロ(pairId が null): 植物は土の中で眠っていて、進み具合は無い(キーがあっても出さない)
        XCTAssertNil(GrowthGauge.text(for: snapshot(grown: 5, pairId: nil)))

        // 新しいキーが無い(古いサーバー・古いキャッシュ): 出さない(「0回」と出して、ちらつかせない)
        var oldServer = snapshot(grown: 5)
        oldServer.plantGrownDays = nil
        oldServer.plantStageFloor = nil
        oldServer.plantNextStageAt = nil
        XCTAssertNil(GrowthGauge.text(for: oldServer))
        // 一部だけ欠けていても出さない
        var partial = snapshot(grown: 5)
        partial.plantStageFloor = nil
        XCTAssertNil(GrowthGauge.text(for: partial))

        // 食い違っている値は出さない(「あと -1 回」を出さない)
        var inverted = snapshot(grown: 5)
        inverted.plantStageFloor = 7 // 下限が回数より大きい
        XCTAssertNil(GrowthGauge.text(for: inverted))
        var arrived = snapshot(grown: 7)
        arrived.plantStage = 2
        arrived.plantStageFloor = 3
        arrived.plantNextStageAt = 7 // 次の段階にもう着いている(段階と食い違う)
        XCTAssertNil(GrowthGauge.text(for: arrived))
        var negative = snapshot(grown: 5)
        negative.plantGrownDays = -1
        XCTAssertNil(GrowthGauge.text(for: negative))
    }

    func testEveryGaugeTextOverTheWholeRangeIsGentleAndWellFormed() {
        // 0〜130回のすべてで、文が出て、数字が正しく、罰・恥系の語を含まない
        for grown in 0...130 {
            let text = gauge(grown)
            XCTAssertNotNil(text, "\(grown)回")
            guard let text else { continue }
            XCTAssertEqual(PunishmentFreeLint.violations(in: text), [], text)
            XCTAssertFalse(text.contains("-"), "\(grown)回: 負の数が出ている: \(text)")
            XCTAssertFalse(text.contains("になってから 0回"), "\(grown)回: 『0回そろったよ』は出さない: \(text)")
        }
    }

    // MARK: PlantProgress(区間の中での位置)

    func testProgressDerivesPositionInTheInterval() throws {
        let progress = try XCTUnwrap(PlantProgress(snapshot: snapshot(grown: 10)))
        XCTAssertEqual(progress.stage, 3)
        XCTAssertEqual(progress.rawStage, 3)
        XCTAssertFalse(progress.isUnknownStage)
        XCTAssertEqual(progress.intervalLength, 7)
        XCTAssertEqual(progress.countInStage, 3)
        XCTAssertEqual(progress.remaining, 4)
        XCTAssertTrue(progress.isLongInterval)
        XCTAssertFalse(progress.isLaterHalf, "3 × 2 = 6 < 7")

        let later = try XCTUnwrap(PlantProgress(snapshot: snapshot(grown: 11)))
        XCTAssertTrue(later.isLaterHalf, "4 × 2 = 8 ≧ 7")
    }

    func testProgressOfTheLastStageHasNoNextAndIsNeverLongOrLater() throws {
        let progress = try XCTUnwrap(PlantProgress(snapshot: snapshot(grown: 128)))
        XCTAssertNil(progress.nextStageAt)
        XCTAssertNil(progress.remaining)
        XCTAssertNil(progress.intervalLength)
        XCTAssertFalse(progress.isLongInterval)
        XCTAssertFalse(progress.isLaterHalf)
        XCTAssertFalse(progress.showsPeek)
    }

    func testProgressRejectsValuesThatDisagree() {
        XCTAssertNil(PlantProgress(rawStage: -1, grownDays: 0, stageFloor: 0, nextStageAt: 1))
        XCTAssertNil(PlantProgress(rawStage: 3, grownDays: -2, stageFloor: 0, nextStageAt: 7))
        XCTAssertNil(PlantProgress(rawStage: 3, grownDays: 5, stageFloor: 7, nextStageAt: 14), "下限 > 回数")
        XCTAssertNil(PlantProgress(rawStage: 3, grownDays: 14, stageFloor: 7, nextStageAt: 14), "回数 = 次の段階(もう着いている)")
        XCTAssertNotNil(PlantProgress(rawStage: 3, grownDays: 7, stageFloor: 7, nextStageAt: 14))
    }

    // MARK: のぞきを出す回数(GROWTH §3.4: 11・18・26・38・56・83回から)

    func testPeekAppearsFromTheListedCountsUntilTheNextStage() {
        // 長い区間(7回以上)の、半分以上から次の段階の直前まで
        let peekZones: [ClosedRange<Int>] = [11...13, 18...20, 26...29, 38...44, 56...65, 83...99]
        for grown in 0...130 {
            let expected = peekZones.contains { $0.contains(grown) }
            let progress = PlantProgress(snapshot: snapshot(grown: grown))
            XCTAssertEqual(progress?.showsPeek, expected, "\(grown)回")
        }
        // §3.4 の「出る回数」
        let firsts = peekZones.map(\.lowerBound)
        XCTAssertEqual(firsts, [11, 18, 26, 38, 56, 83])
    }

    func testPeekIsOnlyForLongIntervals() {
        // 短い区間(段階0・1・2 = 1・2・4回)は、半分を過ぎても出さない
        for grown in 0...6 {
            XCTAssertEqual(PlantProgress(snapshot: snapshot(grown: grown))?.showsPeek, false, "\(grown)回")
        }
        XCTAssertEqual(PlantProgress.longIntervalMinLength, 7)
    }

    func testPeekIsNotShownForUnknownStages() throws {
        let progress = try XCTUnwrap(PlantProgress(rawStage: 12, grownDays: 160, stageFloor: 125, nextStageAt: 175))
        XCTAssertTrue(progress.isUnknownStage)
        XCTAssertEqual(progress.stage, 9, "みのりとして描く")
        XCTAssertFalse(progress.showsPeek)
    }

    func testPlantStateFromSnapshotCarriesThePeek() {
        let early = PlantCharacterState(snapshot: snapshot(grown: 10))
        XCTAssertFalse(early.peek, "前半は出さない")
        let late = PlantCharacterState(snapshot: snapshot(grown: 11))
        XCTAssertTrue(late.peek, "後半は出す")
        XCTAssertEqual(late.stage, 3)

        // 新しいキーが無い snapshot・ソロでは出さない
        var oldServer = snapshot(grown: 11)
        oldServer.plantGrownDays = nil
        oldServer.plantStageFloor = nil
        oldServer.plantNextStageAt = nil
        XCTAssertFalse(PlantCharacterState(snapshot: oldServer).peek)
        XCTAssertFalse(PlantCharacterState(snapshot: snapshot(grown: 11, pairId: nil)).peek)

        // のぞきは、位置がある段階(3〜8)の絵にだけ重なる(PlantLayers が決める)
        let layers = PlantLayers.stack(for: late, dark: false).map(\.name)
        XCTAssertTrue(layers.contains("fx_peek"))
        XCTAssertFalse(PlantLayers.stack(for: early, dark: false).map(\.name).contains("fx_peek"))
    }

    // MARK: 揺れ(PA の手直し: plantMood でなく、描いている状態から)

    func testSwaysFollowsTheDrawnStateNotThePlantMood() {
        // 片方だけ完了(自分 / 相手の葉を見る顔)だけ揺れる
        XCTAssertTrue(PlantCharacterState(snapshot: snapshot(grown: 5, meDone: true)).sways)
        XCTAssertTrue(PlantCharacterState(snapshot: snapshot(grown: 5, partnerDone: true)).sways)
        // ふたりそろった・まだ・すやすやは揺れない
        XCTAssertFalse(PlantCharacterState(snapshot: snapshot(grown: 5, meDone: true, partnerDone: true)).sways)
        XCTAssertFalse(PlantCharacterState(snapshot: snapshot(grown: 5)).sways)
        XCTAssertFalse(PlantCharacterState(snapshot: snapshot(grown: 5, mood: .sad)).sways)

        // 食い違い: mood が古い fidget のまま、完了のフラグだけがふたりそろった(楽観更新)→ 揺れない
        let staleFidget = snapshot(grown: 5, meDone: true, partnerDone: true, mood: .fidget)
        XCTAssertFalse(PlantCharacterState(snapshot: staleFidget).sways, "葉が両方ひらいているのに揺れ続けない")
        // 逆の食い違い: mood は normal のまま、自分だけ完了のフラグが立った → 揺れる(葉も視線もそう描かれる)
        let staleNormal = snapshot(grown: 5, meDone: true, partnerDone: false, mood: .normal)
        XCTAssertTrue(PlantCharacterState(snapshot: staleNormal).sways)

        // ソロは土の中で眠っているので揺れない(自分だけ完了でも)
        XCTAssertFalse(PlantCharacterState(snapshot: snapshot(grown: 0, meDone: true, pairId: nil)).sways)
        XCTAssertFalse(PlantCharacterState.solo.sways)
    }

    // MARK: VoiceOver(GROWTH §5.4)

    func testVoiceOverLabelMatchesTheSpecExample() {
        // 「みどり、わかば。あなた: 完了、ゆうき: まだ。ふたりそろって あと3回で よりそい」
        let label = PlantVoiceOver.label(for: snapshot(grown: 11, meDone: true, partnerDone: false))
        XCTAssertEqual(label, "みどり、わかば。あなた: 完了、ゆうき: まだ。ふたりそろって あと3回で よりそい")
    }

    func testVoiceOverLabelVariants() {
        // 名前が無ければ段階名から
        XCTAssertEqual(
            PlantVoiceOver.label(for: snapshot(grown: 3, partnerDone: true, plantName: nil)),
            "めばえ。あなた: まだ、ゆうき: 完了。ふたりそろって あと4回で わかば"
        )
        // 空の名前も名前なし
        XCTAssertEqual(
            PlantVoiceOver.label(for: snapshot(grown: 0, plantName: "")),
            "たね。あなた: まだ、ゆうき: まだ。ふたりそろって あと1回で ふたば"
        )
        // 長い区間の前半
        XCTAssertEqual(
            PlantVoiceOver.label(for: snapshot(grown: 9, meDone: true, partnerDone: true)),
            "みどり、わかば。あなた: 完了、ゆうき: 完了。わかばになってから 2回そろったよ"
        )
        // 相手の名前が無いときの代わり
        XCTAssertEqual(
            PlantVoiceOver.label(for: snapshot(grown: 100, partnerName: nil)),
            "みどり、みのり。あなた: まだ、あいて: まだ。ふたりで 100回 そろったよ"
        )
    }

    func testVoiceOverLabelWithoutNewKeysOmitsTheGaugeSentence() {
        var oldServer = snapshot(grown: 11, meDone: true)
        oldServer.plantGrownDays = nil
        oldServer.plantStageFloor = nil
        oldServer.plantNextStageAt = nil
        XCTAssertEqual(PlantVoiceOver.label(for: oldServer), "みどり、わかば。あなた: 完了、ゆうき: まだ")
    }

    func testVoiceOverLabelRoundsUnknownStagesToTheLastKnown() {
        var unknown = snapshot(grown: 128)
        unknown.plantStage = 12
        unknown.plantStageFloor = 125
        unknown.plantNextStageAt = 150
        XCTAssertEqual(
            PlantVoiceOver.label(for: unknown),
            "みどり、みのり。あなた: まだ、ゆうき: まだ。あと22回で つぎの おたのしみ",
            "知らない段階は、みのりとして描くので、みのりと読み上げる"
        )
    }

    func testVoiceOverLabelForSolo() {
        XCTAssertEqual(PlantVoiceOver.label(for: snapshot(grown: 0, pairId: nil)), "土の中で眠るタネの子")
    }

    // MARK: 段階名

    func testStageNamesCoverTheTenStages() {
        XCTAssertEqual(Strings.Plant.stageNames.count, 10)
        XCTAssertEqual(Strings.Plant.stageNames, [
            "たね", "ふたば", "めばえ", "わかば", "よりそい", "つぼみ", "いろづき", "ほころび", "ふたりざき", "みのり",
        ])
        XCTAssertEqual(Strings.Plant.stageName(-3), "たね", "負は 0 に丸める")
        XCTAssertEqual(Strings.Plant.stageName(12), "みのり", "知らない大きい段階は、知っている最大(みのり)")
    }

    func testStageNamesMatchTheRenderTestsAndSnapshotThresholdsCount() {
        // サーバーの閾値は 10 個(段階 0〜9)。段階名の数と一致する(PlantLayers.stageRange とも)
        XCTAssertEqual(thresholds.count, Strings.Plant.stageNames.count)
        XCTAssertEqual(PlantLayers.stageRange.count, Strings.Plant.stageNames.count)
    }
}
