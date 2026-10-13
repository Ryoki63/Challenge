// WidgetContentTests.swift — ウィジェットの「状態の導出」の検証(issue #17 T17a / REQUIREMENTS §3.10・GROWTH §5.4)
//
// snapshot → 表示の内容(WidgetContent)。3つの状態(データ無し・ソロ・ペア)× 完了の4通り × 段階 × 進み具合のキーの有無を確かめる。
// 表示原則: 自分未完 = 自分側グレー(Person.done)/ 相手が先に完了 =「(名前)が待ってるよ」/ 数字はストリークだけ /
// 進み具合は細いバーだけ(新しいキーが無いときは出さない)/ ストリークが 0 のときは出さない(罰なし)。
// Foundation だけで書いてあるので、macOS の下見(scripts/macos-check)でも走る。

import XCTest
@testable import Lien

final class WidgetContentTests: XCTestCase {
    private let updatedAt = Date(timeIntervalSince1970: 1_781_166_600)

    /// ペア成立中。進み具合のキーは「わかば(7回〜)の途中: 9回」(次の段階まで 14)
    private func paired(
        me: Bool = false,
        partner: Bool = false,
        stage: Int = 3,
        grown: Int? = 9,
        floor: Int? = 7,
        next: Int? = 14,
        streak: Int = 23,
        partnerName: String? = "ゆうき",
        mood: PlantMood = .normal
    ) -> PairSnapshot {
        PairSnapshot(
            schemaVersion: PairSnapshot.currentSchemaVersion,
            pairId: "1f0c5a4e-9d3b-4c1a-8f2e-7b6d5a4c3b2a",
            updatedAt: updatedAt,
            streakCurrent: streak,
            streakBest: 40,
            todayMeDone: me,
            todayPartnerDone: partner,
            myPromiseTitle: "筋トレ",
            myPromiseEmoji: "💪",
            partnerName: partnerName,
            partnerPromiseTitle: "ランニング",
            partnerPromiseEmoji: "🏃",
            plantStage: stage,
            plantGrownDays: grown,
            plantStageFloor: floor,
            plantNextStageAt: next,
            plantMood: mood,
            plantName: "みどり",
            hasPartnerPhotoToday: false
        )
    }

    private func solo(me: Bool = false, streak: Int = 0) -> PairSnapshot {
        var snapshot = paired(me: me, streak: streak)
        snapshot.pairId = nil
        snapshot.partnerName = nil
        snapshot.partnerPromiseEmoji = nil
        snapshot.partnerPromiseTitle = nil
        snapshot.plantStage = 0
        snapshot.plantGrownDays = 0
        snapshot.plantStageFloor = 0
        snapshot.plantNextStageAt = nil
        return snapshot
    }

    // MARK: - データ無し

    func testNoSnapshotIsTheSleepingSeedWithAnInvitationToOpenTheApp() {
        let content = WidgetContent(snapshot: nil)
        XCTAssertEqual(content, .noData)
        XCTAssertEqual(content.mode, .noData)
        XCTAssertEqual(content.plant, .solo, "snapshot が無いときも、鉢の土の中で眠るタネの子(ホームの空状態と同じ)")
        XCTAssertEqual(content.note, Strings.Widget.emptyMessage)
        XCTAssertNil(content.streakDays)
        XCTAssertNil(content.inlineStreakText)
        XCTAssertNil(content.me)
        XCTAssertNil(content.partner)
        XCTAssertNil(content.progress)
        XCTAssertNil(content.waitingMessage)
        XCTAssertNil(content.partnerLeaf)
        XCTAssertEqual(content.spokenSummary, "\(Strings.Widget.emptyTitle)。\(Strings.Widget.emptyMessage)")
    }

    // MARK: - ソロ(ペア未成立)

    func testSoloIsTheSleepingSeedAndNeverShowsPairThings() {
        // ストリーク・進み具合・相手・待ってるよ は、ペアのものなので出さない(snapshot に値が残っていても)
        var snapshot = solo(me: false, streak: 5)
        snapshot.todayPartnerDone = true
        let content = WidgetContent(snapshot: snapshot)
        XCTAssertEqual(content.mode, .solo)
        XCTAssertTrue(content.plant.isSolo)
        XCTAssertEqual(content.note, Strings.Widget.soloCaption)
        XCTAssertNil(content.streakDays)
        XCTAssertNil(content.inlineStreakText)
        XCTAssertNil(content.me)
        XCTAssertNil(content.partner)
        XCTAssertNil(content.progress)
        XCTAssertNil(content.waitingMessage)
        XCTAssertNil(content.partnerLeaf)
        XCTAssertEqual(content.spokenSummary, "\(Strings.Plant.voiceSolo)。\(Strings.Widget.soloCaption)")
        XCTAssertEqual(content.spokenPartner, Strings.Plant.voiceSolo)
    }

    func testSoloSoilGlowsOnlyOnTheDayIChecked() {
        XCTAssertFalse(WidgetContent(snapshot: solo(me: false)).plant.soilGlow)
        XCTAssertTrue(WidgetContent(snapshot: solo(me: true)).plant.soilGlow, "自分がチェックインした日は、土がほのかに光る")
    }

    // MARK: - ペア: 植物・2人の状態

    func testPairedPlantIsDerivedFromTheSnapshotLikeTheHome() {
        for me in [false, true] {
            for partner in [false, true] {
                for mood in [PlantMood.normal, .happy, .fidget, .sad] {
                    let snapshot = paired(me: me, partner: partner, mood: mood)
                    let content = WidgetContent(snapshot: snapshot)
                    XCTAssertEqual(content.mode, .paired)
                    XCTAssertEqual(content.plant, PlantCharacterState(snapshot: snapshot), "me=\(me) partner=\(partner) \(mood)")
                    XCTAssertEqual(content.me?.done, me)
                    XCTAssertEqual(content.partner?.done, partner)
                }
            }
        }
    }

    func testPeopleCarryTheirPromiseEmojiAndAName() {
        let content = WidgetContent(snapshot: paired(me: true))
        XCTAssertEqual(content.me, WidgetContent.Person(emoji: "💪", name: Strings.Widget.meFallbackLabel, done: true))
        XCTAssertEqual(content.partner, WidgetContent.Person(emoji: "🏃", name: "ゆうき", done: false))
    }

    func testAnUnknownPartnerNameFallsBackToTheGenericLabel() {
        for name in [nil, "", "  ", "\n"] {
            let content = WidgetContent(snapshot: paired(partnerName: name))
            XCTAssertEqual(content.partner?.name, Strings.Widget.partnerFallbackLabel, "name=\(String(describing: name))")
        }
    }

    // MARK: - 「(相手)が待ってるよ」

    func testWaitingMessageOnlyWhenThePartnerIsDoneAndIAmNot() {
        XCTAssertEqual(WidgetContent(snapshot: paired(me: false, partner: true)).waitingMessage, Strings.Widget.partnerWaiting("ゆうき"))
        XCTAssertNil(WidgetContent(snapshot: paired(me: false, partner: false)).waitingMessage)
        XCTAssertNil(WidgetContent(snapshot: paired(me: true, partner: false)).waitingMessage)
        XCTAssertNil(WidgetContent(snapshot: paired(me: true, partner: true)).waitingMessage)
    }

    func testWaitingMessageNeedsTheRealPartnerName() {
        // ホーム(HomeViewModel.partnerWaitingText)と同じ: 名前が分からないときは出さない
        for name in [nil, "", "   "] {
            XCTAssertNil(WidgetContent(snapshot: paired(me: false, partner: true, partnerName: name)).waitingMessage)
        }
        XCTAssertEqual(
            WidgetContent(snapshot: paired(me: false, partner: true, partnerName: " ゆうき ")).waitingMessage,
            Strings.Widget.partnerWaiting("ゆうき"),
            "前後の空白は取る"
        )
    }

    // MARK: - ストリーク

    func testStreakShowsOnlyForAPairAndOnlyWhenPositive() {
        XCTAssertEqual(WidgetContent(snapshot: paired(streak: 23)).streakDays, 23)
        XCTAssertEqual(WidgetContent(snapshot: paired(streak: 23)).inlineStreakText, Strings.Widget.streakDays(23))
        XCTAssertEqual(WidgetContent(snapshot: paired(streak: 1)).streakDays, 1)
        XCTAssertNil(WidgetContent(snapshot: paired(streak: 0)).streakDays, "0日は出さない(罰なし)")
        XCTAssertNil(WidgetContent(snapshot: paired(streak: 0)).inlineStreakText)
        XCTAssertNil(WidgetContent(snapshot: paired(streak: -3)).streakDays, "壊れた値でも「-3日」を出さない")
    }

    // MARK: - 進み具合のバー(数字なし)

    func testProgressIsTheShareOfTheCurrentInterval() {
        // わかば(7〜14): 7 → 0 / 9 → 2/7 / 13 → 6/7
        XCTAssertEqual(WidgetContent(snapshot: paired(grown: 7, floor: 7, next: 14)).progress ?? -1, 0, accuracy: 0.0001)
        XCTAssertEqual(WidgetContent(snapshot: paired(grown: 9, floor: 7, next: 14)).progress ?? -1, 2.0 / 7.0, accuracy: 0.0001)
        XCTAssertEqual(WidgetContent(snapshot: paired(grown: 13, floor: 7, next: 14)).progress ?? -1, 6.0 / 7.0, accuracy: 0.0001)
        // たね(0〜1): まだ1回もそろっていない
        XCTAssertEqual(WidgetContent(snapshot: paired(stage: 0, grown: 0, floor: 0, next: 1)).progress ?? -1, 0, accuracy: 0.0001)
        // 短い区間(ふたば 1〜3): 2回目で半分
        XCTAssertEqual(WidgetContent(snapshot: paired(stage: 1, grown: 2, floor: 1, next: 3)).progress ?? -1, 0.5, accuracy: 0.0001)
    }

    func testProgressIsHiddenWithoutTheNewKeys() {
        // 古いサーバー・古いキャッシュの snapshot: ゲージもバーも出さない(0 で埋めて「進んでいない」と見せない — GROWTH §8.6)
        XCTAssertNil(WidgetContent(snapshot: paired(grown: nil, floor: nil, next: nil)).progress)
        XCTAssertNil(WidgetContent(snapshot: paired(grown: 9, floor: nil, next: 14)).progress)
        XCTAssertNil(WidgetContent(snapshot: paired(grown: nil, floor: 7, next: 14)).progress)
    }

    func testProgressIsHiddenWhenTheValuesContradictEachOther() {
        XCTAssertNil(WidgetContent(snapshot: paired(grown: 9, floor: 10, next: 14)).progress, "段階の下限が成長回数より大きい")
        XCTAssertNil(WidgetContent(snapshot: paired(grown: 14, floor: 7, next: 14)).progress, "もう次の段階に着いているはず")
        XCTAssertNil(WidgetContent(snapshot: paired(grown: 20, floor: 7, next: 14)).progress)
        XCTAssertNil(WidgetContent(snapshot: paired(grown: -1, floor: 0, next: 14)).progress)
    }

    func testProgressIsFullAtTheLastStage() {
        // みのり(100〜)で、サーバーが次の段階を返さない(null): 長さのあるバーを満たす
        XCTAssertEqual(WidgetContent(snapshot: paired(stage: 9, grown: 128, floor: 100, next: nil)).progress, 1)
        // サーバーがみのりにも次の回数(花壇の 125 回。v1.0.1)を返すときは、その区間の進み具合
        XCTAssertEqual(WidgetContent(snapshot: paired(stage: 9, grown: 110, floor: 100, next: 125)).progress ?? -1, 0.4, accuracy: 0.0001)
    }

    func testProgressForAStageTheAppDoesNotKnowStillComesFromTheNumbers() {
        let content = WidgetContent(snapshot: paired(stage: 10, grown: 130, floor: 125, next: 150))
        XCTAssertEqual(content.progress ?? -1, 0.2, accuracy: 0.0001)
        XCTAssertEqual(content.plant.stage, 10, "描くときは PlantLayers が 9 に丸める")
    }

    func testProgressIsAlwaysWithinZeroAndOne() {
        for floor in 0..<30 {
            for grown in floor..<(floor + 30) {
                for next in [nil, grown + 1, grown + 7, grown + 50] as [Int?] {
                    if let progress = WidgetContent(snapshot: paired(grown: grown, floor: floor, next: next)).progress {
                        XCTAssertGreaterThanOrEqual(progress, 0)
                        XCTAssertLessThanOrEqual(progress, 1)
                    }
                }
            }
        }
    }

    // MARK: - ロック画面・円形: 相手の葉

    func testThePartnerLeafIsOpenOnlyWhenThePartnerIsDone() {
        let open = WidgetContent(snapshot: paired(me: false, partner: true)).partnerLeaf
        XCTAssertEqual(open, WidgetContent.PartnerLeaf(layerName: "leaf_open", isOpen: true, isNub: false))
        let folded = WidgetContent(snapshot: paired(me: true, partner: false)).partnerLeaf
        XCTAssertEqual(folded, WidgetContent.PartnerLeaf(layerName: "leaf_folded", isOpen: false, isNub: false))
        // 自分の完了は関係しない(円形は「相手の今日の状態」)
        XCTAssertEqual(WidgetContent(snapshot: paired(me: true, partner: true)).partnerLeaf?.isOpen, true)
        XCTAssertEqual(WidgetContent(snapshot: paired(me: false, partner: false)).partnerLeaf?.isOpen, false)
    }

    func testThePartnerLeafIsABudAtStageZero() {
        // 段階0(たね)はまだ葉が無く、頭の2つの芽が同じ役目をする(GROWTH §3.3)
        let lit = WidgetContent(snapshot: paired(partner: true, stage: 0, grown: 0, floor: 0, next: 1)).partnerLeaf
        XCTAssertEqual(lit, WidgetContent.PartnerLeaf(layerName: "nub_lit", isOpen: true, isNub: true))
        let closed = WidgetContent(snapshot: paired(partner: false, stage: 0, grown: 0, floor: 0, next: 1)).partnerLeaf
        XCTAssertEqual(closed, WidgetContent.PartnerLeaf(layerName: "nub_closed", isOpen: false, isNub: true))
    }

    func testThePartnerLeafIsTheSameLayerThePlantDraws() {
        // 重ね順(PlantLayers.stack)の右の葉と同じレイヤー名であること。レイヤー名はアセットカタログに実在する
        for stage in -1...12 {
            for partner in [false, true] {
                let snapshot = paired(partner: partner, stage: stage)
                let content = WidgetContent(snapshot: snapshot)
                let leaf = content.partnerLeaf
                XCTAssertNotNil(leaf, "stage \(stage)")
                let rightLeaf = PlantLayers.stack(for: content.plant, dark: false).first { $0.slot == .rightLeaf }
                XCTAssertEqual(leaf?.layerName, rightLeaf?.name, "stage \(stage) partner \(partner)")
                XCTAssertTrue(PlantLayers.allLayerNames.contains(leaf?.layerName ?? ""), "stage \(stage)")
                XCTAssertEqual(leaf?.isNub, PlantLayers.clampedStage(stage) == 0, "stage \(stage)")
            }
        }
    }

    func testThereIsNoPartnerLeafWithoutAPair() {
        XCTAssertNil(WidgetContent(snapshot: solo()).partnerLeaf)
        XCTAssertNil(WidgetContent(snapshot: nil).partnerLeaf)
    }

    // MARK: - VoiceOver

    func testTheSpokenSummaryFollowsTheGrowthDoc() {
        // GROWTH §5.4: 「みどり、わかば。あなた: 完了、ゆうき: まだ。ふたりそろって あと2回で よりそい」+ ストリーク + 待ってるよ
        // (わかばは区間が 7 回で、12 回目は後半 = 「あと○回で」の言い方)
        let content = WidgetContent(snapshot: paired(me: true, partner: false, grown: 12))
        XCTAssertEqual(
            content.spokenSummary,
            "みどり、わかば。あなた: 完了、ゆうき: まだ。ふたりそろって あと2回で よりそい。ふたりの記録: 23日"
        )
        let waiting = WidgetContent(snapshot: paired(me: false, partner: true))
        XCTAssertTrue(waiting.spokenSummary.hasSuffix(Strings.Widget.partnerWaiting("ゆうき")), waiting.spokenSummary)
    }

    func testTheSpokenSummaryOmitsWhatIsNotShown() {
        let content = WidgetContent(snapshot: paired(me: false, partner: false, grown: nil, floor: nil, next: nil, streak: 0))
        XCTAssertEqual(content.spokenSummary, "みどり、わかば。あなた: まだ、ゆうき: まだ", "新しいキーが無い・ストリーク 0・待ってない: 文を足さない")
    }

    func testTheSpokenTextForTheLockScreen() {
        XCTAssertEqual(WidgetContent(snapshot: paired(partner: true)).spokenPartner, "ゆうき: 完了")
        XCTAssertEqual(WidgetContent(snapshot: paired(partner: false)).spokenPartner, "ゆうき: まだ")
        XCTAssertEqual(WidgetContent(snapshot: paired(partnerName: nil)).spokenPartner, "\(Strings.Widget.partnerFallbackLabel): まだ")
        XCTAssertEqual(WidgetContent(snapshot: paired(streak: 23)).spokenStreak, "ふたりの記録: 23日")
        XCTAssertEqual(WidgetContent(snapshot: paired(streak: 0)).spokenStreak, Strings.Widget.displayName)
    }

    // MARK: - 数字はストリークだけ

    func testNoNumberAppearsOnTheWidgetExceptTheStreak() {
        // GROWTH §5.4: 数え方の違う数字を並べない。バーは長さだけで、数字も文も持たない(読み上げは別 — spokenSummary)
        for snapshot in [paired(me: false, partner: true), paired(me: true, partner: true), paired(grown: nil, floor: nil, next: nil)] {
            let content = WidgetContent(snapshot: snapshot)
            let visible = [content.waitingMessage, content.note].compactMap { $0 }
            for text in visible {
                XCTAssertFalse(text.contains(where: \.isNumber), "表示の文に数字が入っている: \(text)")
            }
        }
        XCTAssertEqual(WidgetContent(snapshot: paired(streak: 23)).inlineStreakText, "23日", "数字はストリークだけ")
    }

    // MARK: - 描画方式

    func testTheFourLayouts() {
        XCTAssertEqual(
            WidgetLayout.allCases,
            [.small, .medium, .lockCircular, .lockInline],
            "v1.0 のウィジェット: ホーム S / ホーム M(写真は v1.0.1)/ ロック画面の円形・インライン"
        )
    }
}
