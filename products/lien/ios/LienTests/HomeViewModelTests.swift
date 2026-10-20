// HomeViewModelTests.swift — ホーム画面 VM の主要パス(T13。temp dir ストア+モックで CI 完結)
//
// 検証対象:
//   - 楽観更新が App Group snapshot に永続化される+ウィジェット reload が呼ばれる
//   - 完了済みは二重チェックイン不可(1日1回 — REQUIREMENTS §3.4)
//   - snapshot 無しの空状態 / ソロ状態(pairId=null)の表示分岐(§3.9 土の中で眠るタネの子)
//   - 植物の描画状態 plantState(snapshot → PlantCharacterState。導出の表は PlantLayersTests)
//   - 失敗時は責めない文言+リトライ可能(§3.5)
// 実 API(POST /checkin)・オフラインキューの検証は T14 のテストで行う。

import XCTest
@testable import Lien

// MARK: - モック
// トップレベルに置き、テストクラスの @MainActor 隔離を継承させない(CheckinPerforming は非隔離)

private final class MockCheckinService: CheckinPerforming {
    private(set) var callCount = 0
    /// 設定すると performCheckin が throw する
    var error: Error?

    func performCheckin(current: PairSnapshot) async throws -> PairSnapshot {
        callCount += 1
        if let error { throw error }
        var updated = current
        updated.todayMeDone = true
        return updated
    }
}

private struct AnyError: Error {}

// MARK: - テスト本体

@MainActor
final class HomeViewModelTests: XCTestCase {
    /// temp dir ストア(各テストで defer により削除 — PromiseSetupViewModelTests と同じイディオム)
    private func makeTempStore() -> (store: AppGroupStore, tempDir: URL) {
        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("HomeVMTests-\(UUID().uuidString)", isDirectory: true)
        return (AppGroupStore(containerURL: tempDir), tempDir)
    }

    private func makeSnapshot(
        pairId: String? = "pair-1",
        todayMeDone: Bool = false,
        todayPartnerDone: Bool = false,
        partnerName: String? = "ゆうき",
        plantStage: Int = 3,
        plantMood: PlantMood = .normal,
        ticketBalance: Int? = nil
    ) -> PairSnapshot {
        PairSnapshot(
            schemaVersion: PairSnapshot.currentSchemaVersion,
            pairId: pairId,
            updatedAt: Date(timeIntervalSince1970: 1_781_166_600), // 2026-06-11T08:30:00Z
            streakCurrent: 23,
            streakBest: 40,
            todayMeDone: todayMeDone,
            todayPartnerDone: todayPartnerDone,
            myPromiseTitle: "筋トレ",
            myPromiseEmoji: "💪",
            partnerName: partnerName,
            partnerPromiseTitle: "ランニング",
            partnerPromiseEmoji: "🏃",
            plantStage: plantStage,
            plantMood: plantMood,
            plantName: "みどり",
            hasPartnerPhotoToday: false,
            ticketBalance: ticketBalance
        )
    }

    /// VM+reload 回数カウンタを組み立てる
    private func makeViewModel(
        store: AppGroupStore?,
        service: MockCheckinService = MockCheckinService()
    ) -> (vm: HomeViewModel, service: MockCheckinService, reloadCount: () -> Int) {
        var count = 0
        let vm = HomeViewModel(
            store: store,
            checkinService: service,
            reloadWidgets: { count += 1 }
        )
        return (vm, service, { count })
    }

    // MARK: 空状態(snapshot 無し)

    func testLoadWithoutSnapshotShowsEmptyState() {
        let (store, tempDir) = makeTempStore()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let (vm, service, reloadCount) = makeViewModel(store: store)

        vm.load()

        XCTAssertNil(vm.snapshot)
        XCTAssertFalse(vm.canCheckin, "snapshot 無しではチェックインできない")
        XCTAssertFalse(vm.isSolo)
        XCTAssertFalse(vm.showsStreak)
        XCTAssertNil(vm.partnerWaitingText)
        XCTAssertEqual(vm.plantState, .solo, "未取得時は、土の中で眠るタネの子を出す")
        XCTAssertEqual(service.callCount, 0)
        XCTAssertEqual(reloadCount(), 0)
    }

    func testStoreNilIsTreatedAsEmptyState() async {
        // エンタイトルメント未解決(AppGroupStore.standard() == nil)でも落ちない
        let (vm, service, _) = makeViewModel(store: nil)
        vm.load()
        XCTAssertNil(vm.snapshot)
        await vm.performCheckin()
        XCTAssertEqual(service.callCount, 0)
    }

    // MARK: チェックイン(楽観更新の永続化+ウィジェット reload)

    func testCheckinPersistsOptimisticUpdateAndReloadsWidgets() async {
        let (store, tempDir) = makeTempStore()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        try? store.saveSnapshot(makeSnapshot(todayMeDone: false, todayPartnerDone: false))
        let (vm, service, reloadCount) = makeViewModel(store: store)
        vm.load()
        XCTAssertTrue(vm.canCheckin)

        await vm.performCheckin()

        XCTAssertEqual(service.callCount, 1)
        XCTAssertEqual(vm.snapshot?.todayMeDone, true, "画面へ楽観反映")
        XCTAssertNil(vm.checkinErrorMessage)
        XCTAssertEqual(reloadCount(), 1, "保存後にウィジェット reload(DESIGN §3.5)")

        // App Group へ永続化され、ほかのフィールドは保たれる
        let persisted = store.loadSnapshot()
        XCTAssertEqual(persisted?.todayMeDone, true)
        XCTAssertEqual(persisted?.streakCurrent, 23, "ストリークはローカルで触らない(確定はサーバー — DESIGN §5.4)")
        XCTAssertEqual(persisted?.partnerName, "ゆうき")
        XCTAssertEqual(persisted?.pairId, "pair-1")
    }

    func testCheckinIsBlockedWhenAlreadyDone() async {
        // 完了済み snapshot からは二重チェックインできない(1日1回 — §3.4)
        let (store, tempDir) = makeTempStore()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        try? store.saveSnapshot(makeSnapshot(todayMeDone: true))
        let (vm, service, reloadCount) = makeViewModel(store: store)
        vm.load()

        XCTAssertFalse(vm.canCheckin)
        await vm.performCheckin()
        XCTAssertEqual(service.callCount, 0, "完了済みではサービスを呼ばない")
        XCTAssertEqual(reloadCount(), 0)
    }

    func testSecondCheckinAfterSuccessIsNoOp() async {
        let (store, tempDir) = makeTempStore()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        try? store.saveSnapshot(makeSnapshot())
        let (vm, service, reloadCount) = makeViewModel(store: store)
        vm.load()

        await vm.performCheckin()
        await vm.performCheckin() // 2回目は canCheckin ガードで no-op

        XCTAssertEqual(service.callCount, 1)
        XCTAssertEqual(reloadCount(), 1)
    }

    // MARK: ソロ状態(pairId = null)の表示分岐

    func testSoloSnapshotShowsSoilAndHidesPairSections() {
        let (store, tempDir) = makeTempStore()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        // 防御確認のため stage/mood をあえて非ゼロにする(ソロは常に土の中で眠るタネの子 — §3.9)
        try? store.saveSnapshot(makeSnapshot(
            pairId: nil,
            todayPartnerDone: true,
            partnerName: nil,
            plantStage: 3,
            plantMood: .happy
        ))
        let (vm, _, _) = makeViewModel(store: store)
        vm.load()

        XCTAssertTrue(vm.isSolo)
        XCTAssertEqual(
            vm.plantState,
            PlantCharacterState(stage: 0, isSolo: true, soilGlow: false),
            "ソロ状態は、段階・表情によらず土の中で眠るタネの子(§3.9)"
        )
        XCTAssertFalse(vm.showsStreak, "ふたりストリークはペア成立後のみ")
        XCTAssertNil(vm.partnerWaitingText)
        XCTAssertFalse(vm.showsBothDoneCelebration)
        XCTAssertTrue(vm.canCheckin, "招待待ちでもチェックインは可能(§3.2)")
    }

    // MARK: チケット残数バッジ(§3.6 / T19a #19)

    func testTicketBalanceShowsThePairedBalance() {
        let (store, tempDir) = makeTempStore()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        try? store.saveSnapshot(makeSnapshot(ticketBalance: 2))
        let (vm, _, _) = makeViewModel(store: store)
        vm.load()

        XCTAssertEqual(vm.ticketBalance, 2, "ペアの残数をそのまま出す(受信者視点で反転しない)")
    }

    func testTicketBalanceShowsZeroInsteadOfHidingTheBadge() {
        let (store, tempDir) = makeTempStore()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        try? store.saveSnapshot(makeSnapshot(ticketBalance: 0))
        let (vm, _, _) = makeViewModel(store: store)
        vm.load()

        XCTAssertEqual(vm.ticketBalance, 0, "0枚でもバッジを出す(罰なし — REQUIREMENTS §3.5)")
        XCTAssertNotNil(vm.ticketBalance, "0 を nil(=バッジを出さない)にしない")
    }

    func testTicketBalanceIsHiddenWhenMissingSoloOrInvalid() {
        let (store, tempDir) = makeTempStore()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let (vm, _, _) = makeViewModel(store: store)

        // キーが無い古い snapshot
        try? store.saveSnapshot(makeSnapshot(ticketBalance: nil))
        vm.load()
        XCTAssertNil(vm.ticketBalance)

        // ソロ(ペア共有の在庫を持たない)。サーバーが誤って値を返しても出さない
        try? store.saveSnapshot(makeSnapshot(pairId: nil, ticketBalance: 2))
        vm.load()
        XCTAssertNil(vm.ticketBalance)

        // 契約は 0 以上。負の値は表示しない(誤った「-1枚」を出さない)
        try? store.saveSnapshot(makeSnapshot(ticketBalance: -1))
        vm.load()
        XCTAssertNil(vm.ticketBalance)
    }

    func testTicketBalanceIsHiddenWithoutASnapshot() {
        let (store, tempDir) = makeTempStore()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let (vm, _, _) = makeViewModel(store: store)
        vm.load()

        XCTAssertNil(vm.ticketBalance, "空状態ではバッジを出さない")
    }

    // MARK: 表示原則(§3.10)

    func testPartnerWaitingTextAndCelebration() async {
        let (store, tempDir) = makeTempStore()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        try? store.saveSnapshot(makeSnapshot(todayMeDone: false, todayPartnerDone: true))
        let (vm, _, _) = makeViewModel(store: store)
        vm.load()

        XCTAssertEqual(
            vm.partnerWaitingText,
            Strings.Home.partnerWaiting("ゆうき"),
            "相手が先に完了 →「(名前)が待ってるよ」(§3.10)"
        )
        XCTAssertFalse(vm.showsBothDoneCelebration)

        await vm.performCheckin()

        XCTAssertNil(vm.partnerWaitingText, "自分も完了したら待ってるよは消える")
        XCTAssertTrue(vm.showsBothDoneCelebration, "両者完了で「ふたり達成!」(§3.4)")
    }

    func testFidgetMoodTriggersSwayAnimation() {
        let (store, tempDir) = makeTempStore()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        // 片方だけ完了(相手だけ)= fidget。葉の開閉と視線は plantState、揺れは付け足し
        try? store.saveSnapshot(makeSnapshot(todayMeDone: false, todayPartnerDone: true, plantMood: .fidget))
        let (vm, _, _) = makeViewModel(store: store)
        vm.load()

        XCTAssertTrue(vm.plantSways, "fidget は小さな揺れ(REQUIREMENTS §3.9)")
        XCTAssertEqual(
            vm.plantState,
            PlantCharacterState(stage: 3, meOpen: false, partnerOpen: true, expression: .lookRight),
            "相手だけ完了 → 相手(右)の葉がひらき、顔はそちらを見る(GROWTH §4.1)"
        )
    }

    func testPlantStateFollowsTheCheckin() async {
        let (store, tempDir) = makeTempStore()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        try? store.saveSnapshot(makeSnapshot(todayMeDone: false, todayPartnerDone: false, plantMood: .normal))
        let (vm, _, _) = makeViewModel(store: store)
        vm.load()
        XCTAssertEqual(vm.plantState, PlantCharacterState(stage: 3), "朝: 葉は2枚ともたたんでいる")

        await vm.performCheckin()

        XCTAssertEqual(
            vm.plantState,
            PlantCharacterState(stage: 3, meOpen: true, partnerOpen: false, expression: .lookLeft),
            "自分がチェックインしたら、mood が古いままでも自分(左)の葉がすぐにひらく"
        )
    }

    // MARK: 失敗(責めない文言+リトライ可能 — §3.5)

    func testCheckinFailureShowsGentleMessageAndAllowsRetry() async {
        let (store, tempDir) = makeTempStore()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        try? store.saveSnapshot(makeSnapshot())
        let service = MockCheckinService()
        service.error = AnyError()
        let (vm, _, reloadCount) = makeViewModel(store: store, service: service)
        vm.load()

        await vm.performCheckin()

        XCTAssertEqual(vm.checkinErrorMessage, Strings.Home.checkinErrorMessage)
        XCTAssertEqual(vm.snapshot?.todayMeDone, false, "失敗時は楽観反映しない")
        XCTAssertEqual(store.loadSnapshot()?.todayMeDone, false, "失敗時は永続化もしない")
        XCTAssertEqual(reloadCount(), 0)
        XCTAssertTrue(vm.canCheckin, "失敗後もリトライできる")

        service.error = nil
        await vm.performCheckin()
        XCTAssertNil(vm.checkinErrorMessage)
        XCTAssertEqual(store.loadSnapshot()?.todayMeDone, true)
        XCTAssertEqual(reloadCount(), 1)
    }

    // MARK: LocalEchoCheckinService(T14 で実 API に差し替わるまでの場つなぎ)

    func testLocalEchoMarksMeDoneAndCelebratesWhenPartnerDone() async throws {
        let fixedNow = Date(timeIntervalSince1970: 1_781_200_000)
        let echo = LocalEchoCheckinService(now: { fixedNow })

        // 相手未完: mood はそのまま(表情の確定はサーバーに委ねる)
        let alone = try await echo.performCheckin(
            current: makeSnapshot(todayPartnerDone: false, plantMood: .fidget)
        )
        XCTAssertTrue(alone.todayMeDone)
        XCTAssertEqual(alone.plantMood, .fidget)
        XCTAssertEqual(alone.updatedAt, fixedNow)

        // 相手完了済み: 両者完了 → happy(ふたり達成 — §3.4)
        let both = try await echo.performCheckin(
            current: makeSnapshot(todayPartnerDone: true, plantMood: .normal)
        )
        XCTAssertTrue(both.todayMeDone)
        XCTAssertEqual(both.plantMood, .happy)
        XCTAssertEqual(both.streakCurrent, 23, "ストリークはローカルで触らない(DESIGN §5.4)")
    }
}
