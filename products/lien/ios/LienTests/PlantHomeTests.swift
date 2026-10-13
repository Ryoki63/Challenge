// PlantHomeTests.swift — ホームの植物まわり(HomeViewModel と PlantExperienceModel・PlantNamingModel のつなぎ / issue #57)
//
// 検証対象(HomeViewModel.swift):
//   - ゲージの文・VoiceOver の読み上げ文・葉の下の約束の絵文字・植物の名前 が snapshot から導かれる(ソロ・新しいキーが無いとき)
//   - 揺れ(plantSways)は描いている状態から決まる(plantMood が古くても食い違わない — PA の手直し)
//   - 段階アップの演出: 読み込み(load)・チェックイン(apply)・同期のどれで snapshot が変わっても、各段階で1回だけ
//   - 名前付けの導線(「名前をつける」は最初の「ふたば」以降・名前が付くまで / 名前の行は変えるボタン)と、結果の反映
//     (名前だけを端末の snapshot に反映・自分の名前は「かわったよ」に出さない・相手が先だったときは知らせる)
//   - おかえり(2日以上あいたあとの自分のチェックイン)・「ハートを送る」の戻り値

import XCTest
@testable import Lien

// MARK: - モック(トップレベル: テストクラスの @MainActor 隔離を継承させない)

/// チェックインで todayMeDone を立て、設定した分だけ成長を進めて返す(ふたり達成で段階が上がるときの再現)
private final class GrowingCheckinService: CheckinPerforming, Reacting {
    /// チェックインのたびに、返す snapshot を加工する(段階・成長回数の更新)
    var transform: (inout PairSnapshot) -> Void = { _ in }
    private(set) var callCount = 0
    private(set) var reactions: [ReactionStamp] = []
    var reactionError: Error?

    func performCheckin(current: PairSnapshot) async throws -> PairSnapshot {
        callCount += 1
        var updated = current
        updated.todayMeDone = true
        transform(&updated)
        return updated
    }

    func sendReaction(stamp: ReactionStamp) async throws {
        if let reactionError { throw reactionError }
        reactions.append(stamp)
    }
}

private final class RecordingNaming: PlantNaming {
    private(set) var calls: [(name: String, mode: PlantNameMode)] = []
    var result: PlantNameOutcome = .saved(name: "みどり")

    func setName(_ name: String, mode: PlantNameMode) async throws -> PlantNameOutcome {
        calls.append((name, mode))
        return result
    }
}

/// 日付を進められる時計
private final class DayClock {
    var now = Date(timeIntervalSince1970: 1_781_166_600) // 2026-06-11 08:30 UTC
    func advance(days: Int) { now = now.addingTimeInterval(TimeInterval(days) * 86_400) }
}

private var utcCalendar: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
    return calendar
}

@MainActor
final class PlantHomeTests: XCTestCase {
    /// サーバーの閾値 [0,1,3,7,14,21,30,45,66,100] で、成長回数 grown の snapshot を組み立てる
    private func snapshot(
        grown: Int,
        pairId: String? = "pair-A",
        meDone: Bool = false,
        partnerDone: Bool = false,
        plantName: String? = "みどり",
        mood: PlantMood = .normal,
        withGrowthKeys: Bool = true
    ) -> PairSnapshot {
        let thresholds = [0, 1, 3, 7, 14, 21, 30, 45, 66, 100]
        let stage = thresholds.lastIndex { $0 <= grown } ?? 0
        var snapshot = PairSnapshot(
            schemaVersion: PairSnapshot.currentSchemaVersion,
            pairId: pairId,
            updatedAt: Date(timeIntervalSince1970: 1_781_166_600),
            streakCurrent: 4,
            streakBest: 9,
            todayMeDone: meDone,
            todayPartnerDone: partnerDone,
            myPromiseTitle: "筋トレ",
            myPromiseEmoji: "💪",
            partnerName: pairId == nil ? nil : "ゆうき",
            partnerPromiseTitle: pairId == nil ? nil : "ランニング",
            partnerPromiseEmoji: pairId == nil ? nil : "🏃",
            plantStage: stage,
            plantMood: mood,
            plantName: plantName,
            hasPartnerPhotoToday: false
        )
        if withGrowthKeys {
            snapshot.plantGrownDays = grown
            snapshot.plantStageFloor = thresholds[stage]
            snapshot.plantNextStageAt = stage + 1 < thresholds.count ? thresholds[stage + 1] : nil
        }
        return snapshot
    }

    private struct Harness {
        let vm: HomeViewModel
        let service: GrowingCheckinService
        let naming: RecordingNaming
        let memory: InMemoryPlantMemoryStore
        let temp: TempStore
        let clock: DayClock
        let reloads: ReloadCounter

        var store: AppGroupStore { temp.store }
    }

    /// 既定の記録: 版の最初の観測は済んでいて、pair-A の段階は全部お祝い済み(演出が出ない)。
    /// 演出を確かめるテストは、記録を渡して始める
    private static let quietMemory = PlantMemory(initialized: true, celebratedStage: ["pair-A": 9])

    private func makeHarness(
        _ initial: PairSnapshot?,
        memory: PlantMemory = PlantHomeTests.quietMemory,
        withNaming: Bool = true
    ) -> Harness {
        let temp = TempStore()
        if let initial { try? temp.store.saveSnapshot(initial) }
        let service = GrowingCheckinService()
        let naming = RecordingNaming()
        let memoryStore = InMemoryPlantMemoryStore(memory)
        let clock = DayClock()
        let reloads = ReloadCounter()
        let vm = HomeViewModel(
            store: temp.store,
            checkinService: service,
            reactionService: service,
            plantNaming: withNaming ? naming : nil,
            plantMemory: memoryStore,
            now: { clock.now },
            calendar: utcCalendar,
            reloadWidgets: { reloads.value += 1 }
        )
        return Harness(vm: vm, service: service, naming: naming, memory: memoryStore, temp: temp, clock: clock, reloads: reloads)
    }

    // MARK: ゲージの文・VoiceOver・絵文字・名前

    func testGaugeAccessibilityEmojisAndNameFollowTheSnapshot() {
        let h = makeHarness(snapshot(grown: 11, meDone: true))
        defer { h.temp.cleanup() }
        h.vm.load()

        XCTAssertEqual(h.vm.growthGaugeText, "ふたりそろって あと3回で よりそい")
        XCTAssertEqual(
            h.vm.plantAccessibilityText,
            "みどり、わかば。あなた: 完了、ゆうき: まだ。ふたりそろって あと3回で よりそい",
            "GROWTH §5.4 の読み上げ例"
        )
        XCTAssertEqual(h.vm.leafEmojis.me, "💪")
        XCTAssertEqual(h.vm.leafEmojis.partner, "🏃")
        XCTAssertEqual(h.vm.plantName, "みどり")
        XCTAssertTrue(h.vm.plantState.peek, "11回から、のぞき(長い区間の後半)")
    }

    func testSoloHidesGaugeNameAndLeafEmojis() {
        let h = makeHarness(snapshot(grown: 0, pairId: nil, meDone: true, plantName: "みどり"))
        defer { h.temp.cleanup() }
        h.vm.load()

        XCTAssertNil(h.vm.growthGaugeText)
        XCTAssertEqual(h.vm.plantAccessibilityText, "土の中で眠るタネの子")
        XCTAssertNil(h.vm.leafEmojis.me, "ソロには葉が無い")
        XCTAssertNil(h.vm.leafEmojis.partner)
        XCTAssertNil(h.vm.plantName, "ソロには名前を出さない")
        XCTAssertFalse(h.vm.canNamePlant)
        XCTAssertFalse(h.vm.canRenamePlant)
    }

    func testEmptyStateHasNoPlantTexts() {
        let h = makeHarness(nil)
        defer { h.temp.cleanup() }
        h.vm.load()
        XCTAssertNil(h.vm.growthGaugeText)
        XCTAssertNil(h.vm.plantAccessibilityText, "空状態の植物は装飾画像")
        XCTAssertNil(h.vm.plantName)
        XCTAssertFalse(h.vm.plantSways)
    }

    func testSnapshotWithoutNewKeysShowsNoGaugeButStillWorks() {
        let h = makeHarness(snapshot(grown: 11, meDone: true, withGrowthKeys: false))
        defer { h.temp.cleanup() }
        h.vm.load()

        XCTAssertNil(h.vm.growthGaugeText, "新しいキーが無ければ、ゲージを出さない")
        XCTAssertEqual(h.vm.plantAccessibilityText, "みどり、わかば。あなた: 完了、ゆうき: まだ")
        XCTAssertFalse(h.vm.plantState.peek)
    }

    // MARK: 揺れ(PA の手直し)

    func testSwaysFollowsTheDrawnStateEvenWhenTheMoodIsStale() async {
        // 相手が先に完了(fidget)→ 自分がチェックイン: サーバーの応答が来る前の楽観更新では mood が fidget のまま、
        // 完了のフラグだけがふたりそろった。葉は両方ひらいているので、揺れは止まる
        let h = makeHarness(snapshot(grown: 5, meDone: false, partnerDone: true, mood: .fidget))
        defer { h.temp.cleanup() }
        h.vm.load()
        XCTAssertTrue(h.vm.plantSways, "相手だけ完了: 相手の葉を見て、そわそわ")

        await h.vm.performCheckin()

        XCTAssertEqual(h.vm.snapshot?.plantMood, .fidget, "mood は古いまま(楽観更新)")
        XCTAssertFalse(h.vm.plantSways, "葉がふたりともひらいたので揺れない")
        XCTAssertEqual(h.vm.plantState.expression, .happy)
    }

    func testSwaysStartsWhenOnlyOneIsDoneEvenWithAStaleNormalMood() {
        let h = makeHarness(snapshot(grown: 5, meDone: true, partnerDone: false, mood: .normal))
        defer { h.temp.cleanup() }
        h.vm.load()
        XCTAssertTrue(h.vm.plantSways)
    }

    // MARK: 段階アップの演出

    func testLoadingAHigherStageCelebratesOnceAcrossReloads() {
        let h = makeHarness(
            snapshot(grown: 7),
            memory: PlantMemory(initialized: true, celebratedStage: ["pair-A": 2])
        )
        defer { h.temp.cleanup() }

        h.vm.load() // 通知の snapshot(NSE が App Group に書いた)を、ホームを開いて読んだ
        guard case .stageUp(let celebration)? = h.vm.plantExperience.presentation else {
            return XCTFail("段階アップの演出が出ていない")
        }
        XCTAssertEqual(celebration.stage, 3)
        XCTAssertEqual(celebration.grownDays, 7)

        h.vm.plantExperience.dismissPresentation()
        h.vm.load()
        h.vm.load() // 前面復帰・同期のたび
        XCTAssertNil(h.vm.plantExperience.presentation, "同じ段階では、もう出さない")
    }

    func testCheckinThatReachesTheNextStageCelebratesAndACancelDoesNotRepeatIt() async {
        // わかば(7回)の1回手前: 自分のチェックインで、ふたり達成 → 7回 → 段階3
        let h = makeHarness(
            snapshot(grown: 6, meDone: false, partnerDone: true, mood: .fidget),
            memory: PlantMemory(initialized: true, celebratedStage: ["pair-A": 2])
        )
        defer { h.temp.cleanup() }
        h.service.transform = { snapshot in
            snapshot.plantStage = 3
            snapshot.plantGrownDays = 7
            snapshot.plantStageFloor = 7
            snapshot.plantNextStageAt = 14
            snapshot.plantMood = .happy
        }
        h.vm.load()
        XCTAssertNil(h.vm.plantExperience.presentation)

        await h.vm.performCheckin()

        guard case .stageUp(let celebration)? = h.vm.plantExperience.presentation else {
            return XCTFail("チェックインで段階が上がったのに、演出が出ていない")
        }
        XCTAssertEqual(celebration.stage, 3)
        XCTAssertEqual(celebration.previousStage, 2)
        XCTAssertEqual(h.vm.growthGaugeText, "ふたりそろって あと7回で よりそい")

        // 取り消し → 先取りの1回が戻って 6回(段階2)→ もう一度チェックインで 7回: もう一度は出さない
        h.vm.plantExperience.dismissPresentation()
        try? h.store.saveSnapshot(snapshot(grown: 6, meDone: false, partnerDone: true, mood: .fidget))
        h.vm.load()
        XCTAssertNil(h.vm.plantExperience.presentation)
        await h.vm.performCheckin()
        XCTAssertNil(h.vm.plantExperience.presentation, "取り消しのあとに同じ段階へ戻っても、もう一度は祝わない")
    }

    func testNewPairCelebratesTheMeetingWhenItAppears() {
        // ソロのホーム → 相手の受諾でペア成立(段階0): 「はじめまして」
        let h = makeHarness(snapshot(grown: 0, pairId: nil))
        defer { h.temp.cleanup() }
        h.vm.load()
        XCTAssertNil(h.vm.plantExperience.presentation)

        try? h.store.saveSnapshot(snapshot(grown: 0, pairId: "pair-NEW", plantName: nil))
        h.vm.load()

        guard case .stageUp(let celebration)? = h.vm.plantExperience.presentation else {
            return XCTFail("ペア成立の演出が出ていない")
        }
        XCTAssertTrue(celebration.isFirstMeeting)
        XCTAssertEqual(h.vm.growthGaugeText, "ふたりそろって あと1回で ふたば")
    }

    func testFirstLaunchOfThisVersionDoesNotReplayThePast() {
        // 新しいバージョンを初めて起動した既存のペア(段階5): 過去の段階をさかのぼって祝わない
        let h = makeHarness(snapshot(grown: 22), memory: PlantMemory())
        defer { h.temp.cleanup() }
        h.vm.load()
        XCTAssertNil(h.vm.plantExperience.presentation)
        XCTAssertEqual(h.memory.load().celebratedStage["pair-A"], 5)
    }

    // MARK: 名前付けの導線

    func testNamingEntryPointsFollowTheStageAndTheName() {
        // 段階0(たね): ペア成立の直後は付けない(最初の成功と結びつける)
        let h = makeHarness(snapshot(grown: 0, plantName: nil))
        defer { h.temp.cleanup() }
        h.vm.load()
        XCTAssertFalse(h.vm.canNamePlant)

        // 段階1(ふたば)以降で、名前が無い: 「名前をつける」(演出を閉じても、名前が付くまで残る)
        try? h.store.saveSnapshot(snapshot(grown: 1, plantName: nil))
        h.vm.load()
        XCTAssertTrue(h.vm.canNamePlant)
        XCTAssertFalse(h.vm.canRenamePlant)

        // 名前がある: 名前の行が、変えるボタンになる
        try? h.store.saveSnapshot(snapshot(grown: 1, plantName: "みどり"))
        h.vm.load()
        XCTAssertFalse(h.vm.canNamePlant)
        XCTAssertTrue(h.vm.canRenamePlant)

        // 空の名前は、名前が無いのと同じ
        try? h.store.saveSnapshot(snapshot(grown: 3, plantName: ""))
        h.vm.load()
        XCTAssertTrue(h.vm.canNamePlant)
        XCTAssertNil(h.vm.plantName)
    }

    func testNoNamingEntryPointsWithoutANamingService() {
        let h = makeHarness(snapshot(grown: 3, plantName: nil), withNaming: false)
        defer { h.temp.cleanup() }
        h.vm.load()
        XCTAssertNil(h.vm.plantNaming)
        XCTAssertFalse(h.vm.canNamePlant)
        h.vm.presentPlantNameSheet() // 何も起きない(落ちない)
    }

    func testPresentNameSheetPicksTheModeFromTheCurrentName() {
        let h = makeHarness(snapshot(grown: 3, plantName: nil))
        defer { h.temp.cleanup() }
        h.vm.load()
        h.vm.presentPlantNameSheet()
        XCTAssertEqual(h.vm.plantNaming?.mode, .first)
        XCTAssertEqual(h.vm.plantNaming?.draft, "")
        XCTAssertEqual(h.vm.plantNaming?.isSheetPresented, true)

        h.vm.plantNaming?.isSheetPresented = false
        try? h.store.saveSnapshot(snapshot(grown: 3, plantName: "みどり"))
        h.vm.load()
        h.vm.presentPlantNameSheet()
        XCTAssertEqual(h.vm.plantNaming?.mode, .rename)
        XCTAssertEqual(h.vm.plantNaming?.draft, "みどり", "変えるときは、今の名前から")
    }

    // MARK: 名前の結果の反映

    func testSavingANameUpdatesTheSnapshotOnlyByNameAndNeverAnnouncesItToMyself() async {
        let h = makeHarness(snapshot(grown: 3, meDone: true, plantName: nil))
        defer { h.temp.cleanup() }
        h.vm.load()
        XCTAssertTrue(h.vm.canNamePlant)
        h.vm.presentPlantNameSheet()
        h.vm.plantNaming?.draft = "みどり"

        let saved = await h.vm.plantNaming?.submit()

        XCTAssertEqual(saved, true)
        XCTAssertEqual(h.naming.calls.count, 1)
        XCTAssertEqual(h.naming.calls.first?.mode, .first)
        XCTAssertEqual(h.vm.plantName, "みどり", "ホームに名前が出る")
        XCTAssertEqual(h.vm.snapshot?.plantName, "みどり")
        XCTAssertEqual(h.vm.snapshot?.todayMeDone, true, "ほかの値(楽観更新の今日の状態)は触らない")
        XCTAssertEqual(h.store.loadSnapshot()?.plantName, "みどり", "端末の snapshot(ウィジェットと共有)にも反映")
        XCTAssertEqual(h.reloads.value, 1, "ウィジェットを更新する")
        XCTAssertNil(h.vm.plantExperience.nameNotice, "自分が付けた名前は、自分に『かわったよ』を出さない")
        XCTAssertFalse(h.vm.canNamePlant)
        XCTAssertTrue(h.vm.canRenamePlant)

        h.vm.load() // 次に開いたときも出ない
        XCTAssertNil(h.vm.plantExperience.nameNotice)
    }

    func testRenameKeepsTheSameFlowAndSendsRenameMode() async {
        let h = makeHarness(snapshot(grown: 3, plantName: "みどり"))
        defer { h.temp.cleanup() }
        h.vm.load()
        h.vm.presentPlantNameSheet()
        h.vm.plantNaming?.draft = "あおば"
        h.naming.result = .saved(name: "あおば")

        _ = await h.vm.plantNaming?.submit()

        XCTAssertEqual(h.naming.calls.first?.mode, .rename)
        XCTAssertEqual(h.vm.plantName, "あおば")
        XCTAssertNil(h.vm.plantExperience.nameNotice)
    }

    func testWhenThePartnerNamedItFirstTheirNameIsAdoptedAndAnnounced() async {
        // first を送ったら 409: 相手が先に付けていた。その名前に決まる
        let h = makeHarness(snapshot(grown: 3, plantName: nil))
        defer { h.temp.cleanup() }
        h.vm.load()
        h.vm.presentPlantNameSheet()
        h.vm.plantNaming?.draft = "みどり"
        h.naming.result = .adopted(name: "きいろ")

        _ = await h.vm.plantNaming?.submit()

        XCTAssertEqual(h.vm.plantName, "きいろ", "先に付けた人の名前に決まる")
        XCTAssertEqual(h.store.loadSnapshot()?.plantName, "きいろ")
        XCTAssertEqual(h.vm.plantExperience.nameNotice, "名前は『きいろ』になったよ")
        XCTAssertEqual(h.vm.plantNaming?.resultNote, "名前は『きいろ』になったよ")
    }

    func testPartnerRenameShowsANoticeOnTheNextLoad() {
        let h = makeHarness(
            snapshot(grown: 3, plantName: "みどり"),
            memory: PlantMemory(initialized: true, celebratedStage: ["pair-A": 2], seenName: ["pair-A": "みどり"])
        )
        defer { h.temp.cleanup() }
        h.vm.load()
        XCTAssertNil(h.vm.plantExperience.nameNotice)

        try? h.store.saveSnapshot(snapshot(grown: 3, plantName: "あおば")) // 相手が変えた(サイレント push の snapshot)
        h.vm.load()
        XCTAssertEqual(h.vm.plantExperience.nameNotice, "名前が『あおば』にかわったよ")
    }

    func testApplyPlantNameWithoutASnapshotDoesNothing() {
        let h = makeHarness(nil)
        defer { h.temp.cleanup() }
        h.vm.load()
        h.vm.applyPlantName(.saved(name: "みどり"))
        XCTAssertNil(h.vm.snapshot)
        XCTAssertEqual(h.reloads.value, 0)
    }

    // MARK: おかえり

    func testWelcomeBackAppearsOnTheCheckinAfterAGapOfTwoOrMoreDays() async {
        let h = makeHarness(snapshot(grown: 3, meDone: false))
        defer { h.temp.cleanup() }
        h.vm.load()
        await h.vm.performCheckin() // 初めて: 出さない(今日を覚える)
        XCTAssertNil(h.vm.plantExperience.presentation)

        // 3日後(間の日が2日): 新しい日の朝は、自分は未完
        h.clock.advance(days: 3)
        try? h.store.saveSnapshot(snapshot(grown: 3, meDone: false))
        h.vm.load()
        await h.vm.performCheckin()

        XCTAssertEqual(h.vm.plantExperience.presentation, .welcomeBack)

        // 翌日(毎日続けている側): 出さない
        h.vm.plantExperience.dismissPresentation()
        h.clock.advance(days: 1)
        try? h.store.saveSnapshot(snapshot(grown: 3, meDone: false))
        h.vm.load()
        await h.vm.performCheckin()
        XCTAssertNil(h.vm.plantExperience.presentation)
    }

    // MARK: ハートを送る(段階アップの演出のボタン)

    func testSendingAHeartReportsSuccessAndFailure() async {
        let h = makeHarness(snapshot(grown: 7, meDone: true, partnerDone: true))
        defer { h.temp.cleanup() }
        h.vm.load()
        XCTAssertTrue(h.vm.canReact, "相手が今日チェックイン済み")

        let sent = await h.vm.sendReaction(stamp: .heart)
        XCTAssertTrue(sent)
        XCTAssertEqual(h.service.reactions, [.heart], "T15 のリアクション ❤️ を使い回す")

        struct Offline: Error {}
        h.service.reactionError = Offline()
        let failed = await h.vm.sendReaction(stamp: .heart)
        XCTAssertFalse(failed)
        XCTAssertEqual(h.vm.reactionErrorMessage, Strings.Reaction.errorMessage)
    }

    func testSendingAHeartIsRefusedWhenThePartnerHasNotCheckedIn() async {
        let h = makeHarness(snapshot(grown: 7, meDone: true, partnerDone: false))
        defer { h.temp.cleanup() }
        h.vm.load()
        XCTAssertFalse(h.vm.canReact)
        let sent = await h.vm.sendReaction(stamp: .heart)
        XCTAssertFalse(sent)
        XCTAssertTrue(h.service.reactions.isEmpty)
    }

    // MARK: 今日のひとこと

    func testWhisperShowsOnTheFirstAppearanceOfTheDayAndNeverForSolo() {
        let h = makeHarness(
            snapshot(grown: 3),
            memory: PlantMemory(initialized: true, celebratedStage: ["pair-A": 2])
        )
        defer { h.temp.cleanup() }
        h.vm.load()
        XCTAssertNil(h.vm.plantExperience.whisper)

        h.vm.plantExperience.homeDidAppear()

        let line = h.vm.plantExperience.whisper
        XCTAssertNotNil(line)
        XCTAssertEqual(PunishmentFreeLint.violations(in: line ?? ""), [], "ひとことも罰なし文言")

        let solo = makeHarness(snapshot(grown: 0, pairId: nil))
        defer { solo.temp.cleanup() }
        solo.vm.load()
        solo.vm.plantExperience.homeDidAppear()
        XCTAssertNil(solo.vm.plantExperience.whisper)
    }
}
