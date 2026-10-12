// NudgeReactTests.swift — つつく/リアクションのホーム導線(T15 / REQUIREMENTS §3.7, §3.8)
//
// 検証対象:
//   - canNudge: ペア成立+相手未完のときだけ true(能力検出含む — checkinService が
//     NudgeSending に適合しない場合は常に false)
//   - canReact: ペア成立+相手が今日完了済みのときだけ true(Reacting 適合も同様)
//   - sendNudge/sendReaction: 成功で *SentNote、失敗で *ErrorMessage(責めない文言 — §3.5)。
//     429(NudgeSendError.limitReached)は専用文言
//   - LocalEchoCheckinService は NudgeSending / Reacting の両方に適合する(モック注入 — T15)
//
// 実 Supabase Functions nudge/react への実 HTTP 呼び出しの検証は、CheckinService 本結線と合わせて
// 行う後続の統合タスクの責務(本テストはモック注入のホーム導線のみを対象とする)

import XCTest
@testable import Lien

// MARK: - モック

/// NudgeSending/Reacting の両方に適合する最小モック(呼び出し記録+エラー注入可能)。
/// トップレベルに置き、テストクラスの @MainActor 隔離を継承させない(CheckinPerforming と同じ理由)
private final class MockNudgeReactService: CheckinPerforming, NudgeSending, Reacting {
    private(set) var nudgeCalls: [NudgeStamp] = []
    private(set) var reactionCalls: [ReactionStamp] = []
    var nudgeError: Error?
    var reactionError: Error?

    func performCheckin(current: PairSnapshot) async throws -> PairSnapshot {
        var updated = current
        updated.todayMeDone = true
        return updated
    }

    func sendNudge(stamp: NudgeStamp) async throws {
        nudgeCalls.append(stamp)
        if let nudgeError { throw nudgeError }
    }

    func sendReaction(stamp: ReactionStamp) async throws {
        reactionCalls.append(stamp)
        if let reactionError { throw reactionError }
    }
}

/// NudgeSending/Reacting のどちらにも適合しない CheckinPerforming(能力検出 = false の確認用)
private final class PlainCheckinService: CheckinPerforming {
    func performCheckin(current: PairSnapshot) async throws -> PairSnapshot {
        current
    }
}

private struct AnyError: Error {}

// MARK: - テスト本体

@MainActor
final class NudgeReactTests: XCTestCase {
    private func makeTempStore() -> (store: AppGroupStore, tempDir: URL) {
        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("NudgeReactTests-\(UUID().uuidString)", isDirectory: true)
        return (AppGroupStore(containerURL: tempDir), tempDir)
    }

    private func makeSnapshot(
        pairId: String? = "pair-1",
        todayMeDone: Bool = false,
        todayPartnerDone: Bool = false
    ) -> PairSnapshot {
        PairSnapshot(
            schemaVersion: PairSnapshot.currentSchemaVersion,
            pairId: pairId,
            updatedAt: Date(timeIntervalSince1970: 1_781_166_600),
            streakCurrent: 23,
            streakBest: 40,
            todayMeDone: todayMeDone,
            todayPartnerDone: todayPartnerDone,
            myPromiseTitle: "筋トレ",
            myPromiseEmoji: "💪",
            partnerName: "ゆうき",
            partnerPromiseTitle: "ランニング",
            partnerPromiseEmoji: "🏃",
            plantStage: 3,
            plantMood: .normal,
            plantName: "みどり",
            hasPartnerPhotoToday: false
        )
    }

    // MARK: canNudge / canReact(能力検出+表示条件)

    func testCanNudgeTrueOnlyWhenPairedAndPartnerUndone() {
        let (store, tempDir) = makeTempStore()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        try? store.saveSnapshot(makeSnapshot(todayPartnerDone: false))
        let vm = HomeViewModel(store: store, checkinService: MockNudgeReactService(), reloadWidgets: {})
        vm.load()

        XCTAssertTrue(vm.canNudge, "ペア成立+相手未完 → つつける(§3.7)")
        XCTAssertFalse(vm.canReact, "相手が未完のときはリアクションできない(§3.8)")
    }

    func testCanNudgeFalseWhenPartnerAlreadyDone() {
        let (store, tempDir) = makeTempStore()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        try? store.saveSnapshot(makeSnapshot(todayPartnerDone: true))
        let vm = HomeViewModel(store: store, checkinService: MockNudgeReactService(), reloadWidgets: {})
        vm.load()

        XCTAssertFalse(vm.canNudge, "相手が完了済みのときはつつけない(§3.7)")
        XCTAssertTrue(vm.canReact, "相手が完了済み → リアクションできる(§3.8)")
    }

    func testCanNudgeAndCanReactFalseWhenSolo() {
        let (store, tempDir) = makeTempStore()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        try? store.saveSnapshot(makeSnapshot(pairId: nil, todayPartnerDone: false))
        let vm = HomeViewModel(store: store, checkinService: MockNudgeReactService(), reloadWidgets: {})
        vm.load()

        XCTAssertFalse(vm.canNudge, "ソロ状態には相手がいない")
        XCTAssertFalse(vm.canReact, "ソロ状態には相手がいない")
    }

    func testCanNudgeAndCanReactFalseWhenServiceDoesNotConform() {
        // 能力検出: checkinService が NudgeSending / Reacting に適合しない場合は常に false
        let (store, tempDir) = makeTempStore()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        try? store.saveSnapshot(makeSnapshot(todayPartnerDone: true))
        let vm = HomeViewModel(store: store, checkinService: PlainCheckinService(), reloadWidgets: {})
        vm.load()

        XCTAssertFalse(vm.canNudge)
        XCTAssertFalse(vm.canReact)
    }

    func testCanNudgeFalseWithoutSnapshot() {
        let vm = HomeViewModel(store: nil, checkinService: MockNudgeReactService(), reloadWidgets: {})
        vm.load()
        XCTAssertFalse(vm.canNudge)
        XCTAssertFalse(vm.canReact)
    }

    // MARK: sendNudge

    func testSendNudgeSuccessShowsSentNoteAndDoesNotMutateSnapshot() async {
        let (store, tempDir) = makeTempStore()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        try? store.saveSnapshot(makeSnapshot(todayPartnerDone: false))
        let service = MockNudgeReactService()
        let vm = HomeViewModel(store: store, checkinService: service, reloadWidgets: {})
        vm.load()

        await vm.sendNudge(stamp: .wave)

        XCTAssertEqual(service.nudgeCalls, [.wave])
        XCTAssertEqual(vm.nudgeSentNote, Strings.Nudge.sentNote)
        XCTAssertNil(vm.nudgeErrorMessage)
        XCTAssertFalse(vm.isSendingNudge)
        // つつきは自分の todayMeDone/todayPartnerDone を変えない(通知のみの操作 — §3.7)
        XCTAssertEqual(vm.snapshot?.todayPartnerDone, false)
    }

    func testSendNudgeWhenNotAllowedIsNoOp() async {
        let (store, tempDir) = makeTempStore()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        try? store.saveSnapshot(makeSnapshot(todayPartnerDone: true)) // canNudge == false
        let service = MockNudgeReactService()
        let vm = HomeViewModel(store: store, checkinService: service, reloadWidgets: {})
        vm.load()

        await vm.sendNudge(stamp: .wave)

        XCTAssertTrue(service.nudgeCalls.isEmpty, "canNudge が false のときはサービスを呼ばない")
    }

    func testSendNudgeLimitReachedShowsDedicatedMessage() async {
        let (store, tempDir) = makeTempStore()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        try? store.saveSnapshot(makeSnapshot(todayPartnerDone: false))
        let service = MockNudgeReactService()
        service.nudgeError = NudgeSendError.limitReached
        let vm = HomeViewModel(store: store, checkinService: service, reloadWidgets: {})
        vm.load()

        await vm.sendNudge(stamp: .pray)

        XCTAssertEqual(
            vm.nudgeErrorMessage,
            Strings.Nudge.limitReachedMessage,
            "1日3回の上限超過は専用の責めない文言(§3.5 / §3.7)"
        )
        XCTAssertNil(vm.nudgeSentNote)
    }

    func testSendNudgeGenericFailureShowsGentleMessageAndAllowsRetry() async {
        let (store, tempDir) = makeTempStore()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        try? store.saveSnapshot(makeSnapshot(todayPartnerDone: false))
        let service = MockNudgeReactService()
        service.nudgeError = AnyError()
        let vm = HomeViewModel(store: store, checkinService: service, reloadWidgets: {})
        vm.load()

        await vm.sendNudge(stamp: .sparkle)
        XCTAssertEqual(vm.nudgeErrorMessage, Strings.Nudge.errorMessage)
        XCTAssertTrue(vm.canNudge, "失敗後もリトライできる(§3.5)")

        service.nudgeError = nil
        await vm.sendNudge(stamp: .sparkle)
        XCTAssertNil(vm.nudgeErrorMessage)
        XCTAssertEqual(vm.nudgeSentNote, Strings.Nudge.sentNote)
        XCTAssertEqual(service.nudgeCalls, [.sparkle, .sparkle])
    }

    // MARK: sendReaction

    func testSendReactionSuccessShowsSentNote() async {
        let (store, tempDir) = makeTempStore()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        try? store.saveSnapshot(makeSnapshot(todayPartnerDone: true))
        let service = MockNudgeReactService()
        let vm = HomeViewModel(store: store, checkinService: service, reloadWidgets: {})
        vm.load()

        await vm.sendReaction(stamp: .heart)

        XCTAssertEqual(service.reactionCalls, [.heart])
        XCTAssertEqual(vm.reactionSentNote, Strings.Reaction.sentNote)
        XCTAssertNil(vm.reactionErrorMessage)
        XCTAssertFalse(vm.isSendingReaction)
    }

    func testSendReactionWhenNotAllowedIsNoOp() async {
        let (store, tempDir) = makeTempStore()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        try? store.saveSnapshot(makeSnapshot(todayPartnerDone: false)) // canReact == false
        let service = MockNudgeReactService()
        let vm = HomeViewModel(store: store, checkinService: service, reloadWidgets: {})
        vm.load()

        await vm.sendReaction(stamp: .fire)

        XCTAssertTrue(service.reactionCalls.isEmpty)
    }

    func testSendReactionFailureShowsGentleMessageAndAllowsRetry() async {
        let (store, tempDir) = makeTempStore()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        try? store.saveSnapshot(makeSnapshot(todayPartnerDone: true))
        let service = MockNudgeReactService()
        service.reactionError = AnyError()
        let vm = HomeViewModel(store: store, checkinService: service, reloadWidgets: {})
        vm.load()

        await vm.sendReaction(stamp: .muscle)
        XCTAssertEqual(vm.reactionErrorMessage, Strings.Reaction.errorMessage)
        XCTAssertTrue(vm.canReact, "失敗後もリトライできる(§3.5)")

        service.reactionError = nil
        await vm.sendReaction(stamp: .muscle)
        XCTAssertNil(vm.reactionErrorMessage)
        XCTAssertEqual(vm.reactionSentNote, Strings.Reaction.sentNote)
    }

    // MARK: LocalEchoCheckinService のモック適合(T15。ホーム結線の既定注入先)

    func testLocalEchoCheckinServiceConformsToNudgeSendingAndReacting() async throws {
        let echo = LocalEchoCheckinService()
        try await echo.sendNudge(stamp: .wave)
        try await echo.sendReaction(stamp: .heart)
        // モックは送信・永続化を行わず、例外を投げなければ十分(導線確認用 — issue #15 スコープ)
    }

    // MARK: スタンプ語彙(サーバー側 _shared/messages.ts と一致させる — §3.7, §3.8)

    func testNudgeStampVocabularyMatchesServer() {
        XCTAssertEqual(
            NudgeStamp.allCases.map(\.rawValue),
            ["👋", "⏰", "🙏", "📣", "😤", "✨"],
            "supabase/functions/_shared/messages.ts の NUDGE_STAMPS と語彙・順序を一致させる"
        )
    }

    func testReactionStampVocabularyMatchesServer() {
        XCTAssertEqual(
            ReactionStamp.allCases.map(\.rawValue),
            ["❤️", "🔥", "👏", "😂", "🥹", "💪"],
            "supabase/functions/_shared/messages.ts の REACTION_STAMPS と語彙・順序を一致させる"
        )
    }
}
