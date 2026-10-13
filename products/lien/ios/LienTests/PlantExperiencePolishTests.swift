// PlantExperiencePolishTests.swift — 植物の体験の仕上げ(PB #57 の Opus レビューの改善提案)
//
//   1. 「見せた」の記録     : 段階アップを「見せた」と記録するのは、前面で実際に表示したとき。snapshot を観測した時点では記録しない
//                          (サイレント push で起こされたバックグラウンドのプロセスが観測して終了しても、演出を失わない)
//   2. ペアが終わったとき   : 演出を出している間にペアが解消された・別のペアになったら、その演出(と、ひとこと)を下げる
//   3. ハートを送る        : 今日すでにリアクションを送っていたら出さない(付け替えは相手に届かないため)
//   4. 名前の知らせ        : 相手が初めて付けたときは「なったよ」、変えたときは「かわったよ」
//   5. 旧ペアの記録の掃除   : 解消した旧ペアの、相手が付けた植物の名前を端末に残さない
//   6. 吹き出しの余白      : 最大2行の吹き出しが、文字を大きくしても ScrollView の上端に食い込まない
//   7. ひとこと            : VoiceOver のアクションを出せるのはペア成立中だけ
//
// 基本の挙動は StageCelebrationTests(記録の判定・モデル)と PlantHomeTests(HomeViewModel のつなぎ)。

import XCTest
@testable import Lien

// MARK: - 部品

private enum Snap {
    /// 成長ルール v2 の新キーつきのペアの snapshot(段階 stage。回数は段階の閾値から)
    static func paired(
        pairId: String = "pair-A",
        stage: Int,
        grownDays: Int? = nil,
        meDone: Bool = false,
        partnerDone: Bool = false,
        plantName: String? = nil
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
            plantMood: .normal,
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

    static func initialized(celebrated: [String: Int] = [:], seenName: [String: String] = [:]) -> PlantMemory {
        PlantMemory(initialized: true, celebratedStage: celebrated, seenName: seenName)
    }
}

private var utc: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
    return calendar
}

private final class Clock {
    var now = Date(timeIntervalSince1970: 1_781_166_600) // 2026-06-11 08:30 UTC
    func advance(days: Int) { now = now.addingTimeInterval(TimeInterval(days) * 86_400) }
}

// MARK: - 1・4・5. 記録(純粋)

final class PlantMemoryPolishTests: XCTestCase {
    // MARK: 「見せた」の記録は、表示したとき

    func testObservingDoesNotRecordTheCelebrationUntilItIsMarkedAsShown() throws {
        var memory = Snap.initialized(celebrated: ["pair-A": 2])

        let first = try XCTUnwrap(memory.observe(Snap.paired(stage: 3, grownDays: 7)).celebration)
        XCTAssertEqual(first.stage, 3)
        XCTAssertEqual(first.previousStage, 2)
        XCTAssertEqual(memory.celebratedStage["pair-A"], 2, "観測しただけでは「見せた」と記録しない")

        // まだ見せていないので、同じ snapshot を見ると、また返る(呼び出し側が、出している演出と同じか見て二重に出さない)
        XCTAssertEqual(memory.observe(Snap.paired(stage: 3, grownDays: 7)).celebration, first)

        memory.markCelebrated(first)
        XCTAssertEqual(memory.celebratedStage["pair-A"], 3, "前面で表示したあとに記録する")
        XCTAssertNil(memory.observe(Snap.paired(stage: 3, grownDays: 7)).celebration, "記録したら、もう出さない")
    }

    func testMarkingNeverMovesTheRecordBackward() {
        var memory = Snap.initialized(celebrated: ["pair-A": 5])
        memory.markCelebrated(StageCelebration(pairId: "pair-A", stage: 3, previousStage: 2, grownDays: 7))
        XCTAssertEqual(memory.celebratedStage["pair-A"], 5, "古い演出を遅れて記録しても、進んだ記録を戻さない")

        memory.markCelebrated(StageCelebration(pairId: "pair-A", stage: 6, previousStage: 5, grownDays: 30))
        XCTAssertEqual(memory.celebratedStage["pair-A"], 6)
    }

    func testTheSilentInitializationOfANewVersionIsRecordedAtOnce() {
        // 見せるものが無い(過去をさかのぼって祝わない)ので、観測の時点で記録してよい
        var memory = PlantMemory()
        XCTAssertNil(memory.observe(Snap.paired(stage: 4)).celebration)
        XCTAssertEqual(memory.celebratedStage["pair-A"], 4)
        XCTAssertTrue(memory.initialized)
    }

    func testAStageSkippedWhileTheAppWasInTheBackgroundIsStillCelebratedWithTheLastSeenStageBefore() throws {
        // バックグラウンドで 3 → 5 まで観測(記録は 2 のまま)。前面に出たときの演出は「最後に見た段階」から
        var memory = Snap.initialized(celebrated: ["pair-A": 2])
        _ = memory.observe(Snap.paired(stage: 3, grownDays: 7))
        let latest = try XCTUnwrap(memory.observe(Snap.paired(stage: 5, grownDays: 21)).celebration)
        XCTAssertEqual(latest.stage, 5)
        XCTAssertEqual(latest.previousStage, 2)
        XCTAssertEqual(latest.beforeStage, 2, "変わる前 = ユーザーが最後に見た段階")
    }

    // MARK: ハートの記録(リアクションを送った日)

    func testReactionDayIsRememberedPerDay() {
        var memory = PlantMemory()
        XCTAssertFalse(memory.hasReacted(day: 900))
        memory.noteReaction(day: 900)
        XCTAssertTrue(memory.hasReacted(day: 900))
        XCTAssertFalse(memory.hasReacted(day: 901), "次の日は、また送れる")
        XCTAssertFalse(memory.hasReacted(day: 899))
    }

    func testReactionDayRoundTripsAndOldRecordsStillLoad() throws {
        let memory = PlantMemory(initialized: true, lastReactionDay: 912)
        let decoded = try JSONDecoder().decode(PlantMemory.self, from: JSONEncoder().encode(memory))
        XCTAssertEqual(decoded, memory)
        XCTAssertEqual(decoded.lastReactionDay, 912)

        // このキーが無い古い記録(1.0.0 の途中の版が書いたもの)も読める
        let old = try JSONDecoder().decode(PlantMemory.self, from: Data(#"{"initialized": true, "lastWhisperDay": 5}"#.utf8))
        XCTAssertNil(old.lastReactionDay)
        XCTAssertEqual(old.lastWhisperDay, 5)
    }

    // MARK: 4. 名前の知らせ(初めて / 変えた)

    func testFirstNameIsToldApartFromARename() {
        var memory = Snap.initialized(celebrated: ["pair-A": 2])
        let first = memory.observe(Snap.paired(stage: 2, plantName: "みどり"))
        XCTAssertEqual(first.changedName, "みどり")
        XCTAssertTrue(first.isFirstName, "このペアで初めて見る名前 = 相手が初めて付けた")

        let renamed = memory.observe(Snap.paired(stage: 2, plantName: "あおば"))
        XCTAssertEqual(renamed.changedName, "あおば")
        XCTAssertFalse(renamed.isFirstName, "変えたときは「かわったよ」")

        let unchanged = memory.observe(Snap.paired(stage: 2, plantName: "あおば"))
        XCTAssertNil(unchanged.changedName)
        XCTAssertFalse(unchanged.isFirstName)
    }

    func testAFirstNameSeenTogetherWithACelebrationIsNotAnnounced() {
        var memory = Snap.initialized(celebrated: ["pair-A": 0])
        let observation = memory.observe(Snap.paired(stage: 1, plantName: "みどり"))
        XCTAssertNotNil(observation.celebration)
        XCTAssertNil(observation.changedName, "演出の中で名前を見せる")
        XCTAssertFalse(observation.isFirstName)
    }

    // MARK: 5. 旧ペアの記録の掃除

    func testObservingAPairForgetsTheOtherPairs() {
        var memory = Snap.initialized(
            celebrated: ["pair-OLD": 6, "pair-A": 2],
            seenName: ["pair-OLD": "ふるいなまえ", "pair-A": "みどり"]
        )
        _ = memory.observe(Snap.paired(stage: 2, plantName: "みどり"))
        XCTAssertEqual(memory.celebratedStage, ["pair-A": 2])
        XCTAssertEqual(memory.seenName, ["pair-A": "みどり"], "旧ペアの名前(相手が付けた UGC)は残さない")
    }

    func testSoloForgetsTheNamesButKeepsTheStageRecords() {
        // ペアを解消してソロに戻った: 相手が付けた名前は意味が無いので消す。段階の記録は、ソロでは触らない
        var memory = Snap.initialized(celebrated: ["pair-A": 5], seenName: ["pair-A": "みどり"])
        _ = memory.observe(Snap.solo())
        XCTAssertTrue(memory.seenName.isEmpty)
        XCTAssertEqual(memory.celebratedStage, ["pair-A": 5])
    }

    func testForgettingKeepsTheOtherFields() {
        var memory = PlantMemory(
            initialized: true, celebratedStage: ["pair-OLD": 3], seenName: ["pair-OLD": "x"],
            lastCheckinDay: 10, lastWhisperDay: 11, lastReactionDay: 12
        )
        memory.forgetOtherPairs(keeping: "pair-NEW")
        XCTAssertEqual(memory.lastCheckinDay, 10)
        XCTAssertEqual(memory.lastWhisperDay, 11)
        XCTAssertEqual(memory.lastReactionDay, 12)
        XCTAssertTrue(memory.initialized)
        XCTAssertTrue(memory.celebratedStage.isEmpty)
    }
}

// MARK: - 1・2・4・7. モデル

@MainActor
final class PlantExperienceRecordingTests: XCTestCase {
    private func makeModel(
        store: InMemoryPlantMemoryStore,
        clock: Clock = Clock()
    ) -> PlantExperienceModel {
        PlantExperienceModel(memoryStore: store, now: { clock.now }, calendar: utc)
    }

    private func shownCelebration(_ model: PlantExperienceModel) -> StageCelebration? {
        if case .stageUp(let celebration)? = model.presentation { return celebration }
        return nil
    }

    // MARK: 1. 前面で表示したときに記録する

    func testABackgroundObservationDoesNotUseUpTheCelebration() {
        let store = InMemoryPlantMemoryStore(Snap.initialized(celebrated: ["pair-A": 2]))

        // サイレント push で起こされたプロセスが、バックグラウンドで snapshot を観測した(refresh → reloadToken → load)
        let background = makeModel(store: store)
        background.snapshotDidChange(Snap.paired(stage: 3, grownDays: 7))
        XCTAssertEqual(shownCelebration(background)?.stage, 3, "演出は用意する")
        XCTAssertEqual(store.load().celebratedStage["pair-A"], 2, "でも、見せていないので記録しない")

        // そのあとプロセスが終了。次の起動(前面)で、同じ段階の演出が出る
        let foreground = makeModel(store: store)
        foreground.snapshotDidChange(Snap.paired(stage: 3, grownDays: 7))
        XCTAssertEqual(shownCelebration(foreground)?.stage, 3, "一度も見せていない演出を失わない")
        foreground.presentationDidAppear() // 前面で表示した
        XCTAssertEqual(store.load().celebratedStage["pair-A"], 3)

        // 次の起動では、もう出ない
        let later = makeModel(store: store)
        later.snapshotDidChange(Snap.paired(stage: 3, grownDays: 7))
        XCTAssertNil(later.presentation)
    }

    func testObservingTheSameSnapshotAgainKeepsTheUnrecordedPresentation() {
        let store = InMemoryPlantMemoryStore(Snap.initialized(celebrated: ["pair-A": 2]))
        let model = makeModel(store: store)
        model.snapshotDidChange(Snap.paired(stage: 3, grownDays: 7))
        let first = model.presentation
        XCTAssertNotNil(first)

        model.snapshotDidChange(Snap.paired(stage: 3, grownDays: 7)) // 前面復帰・同期のたび
        XCTAssertEqual(model.presentation, first, "同じ演出を出し直さない・消さない")

        model.presentationDidAppear()
        model.presentationDidAppear() // 二重に呼ばれても害は無い
        model.snapshotDidChange(Snap.paired(stage: 3, grownDays: 8))
        XCTAssertEqual(model.presentation, first, "表示したあとも、閉じるまで出ている")
        XCTAssertEqual(store.load().celebratedStage["pair-A"], 3)
    }

    func testClosingRecordsEvenIfTheAppearanceWasNeverReported() {
        let store = InMemoryPlantMemoryStore(Snap.initialized(celebrated: ["pair-A": 2]))
        let model = makeModel(store: store)
        model.snapshotDidChange(Snap.paired(stage: 3, grownDays: 7))

        model.dismissPresentation() // 見た(閉じた)のだから、もう一度は出さない
        XCTAssertEqual(store.load().celebratedStage["pair-A"], 3)
        XCTAssertNil(model.presentation)
    }

    func testAppearingWithoutAPresentationChangesNothing() {
        let store = InMemoryPlantMemoryStore(Snap.initialized(celebrated: ["pair-A": 2]))
        let model = makeModel(store: store)
        model.presentationDidAppear()
        XCTAssertEqual(store.load(), Snap.initialized(celebrated: ["pair-A": 2]))
    }

    func testANewerStageReplacesAnUnrecordedCelebration() {
        let store = InMemoryPlantMemoryStore(Snap.initialized(celebrated: ["pair-A": 2]))
        let model = makeModel(store: store)
        model.snapshotDidChange(Snap.paired(stage: 3, grownDays: 7))
        model.snapshotDidChange(Snap.paired(stage: 4, grownDays: 14)) // 見せないまま、もう1段階進んだ

        let celebration = shownCelebration(model)
        XCTAssertEqual(celebration?.stage, 4, "現在の段階だけを祝う")
        XCTAssertEqual(celebration?.beforeStage, 2, "変わる前 = 最後に見た段階")
        model.presentationDidAppear()
        XCTAssertEqual(store.load().celebratedStage["pair-A"], 4)
    }

    func testAnUnrecordedCelebrationIsWithdrawnWhenTheStageGoesBackButAShownOneStays() {
        // まだ見せていない演出: 取り消しで段階が戻ったら、出す前提が消えたので下げる
        let store = InMemoryPlantMemoryStore(Snap.initialized(celebrated: ["pair-A": 2]))
        let model = makeModel(store: store)
        model.snapshotDidChange(Snap.paired(stage: 3, grownDays: 7))
        XCTAssertNotNil(model.presentation)
        model.snapshotDidChange(Snap.paired(stage: 2, grownDays: 6))
        XCTAssertNil(model.presentation, "見せる前に、段階が戻った")
        XCTAssertEqual(store.load().celebratedStage["pair-A"], 2)

        // また上がったら、まだ見ていないので出る
        model.snapshotDidChange(Snap.paired(stage: 3, grownDays: 7))
        XCTAssertEqual(shownCelebration(model)?.stage, 3)

        // 見せたあとは、見ているものを勝手に消さない(閉じるのは本人)
        model.presentationDidAppear()
        model.snapshotDidChange(Snap.paired(stage: 2, grownDays: 6))
        XCTAssertEqual(shownCelebration(model)?.stage, 3)
        model.dismissPresentation()
        model.snapshotDidChange(Snap.paired(stage: 3, grownDays: 7))
        XCTAssertNil(model.presentation, "見せたあとに戻って上がっても、もう一度は祝わない")
    }

    // MARK: 2. ペアが終わったとき

    func testAStageUpIsDroppedWhenThePairIsDissolvedWhileItIsShown() {
        let store = InMemoryPlantMemoryStore(Snap.initialized(celebrated: ["pair-A": 2]))
        let model = makeModel(store: store)
        model.snapshotDidChange(Snap.paired(stage: 3, grownDays: 7, plantName: "みどり"))
        model.presentationDidAppear()
        XCTAssertNotNil(model.presentation)
        XCTAssertNil(model.nameNotice, "名前は演出の中で見せる(演出と同時には知らせない)")

        // 相手がブロック(ペア解消)した: 同期でソロになった
        model.snapshotDidChange(Snap.solo())

        XCTAssertNil(model.presentation, "古い段階アップを、閉じるまで出し続けない")
        XCTAssertNil(model.nameNotice)
    }

    func testAnUnrecordedStageUpIsDroppedAndNotRecordedWhenThePairIsDissolved() {
        let store = InMemoryPlantMemoryStore(Snap.initialized(celebrated: ["pair-A": 2]))
        let model = makeModel(store: store)
        model.snapshotDidChange(Snap.paired(stage: 3, grownDays: 7))
        model.snapshotDidChange(Snap.solo())
        XCTAssertNil(model.presentation)
        model.presentationDidAppear() // 消えた演出を、遅れて「見せた」と記録しない
        XCTAssertEqual(store.load().celebratedStage["pair-A"], 2)
    }

    func testAStageUpOfTheOldPairIsReplacedWhenANewPairAppears() {
        let store = InMemoryPlantMemoryStore(Snap.initialized(celebrated: ["pair-A": 2]))
        let model = makeModel(store: store)
        model.snapshotDidChange(Snap.paired(stage: 3, grownDays: 7))
        model.presentationDidAppear()
        XCTAssertEqual(shownCelebration(model)?.pairId, "pair-A")

        // 解消して組み直した: 新しいペアの「はじめまして」になる(古いペアの段階アップは残らない)
        model.snapshotDidChange(Snap.paired(pairId: "pair-NEW", stage: 0, grownDays: 0))
        XCTAssertEqual(shownCelebration(model)?.pairId, "pair-NEW")
        XCTAssertEqual(shownCelebration(model)?.isFirstMeeting, true)
    }

    func testWelcomeBackIsDroppedWhenThePairEnds() {
        let clock = Clock()
        let store = InMemoryPlantMemoryStore(Snap.initialized(celebrated: ["pair-A": 9]))
        let model = makeModel(store: store, clock: clock)
        model.snapshotDidChange(Snap.paired(stage: 4, meDone: true))
        model.myCheckinCompleted(snapshot: Snap.paired(stage: 4, meDone: true))
        clock.advance(days: 5)
        model.myCheckinCompleted(snapshot: Snap.paired(stage: 4, meDone: true))
        XCTAssertEqual(model.presentation, .welcomeBack)

        model.snapshotDidChange(Snap.solo(meDone: true))
        XCTAssertNil(model.presentation, "「また いっしょに」を、ペアが無いのに出し続けない")
    }

    func testTheWhisperIsHiddenWhenThePairEnds() {
        let store = InMemoryPlantMemoryStore(Snap.initialized(celebrated: ["pair-A": 9]))
        let model = makeModel(store: store)
        model.snapshotDidChange(Snap.paired(stage: 4, partnerDone: true))
        model.homeDidAppear()
        XCTAssertNotNil(model.whisper)

        model.snapshotDidChange(Snap.solo())
        XCTAssertNil(model.whisper, "ペアが解消されたら、吹き出しも下げる")
    }

    func testANilSnapshotDoesNotDropThePresentation() {
        // snapshot を読めなかっただけ(未取得)では、出している演出を消さない
        let store = InMemoryPlantMemoryStore(Snap.initialized(celebrated: ["pair-A": 2]))
        let model = makeModel(store: store)
        model.snapshotDidChange(Snap.paired(stage: 3, grownDays: 7))
        model.snapshotDidChange(nil)
        XCTAssertNotNil(model.presentation)
    }

    // MARK: 4. 名前の知らせ

    func testTheFirstNameByThePartnerAndARenameUseDifferentWords() {
        let store = InMemoryPlantMemoryStore(Snap.initialized(celebrated: ["pair-A": 2]))
        let model = makeModel(store: store)

        model.snapshotDidChange(Snap.paired(stage: 2, plantName: "みどり"))
        XCTAssertEqual(model.nameNotice, "名前が『みどり』になったよ")
        model.dismissNameNotice()

        model.snapshotDidChange(Snap.paired(stage: 2, plantName: "あおば"))
        XCTAssertEqual(model.nameNotice, "名前が『あおば』にかわったよ")
    }

    // MARK: 3. ハートを送る(その日のうちは1回)

    func testHasReactedTodayFollowsTheDay() {
        let clock = Clock()
        let store = InMemoryPlantMemoryStore(Snap.initialized())
        let model = makeModel(store: store, clock: clock)
        XCTAssertFalse(model.hasReactedToday)

        model.noteReactionSent()
        XCTAssertTrue(model.hasReactedToday)
        XCTAssertTrue(makeModel(store: store, clock: clock).hasReactedToday, "アプリを開き直しても、その日のうちは覚えている")

        clock.advance(days: 1)
        XCTAssertFalse(model.hasReactedToday, "次の日は、また送れる")
    }

    func testSigningOutForgetsTheReaction() {
        let store = InMemoryPlantMemoryStore(Snap.initialized())
        let model = makeModel(store: store)
        model.noteReactionSent()
        store.reset() // サインアウト・アカウントの削除の後始末
        XCTAssertFalse(model.hasReactedToday, "次のアカウントに持ち越さない")
    }
}

// MARK: - 3・7. HomeViewModel のつなぎ(ハート・ひとこと)

@MainActor
final class HomeViewModelPlantPolishTests: XCTestCase {
    private final class ReactingService: CheckinPerforming, Reacting {
        private(set) var stamps: [ReactionStamp] = []
        var error: Error?

        func performCheckin(current: PairSnapshot) async throws -> PairSnapshot {
            var updated = current
            updated.todayMeDone = true
            return updated
        }

        func sendReaction(stamp: ReactionStamp) async throws {
            if let error { throw error }
            stamps.append(stamp)
        }
    }

    private struct Offline: Error {}

    private struct Harness {
        let vm: HomeViewModel
        let service: ReactingService
        let clock: Clock
        let temp: TempStore
    }

    private func makeHarness(_ snapshot: PairSnapshot) -> Harness {
        let temp = TempStore()
        try? temp.store.saveSnapshot(snapshot)
        let service = ReactingService()
        let clock = Clock()
        let vm = HomeViewModel(
            store: temp.store,
            checkinService: service,
            reactionService: service,
            plantMemory: InMemoryPlantMemoryStore(Snap.initialized(celebrated: ["pair-A": 9])),
            now: { clock.now },
            calendar: utc,
            reloadWidgets: {}
        )
        vm.load()
        return Harness(vm: vm, service: service, clock: clock, temp: temp)
    }

    // MARK: ハート

    func testTheHeartIsOfferedWhenThePartnerIsDoneAndIsNotOfferedAgainAfterAnyReactionToday() async {
        let h = makeHarness(Snap.paired(stage: 3, meDone: true, partnerDone: true))
        defer { h.temp.cleanup() }
        XCTAssertTrue(h.vm.canReact)
        XCTAssertTrue(h.vm.canSendHeart, "相手が今日チェックイン済みで、まだリアクションしていない")

        // ふだんのリアクション(🔥)を送った: その日の❤️は、付け替えになるだけで相手に届かないので出さない
        let sent = await h.vm.sendReaction(stamp: .fire)
        XCTAssertTrue(sent)
        XCTAssertTrue(h.vm.canReact, "ふだんのリアクション導線は、そのまま(付け替えられる)")
        XCTAssertFalse(h.vm.canSendHeart, "リアクション済みの日は、ハートのボタンを出さない")

        // 次の日は、また出す(相手も新しい日にチェックイン済み)
        h.clock.advance(days: 1)
        XCTAssertTrue(h.vm.canSendHeart)
    }

    func testSendingTheHeartItselfAlsoMarksTheDay() async {
        let h = makeHarness(Snap.paired(stage: 3, meDone: true, partnerDone: true))
        defer { h.temp.cleanup() }
        let sent = await h.vm.sendReaction(stamp: .heart)
        XCTAssertTrue(sent)
        XCTAssertEqual(h.service.stamps, [.heart])
        XCTAssertFalse(h.vm.canSendHeart, "送ったあとは出さない(演出の中の「ハートを送ったよ」は残る)")
    }

    func testAFailedReactionDoesNotUseUpTheHeart() async {
        let h = makeHarness(Snap.paired(stage: 3, meDone: true, partnerDone: true))
        defer { h.temp.cleanup() }
        h.service.error = Offline()
        let sent = await h.vm.sendReaction(stamp: .heart)
        XCTAssertFalse(sent)
        XCTAssertTrue(h.vm.canSendHeart, "送れなかったなら、またためせる")
    }

    func testTheHeartIsNotOfferedWhileThePartnerHasNotCheckedIn() {
        let h = makeHarness(Snap.paired(stage: 3, meDone: true, partnerDone: false))
        defer { h.temp.cleanup() }
        XCTAssertFalse(h.vm.canSendHeart)
    }

    // MARK: ひとこと(VoiceOver のアクション)

    func testTheWhisperActionIsOfferedOnlyWhilePaired() {
        let paired = makeHarness(Snap.paired(stage: 3))
        defer { paired.temp.cleanup() }
        XCTAssertTrue(paired.vm.canWhisper)

        let solo = makeHarness(Snap.solo())
        defer { solo.temp.cleanup() }
        XCTAssertFalse(solo.vm.canWhisper, "土の中で眠るソロには、ひとことが無い")

        let empty = HomeViewModel(store: nil, checkinService: LocalEchoCheckinService(), reloadWidgets: {})
        XCTAssertFalse(empty.canWhisper)
    }

    func testTappingThePlantShowsTheWhisperAgainSoTheVoiceOverActionHasSomethingToShow() {
        let h = makeHarness(Snap.paired(stage: 3, partnerDone: true))
        defer { h.temp.cleanup() }
        XCTAssertNil(h.vm.plantExperience.whisper)
        h.vm.plantExperience.plantTapped() // VoiceOver のアクション「タネの子のひとこと」は、植物のタップと同じ
        XCTAssertNotNil(h.vm.plantExperience.whisper)
        XCTAssertEqual(h.vm.plantExperience.whisperToken, 1)
    }
}

// MARK: - 6. 吹き出しの余白

final class WhisperBubbleMetricsTests: XCTestCase {
    func testTheRoomAboveThePlantNeverLetsTheBubbleRunIntoTheTopOfTheScroll() {
        // 文字の大きさ(行の高さ)を、標準の 0.8 倍から 3 倍まで変えて、吹き出しがホームの ScrollView の上端
        // (植物の枠の上に、この余白 + 親の余白がある)に収まる
        var scale: CGFloat = 0.8
        while scale <= 3.0 {
            let lineHeight = WhisperBubbleMetrics.baseLineHeight * scale
            let room = WhisperBubbleMetrics.roomAbovePlant(lineHeight: lineHeight)
            let extent = WhisperBubbleMetrics.extent(lineHeight: lineHeight)
            XCTAssertGreaterThanOrEqual(
                room + WhisperBubbleMetrics.parentTopPadding, extent + WhisperBubbleMetrics.safetyMargin,
                "文字 \(scale) 倍: 余白 \(room) + 親 \(WhisperBubbleMetrics.parentTopPadding) < 吹き出し \(extent) + 余裕"
            )
            XCTAssertGreaterThanOrEqual(room, WhisperBubbleMetrics.minimumRoom, "植物の上の空きは、これより狭くしない")
            scale += 0.1
        }
    }

    func testTheStandardSizeKeepsTheLayoutNearlyAsItWas() {
        // 標準の文字の大きさでは、植物の上の余白は従来(32pt)に近い(余裕の分だけ少し広い)— ホームのレイアウトをほとんど動かさない
        let room = WhisperBubbleMetrics.roomAbovePlant(lineHeight: WhisperBubbleMetrics.baseLineHeight)
        XCTAssertEqual(room, 32, accuracy: 6)
        XCTAssertGreaterThanOrEqual(room, 32)
    }

    func testTheRoomGrowsWithTheTextSize() {
        let standard = WhisperBubbleMetrics.roomAbovePlant(lineHeight: WhisperBubbleMetrics.baseLineHeight)
        let large = WhisperBubbleMetrics.roomAbovePlant(lineHeight: WhisperBubbleMetrics.baseLineHeight * 2)
        XCTAssertGreaterThan(large, standard + 20)
    }

    func testTheConstantsAgreeWithTheDesignSystem() {
        XCTAssertEqual(WhisperBubbleMetrics.parentTopPadding, LienSpacing.l, "ホームの ScrollView の内容の余白")
        XCTAssertEqual(WhisperBubbleMetrics.minimumRoom, LienSpacing.xl)
        XCTAssertEqual(WhisperBubbleMetrics.maxLines, 2)
    }
}
