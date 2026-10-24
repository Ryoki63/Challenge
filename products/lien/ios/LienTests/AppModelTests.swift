// AppModelTests.swift — ルート状態とサーバー同期の司令塔(AppModel — issue #55)
//
// 検証対象(AppModel.swift):
//   - 起動時の phase 導出(セッション+App Group snapshot)と、初回同期での解決(再インストール相当)
//   - 起動時・前面復帰時・push 受信時の同期で phase が更新される(solo ⇄ paired を含む)
//   - 同期は同時に1本だけ(走行中の要求は終了直後の1回に畳む)/ 前面復帰直後の二重取得は省く
//   - 端末の方が新しいとき(未送信キューあり)は巻き戻さない
//   - オンボ完了・約束保存・ペア成立・ディープリンクの扱い
//   - オンボ完了時の push_token 保存の促し
//   - オンボのまま起動したあとでセッションが読めるようになったとき(Keychain が最初のアンロック前だった)の
//     phase の導き直し。オンボ操作中にできたセッションは復元と取り違えない(issue #62)

import XCTest
@testable import Lien

// MARK: - モック(トップレベル)

private final class RecordingRegistrar: PushRegistrationUpdating {
    private(set) var calls: [(token: String, environment: PushEnvironment)] = []
    /// サーバーの users 行の代わり(送った内容がそのまま読み戻せる)
    private var server = ServerPushRegistration(token: nil, environment: nil)

    func updatePushRegistration(token: String, environment: PushEnvironment) async throws {
        calls.append((token, environment))
        server = ServerPushRegistration(token: token, environment: environment)
    }

    func fetchPushRegistration() async throws -> ServerPushRegistration {
        server
    }
}

private final class MockPushAuthorizer: PushAuthorizing {
    @discardableResult
    func requestAuthorization() async -> Bool { true }
}

/// 時刻を進められる時計
private final class TestClock {
    var now = Date(timeIntervalSince1970: 1_781_166_600)
    func advance(_ seconds: TimeInterval) { now = now.addingTimeInterval(seconds) }
}

@MainActor
final class AppModelTests: XCTestCase {
    /// テスト対象とその周辺(モック・temp ストア)
    private struct Harness {
        let model: AppModel
        let auth: StubAuthService
        let client: MockSnapshotClient
        let temp: TempStore
        let registrar: RecordingRegistrar
        let reloads: ReloadCounter
        let clock: TestClock

        var store: AppGroupStore { temp.store }
    }

    private func makeHarness(
        signedIn: Bool = true,
        local: PairSnapshot? = nil,
        server: Result<PairSnapshot, Error> = .success(SnapshotFactory.solo()),
        withPendingOps: Bool = false
    ) async throws -> Harness {
        let temp = TempStore()
        if let local { try temp.store.saveSnapshot(local) }
        let auth = StubAuthService()
        if signedIn { try await auth.signInAnonymously() }
        let client = MockSnapshotClient(result: server)
        let registrar = RecordingRegistrar()
        let reloads = ReloadCounter()
        let clock = TestClock()
        let queue = withPendingOps ? PendingOpsQueue(store: temp.store) : nil
        queue?.enqueue(.checkin(dateLocal: "2026-06-11", photoPath: nil))

        let services = AppServices(
            isLive: true,
            auth: auth,
            pushAuthorizer: MockPushAuthorizer(),
            inviteClient: StubInviteClient(),
            promiseClient: StubPromiseAPIClient(),
            snapshotClient: client,
            checkinService: LocalEchoCheckinService(),
            nudgeService: nil,
            reactionService: nil,
            pendingOps: queue,
            store: temp.store,
            pushTokenSync: PushTokenSync(
                registrar: registrar,
                currentUserID: { auth.currentUserID },
                environment: .sandbox,
                ledger: InMemoryPushRegistrationLedger()
            ),
            reloadWidgets: { reloads.value += 1 }
        )
        let model = AppModel(services: services, now: { clock.now })
        return Harness(
            model: model,
            auth: auth,
            client: client,
            temp: temp,
            registrar: registrar,
            reloads: reloads,
            clock: clock
        )
    }

    // MARK: 起動時の phase

    func testInitialPhaseWithoutSessionIsOnboarding() async throws {
        let h = try await makeHarness(signedIn: false, local: SnapshotFactory.paired())
        defer { h.temp.cleanup() }
        XCTAssertEqual(h.model.phase, .onboarding)
    }

    func testInitialPhaseIsDerivedFromStoredSnapshot() async throws {
        let h = try await makeHarness(local: SnapshotFactory.paired())
        defer { h.temp.cleanup() }
        XCTAssertEqual(h.model.phase, .paired)
        XCTAssertEqual(h.client.callCount, 0, "init ではネットワークを使わない")
    }

    func testStartWithoutSessionDoesNotSync() async throws {
        let h = try await makeHarness(signedIn: false)
        defer { h.temp.cleanup() }
        await h.model.start()
        XCTAssertEqual(h.client.callCount, 0, "セッションが無い間は同期しない(オンボ中)")
        XCTAssertEqual(h.model.phase, .onboarding)
    }

    func testStartRestoresSessionThatBecameReadableBetweenInitAndStart() async throws {
        // 保険(issue #62 の続き): init の時点ではセッションを読めずオンボーディングで立ち上がったが、RootView の .task が
        // start() を呼ぶまでの間に(最初のアンロックのあとで)読めるようになっていた。前面復帰・push を待たずに、既存ユーザーとして復帰する
        let h = try await makeHarness(
            signedIn: false,
            local: SnapshotFactory.solo(),
            server: .success(SnapshotFactory.paired())
        )
        defer { h.temp.cleanup() }
        XCTAssertEqual(h.model.phase, .onboarding)

        try await h.auth.signInAnonymously() // init のあと・start のまえに、Keychain が読めるようになった
        await h.model.start()

        XCTAssertEqual(h.model.phase, .paired, "オンボーディングに取り残さない")
        XCTAssertEqual(h.client.callCount, 1, "復帰して、すぐ同期する")
    }

    func testStartDuringOnboardingDoesNotMistakeTheNewSessionForARestoredOne() async throws {
        // ニックネーム送信で匿名サインインしたあと(オンボ操作中)に start() が来ても、通知の許可画面などを飛ばさない
        let h = try await makeHarness(signedIn: false, server: .success(SnapshotFactory.noPromise()))
        defer { h.temp.cleanup() }
        h.model.onboardingProfileSubmitStarted()
        try await h.auth.signInAnonymously()

        await h.model.start()

        XCTAssertEqual(h.model.phase, .onboarding)
        XCTAssertEqual(h.client.callCount, 0)
    }

    func testStartResolvesExistingAccountThroughSyncAfterReinstall() async throws {
        // 再インストール: Keychain のセッションは残るが App Group は空。サーバーには約束とペアがある
        let h = try await makeHarness(local: nil, server: .success(SnapshotFactory.paired()))
        defer { h.temp.cleanup() }
        XCTAssertEqual(h.model.phase, .promiseSetup, "同期前は snapshot が無い")

        await h.model.start()

        XCTAssertFalse(h.model.isResolving)
        XCTAssertEqual(h.model.phase, .paired, "約束設定を見せずに既存の約束・ペアへ復帰する")
        XCTAssertEqual(h.client.callCount, 1)
    }

    func testStartWithFailedFirstSyncFallsBackToPromiseSetup() async throws {
        let h = try await makeHarness(local: nil, server: .failure(SnapshotClientError.network))
        defer { h.temp.cleanup() }

        await h.model.start()

        XCTAssertFalse(h.model.isResolving, "失敗しても読み込み表示のまま止まらない")
        XCTAssertEqual(h.model.phase, .promiseSetup)
    }

    func testStartSyncFailureKeepsLocalPhase() async throws {
        let h = try await makeHarness(local: SnapshotFactory.paired(), server: .failure(SnapshotClientError.network))
        defer { h.temp.cleanup() }

        await h.model.start()

        XCTAssertEqual(h.model.phase, .paired, "オフラインでも端末の snapshot で表示を続ける")
        XCTAssertEqual(h.store.loadSnapshot(), SnapshotFactory.paired())
    }

    // MARK: オンボのまま起動したあとのセッション復元(issue #62)

    func testSceneActivationRestoresSessionThatBecameReadableAfterLaunch() async throws {
        // 再起動後の最初のアンロック前にバックグラウンド起動された: Keychain を読めず、セッション無し =
        // オンボで立ち上がった。App Group の snapshot(既存ユーザー)は残っている
        let h = try await makeHarness(
            signedIn: false,
            local: SnapshotFactory.solo(),
            server: .success(SnapshotFactory.paired())
        )
        defer { h.temp.cleanup() }
        await h.model.start()
        XCTAssertEqual(h.model.phase, .onboarding)
        XCTAssertEqual(h.client.callCount, 0)

        try await h.auth.signInAnonymously() // アンロック後、セッションが読めるようになった
        await h.model.sceneDidBecomeActive()

        XCTAssertEqual(h.model.phase, .paired, "オンボのままにせず、既存ユーザーとして復帰して同期する")
        XCTAssertEqual(h.client.callCount, 1)
    }

    func testSceneActivationRestoreWithoutLocalSnapshotWaitsForFirstSyncBeforePromiseSetup() async throws {
        let h = try await makeHarness(signedIn: false, local: nil, server: .success(SnapshotFactory.paired()))
        defer { h.temp.cleanup() }
        try await h.auth.signInAnonymously()
        h.client.holdsFirstFetch = true

        let model = h.model
        let activation = Task { await model.sceneDidBecomeActive() }
        await waitUntil { h.client.callCount == 1 }
        XCTAssertEqual(model.phase, .promiseSetup)
        XCTAssertTrue(model.isResolving, "初回同期の結果が出るまで、約束設定を見せずに読み込み表示にする")

        h.client.release()
        await activation.value

        XCTAssertFalse(model.isResolving)
        XCTAssertEqual(model.phase, .paired, "サーバーに既存の約束・ペアがあれば、約束設定を見せずにそこへ復帰する")
    }

    func testSceneActivationWithoutSessionStaysInOnboarding() async throws {
        let h = try await makeHarness(signedIn: false, local: SnapshotFactory.solo())
        defer { h.temp.cleanup() }

        await h.model.sceneDidBecomeActive()

        XCTAssertEqual(h.model.phase, .onboarding, "セッションがまだ読めないなら、オンボのまま")
        XCTAssertEqual(h.client.callCount, 0)
    }

    func testSceneActivationDuringOnboardingDoesNotMistakeNewSessionForRestoredOne() async throws {
        // ニックネーム送信で匿名サインインしたあと(通知の許可画面)に、別アプリから戻る / OS の許可ダイアログが閉じる:
        // その前面復帰で phase を進めてしまうと、通知の許可画面を飛ばしてしまう
        let h = try await makeHarness(signedIn: false, server: .success(SnapshotFactory.noPromise()))
        defer { h.temp.cleanup() }
        h.model.onboardingProfileSubmitStarted() // OnboardingViewModel.submitProfile の冒頭
        try await h.auth.signInAnonymously()

        await h.model.sceneDidBecomeActive()
        XCTAssertEqual(h.model.phase, .onboarding, "オンボ操作中は進めない")
        XCTAssertEqual(h.client.callCount, 0)

        await h.model.remoteNotificationReceived()
        XCTAssertEqual(h.model.phase, .onboarding)
        XCTAssertEqual(h.client.callCount, 0)

        await h.model.onboardingFinished() // オンボ完了で初めて先へ進む
        XCTAssertEqual(h.model.phase, .promiseSetup)
        XCTAssertEqual(h.client.callCount, 1)
    }

    func testRemoteNotificationRestoresSessionThatBecameReadableAfterLaunch() async throws {
        let h = try await makeHarness(
            signedIn: false,
            local: SnapshotFactory.solo(),
            server: .success(SnapshotFactory.paired())
        )
        defer { h.temp.cleanup() }
        try await h.auth.signInAnonymously()

        await h.model.remoteNotificationReceived()

        XCTAssertEqual(h.model.phase, .paired)
        XCTAssertEqual(h.client.callCount, 1)
    }

    func testRestoredSessionFlushesHeldPushRegistration() async throws {
        let h = try await makeHarness(signedIn: false, local: SnapshotFactory.solo())
        defer { h.temp.cleanup() }
        await h.model.services.pushTokenSync.receive(token: "aabbcc") // トークンは来たが、セッションが無くて保留
        XCTAssertEqual(h.registrar.calls.count, 0)

        try await h.auth.signInAnonymously()
        await h.model.sceneDidBecomeActive()
        await waitUntil { h.registrar.calls.count >= 1 }

        XCTAssertEqual(h.registrar.calls.count, 1, "セッションが戻ったら保留中の push_token / push_env を保存する")
    }

    // MARK: 同期による phase 更新

    func testSyncMovesSoloToPairedWhenPartnerAccepts() async throws {
        let h = try await makeHarness(local: SnapshotFactory.solo(), server: .success(SnapshotFactory.paired()))
        defer { h.temp.cleanup() }
        XCTAssertEqual(h.model.phase, .solo)

        await h.model.refresh()

        XCTAssertEqual(h.model.phase, .paired)
    }

    func testSyncMovesPairedToSoloWhenPairIsDissolved() async throws {
        let h = try await makeHarness(local: SnapshotFactory.paired(), server: .success(SnapshotFactory.solo()))
        defer { h.temp.cleanup() }

        await h.model.refresh()

        XCTAssertEqual(h.model.phase, .solo)
    }

    func testRefreshBumpsSnapshotRevisionSoHomeReloads() async throws {
        let h = try await makeHarness(local: SnapshotFactory.solo())
        defer { h.temp.cleanup() }
        let before = h.model.snapshotRevision
        await h.model.refresh()
        XCTAssertGreaterThan(h.model.snapshotRevision, before)
    }

    func testRemoteNotificationTriggersSync() async throws {
        let h = try await makeHarness(local: SnapshotFactory.solo(), server: .success(SnapshotFactory.paired()))
        defer { h.temp.cleanup() }

        await h.model.remoteNotificationReceived()

        XCTAssertEqual(h.client.callCount, 1)
        XCTAssertEqual(h.model.phase, .paired, "pair_update の push でペア成立が画面に反映される")
    }

    func testRemoteNotificationIsIgnoredBeforeOnboarding() async throws {
        let h = try await makeHarness(signedIn: false)
        defer { h.temp.cleanup() }
        await h.model.remoteNotificationReceived()
        XCTAssertEqual(h.client.callCount, 0)
    }

    func testPendingOpsKeepLocalOptimisticState() async throws {
        // オフラインで完了を記録した(未送信)。サーバーはまだ「未完」→ 巻き戻さない
        let local = SnapshotFactory.paired(todayMeDone: true)
        let h = try await makeHarness(
            local: local,
            server: .success(SnapshotFactory.paired(todayMeDone: false)),
            withPendingOps: true
        )
        defer { h.temp.cleanup() }

        await h.model.refresh()

        XCTAssertEqual(h.store.loadSnapshot(), local)
        XCTAssertEqual(h.model.phase, .paired)
    }

    // MARK: 同時実行・前面復帰の間引き

    func testConcurrentRefreshesCoalesceIntoOneExtraRun() async throws {
        let h = try await makeHarness(local: SnapshotFactory.solo())
        defer { h.temp.cleanup() }
        h.client.holdsFirstFetch = true // 最初の取得を関門で止め、「走行中」を決定的に作る

        let model = h.model
        let first = Task { await model.refresh() }
        await waitUntil { h.client.callCount == 1 } // first が取得の途中(走行中)になった
        XCTAssertFalse(model.rerunRequested)

        // 走行中に来た要求は、待たずに「あとで1回」と記録して即座に戻る
        let second = Task { await model.refresh() }
        let third = Task { await model.refresh() }
        await second.value
        await third.value
        XCTAssertTrue(model.rerunRequested)
        XCTAssertEqual(h.client.callCount, 1, "走行中は新しい取得を始めない")

        h.client.release()
        await first.value

        XCTAssertEqual(h.client.callCount, 2, "走行中の要求は終了直後の1回に畳む(3本同時でも 1 + 1)")
        XCTAssertFalse(model.rerunRequested)
    }

    func testSceneActivationRightAfterStartIsSkipped() async throws {
        let h = try await makeHarness(local: SnapshotFactory.solo())
        defer { h.temp.cleanup() }
        await h.model.start()
        XCTAssertEqual(h.client.callCount, 1)

        await h.model.sceneDidBecomeActive() // 起動直後の scenePhase 変化
        XCTAssertEqual(h.client.callCount, 1, "直近 2 秒以内の同期があれば省く")

        h.clock.advance(AppModel.minForegroundRefreshInterval + 1)
        await h.model.sceneDidBecomeActive()
        XCTAssertEqual(h.client.callCount, 2)
    }

    func testRemoteNotificationIsNotDebounced() async throws {
        let h = try await makeHarness(local: SnapshotFactory.solo())
        defer { h.temp.cleanup() }
        await h.model.start()
        await h.model.remoteNotificationReceived()
        XCTAssertEqual(h.client.callCount, 2, "push 起点の同期は間引かない")
    }

    // MARK: オンボ完了・約束保存・ペア成立

    func testOnboardingFinishedRoutesToPromiseSetupAfterFirstSync() async throws {
        let h = try await makeHarness(signedIn: false, server: .success(SnapshotFactory.noPromise()))
        defer { h.temp.cleanup() }
        XCTAssertEqual(h.model.phase, .onboarding)

        try await h.auth.signInAnonymously() // OnboardingViewModel.submitProfile 相当
        await h.model.onboardingFinished()

        XCTAssertEqual(h.model.phase, .promiseSetup)
        XCTAssertFalse(h.model.isResolving)
        XCTAssertEqual(h.client.callCount, 1)
        XCTAssertNotNil(h.store.loadSnapshot(), "初回同期でサーバーの(約束なし)snapshot が端末に入る")
    }

    func testOnboardingFinishedFlushesHeldPushRegistration() async throws {
        let h = try await makeHarness(signedIn: false, server: .success(SnapshotFactory.noPromise()))
        defer { h.temp.cleanup() }
        // 通知許可済みで未サインインの起動: トークンは先に届き、保留される
        await h.model.services.pushTokenSync.receive(token: "aabbcc")
        XCTAssertEqual(h.registrar.calls.count, 0)

        try await h.auth.signInAnonymously()
        await h.model.onboardingFinished()
        await waitUntil { h.registrar.calls.count >= 1 }

        XCTAssertEqual(h.registrar.calls.count, 1, "セッション確立で push_token / push_env を保存する")
        XCTAssertEqual(h.registrar.calls.first?.token, "aabbcc")
        XCTAssertEqual(h.registrar.calls.first?.environment, .sandbox)
    }

    func testStartFlushesPushRegistrationForRestoredSession() async throws {
        let h = try await makeHarness(local: SnapshotFactory.solo())
        defer { h.temp.cleanup() }
        await h.model.services.pushTokenSync.receive(token: "112233") // 起動時の登録コールバック
        await h.model.start()
        // 既にセッションがあるのでトークン受信時点で送られ、start() は二重送信しない
        await waitUntil { h.registrar.calls.count >= 1 }
        XCTAssertEqual(h.registrar.calls.count, 1)
    }

    func testPromiseSavedMovesToSolo() async throws {
        let h = try await makeHarness(local: SnapshotFactory.noPromise(), server: .success(SnapshotFactory.solo()))
        defer { h.temp.cleanup() }
        XCTAssertEqual(h.model.phase, .promiseSetup)

        // PromiseSetupViewModel が snapshot に約束を書き込んだ状態
        try h.store.saveSnapshot(SnapshotFactory.solo())
        h.model.promiseSaved()

        XCTAssertEqual(h.model.phase, .solo, "保存直後にホームへ")
        XCTAssertEqual(h.reloads.value, 1, "ウィジェットを約束入りの表示へ")
        await waitUntil { h.client.callCount >= 1 }
        XCTAssertEqual(h.client.callCount, 1, "保存後にサーバーの正と突き合わせる")
    }

    func testPairingSucceededMovesToPairedAndClosesSheet() async throws {
        let h = try await makeHarness(local: SnapshotFactory.solo(), server: .success(SnapshotFactory.paired()))
        defer { h.temp.cleanup() }
        h.model.pendingInviteToken = "AbCd2345"
        h.model.presentPairing()
        XCTAssertTrue(h.model.showsPairing)

        // PairingViewModel が受諾者視点の snapshot を保存した状態
        try h.store.saveSnapshot(SnapshotFactory.paired())
        h.model.pairingSucceeded()

        XCTAssertEqual(h.model.phase, .paired)
        XCTAssertNil(h.model.pendingInviteToken)
        XCTAssertFalse(h.model.showsPairing)
        XCTAssertEqual(h.reloads.value, 1, "ウィジェットをペア成立後の表示へ")
        await waitUntil { h.client.callCount >= 1 } // 成立後の突き合わせ同期(投げ捨てた Task)の完了待ち
    }

    func testHomeDeepLinkDismissesSettingsInSoloAndPaired() async throws {
        for snapshot in [SnapshotFactory.solo(), SnapshotFactory.paired()] {
            let harness = try await makeHarness(local: snapshot, server: .success(snapshot))
            defer { harness.temp.cleanup() }
            let phase = harness.model.phase
            harness.model.presentSettings()
            XCTAssertTrue(harness.model.showsSettings)

            harness.model.handleDeepLink(URL(string: "lien://home")!)
            await harness.model.sceneDidBecomeActive()

            XCTAssertEqual(harness.model.phase, phase)
            XCTAssertFalse(harness.model.showsSettings)
            XCTAssertFalse(harness.model.showsPairing)
            XCTAssertEqual(harness.store.loadSnapshot(), snapshot)
        }
    }

    func testHomeDeepLinkDismissesManuallyPresentedPairing() async throws {
        let harness = try await makeHarness(local: SnapshotFactory.solo())
        defer { harness.temp.cleanup() }
        harness.model.presentPairing()
        XCTAssertTrue(harness.model.showsPairing)

        await harness.model.sceneDidBecomeActive()
        harness.model.handleDeepLink(URL(string: "lien://home")!)

        XCTAssertEqual(harness.model.phase, .solo)
        XCTAssertFalse(harness.model.showsPairing)
        XCTAssertFalse(harness.model.showsSettings)
    }

    func testHomeDeepLinkClearsPendingInviteSoRefreshDoesNotReopenPairing() async throws {
        let harness = try await makeHarness(local: SnapshotFactory.solo())
        defer { harness.temp.cleanup() }
        harness.model.handleDeepLink(inviteURL("AbCd2345"))
        XCTAssertTrue(harness.model.showsPairing)

        harness.model.handleDeepLink(URL(string: "lien://home")!)
        await harness.model.refresh()

        XCTAssertNil(harness.model.pendingInviteToken)
        XCTAssertFalse(harness.model.showsPairing)
        XCTAssertEqual(harness.model.phase, .solo)

        harness.model.handleDeepLink(inviteURL("EfGh6789"))
        XCTAssertEqual(harness.model.pendingInviteToken, "EfGh6789")
        XCTAssertTrue(harness.model.showsPairing)
    }

    func testHomeDeepLinkBeforeStartupPreservesSoloAndPairedHomes() async throws {
        for snapshot in [SnapshotFactory.solo(), SnapshotFactory.paired()] {
            let harness = try await makeHarness(local: snapshot, server: .success(snapshot))
            defer { harness.temp.cleanup() }
            let phase = harness.model.phase

            harness.model.handleDeepLink(URL(string: "lien://home")!)
            await harness.model.start()

            XCTAssertEqual(harness.model.phase, phase)
            XCTAssertFalse(harness.model.showsSettings)
            XCTAssertFalse(harness.model.showsPairing)
        }
    }

    func testHomeDeepLinkDoesNotBypassOnboardingWithoutSession() async throws {
        let harness = try await makeHarness(signedIn: false, local: SnapshotFactory.paired())
        defer { harness.temp.cleanup() }
        harness.model.handleDeepLink(inviteURL("AbCd2345"))

        harness.model.handleDeepLink(URL(string: "lien://home")!)
        await harness.model.start()

        XCTAssertEqual(harness.model.phase, .onboarding)
        XCTAssertNil(harness.model.pendingInviteToken)
        XCTAssertFalse(harness.model.showsPairing)
        XCTAssertEqual(harness.client.callCount, 0)
    }

    func testHomeDeepLinkWithoutPromiseStaysInSetupAndDiscardsPendingInvite() async throws {
        let harness = try await makeHarness(
            local: SnapshotFactory.noPromise(), server: .success(SnapshotFactory.noPromise())
        )
        defer { harness.temp.cleanup() }
        harness.model.handleDeepLink(inviteURL("AbCd2345"))
        harness.model.presentSettings()

        harness.model.handleDeepLink(URL(string: "lien://home")!)
        await harness.model.start()

        XCTAssertEqual(harness.model.phase, .promiseSetup)
        XCTAssertNil(harness.model.pendingInviteToken)
        XCTAssertFalse(harness.model.showsSettings)
        XCTAssertFalse(harness.model.showsPairing)
    }

    func testOrdinaryForegroundActivationKeepsPresentedSheets() async throws {
        let settings = try await makeHarness(local: SnapshotFactory.paired(), server: .success(SnapshotFactory.paired()))
        defer { settings.temp.cleanup() }
        settings.model.presentSettings()
        await settings.model.sceneDidBecomeActive()
        XCTAssertTrue(settings.model.showsSettings)

        let pairing = try await makeHarness(local: SnapshotFactory.solo())
        defer { pairing.temp.cleanup() }
        pairing.model.presentPairing()
        await pairing.model.sceneDidBecomeActive()
        XCTAssertTrue(pairing.model.showsPairing)
    }

    func testUnrelatedURLsDoNotDismissSettingsOrPairing() async throws {
        let harness = try await makeHarness(local: SnapshotFactory.solo())
        defer { harness.temp.cleanup() }
        harness.model.handleDeepLink(inviteURL("AbCd2345"))
        harness.model.presentSettings()

        for rawURL in ["https://home", "other://home", "lien://homepage", "lien://home/extra", "lien://home?t=AbCd2345"] {
            harness.model.handleDeepLink(try XCTUnwrap(URL(string: rawURL)))
            XCTAssertTrue(harness.model.showsSettings, rawURL)
            XCTAssertTrue(harness.model.showsPairing, rawURL)
            XCTAssertEqual(harness.model.pendingInviteToken, "AbCd2345", rawURL)
        }
    }

    // MARK: ディープリンク(招待コード)

    private func inviteURL(_ token: String) -> URL {
        URL(string: "lien://invite/\(token)")!
    }

    func testDeepLinkInSoloOpensPairingWithToken() async throws {
        let h = try await makeHarness(local: SnapshotFactory.solo())
        defer { h.temp.cleanup() }

        h.model.handleDeepLink(inviteURL("AbCd2345"))

        XCTAssertEqual(h.model.pendingInviteToken, "AbCd2345")
        XCTAssertTrue(h.model.showsPairing, "ソロのホームでは招待画面を自動で開く")
    }

    func testDeepLinkBeforeHomeIsHeldAndOpensPairingWhenSoloArrives() async throws {
        let h = try await makeHarness(local: SnapshotFactory.noPromise())
        defer { h.temp.cleanup() }
        XCTAssertEqual(h.model.phase, .promiseSetup)

        h.model.handleDeepLink(inviteURL("AbCd2345"))
        XCTAssertEqual(h.model.pendingInviteToken, "AbCd2345", "約束設定中でもコードは保持する")
        XCTAssertFalse(h.model.showsPairing)

        try h.store.saveSnapshot(SnapshotFactory.solo())
        h.model.promiseSaved() // 約束保存 → ソロのホームへ
        XCTAssertEqual(h.model.phase, .solo)
        XCTAssertTrue(h.model.showsPairing, "ホームに着いたら招待画面を開く")
        await waitUntil { h.client.callCount >= 1 } // 保存後の突き合わせ同期(投げ捨てた Task)の完了待ち
    }

    func testDeepLinkIsIgnoredWhenPairedOrInvalid() async throws {
        let h = try await makeHarness(local: SnapshotFactory.paired())
        defer { h.temp.cleanup() }
        h.model.handleDeepLink(inviteURL("AbCd2345"))
        XCTAssertNil(h.model.pendingInviteToken, "ペア成立済みでは招待コードを使わない")
        XCTAssertFalse(h.model.showsPairing)

        let solo = try await makeHarness(local: SnapshotFactory.solo())
        defer { solo.temp.cleanup() }
        solo.model.handleDeepLink(URL(string: "lien://invite/short")!) // 形式不正
        solo.model.handleDeepLink(URL(string: "lien://other/AbCd2345")!) // 招待以外
        XCTAssertNil(solo.model.pendingInviteToken)
        XCTAssertFalse(solo.model.showsPairing)
    }

    func testPresentPairingIsOnlyForSolo() async throws {
        let paired = try await makeHarness(local: SnapshotFactory.paired())
        defer { paired.temp.cleanup() }
        paired.model.presentPairing()
        XCTAssertFalse(paired.model.showsPairing)

        let solo = try await makeHarness(local: SnapshotFactory.solo())
        defer { solo.temp.cleanup() }
        solo.model.presentPairing()
        XCTAssertTrue(solo.model.showsPairing, "ソロはいつでも招待画面を開ける(招待は任意)")
    }
}
