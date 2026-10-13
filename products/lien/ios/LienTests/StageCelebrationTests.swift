// StageCelebrationTests.swift — 段階アップの全画面演出・名前の知らせ・おかえり・今日のひとことの「もう見せたか」(issue #57)
//
// 検証対象(PlantMemory.swift / PlantExperienceModel.swift。docs/GROWTH.md §4.4・§5.2・§5.3・§5.5):
//   - 各段階で1回だけ(同じ snapshot を何度見ても1回)。段階0(ペア成立の「はじめまして」)も含む
//   - 新しいバージョンの初回は、今の段階で静かに初期化する(過去の段階をさかのぼって祝わない)
//   - 取り消しで段階が戻ったあと、また同じ段階に上がっても、もう一度は出さない
//   - 複数の段階を一度に飛んだとき・アプリが知らない大きい段階・ペアごとの記録・ソロ
//   - 相手が名前を付けた・変えた知らせ(自分が付けた名前・演出と同時・最初の観測では出さない)
//   - おかえり(2日以上あいたあとの自分のチェックイン)・今日のひとこと(その日はじめて)
//   - 記録の保存(UserDefaults)・サインアウトでの消去

import XCTest
@testable import Lien

// MARK: - 部品

private enum Fixture {
    /// 成長ルール v2 の新キーつきのペアの snapshot(段階 stage。回数・下限・次の段階は段階の閾値から)
    static func paired(
        pairId: String = "pair-A",
        stage: Int,
        grownDays: Int? = nil,
        meDone: Bool = false,
        partnerDone: Bool = false,
        plantName: String? = nil,
        mood: PlantMood = .normal
    ) -> PairSnapshot {
        let thresholds = [0, 1, 3, 7, 14, 21, 30, 45, 66, 100]
        let known = min(max(stage, 0), 9)
        return PairSnapshot(
            schemaVersion: PairSnapshot.currentSchemaVersion,
            pairId: pairId,
            updatedAt: Date(timeIntervalSince1970: 1_781_166_600),
            streakCurrent: 3,
            streakBest: 5,
            todayMeDone: meDone,
            todayPartnerDone: partnerDone,
            myPromiseTitle: "筋トレ",
            myPromiseEmoji: "💪",
            partnerName: "ゆうき",
            partnerPromiseTitle: "ランニング",
            partnerPromiseEmoji: "🏃",
            plantStage: stage,
            plantGrownDays: grownDays ?? thresholds[known],
            plantStageFloor: thresholds[known],
            plantNextStageAt: known + 1 < thresholds.count ? thresholds[known + 1] : nil,
            plantMood: mood,
            plantName: plantName,
            hasPartnerPhotoToday: false
        )
    }

    static func solo(meDone: Bool = false) -> PairSnapshot {
        var snapshot = SnapshotFactory.solo(todayMeDone: meDone)
        snapshot.plantGrownDays = 0
        snapshot.plantStageFloor = 0
        snapshot.plantNextStageAt = nil
        return snapshot
    }

    /// すでに初期化済み(版の最初の観測を済ませた)の記録
    static func initializedMemory(celebrated: [String: Int] = [:]) -> PlantMemory {
        PlantMemory(initialized: true, celebratedStage: celebrated)
    }
}

// MARK: - 記録の判定(純粋)

final class StageCelebrationTests: XCTestCase {
    // MARK: 版の最初の観測

    func testFirstObservationInitializesSilentlyAtTheCurrentStage() {
        // 新しいバージョンを初めて起動した既存のペア: 過去の段階をさかのぼって祝わない
        var memory = PlantMemory()
        XCTAssertFalse(memory.initialized)

        let observation = memory.observe(Fixture.paired(stage: 4, plantName: "みどり"))

        XCTAssertNil(observation.celebration)
        XCTAssertNil(observation.changedName, "最初の観測では、名前の知らせも出さない(ずっと前からある名前)")
        XCTAssertTrue(memory.initialized)
        XCTAssertEqual(memory.celebratedStage["pair-A"], 4)
        XCTAssertEqual(memory.seenName["pair-A"], "みどり", "名前は覚える")
    }

    func testFirstObservationOfAZeroStagePairIsAlsoSilent() {
        var memory = PlantMemory()
        XCTAssertNil(memory.observe(Fixture.paired(stage: 0)).celebration)
        XCTAssertEqual(memory.celebratedStage["pair-A"], 0)
    }

    func testSoloFirstObservationMarksInitializedSoTheFirstPairIsCelebrated() {
        // 新規ユーザー: 最初に見る snapshot はソロ(約束を決めたあとのホーム)。そのあとできたペアは、新しいペアとして祝う
        var memory = PlantMemory()
        XCTAssertNil(memory.observe(Fixture.solo()).celebration)
        XCTAssertTrue(memory.initialized)
        XCTAssertTrue(memory.celebratedStage.isEmpty, "ソロでは、ペアごとの記録に触れない")

        let observation = memory.observe(Fixture.paired(stage: 0))
        let celebration = observation.celebration
        XCTAssertEqual(celebration?.stage, 0)
        XCTAssertEqual(celebration?.isFirstMeeting, true, "段階0 = ペア成立の「はじめまして」")
        XCTAssertNil(celebration?.previousStage)
        XCTAssertNil(celebration?.beforeStage, "変わる前は、土の中で眠っていた姿(植物の段階ではない)")
    }

    // MARK: 各段階で1回だけ

    func testEachStageIsCelebratedOnlyOnce() {
        var memory = Fixture.initializedMemory(celebrated: ["pair-A": 4])

        let up = memory.observe(Fixture.paired(stage: 5, grownDays: 21)).celebration
        XCTAssertEqual(up?.stage, 5)
        XCTAssertEqual(up?.previousStage, 4)
        XCTAssertEqual(up?.beforeStage, 4)
        XCTAssertEqual(up?.grownDays, 21)
        XCTAssertEqual(up?.pairId, "pair-A")
        XCTAssertEqual(up?.isFirstMeeting, false)
        XCTAssertEqual(memory.celebratedStage["pair-A"], 5)

        // 同じ snapshot を何度見ても、もう出さない(ホームを開き直す・前面復帰・同期のたびに見る)
        for _ in 0..<3 {
            XCTAssertNil(memory.observe(Fixture.paired(stage: 5, grownDays: 21)).celebration)
        }
        // 次の段階では、また1回出る
        XCTAssertEqual(memory.observe(Fixture.paired(stage: 6, grownDays: 30)).celebration?.stage, 6)
    }

    func testTheWholeJourneyCelebratesEveryStageExactlyOnce() {
        var memory = Fixture.initializedMemory()
        var celebrated: [Int] = []
        for grown in 0...130 {
            let thresholds = [0, 1, 3, 7, 14, 21, 30, 45, 66, 100]
            let stage = thresholds.lastIndex { $0 <= grown } ?? 0
            // 同じ回数を2回見る(2回目は出ない)
            for _ in 0..<2 {
                if let celebration = memory.observe(Fixture.paired(stage: stage, grownDays: grown)).celebration {
                    celebrated.append(celebration.stage)
                }
            }
        }
        XCTAssertEqual(celebrated, Array(0...9), "段階0〜9を、1回ずつ・順に")
    }

    func testFirstFutabaOffersNamingAndOtherStagesDoNot() {
        var memory = Fixture.initializedMemory(celebrated: ["pair-A": 0])
        let futaba = memory.observe(Fixture.paired(stage: 1)).celebration
        XCTAssertEqual(futaba?.offersNaming, true, "最初の「ふたば」の演出の中で名前を付ける(GROWTH §5.3)")

        let meeting = Fixture.initializedMemory()
        var fresh = meeting
        XCTAssertEqual(fresh.observe(Fixture.paired(stage: 0)).celebration?.offersNaming, false, "ペア成立の直後ではない")
        XCTAssertEqual(memory.observe(Fixture.paired(stage: 2)).celebration?.offersNaming, false)
    }

    // MARK: 取り消し・段階を飛ぶ・知らない段階

    func testCancelingAndReachingTheSameStageAgainDoesNotCelebrateAgain() {
        // 当日のチェックインを取り消すと、先取りしていた1回分が戻って、段階が下がることがある
        var memory = Fixture.initializedMemory(celebrated: ["pair-A": 2])
        XCTAssertEqual(memory.observe(Fixture.paired(stage: 3, grownDays: 7)).celebration?.stage, 3, "わかばに上がった")

        XCTAssertNil(memory.observe(Fixture.paired(stage: 2, grownDays: 6)).celebration, "取り消しで戻った")
        XCTAssertEqual(memory.celebratedStage["pair-A"], 3, "記録は戻さない")
        XCTAssertNil(memory.observe(Fixture.paired(stage: 3, grownDays: 7)).celebration, "同じ段階にまた上がっても、もう一度は出さない")
        XCTAssertEqual(memory.observe(Fixture.paired(stage: 4, grownDays: 14)).celebration?.stage, 4, "次の段階は祝う")
    }

    func testSkippingSeveralStagesCelebratesOnlyTheCurrentOne() {
        // アプリを長く開かなかった(複数の段階が進んだ)
        var memory = Fixture.initializedMemory(celebrated: ["pair-A": 1])
        let celebration = memory.observe(Fixture.paired(stage: 4, grownDays: 14)).celebration
        XCTAssertEqual(celebration?.stage, 4)
        XCTAssertEqual(celebration?.previousStage, 1)
        XCTAssertEqual(celebration?.beforeStage, 1, "変わる前 = 最後に見た段階")
        XCTAssertNil(memory.observe(Fixture.paired(stage: 4, grownDays: 14)).celebration)
    }

    func testPairBornWhileTheAppWasClosedCelebratesTheCurrentStageWithoutMeeting() {
        // 相手がペア成立のあとチェックインを重ね、自分は初めてアプリを開いたらもう「ふたば」だった
        var memory = Fixture.initializedMemory()
        let celebration = memory.observe(Fixture.paired(stage: 1)).celebration
        XCTAssertEqual(celebration?.stage, 1)
        XCTAssertNil(celebration?.previousStage)
        XCTAssertEqual(celebration?.beforeStage, 0, "前の記録が無いときは、1つ前の段階")
        XCTAssertEqual(celebration?.offersNaming, true, "名前もここで付けられる")
    }

    func testUnknownLargeStageIsClampedSoTheLastStageIsNotCelebratedRepeatedly() {
        // 1.0.1 の花壇の段階 10 以降をサーバーが返した古いアプリは、みのり(9)として描く
        var memory = Fixture.initializedMemory(celebrated: ["pair-A": 9])
        XCTAssertNil(memory.observe(Fixture.paired(stage: 10, grownDays: 125)).celebration)
        XCTAssertNil(memory.observe(Fixture.paired(stage: 12, grownDays: 175)).celebration)
        XCTAssertEqual(memory.celebratedStage["pair-A"], 9)

        var behind = Fixture.initializedMemory(celebrated: ["pair-A": 8])
        let celebration = behind.observe(Fixture.paired(stage: 11, grownDays: 150)).celebration
        XCTAssertEqual(celebration?.stage, 9, "みのりとして、1回だけ祝う")
    }

    // MARK: ペアごと・ソロ

    func testPairsAreTrackedSeparately() {
        var memory = Fixture.initializedMemory(celebrated: ["pair-A": 5])
        // 別のペア(組み直し)は、新しいペアとして段階0から祝う
        let rebuilt = memory.observe(Fixture.paired(pairId: "pair-B", stage: 0)).celebration
        XCTAssertEqual(rebuilt?.stage, 0)
        XCTAssertEqual(rebuilt?.pairId, "pair-B")
        XCTAssertEqual(memory.celebratedStage["pair-A"], 5, "前のペアの記録は触らない")
        XCTAssertEqual(memory.celebratedStage["pair-B"], 0)
    }

    func testSoloSnapshotDoesNotCelebrate() {
        var memory = Fixture.initializedMemory(celebrated: ["pair-A": 5])
        XCTAssertNil(memory.observe(Fixture.solo(meDone: true)).celebration)
        XCTAssertEqual(memory.celebratedStage, ["pair-A": 5])
    }

    // MARK: 名前の知らせ(GROWTH §5.3)

    func testPartnerNamingOrRenamingShowsNoticeOnceAfterTheFirstObservation() {
        var memory = Fixture.initializedMemory(celebrated: ["pair-A": 2])
        // 名前が無い → 相手が付けた
        XCTAssertEqual(memory.observe(Fixture.paired(stage: 2, plantName: "みどり")).changedName, "みどり")
        XCTAssertNil(memory.observe(Fixture.paired(stage: 2, plantName: "みどり")).changedName, "同じ名前は、もう知らせない")
        // 相手が変えた
        XCTAssertEqual(memory.observe(Fixture.paired(stage: 2, plantName: "あおば")).changedName, "あおば")
        // 名前が(まだ)無い snapshot は知らせない
        XCTAssertNil(memory.observe(Fixture.paired(stage: 2, plantName: nil)).changedName)
        XCTAssertNil(memory.observe(Fixture.paired(stage: 2, plantName: "")).changedName)
    }

    func testOwnNameIsNotAnnouncedToMyself() {
        var memory = Fixture.initializedMemory(celebrated: ["pair-A": 2])
        memory.recordOwnName(pairId: "pair-A", name: "みどり")
        XCTAssertNil(memory.observe(Fixture.paired(stage: 2, plantName: "みどり")).changedName)
    }

    func testNameChangeTogetherWithACelebrationIsRememberedButNotAnnounced() {
        // 演出の中で名前を見せる。演出と同時に「かわったよ」を出さない
        var memory = Fixture.initializedMemory(celebrated: ["pair-A": 0])
        let observation = memory.observe(Fixture.paired(stage: 1, plantName: "みどり"))
        XCTAssertEqual(observation.celebration?.stage, 1)
        XCTAssertNil(observation.changedName)
        XCTAssertEqual(memory.seenName["pair-A"], "みどり")
        XCTAssertNil(memory.observe(Fixture.paired(stage: 1, plantName: "みどり")).changedName, "あとで知らせ直さない")
    }

    func testNamesAreTrackedPerPair() {
        var memory = Fixture.initializedMemory(celebrated: ["pair-A": 2, "pair-B": 2])
        _ = memory.observe(Fixture.paired(pairId: "pair-A", stage: 2, plantName: "みどり"))
        XCTAssertEqual(memory.observe(Fixture.paired(pairId: "pair-B", stage: 2, plantName: "みどり")).changedName, "みどり")
    }

    // MARK: おかえり(GROWTH §4.4)

    func testWelcomeBackNeedsAGapOfAtLeastTwoMissedDays() {
        var memory = PlantMemory()
        // 初めて(記録が無い): 出さない。今日を覚える
        XCTAssertFalse(memory.noteMyCheckin(day: 1000))
        XCTAssertEqual(memory.lastCheckinDay, 1000)
        // 毎日続けている側には出ない
        XCTAssertFalse(memory.noteMyCheckin(day: 1001))
        // 差が 1・2(間の日が 0・1 日): 出さない
        XCTAssertFalse(memory.noteMyCheckin(day: 1002), "前回 1001 から差 1")
        XCTAssertFalse(memory.noteMyCheckin(day: 1004), "前回 1002 から差 2(間に1日)")
        // 2日以上あいた(間の日が2日): 出す。日付の差が 3 以上
        XCTAssertTrue(memory.noteMyCheckin(day: 1007), "前回 1004 から差 3(間に1005・1006 の2日)")
        XCTAssertEqual(memory.lastCheckinDay, 1007, "出したあとも、今日を覚える")
        XCTAssertTrue(PlantMemory.welcomeBackMinGapDays == 3)
        XCTAssertTrue(memory.noteMyCheckin(day: 1100), "ずっとあいたあとも出す(空いた日数は表示しない)")
    }

    func testWelcomeBackIsNotShownWhenTheClockMovesBackward() {
        var memory = PlantMemory(lastCheckinDay: 1000)
        XCTAssertFalse(memory.noteMyCheckin(day: 990))
        XCTAssertEqual(memory.lastCheckinDay, 990)
    }

    // MARK: 今日のひとこと(GROWTH §5.5)

    func testWhisperIsClaimedOncePerDay() {
        var memory = PlantMemory()
        XCTAssertTrue(memory.claimWhisper(day: 500), "その日はじめて")
        XCTAssertFalse(memory.claimWhisper(day: 500), "同じ日は、もう出さない")
        XCTAssertTrue(memory.claimWhisper(day: 501), "次の日は、また出す")
    }

    // MARK: 記録の保存

    func testMemoryRoundTripsThroughJSONAndFillsMissingKeys() throws {
        let memory = PlantMemory(
            initialized: true,
            celebratedStage: ["pair-A": 3, "pair-B": 0],
            seenName: ["pair-A": "みどり"],
            lastCheckinDay: 700,
            lastWhisperDay: 701
        )
        let decoded = try JSONDecoder().decode(PlantMemory.self, from: JSONEncoder().encode(memory))
        XCTAssertEqual(decoded, memory)

        // 将来(別の版)に足したキーがあっても、欠けているキーがあっても、読み捨てずに読める
        let sparse = try JSONDecoder().decode(
            PlantMemory.self,
            from: Data(#"{"initialized": true, "futureKey": 1}"#.utf8)
        )
        XCTAssertEqual(sparse, PlantMemory(initialized: true))
    }

    func testUserDefaultsStoreRoundTripsAndReadsCorruptDataAsEmpty() throws {
        let suite = "StageCelebrationTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = UserDefaultsPlantMemoryStore(defaults: defaults)

        XCTAssertEqual(store.load(), PlantMemory(), "何も無ければ初期値")
        let memory = PlantMemory(initialized: true, celebratedStage: ["pair-A": 4], lastCheckinDay: 42)
        store.save(memory)
        XCTAssertEqual(UserDefaultsPlantMemoryStore(defaults: defaults).load(), memory, "別のインスタンス(再起動)でも同じ")

        defaults.set(Data("not json".utf8), forKey: UserDefaultsPlantMemoryStore.key)
        XCTAssertEqual(store.load(), PlantMemory(), "壊れた記録は、初期値(= 静かな初期化)として読む")
    }

    func testResetClearsTheRecordsButKeepsInitialized() {
        let store = InMemoryPlantMemoryStore(PlantMemory(
            initialized: true,
            celebratedStage: ["pair-A": 5],
            seenName: ["pair-A": "みどり"],
            lastCheckinDay: 700,
            lastWhisperDay: 701
        ))

        store.reset()

        var memory = store.load()
        XCTAssertEqual(memory, PlantMemory(initialized: true))
        // 次のアカウントで最初にできたペアは、新しいペアとして「はじめまして」を祝う(静かに初期化してしまわない)
        XCTAssertEqual(memory.observe(Fixture.paired(pairId: "pair-X", stage: 0)).celebration?.stage, 0)
        // 前のアカウントの最後のチェックイン日から、おかえりを出さない
        XCTAssertFalse(memory.noteMyCheckin(day: 9999))
    }
}

// MARK: - モデル(PlantExperienceModel)

@MainActor
final class PlantExperienceModelTests: XCTestCase {
    /// 日付を進められる時計(端末のローカル日。テストは UTC のカレンダーで日を数える)
    private final class Clock {
        var now = Date(timeIntervalSince1970: 1_781_166_600) // 2026-06-11 08:30 UTC
        func advance(days: Int) { now = now.addingTimeInterval(TimeInterval(days) * 86_400) }
        func set(hour: Int) {
            let calendar = Clock.calendar
            let startOfDay = calendar.startOfDay(for: now)
            now = calendar.date(byAdding: .hour, value: hour, to: startOfDay) ?? now
        }

        static var calendar: Calendar {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
            return calendar
        }
    }

    private func makeModel(
        memory: PlantMemory = Fixture.initializedMemory(),
        clock: Clock = Clock()
    ) -> (model: PlantExperienceModel, store: InMemoryPlantMemoryStore, clock: Clock) {
        let store = InMemoryPlantMemoryStore(memory)
        let model = PlantExperienceModel(memoryStore: store, now: { clock.now }, calendar: Clock.calendar)
        return (model, store, clock)
    }

    // MARK: 段階アップの演出

    func testStageUpPresentsOnceAndStaysDismissed() {
        let (model, _, _) = makeModel(memory: Fixture.initializedMemory(celebrated: ["pair-A": 2]))
        XCTAssertNil(model.presentation)

        model.snapshotDidChange(Fixture.paired(stage: 3, grownDays: 7))
        guard case .stageUp(let celebration)? = model.presentation else {
            return XCTFail("段階アップの演出が出ていない: \(String(describing: model.presentation))")
        }
        XCTAssertEqual(celebration.stage, 3)

        model.dismissPresentation()
        XCTAssertNil(model.presentation)
        // ホームを開き直す・同期のたびに同じ snapshot を渡しても、もう出さない
        model.snapshotDidChange(Fixture.paired(stage: 3, grownDays: 7))
        model.snapshotDidChange(Fixture.paired(stage: 3, grownDays: 8))
        XCTAssertNil(model.presentation)
    }

    func testFirstSnapshotInANewVersionPresentsNothing() {
        let (model, store, _) = makeModel(memory: PlantMemory())
        model.snapshotDidChange(Fixture.paired(stage: 5))
        XCTAssertNil(model.presentation, "新しいバージョンの初回は、今の段階で静かに初期化")
        XCTAssertEqual(store.load().celebratedStage["pair-A"], 5)
    }

    func testNilSnapshotDoesNothing() {
        let (model, store, _) = makeModel()
        model.snapshotDidChange(nil)
        XCTAssertNil(model.presentation)
        XCTAssertEqual(store.load(), Fixture.initializedMemory(), "記録に触れない")
    }

    func testRecordsAreReadAgainSoASignOutResetIsNotOverwrittenByAStaleCopy() {
        let (model, store, _) = makeModel(memory: Fixture.initializedMemory(celebrated: ["pair-A": 2]))
        model.snapshotDidChange(Fixture.paired(stage: 2))
        store.reset() // サインアウトの後始末(AppModel.endSession)
        // 新しいアカウントの新しいペア: 古い記録の写しではなく、消した記録から始まる
        model.snapshotDidChange(Fixture.paired(pairId: "pair-NEW", stage: 0))
        XCTAssertEqual(model.presentation?.id, "stageUp:pair-NEW#0")
    }

    // MARK: 名前の知らせ

    func testPartnerRenameShowsANoticeAndOwnNameDoesNot() {
        let (model, _, _) = makeModel(memory: Fixture.initializedMemory(celebrated: ["pair-A": 2]))
        model.snapshotDidChange(Fixture.paired(stage: 2, plantName: "みどり"))
        XCTAssertEqual(model.nameNotice, Strings.Plant.nameChangedNotice("みどり"))
        model.dismissNameNotice()
        XCTAssertNil(model.nameNotice)

        // 自分が変えた: 知らせない
        model.recordOwnName(pairId: "pair-A", name: "あおば")
        model.snapshotDidChange(Fixture.paired(stage: 2, plantName: "あおば"))
        XCTAssertNil(model.nameNotice)

        // 相手が付けていた名前に決まった(409): 文言を出す
        model.showNameNotice(Strings.Plant.nameAdoptedNote("きいろ"))
        XCTAssertEqual(model.nameNotice, "名前は『きいろ』になったよ")
    }

    func testNameNoticeClearsWhenThePairEnds() {
        let (model, _, _) = makeModel(memory: Fixture.initializedMemory(celebrated: ["pair-A": 2]))
        model.snapshotDidChange(Fixture.paired(stage: 2, plantName: "みどり"))
        XCTAssertNotNil(model.nameNotice)
        model.snapshotDidChange(Fixture.solo())
        XCTAssertNil(model.nameNotice, "ペアが解消されたら、相手の名前の知らせは意味がない")
    }

    // MARK: おかえり

    func testWelcomeBackAfterAGapOfTwoOrMoreDays() {
        let (model, _, clock) = makeModel()
        let snapshot = Fixture.paired(stage: 3, meDone: true)
        model.myCheckinCompleted(snapshot: snapshot) // 初めて: 出さない
        XCTAssertNil(model.presentation)

        clock.advance(days: 1)
        model.myCheckinCompleted(snapshot: snapshot) // 毎日: 出さない
        XCTAssertNil(model.presentation)

        clock.advance(days: 3) // 間の日が2日
        model.myCheckinCompleted(snapshot: snapshot)
        XCTAssertEqual(model.presentation, .welcomeBack)

        model.dismissPresentation()
        clock.advance(days: 1)
        model.myCheckinCompleted(snapshot: snapshot)
        XCTAssertNil(model.presentation, "また毎日に戻れば出ない")
    }

    func testWelcomeBackIsSkippedForSoloAndWhileAStageUpIsShown() {
        let (model, _, clock) = makeModel(memory: Fixture.initializedMemory(celebrated: ["pair-A": 2]))
        model.myCheckinCompleted(snapshot: Fixture.paired(stage: 2, meDone: true))
        clock.advance(days: 5)

        // ソロ(「また いっしょに」が合わない): 出さない
        model.myCheckinCompleted(snapshot: Fixture.solo(meDone: true))
        XCTAssertNil(model.presentation)

        // 段階アップの演出が出ているときは、そちらだけ
        clock.advance(days: 5)
        model.snapshotDidChange(Fixture.paired(stage: 3, grownDays: 7, meDone: true))
        guard case .stageUp? = model.presentation else { return XCTFail("段階アップが出ていない") }
        model.myCheckinCompleted(snapshot: Fixture.paired(stage: 3, meDone: true))
        guard case .stageUp? = model.presentation else { return XCTFail("おかえりが段階アップを上書きした") }
    }

    // MARK: 今日のひとこと

    func testWhisperAppearsOncePerDayAndTapShowsItAgain() {
        let (model, _, clock) = makeModel(memory: Fixture.initializedMemory(celebrated: ["pair-A": 2]))
        let snapshot = Fixture.paired(stage: 2)
        model.snapshotDidChange(snapshot)
        XCTAssertNil(model.whisper)

        model.homeDidAppear() // その日はじめて
        let first = model.whisper
        XCTAssertNotNil(first)
        XCTAssertEqual(model.whisperToken, 1)

        model.hideWhisper()
        XCTAssertNil(model.whisper)
        model.homeDidAppear() // 同じ日の2回目(前面復帰など): 出さない
        XCTAssertNil(model.whisper)

        model.plantTapped() // 植物をタップ: もう一度(同じ日の同じ状況なら同じ言葉)
        XCTAssertEqual(model.whisper, first)
        XCTAssertEqual(model.whisperToken, 2, "出し直すたびに増える(View のタイマーの作り直し)")

        clock.advance(days: 1)
        model.hideWhisper()
        model.homeDidAppear() // 次の日: また出す
        XCTAssertNotNil(model.whisper)
    }

    func testWhisperIsNotShownForSoloOrWhileAPresentationIsShown() {
        let (solo, _, _) = makeModel()
        solo.snapshotDidChange(Fixture.solo())
        solo.homeDidAppear()
        solo.plantTapped()
        XCTAssertNil(solo.whisper, "土の中で眠っているソロには出さない")

        let (paired, store, _) = makeModel(memory: Fixture.initializedMemory(celebrated: ["pair-A": 2]))
        paired.snapshotDidChange(Fixture.paired(stage: 3, grownDays: 7)) // 段階アップの演出が出る
        paired.homeDidAppear()
        XCTAssertNil(paired.whisper)
        XCTAssertNil(store.load().lastWhisperDay, "今日のぶんは使わない(演出を閉じたあとの次の機会に出す)")

        paired.dismissPresentation()
        paired.homeDidAppear()
        XCTAssertNotNil(paired.whisper)
    }

    func testAStageUpHidesTheCurrentWhisper() {
        let (model, _, _) = makeModel(memory: Fixture.initializedMemory(celebrated: ["pair-A": 2]))
        model.snapshotDidChange(Fixture.paired(stage: 2))
        model.homeDidAppear()
        XCTAssertNotNil(model.whisper)
        model.snapshotDidChange(Fixture.paired(stage: 3, grownDays: 7))
        XCTAssertNil(model.whisper)
    }
}
