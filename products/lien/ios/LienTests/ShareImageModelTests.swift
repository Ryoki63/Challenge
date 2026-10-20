// ShareImageModelTests.swift — シェア画像の状態・内容・節目のお祝いの出し方(T22 / REQUIREMENTS §3.13)
//
// 画像の実描画は ShareImageRenderTests(CI の iOS)。ここは Foundation だけで動く部分を macOS の下見でも確かめる。

import Foundation
import XCTest
@testable import Lien

@MainActor
final class ShareImageModelTests: XCTestCase {
    private enum TestError: Error {
        case offline
    }

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        return calendar
    }

    /// 2026-10-20 12:00 JST
    private var now: Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: 20, hour: 12))!
    }

    private func makeDefaults() -> UserDefaults {
        let suite = "ShareImageModelTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    private func makeModel(
        nameLoader: ShareImageModel.NameLoader? = { "ゆうき" },
        memory: ShareMilestoneStoring = InMemoryShareMilestoneStore(ShareMilestoneMemory(initialized: true)),
        defaults: UserDefaults? = nil,
        nowProvider: (() -> Date)? = nil
    ) -> ShareImageModel {
        ShareImageModel(
            nameLoader: nameLoader,
            memoryStore: memory,
            now: nowProvider ?? { self.now },
            calendar: calendar,
            defaults: defaults ?? makeDefaults()
        )
    }

    private func snapshot(
        pairId: String? = "pair-A",
        streak: Int = 7,
        partnerName: String? = "あき",
        stage: Int = 4,
        hasPhoto: Bool = false
    ) -> PairSnapshot {
        PairSnapshot(
            schemaVersion: PairSnapshot.currentSchemaVersion,
            pairId: pairId,
            updatedAt: now,
            streakCurrent: streak,
            streakBest: max(streak, 40),
            todayMeDone: true,
            todayPartnerDone: true,
            myPromiseTitle: "筋トレ",
            myPromiseEmoji: "💪",
            partnerName: partnerName,
            partnerPromiseTitle: "まいにち散歩",
            partnerPromiseEmoji: "🚶",
            plantStage: stage,
            plantGrownDays: 10,
            plantStageFloor: 7,
            plantNextStageAt: 14,
            plantMood: .happy,
            plantName: "みどり",
            hasPartnerPhotoToday: hasPhoto
        )
    }

    // MARK: 導線

    func testManualShareNeedsAPairAndARecord() {
        let model = makeModel()

        model.snapshotDidChange(snapshot(pairId: nil, streak: 0))
        XCTAssertFalse(model.canShare)
        model.presentManual()
        XCTAssertNil(model.presentation)

        model.snapshotDidChange(snapshot(streak: 0))
        XCTAssertFalse(model.canShare)
        model.presentManual()
        XCTAssertNil(model.presentation)

        model.snapshotDidChange(snapshot(streak: 1))
        XCTAssertTrue(model.canShare)
        model.presentManual()
        XCTAssertEqual(model.presentation, .manual)
    }

    // MARK: 内容

    func testLoadBuildsTheContentFromTheSnapshot() async {
        let model = makeModel()
        model.snapshotDidChange(snapshot(streak: 20, stage: 6, hasPhoto: true))
        model.presentManual()

        await model.load()

        XCTAssertEqual(model.loadState, .ready)
        let content = model.content
        XCTAssertEqual(content?.myName, "ゆうき")
        XCTAssertEqual(content?.partnerName, "あき")
        XCTAssertEqual(content?.streakDays, 20)
        XCTAssertEqual(content?.plantStage, 6)
        XCTAssertEqual(content?.appName, "Lien")
        XCTAssertEqual(content?.startedOnText, "2026年10月1日", "開始日 = 今日 − (20 − 1)日")
    }

    func testTheContentDoesNotIncludeTheCheckinPhoto() async {
        let withPhoto = makeModel()
        withPhoto.snapshotDidChange(snapshot(streak: 30, hasPhoto: true))
        withPhoto.presentManual()
        await withPhoto.load()

        let withoutPhoto = makeModel()
        withoutPhoto.snapshotDidChange(snapshot(streak: 30, hasPhoto: false))
        withoutPhoto.presentManual()
        await withoutPhoto.load()

        XCTAssertNotNil(withPhoto.content)
        XCTAssertEqual(withPhoto.content, withoutPhoto.content, "写真の有無はシェア画像の内容に影響しない(§3.13)")
    }

    func testPartnerNameFallsBack() async {
        let model = makeModel()
        model.snapshotDidChange(snapshot(partnerName: nil))
        model.presentManual()

        await model.load()

        XCTAssertEqual(model.content?.partnerName, Strings.Share.partnerFallbackName)
    }

    func testStartedOnCrossesMonthsAndYears() {
        XCTAssertEqual(
            ShareImageContent.dateText(
                ShareImageContent.streakStartDate(streakDays: 30, now: now, calendar: calendar),
                calendar: calendar
            ),
            "2026年9月21日"
        )
        XCTAssertEqual(
            ShareImageContent.dateText(
                ShareImageContent.streakStartDate(streakDays: 365, now: now, calendar: calendar),
                calendar: calendar
            ),
            "2025年10月21日"
        )
    }

    // MARK: 自分のニックネーム

    func testTheNameIsCachedAndUsedWhenTheServerCannotBeRead() async {
        let defaults = makeDefaults()
        let online = makeModel(nameLoader: { "ゆうき" }, defaults: defaults)
        online.snapshotDidChange(snapshot())
        online.presentManual()
        await online.load()
        XCTAssertEqual(defaults.string(forKey: ShareImageModel.cachedNameKey), "ゆうき")

        let offline = makeModel(nameLoader: { throw TestError.offline }, defaults: defaults)
        offline.snapshotDidChange(snapshot())
        offline.presentManual()
        await offline.load()

        XCTAssertEqual(offline.loadState, .ready)
        XCTAssertEqual(offline.content?.myName, "ゆうき")
    }

    func testWithoutANameOrACacheTheLoadFails() async {
        let model = makeModel(nameLoader: { throw TestError.offline })
        model.snapshotDidChange(snapshot())
        model.presentManual()

        await model.load()

        XCTAssertEqual(model.loadState, .failed)
        XCTAssertNil(model.content)
    }

    func testAnEmptyNameIsAFailure() async {
        let model = makeModel(nameLoader: { "  " })
        model.snapshotDidChange(snapshot())
        model.presentManual()

        await model.load()

        XCTAssertEqual(model.loadState, .failed)
    }

    func testOldSnapshotCannotBeLoadedWhenThereIsNoRecord() async {
        let model = makeModel()
        model.snapshotDidChange(snapshot(pairId: nil, streak: 0))
        model.presentManual()

        await model.load()

        XCTAssertEqual(model.loadState, .unavailable)
        XCTAssertNil(model.content)
    }

    // MARK: 節目

    func testTheFirstObservationIsSilent() {
        let memory = InMemoryShareMilestoneStore()
        let model = makeModel(memory: memory)
        model.snapshotDidChange(snapshot(streak: 30))

        XCTAssertNil(model.presentation, "アップデート直後に、過去の 30日をさかのぼって祝わない")
        XCTAssertTrue(memory.load().initialized)
        XCTAssertEqual(memory.load().records["pair-A"]?.celebratedDays, 30)
    }

    func testReachingSevenDaysShowsTheCelebrationOnce() {
        let memory = InMemoryShareMilestoneStore(ShareMilestoneMemory(initialized: true))
        var currentNow = now
        let model = makeModel(memory: memory, nowProvider: { currentNow })
        model.snapshotDidChange(snapshot(streak: 6))
        XCTAssertNil(model.presentation)

        // 翌日: 6日目の1日目はそのまま(アンカーは動かない)
        currentNow = calendar.date(byAdding: .day, value: 1, to: now)!
        model.snapshotDidChange(snapshot(streak: 7))
        XCTAssertEqual(
            model.presentation,
            .milestone(
                ShareMilestone(
                    pairId: "pair-A",
                    days: 7,
                    streakStartDay: PlantDay.number(of: now, calendar: calendar) - 5
                )
            )
        )

        // 前面に出した時点で「見た」と記録する
        model.presentationDidAppear()
        XCTAssertEqual(memory.load().records["pair-A"]?.celebratedDays, 7)

        model.dismissPresentation()
        model.snapshotDidChange(snapshot(streak: 7))
        XCTAssertNil(model.presentation)
    }

    func testAManualSheetIsNotReplacedByAMilestone() {
        let memory = InMemoryShareMilestoneStore(ShareMilestoneMemory(initialized: true))
        let model = makeModel(memory: memory)
        model.snapshotDidChange(snapshot(streak: 1))
        model.presentManual()
        XCTAssertEqual(model.presentation, .manual)

        model.snapshotDidChange(snapshot(streak: 7))
        XCTAssertEqual(model.presentation, .manual, "開いているシートを勝手に差し替えない")

        // 閉じたあとの次の読み込みで、節目を出す(まだ「見た」と記録していない)
        model.dismissPresentation()
        model.snapshotDidChange(snapshot(streak: 7))
        XCTAssertEqual(model.presentation?.milestone?.days, 7)
    }

    func testAnUnreadableSnapshotKeepsTheMilestoneRecords() {
        let memory = InMemoryShareMilestoneStore(ShareMilestoneMemory(initialized: true))
        let model = makeModel(memory: memory)
        model.snapshotDidChange(snapshot(streak: 1))
        let before = memory.load()

        model.snapshotDidChange(nil)

        XCTAssertNil(model.presentation)
        XCTAssertEqual(memory.load(), before, "読めないだけの snapshot で、端末の記録を消さない")
    }

    func testAStreakResetToZeroIsRecordedForTheNextStreak() {
        let memory = InMemoryShareMilestoneStore(ShareMilestoneMemory(initialized: true))
        let model = makeModel(memory: memory)
        model.snapshotDidChange(snapshot(streak: 7))
        model.presentationDidAppear()
        XCTAssertEqual(memory.load().records["pair-A"]?.celebratedDays, 7)

        model.snapshotDidChange(snapshot(streak: 0))

        // 前面で見せたお祝いは、ユーザーが閉じるまで残す(記録は次のストリークのために戻す)
        XCTAssertNotNil(model.presentation)
        model.dismissPresentation()
        XCTAssertNil(model.presentation)
        XCTAssertEqual(memory.load().records["pair-A"]?.lastStreakDays, 0)
        XCTAssertEqual(memory.load().records["pair-A"]?.celebratedDays, 0, "次のストリークでは、また 7日を祝える")
    }

    func testSoloDismissesTheOpenShareSheet() {
        let model = makeModel()
        model.snapshotDidChange(snapshot(streak: 1))
        model.presentManual()
        XCTAssertNotNil(model.presentation)

        model.snapshotDidChange(snapshot(pairId: nil, streak: 0))
        XCTAssertNil(model.presentation, "ペアが解消されたら、旧ペアの名前を出したままにしない")
    }

    func testResetClearsTheCacheAndTheMilestones() async {
        let memory = InMemoryShareMilestoneStore(ShareMilestoneMemory(initialized: true))
        let defaults = makeDefaults()
        let model = makeModel(memory: memory, defaults: defaults)
        model.snapshotDidChange(snapshot(streak: 1))
        model.presentManual()
        await model.load()
        XCTAssertNotNil(model.content)

        model.reset()

        XCTAssertNil(model.presentation)
        XCTAssertNil(model.content)
        XCTAssertNil(defaults.string(forKey: ShareImageModel.cachedNameKey))
        XCTAssertTrue(memory.load().records.isEmpty)
        XCTAssertTrue(memory.load().initialized)
    }
}
