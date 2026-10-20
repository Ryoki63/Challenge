// ShareMilestoneTests.swift — シェア画像の節目(7/30/100/365日)の判定と記録(T22 / REQUIREMENTS §3.13)
//
// 純粋なロジック(端末の日付の通し日数で扱う)だけを確かめる。画像の実描画は ShareImageRenderTests(CI の iOS)。

import XCTest
@testable import Lien

final class ShareMilestoneTests: XCTestCase {
    func testHighestMilestone() {
        XCTAssertNil(ShareMilestone.highest(atOrBelow: 0))
        XCTAssertNil(ShareMilestone.highest(atOrBelow: 6))
        XCTAssertEqual(ShareMilestone.highest(atOrBelow: 7), 7)
        XCTAssertEqual(ShareMilestone.highest(atOrBelow: 29), 7)
        XCTAssertEqual(ShareMilestone.highest(atOrBelow: 30), 30)
        XCTAssertEqual(ShareMilestone.highest(atOrBelow: 99), 30)
        XCTAssertEqual(ShareMilestone.highest(atOrBelow: 100), 100)
        XCTAssertEqual(ShareMilestone.highest(atOrBelow: 364), 100)
        XCTAssertEqual(ShareMilestone.highest(atOrBelow: 365), 365)
        XCTAssertEqual(ShareMilestone.highest(atOrBelow: 999), 365)
    }

    func testFirstObservationIsSilentAndSeedsTheCurrentMilestone() {
        var memory = ShareMilestoneMemory()

        // この版を初めて起動した既存の利用者(30日)。さかのぼって祝わない
        XCTAssertNil(memory.observe(pairId: "pair-A", streakDays: 30, streakStartDay: 100))
        XCTAssertTrue(memory.initialized)
        XCTAssertEqual(memory.records["pair-A"], ShareMilestoneRecord(streakStartDay: 100, celebratedDays: 30))

        // 同じストリークでは、もう 30日を祝わない
        XCTAssertNil(memory.observe(pairId: "pair-A", streakDays: 30, streakStartDay: 100))
        XCTAssertNil(memory.observe(pairId: "pair-A", streakDays: 31, streakStartDay: 100))
    }

    func testSevenDaysIsCelebratedOnceUntilItIsMarkedShown() {
        var memory = ShareMilestoneMemory()
        XCTAssertNil(memory.observe(pairId: "pair-A", streakDays: 6, streakStartDay: 100))

        let milestone = memory.observe(pairId: "pair-A", streakDays: 7, streakStartDay: 100)
        XCTAssertEqual(milestone, ShareMilestone(pairId: "pair-A", days: 7, streakStartDay: 100))

        // まだ「出した」と記録していないので、同じ観測ではまた返る(呼び出し側が二重に出さない)
        XCTAssertEqual(
            memory.observe(pairId: "pair-A", streakDays: 7, streakStartDay: 100),
            milestone
        )

        memory.markShown(milestone!)
        XCTAssertNil(memory.observe(pairId: "pair-A", streakDays: 7, streakStartDay: 100))
        XCTAssertNil(memory.observe(pairId: "pair-A", streakDays: 29, streakStartDay: 100))
    }

    func testJumpedMilestonesCelebrateOnlyTheHighest() {
        var memory = ShareMilestoneMemory()
        XCTAssertNil(memory.observe(pairId: "pair-A", streakDays: 6, streakStartDay: 100))

        // 何日かアプリを開かず、7日を飛ばして 30日
        let milestone = memory.observe(pairId: "pair-A", streakDays: 30, streakStartDay: 100)
        XCTAssertEqual(milestone?.days, 30)
        memory.markShown(milestone!)
        XCTAssertNil(memory.observe(pairId: "pair-A", streakDays: 30, streakStartDay: 100))

        // 100日
        let hundred = memory.observe(pairId: "pair-A", streakDays: 100, streakStartDay: 100)
        XCTAssertEqual(hundred?.days, 100)
    }

    func testANewStreakCelebratesAgain() {
        var memory = ShareMilestoneMemory()
        XCTAssertNil(memory.observe(pairId: "pair-A", streakDays: 6, streakStartDay: 100))
        let first = memory.observe(pairId: "pair-A", streakDays: 7, streakStartDay: 100)
        memory.markShown(first!)

        // 途切れて、新しいストリークの 7日目(1日目が 200 に変わった)
        let again = memory.observe(pairId: "pair-A", streakDays: 7, streakStartDay: 200)
        XCTAssertEqual(again, ShareMilestone(pairId: "pair-A", days: 7, streakStartDay: 200))
    }

    func testANewStreakAtTheSameDayCountIsCelebratedAgain() {
        var memory = ShareMilestoneMemory()
        XCTAssertNil(memory.observe(pairId: "pair-A", streakDays: 30, streakStartDay: 100))
        // 最初の観測で 30 は静かに記録済み。ストリークが変わって再び 30日
        let again = memory.observe(pairId: "pair-A", streakDays: 30, streakStartDay: 200)
        XCTAssertEqual(again, ShareMilestone(pairId: "pair-A", days: 30, streakStartDay: 200))
    }

    func testBelowSevenIsNotCelebrated() {
        var memory = ShareMilestoneMemory(initialized: true)
        XCTAssertNil(memory.observe(pairId: "pair-A", streakDays: 6, streakStartDay: 100))
        XCTAssertEqual(memory.records["pair-A"], ShareMilestoneRecord(streakStartDay: 100, celebratedDays: 0))
    }

    func testANewPairAfterInitializationIsCelebrated() {
        var memory = ShareMilestoneMemory(initialized: true)
        XCTAssertNil(memory.observe(pairId: "pair-A", streakDays: 3, streakStartDay: 100))

        // 新しいペアが 7日目(記録が無いペア)。この版の最初の観測ではないので祝う
        let milestone = memory.observe(pairId: "pair-B", streakDays: 7, streakStartDay: 300)
        XCTAssertEqual(milestone, ShareMilestone(pairId: "pair-B", days: 7, streakStartDay: 300))
    }

    func testOtherPairsAreForgotten() {
        var memory = ShareMilestoneMemory(initialized: true)
        _ = memory.observe(pairId: "pair-A", streakDays: 7, streakStartDay: 100)
        _ = memory.observe(pairId: "pair-B", streakDays: 7, streakStartDay: 200)
        XCTAssertEqual(Set(memory.records.keys), ["pair-B"])

        // ソロに戻った: 全部忘れる
        memory.forgetOtherPairs(keeping: nil)
        XCTAssertTrue(memory.records.isEmpty)
    }

    func testMarkShownIgnoresAnOldStreak() {
        var memory = ShareMilestoneMemory(initialized: true)
        let old = memory.observe(pairId: "pair-A", streakDays: 7, streakStartDay: 100)!
        _ = memory.observe(pairId: "pair-A", streakDays: 7, streakStartDay: 200) // 新しいストリーク
        memory.markShown(old) // 古いストリークの記録は進めない
        XCTAssertEqual(memory.records["pair-A"]?.streakStartDay, 200)
        XCTAssertEqual(memory.records["pair-A"]?.celebratedDays, 0)
    }

    func testCodableRoundTripAndMissingKeys() throws {
        var memory = ShareMilestoneMemory(initialized: true)
        _ = memory.observe(pairId: "pair-A", streakDays: 7, streakStartDay: 100)
        let data = try JSONEncoder().encode(memory)
        XCTAssertEqual(try JSONDecoder().decode(ShareMilestoneMemory.self, from: data), memory)

        // 古い記録(キーが無い)は初期値で読む
        let decoded = try JSONDecoder().decode(ShareMilestoneMemory.self, from: Data("{}".utf8))
        XCTAssertFalse(decoded.initialized)
        XCTAssertTrue(decoded.records.isEmpty)
    }

    func testResetKeepsInitialized() {
        let store = InMemoryShareMilestoneStore()
        var memory = ShareMilestoneMemory()
        _ = memory.observe(pairId: "pair-A", streakDays: 7, streakStartDay: 100)
        store.save(memory)
        store.reset()
        XCTAssertTrue(store.load().initialized)
        XCTAssertTrue(store.load().records.isEmpty)
    }
}
