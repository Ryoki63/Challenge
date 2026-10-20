// AppModelAccountTests.swift — アカウント・ペアの操作と端末の後始末(AppModel / issue #23)
//
// 検証対象(AppModel.swift の AccountOperating):
//   - ペアの解消: サーバーがソロの形の snapshot を返し、端末の snapshot・ウィジェット・phase を即座にソロへ。失敗では何も変えない
//   - アカウントの削除 / サインアウト / セッション無効のあと: サインアウトし、端末の記録(snapshot・未送信キュー・
//     相手の写真のサムネ)を消し、ウィジェットを更新し、オンボーディングへ戻る。push の登録は適切に外す
//   - 削除はサーバーの成功を待ち、401 などを成功とみなさない(アカウントが残るのに端末だけ消さない)
//   - 走っている同期が、消したあとに古い snapshot を書き戻さない
//   - セッション無効(401 / user_not_found の連続)の確認 — 出す前に認証サーバーへ直接たしかめる(SessionVerifying)
//   - 認証 SDK がセッションを破棄したとき(アカウントがサーバーで消えたあと)の後始末
//   - 削除の応答だけ取りこぼしたとき(サーバーでは削除済み)の出口

import XCTest
@testable import Lien

// MARK: - モック(トップレベル)

private final class MockAccountClient: AccountAPIClient {
    var dissolveResult: Result<PairSnapshot, Error> = .success(SnapshotFactory.solo())
    var deleteError: Error?
    private(set) var dissolveCount = 0
    private(set) var deleteCount = 0

    func dissolvePair() async throws -> PairSnapshot {
        dissolveCount += 1
        return try dissolveResult.get()
    }

    func deleteAccount() async throws {
        deleteCount += 1
        if let deleteError { throw deleteError }
    }
}

private final class AccountRegistrar: PushRegistrationUpdating {
    private(set) var calls: [(token: String, environment: PushEnvironment)] = []
    private(set) var clearCount = 0
    var clearError: Error?
    private var server = ServerPushRegistration(token: nil, environment: nil)

    func updatePushRegistration(token: String, environment: PushEnvironment) async throws {
        calls.append((token, environment))
        server = ServerPushRegistration(token: token, environment: environment)
    }

    func fetchPushRegistration() async throws -> ServerPushRegistration { server }

    func clearPushRegistration() async throws {
        clearCount += 1
        if let clearError { throw clearError }
        server = ServerPushRegistration(token: nil, environment: nil)
    }
}

private final class AccountPushAuthorizer: PushAuthorizing {
    @discardableResult
    func requestAuthorization() async -> Bool { true }
}

private final class MockSessionVerifier: SessionVerifying {
    var verdict: SessionVerdict
    private(set) var calls = 0

    init(_ verdict: SessionVerdict) {
        self.verdict = verdict
    }

    func verify() async -> SessionVerdict {
        calls += 1
        return verdict
    }
}

private struct Offline: Error {}

@MainActor
final class AppModelAccountTests: XCTestCase {
    private struct Harness {
        let model: AppModel
        let auth: StubAuthService
        let sync: MockSnapshotClient
        let account: MockAccountClient
        let registrar: AccountRegistrar
        let temp: TempStore
        let reloads: ReloadCounter
        let queue: PendingOpsQueue
        let verifier: MockSessionVerifier?
        /// 植物の体験の「もう見せたか」の記録(PB #57)。段階アップの演出を見せた段階・最後のチェックイン日が入っている
        let plantMemory: InMemoryPlantMemoryStore

        var store: AppGroupStore { temp.store }
    }

    private func makeHarness(
        signedIn: Bool = true,
        local: PairSnapshot? = SnapshotFactory.paired(),
        server: Result<PairSnapshot, Error> = .success(SnapshotFactory.paired()),
        withAccountClient: Bool = true,
        verifier verdict: SessionVerdict? = nil,
        recheckInterval: TimeInterval = 0
    ) async throws -> Harness {
        let temp = TempStore()
        if let local { try temp.store.saveSnapshot(local) }
        let auth = StubAuthService()
        if signedIn { try await auth.signInAnonymously() }
        let sync = MockSnapshotClient(result: server)
        let account = MockAccountClient()
        let registrar = AccountRegistrar()
        let reloads = ReloadCounter()
        let queue = PendingOpsQueue(store: temp.store)
        queue.enqueue(.checkin(dateLocal: "2026-06-11", photoPath: nil))
        let verifier = verdict.map { MockSessionVerifier($0) }
        let plantMemory = InMemoryPlantMemoryStore(PlantMemory(
            initialized: true,
            celebratedStage: ["1f0c5a4e-9d3b-4c1a-8f2e-7b6d5a4c3b2a": 5],
            seenName: ["1f0c5a4e-9d3b-4c1a-8f2e-7b6d5a4c3b2a": "みどり"],
            lastCheckinDay: 700,
            lastWhisperDay: 701
        ))

        let services = AppServices(
            isLive: true,
            auth: auth,
            pushAuthorizer: AccountPushAuthorizer(),
            inviteClient: StubInviteClient(),
            promiseClient: StubPromiseAPIClient(),
            snapshotClient: sync,
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
            reloadWidgets: { reloads.value += 1 },
            accountClient: withAccountClient ? account : nil,
            sessionVerifier: verifier,
            plantMemory: plantMemory
        )
        // 相手の写真のサムネ(NSE が置く)も端末に残っている状況
        try Data("jpeg".utf8).write(to: temp.store.photoThumbFileURL)
        return Harness(
            // セッションが消えたときの読み直しは、既定では待たずに回す(間隔 0)
            model: AppModel(services: services, sessionRecheck: (count: 3, interval: recheckInterval)),
            auth: auth,
            sync: sync,
            account: account,
            registrar: registrar,
            temp: temp,
            reloads: reloads,
            queue: queue,
            verifier: verifier,
            plantMemory: plantMemory
        )
    }

    private func assertLocalDataIsErased(_ h: Harness, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertNil(h.store.loadSnapshot(), "snapshot が消えている", file: file, line: line)
        XCTAssertTrue(h.queue.isEmpty, "未送信のチェックインのキューが消えている", file: file, line: line)
        // 植物の体験の記録も、前のアカウントのものを持ち越さない(次のアカウントの最初のペアは「はじめまして」を祝い、
        // おかえりも前のアカウントの最後のチェックイン日から数えない)。「版の最初の観測を済ませた」だけは残る
        XCTAssertEqual(h.plantMemory.load(), PlantMemory(initialized: true), "植物の体験の記録が消えている", file: file, line: line)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: h.store.photoThumbFileURL.path),
            "相手の写真のサムネが消えている",
            file: file,
            line: line
        )
    }

    // MARK: ペアの解消(= ブロック)

    func testDissolvePairMovesTheDeviceToSoloImmediately() async throws {
        let h = try await makeHarness(local: SnapshotFactory.paired(todayMeDone: true))
        defer { h.temp.cleanup() }
        let solo = SnapshotFactory.paired(todayMeDone: true).dissolved(updatedAt: SnapshotFactory.fixedDate)
        h.account.dissolveResult = .success(solo)
        XCTAssertEqual(h.model.phase, .paired)
        let revision = h.model.snapshotRevision
        let reloadsBefore = h.reloads.value

        try await h.model.dissolvePair()
        await waitUntil { h.sync.callCount >= 1 } // 解消のあとの突き合わせ(未送信キューがあるので上書きしない)が終わるまで待つ

        XCTAssertEqual(h.account.dissolveCount, 1)
        XCTAssertEqual(h.store.loadSnapshot(), solo, "サーバーが返したソロの形を端末に書く")
        XCTAssertEqual(h.model.phase, .solo, "paired → solo")
        XCTAssertGreaterThan(h.model.snapshotRevision, revision, "ホームに読み直しを促す(相手の写真の表示も消える)")
        XCTAssertGreaterThan(h.reloads.value, reloadsBefore, "ウィジェットも更新する")
        XCTAssertNotNil(h.auth.currentUserID, "解消してもセッションは残る(アカウントは消えない)")
    }

    func testDissolveFailureChangesNothing() async throws {
        let h = try await makeHarness(local: SnapshotFactory.paired())
        defer { h.temp.cleanup() }
        h.account.dissolveResult = .failure(AccountClientError.network)
        let before = h.store.loadSnapshot()
        let reloadsBefore = h.reloads.value

        do {
            try await h.model.dissolvePair()
            XCTFail("失敗するはず")
        } catch {
            XCTAssertEqual(error as? AccountClientError, .network)
        }

        XCTAssertEqual(h.store.loadSnapshot(), before)
        XCTAssertEqual(h.model.phase, .paired)
        XCTAssertEqual(h.reloads.value, reloadsBefore)
    }

    func testDissolveIsIdempotentWhenThereIsAlreadyNoPair() async throws {
        // サーバーは 200 { dissolved: false, snapshot: ソロ } を返す。端末が古くて paired のままでも、ソロに追いつく
        let h = try await makeHarness(local: SnapshotFactory.paired())
        defer { h.temp.cleanup() }
        h.account.dissolveResult = .success(SnapshotFactory.solo())

        try await h.model.dissolvePair()
        await waitUntil { h.sync.callCount >= 1 }
        XCTAssertEqual(h.model.phase, .solo)
    }

    func testDissolveWithoutAnAccountClientFails() async throws {
        let h = try await makeHarness(withAccountClient: false)
        defer { h.temp.cleanup() }
        do {
            try await h.model.dissolvePair()
            XCTFail()
        } catch {
            XCTAssertEqual(error as? AccountClientError, .unavailable)
        }
        XCTAssertEqual(h.model.phase, .paired)
    }

    func testDissolveKeepsTheOptimisticDoneStateWhileCheckinsAreStillQueued() async throws {
        // 端末は「今日は完了」(楽観)で、未送信のチェックインがキューに残っている。サーバーのソロの snapshot は「未完」
        let h = try await makeHarness(
            local: SnapshotFactory.paired(todayMeDone: true),
            server: .success(SnapshotFactory.solo(todayMeDone: false))
        )
        defer { h.temp.cleanup() }
        h.account.dissolveResult = .success(SnapshotFactory.solo(todayMeDone: false))
        XCTAssertFalse(h.queue.isEmpty)

        try await h.model.dissolvePair()
        await waitUntil { h.sync.callCount >= 1 }

        let saved = try XCTUnwrap(h.store.loadSnapshot())
        XCTAssertNil(saved.pairId, "ソロにはなる")
        XCTAssertTrue(saved.todayMeDone, "未送信のチェックインの楽観の状態を、解消で巻き戻さない")
    }

    func testDissolveTakesTheServersDoneStateWhenNothingIsQueued() async throws {
        let h = try await makeHarness(
            local: SnapshotFactory.paired(todayMeDone: true),
            server: .success(SnapshotFactory.solo(todayMeDone: false))
        )
        defer { h.temp.cleanup() }
        h.queue.replaceAll([]) // 送り終わっている
        h.account.dissolveResult = .success(SnapshotFactory.solo(todayMeDone: false))

        try await h.model.dissolvePair()
        await waitUntil { h.sync.callCount >= 1 }

        XCTAssertEqual(h.store.loadSnapshot()?.todayMeDone, false, "キューが空ならサーバーの値が正")
    }

    // MARK: アカウントの削除

    func testDeleteAccountDoesNotReportSuccessWhenLocalCleanupFails() async throws {
        let harness = try await makeHarness()
        defer { harness.temp.cleanup() }
        try FileManager.default.removeItem(at: harness.temp.directory)
        try Data("unavailable".utf8).write(to: harness.temp.directory)

        do {
            try await harness.model.deleteAccount()
            XCTFail("後始末の失敗を削除完了として返さない")
        } catch {
            XCTAssertEqual((error as? CocoaError)?.code, .fileWriteUnknown)
        }
        XCTAssertNotNil(harness.auth.currentUserID)
        XCTAssertEqual(harness.account.deleteCount, 1)

        try FileManager.default.removeItem(at: harness.temp.directory)
        await harness.model.remoteNotificationReceived()
        XCTAssertNil(harness.auth.currentUserID)
        assertLocalDataIsErased(harness)
        XCTAssertEqual(harness.account.deleteCount, 1, "後始末だけを再試行する")
    }

    func testDeleteAccountErasesTheDeviceAndReturnsToOnboarding() async throws {
        let h = try await makeHarness()
        defer { h.temp.cleanup() }
        h.model.showsSettings = true
        let reloadsBefore = h.reloads.value
        await h.model.services.pushTokenSync.receive(token: "aabbcc")

        try await h.model.deleteAccount()

        XCTAssertEqual(h.account.deleteCount, 1)
        XCTAssertNil(h.auth.currentUserID, "サインアウトしている")
        assertLocalDataIsErased(h)
        XCTAssertEqual(h.model.phase, .onboarding)
        XCTAssertFalse(h.model.showsSettings, "設定のシートも閉じる")
        XCTAssertFalse(h.model.showsPairing)
        XCTAssertNil(h.model.pendingInviteToken)
        XCTAssertGreaterThan(h.reloads.value, reloadsBefore, "ウィジェットを空の表示に更新する")
        XCTAssertEqual(h.registrar.clearCount, 0, "アカウントごと消えたので、push の登録を外す通信はしない")
    }

    func testDeleteAccountFailureKeepsEverything() async throws {
        let h = try await makeHarness()
        defer { h.temp.cleanup() }
        h.account.deleteError = AccountClientError.server(code: "internal_error")
        let before = h.store.loadSnapshot()

        do {
            try await h.model.deleteAccount()
            XCTFail("失敗するはず")
        } catch {
            XCTAssertEqual(error as? AccountClientError, .server(code: "internal_error"))
        }

        XCTAssertNotNil(h.auth.currentUserID, "セッションは残る(やり直せる)")
        XCTAssertEqual(h.store.loadSnapshot(), before, "端末の記録も残る")
        XCTAssertFalse(h.queue.isEmpty)
        XCTAssertEqual(h.model.phase, .paired)

        // やり直し
        h.account.deleteError = nil
        try await h.model.deleteAccount()
        XCTAssertEqual(h.model.phase, .onboarding)
        assertLocalDataIsErased(h)
    }

    func testUnauthorizedDuringDeleteIsNotTreatedAsSuccess() async throws {
        // 401 は認証サーバーの一時的な不調でも出る。アカウントが残っているのに端末の記録だけ消すと、削除できないまま戻れなくなる
        let h = try await makeHarness()
        defer { h.temp.cleanup() }
        h.account.deleteError = AccountClientError.unauthorized

        do {
            try await h.model.deleteAccount()
            XCTFail()
        } catch {
            XCTAssertEqual(error as? AccountClientError, .unauthorized)
        }

        XCTAssertNotNil(h.auth.currentUserID)
        XCTAssertNotNil(h.store.loadSnapshot())
        XCTAssertEqual(h.model.phase, .paired)
    }

    func testDeleteWhoseResponseWasLostCompletesWhenTheAuthServerSaysTheUserIsGone() async throws {
        // 1 回目の削除はサーバーでは済んでいたが、応答だけ取りこぼした。やり直すと 401 になる。
        // 認証サーバーも「ユーザーが居ない」と確かに答えるので、削除は済んでいたものとして端末を片づける
        let h = try await makeHarness(verifier: .rejected)
        defer { h.temp.cleanup() }
        h.account.deleteError = AccountClientError.unauthorized

        try await h.model.deleteAccount()

        XCTAssertEqual(h.verifier?.calls, 1)
        XCTAssertEqual(h.account.deleteCount, 1)
        XCTAssertNil(h.auth.currentUserID)
        assertLocalDataIsErased(h)
        XCTAssertEqual(h.model.phase, .onboarding)
        XCTAssertEqual(h.registrar.clearCount, 0, "アカウントはもう無いので、push の登録を外す通信はしない")
    }

    func testUnauthorizedDeleteStillFailsWhenTheAuthServerAcceptsTheLogin() async throws {
        // 認証サーバーがこのログインを受け付けている = 401 は自分たちのサーバーの側の問題。アカウントは残っている
        let h = try await makeHarness(verifier: .valid)
        defer { h.temp.cleanup() }
        h.account.deleteError = AccountClientError.unauthorized

        do {
            try await h.model.deleteAccount()
            XCTFail("失敗するはず")
        } catch {
            XCTAssertEqual(error as? AccountClientError, .unauthorized)
        }

        XCTAssertEqual(h.verifier?.calls, 1)
        XCTAssertNotNil(h.auth.currentUserID)
        XCTAssertNotNil(h.store.loadSnapshot())
        XCTAssertEqual(h.model.phase, .paired)
    }

    func testUnauthorizedDeleteStillFailsWhenTheAuthServerCannotBeReached() async throws {
        let h = try await makeHarness(verifier: .unknown)
        defer { h.temp.cleanup() }
        h.account.deleteError = AccountClientError.unauthorized

        do {
            try await h.model.deleteAccount()
            XCTFail("失敗するはず")
        } catch {
            XCTAssertEqual(error as? AccountClientError, .unauthorized)
        }

        XCTAssertNotNil(h.auth.currentUserID, "たしかめられないときは、消さない")
        XCTAssertNotNil(h.store.loadSnapshot())
    }

    func testOtherDeleteFailuresDoNotAskTheAuthServer() async throws {
        let h = try await makeHarness(verifier: .rejected)
        defer { h.temp.cleanup() }

        for failure in [AccountClientError.network, .server(code: "internal_error")] {
            h.account.deleteError = failure
            do {
                try await h.model.deleteAccount()
                XCTFail("失敗するはず")
            } catch {
                XCTAssertEqual(error as? AccountClientError, failure)
            }
        }

        XCTAssertEqual(h.verifier?.calls, 0, "通信・サーバーの失敗は、削除済みの疑いではない")
        XCTAssertNotNil(h.auth.currentUserID)
    }

    func testFailedDeleteNudgesASyncSoTheDeviceFollowsTheServer() async throws {
        // 削除は途中まで進んでいる(現役のペアの解消は済んでいる)かもしれない。端末のペアの表示をサーバーに追いつかせる
        let h = try await makeHarness(
            local: SnapshotFactory.paired(),
            server: .success(SnapshotFactory.solo())
        )
        defer { h.temp.cleanup() }
        h.queue.replaceAll([]) // 送り終わっている(同期が上書きしてよい)
        h.account.deleteError = AccountClientError.server(code: "internal_error")
        XCTAssertEqual(h.model.phase, .paired)

        do {
            try await h.model.deleteAccount()
            XCTFail("失敗するはず")
        } catch {}
        await waitUntil { h.model.phase == .solo }

        XCTAssertEqual(h.model.phase, .solo, "ペアはサーバーで解消済み: 端末の表示もソロへ追いつく")
        XCTAssertNotNil(h.auth.currentUserID, "セッションは残る(やり直せる)")
    }

    // MARK: サインアウト

    func testSignOutStopsPushThenErasesTheDeviceAndReturnsToOnboarding() async throws {
        let h = try await makeHarness()
        defer { h.temp.cleanup() }
        await h.model.services.pushTokenSync.receive(token: "aabbcc")
        XCTAssertEqual(h.registrar.calls.count, 1, "サインアウトの前に、この端末の登録がある")

        await h.model.signOut()

        XCTAssertEqual(h.registrar.clearCount, 1, "サインアウトの前に、この端末への push を止める(users.push_token を null に)")
        XCTAssertNil(h.auth.currentUserID)
        assertLocalDataIsErased(h)
        XCTAssertEqual(h.model.phase, .onboarding)
        XCTAssertEqual(h.account.deleteCount, 0, "サインアウトはアカウントを消さない")
    }

    func testSignOutKeepsSessionUntilCoordinatedCleanupCanRetry() async throws {
        let harness = try await makeHarness()
        defer { harness.temp.cleanup() }
        try FileManager.default.removeItem(at: harness.temp.directory)
        try Data("unavailable".utf8).write(to: harness.temp.directory)

        await harness.model.signOut()
        XCTAssertNotNil(harness.auth.currentUserID)
        XCTAssertEqual(harness.model.phase, .paired)
        let fetchCount = harness.sync.callCount
        await harness.model.refresh()
        XCTAssertEqual(harness.sync.callCount, fetchCount)

        try FileManager.default.removeItem(at: harness.temp.directory)
        await harness.model.sceneDidBecomeActive()
        XCTAssertNil(harness.auth.currentUserID)
        XCTAssertEqual(harness.model.phase, .onboarding)
        assertLocalDataIsErased(harness)
    }

    func testNewModelResumesPersistedCleanupBeforeFetchingSnapshot() async throws {
        let harness = try await makeHarness()
        defer { harness.temp.cleanup() }
        try harness.store.beginSessionCleanup()
        let restarted = AppModel(services: harness.model.services)
        let fetchCount = harness.sync.callCount
        await restarted.refresh()
        XCTAssertEqual(harness.sync.callCount, fetchCount)
        await restarted.start()
        XCTAssertNil(harness.auth.currentUserID)
        XCTAssertNil(harness.store.loadSnapshot())
        XCTAssertFalse(harness.store.sessionCleanupIsPending())
        XCTAssertEqual(restarted.phase, .onboarding)
        XCTAssertEqual(harness.sync.callCount, fetchCount)
    }

    func testSignOutStillCompletesWhenStoppingPushFails() async throws {
        let h = try await makeHarness()
        defer { h.temp.cleanup() }
        h.registrar.clearError = Offline()
        await h.model.services.pushTokenSync.receive(token: "aabbcc")

        await h.model.signOut()

        XCTAssertEqual(h.registrar.clearCount, 1)
        XCTAssertNil(h.auth.currentUserID, "push の登録を外せなくても、サインアウトは止めない")
        XCTAssertEqual(h.model.phase, .onboarding)
        assertLocalDataIsErased(h)
    }

    func testSignOutClosesOpenModerationConfirmations() async throws {
        // ブロックの説明シートや通報の確認が開いたままサインアウトしても、次のアカウントのホームに持ち越さない
        let h = try await makeHarness()
        defer { h.temp.cleanup() }
        h.model.moderation.requestBlock()
        h.model.moderation.requestReport(.nickname("ゆうき"))

        await h.model.signOut()

        XCTAssertEqual(h.model.moderation.block.stage, .idle)
        XCTAssertNil(h.model.moderation.pendingReport)
    }

    func testNewAccountAfterSignOutRegistersTheSameDeviceTokenAgain() async throws {
        let h = try await makeHarness()
        defer { h.temp.cleanup() }
        await h.model.services.pushTokenSync.receive(token: "aabbcc")
        XCTAssertEqual(h.registrar.calls.count, 1)
        await h.model.signOut()

        // 同じ端末で、新しい匿名アカウントを作る
        try await h.auth.signInAnonymously()
        await h.model.services.pushTokenSync.sessionDidChange()

        XCTAssertEqual(h.registrar.calls.count, 2, "新しいアカウントに、同じデバイストークンを登録し直す")
        XCTAssertEqual(h.registrar.calls.last?.token, "aabbcc")
    }

    func testSyncWorksAgainForTheNextAccountAfterSignOut() async throws {
        let h = try await makeHarness()
        defer { h.temp.cleanup() }
        await h.model.signOut()
        XCTAssertEqual(h.model.phase, .onboarding)

        try await h.auth.signInAnonymously()
        h.sync.result = .success(SnapshotFactory.noPromise())
        await h.model.onboardingFinished()

        XCTAssertEqual(h.model.phase, .promiseSetup, "栓は開き直っている(次のアカウントの同期は書き込める)")
        XCTAssertNotNil(h.store.loadSnapshot())
    }

    func testSignOutIsIgnoredWhileAlreadyEnding() async throws {
        let h = try await makeHarness()
        defer { h.temp.cleanup() }
        async let first: Void = h.model.signOut()
        async let second: Void = h.model.signOut()
        _ = await (first, second)
        XCTAssertEqual(h.model.phase, .onboarding)
        XCTAssertEqual(h.registrar.clearCount, 1, "後始末は 1 回だけ(重なった呼び出しは無視する)")
    }

    // MARK: 走っている同期との競合

    func testInFlightSyncDoesNotWriteBackAfterTheDeviceWasErased() async throws {
        let h = try await makeHarness(local: SnapshotFactory.paired(), server: .success(SnapshotFactory.paired(todayMeDone: true)))
        defer { h.temp.cleanup() }
        h.sync.holdsFirstFetch = true
        let model = h.model

        let refreshing = Task { await model.refresh() }
        await waitUntil { h.sync.callCount == 1 } // 取得の応答待ち
        let signingOut = Task { await model.signOut() }
        try await Task.sleep(nanoseconds: 120_000_000) // サインアウトは、走っている同期の終了を待っている
        XCTAssertNotNil(h.auth.currentUserID)

        h.sync.release() // 古いアカウントの snapshot がここで届く
        await refreshing.value
        await signingOut.value

        XCTAssertNil(h.store.loadSnapshot(), "消したあとに、古いアカウントの snapshot を書き戻さない")
        XCTAssertEqual(h.model.phase, .onboarding)
        XCTAssertNil(h.auth.currentUserID)
    }

    // MARK: セッション無効(401 / user_not_found が続く)

    func testSessionLostPromptAppearsAfterThreeConsecutiveRejections() async throws {
        let h = try await makeHarness(server: .failure(SnapshotClientError.unauthorized))
        defer { h.temp.cleanup() }

        await h.model.refresh()
        await h.model.refresh()
        XCTAssertFalse(h.model.sessionLost, "2 回ではまだ出さない")
        await h.model.refresh()
        XCTAssertTrue(h.model.sessionLost, "3 回続いたら確認を出す")

        XCTAssertNotNil(h.auth.currentUserID, "確認を出すだけで、勝手には何も消さない")
        XCTAssertNotNil(h.store.loadSnapshot())
        XCTAssertEqual(h.model.phase, .paired)
    }

    func testUserNotFoundAlsoCounts() async throws {
        let h = try await makeHarness(server: .failure(SnapshotClientError.userNotFound))
        defer { h.temp.cleanup() }
        for _ in 0..<3 { await h.model.refresh() }
        XCTAssertTrue(h.model.sessionLost)
    }

    func testOneSuccessfulSyncOrNetworkFailureDoesNotTriggerThePrompt() async throws {
        let h = try await makeHarness(server: .failure(SnapshotClientError.unauthorized))
        defer { h.temp.cleanup() }
        await h.model.refresh()
        await h.model.refresh()

        h.sync.result = .success(SnapshotFactory.paired())
        await h.model.refresh() // サーバーが答えた: 数え直し
        h.sync.result = .failure(SnapshotClientError.unauthorized)
        await h.model.refresh()
        await h.model.refresh()
        XCTAssertFalse(h.model.sessionLost, "成功をはさんだので、まだ 2 回")

        h.sync.result = .failure(SnapshotClientError.network)
        for _ in 0..<5 { await h.model.refresh() }
        XCTAssertFalse(h.model.sessionLost, "通信の失敗は数えない")
    }

    func testLaterResetsTheCountAndRestartErasesEverything() async throws {
        let h = try await makeHarness(server: .failure(SnapshotClientError.unauthorized))
        defer { h.temp.cleanup() }
        for _ in 0..<3 { await h.model.refresh() }
        XCTAssertTrue(h.model.sessionLost)

        h.model.dismissSessionLostPrompt() // 「あとで」
        XCTAssertFalse(h.model.sessionLost)
        XCTAssertNotNil(h.auth.currentUserID, "何も消さない")
        await h.model.refresh()
        await h.model.refresh()
        XCTAssertFalse(h.model.sessionLost, "数え直しなので、すぐには出ない")
        await h.model.refresh()
        XCTAssertTrue(h.model.sessionLost, "また 3 回続いたら出る")

        await h.model.restartAfterSessionLost() // 「はじめからやり直す」
        XCTAssertFalse(h.model.sessionLost)
        XCTAssertNil(h.auth.currentUserID)
        assertLocalDataIsErased(h)
        XCTAssertEqual(h.model.phase, .onboarding)
        XCTAssertEqual(h.registrar.clearCount, 0, "サーバーに受け付けられないセッションで push の登録を外す通信はしない")
    }

    // 出す前に、認証サーバーへ直接たしかめる

    func testSessionLostPromptNeedsTheAuthServerToConfirmTheRejection() async throws {
        let h = try await makeHarness(server: .failure(SnapshotClientError.unauthorized), verifier: .rejected)
        defer { h.temp.cleanup() }

        await h.model.refresh()
        await h.model.refresh()
        XCTAssertEqual(h.verifier?.calls, 0, "3 回に届くまでは、たしかめない")
        XCTAssertFalse(h.model.sessionLost)
        await h.model.refresh()

        XCTAssertEqual(h.verifier?.calls, 1)
        XCTAssertTrue(h.model.sessionLost, "認証サーバーも「ユーザーが居ない」と答えたので、確認を出す")
        XCTAssertNotNil(h.auth.currentUserID, "確認を出すだけで、勝手には何も消さない")
    }

    func testNoPromptWhenTheAuthServerStillAcceptsTheLogin() async throws {
        // 自分たちのサーバーが 401 を返し続けても、認証サーバーが受け付けているなら、サーバーの側の問題(サービスキーの設定の誤りなど)
        let h = try await makeHarness(server: .failure(SnapshotClientError.unauthorized), verifier: .valid)
        defer { h.temp.cleanup() }

        for _ in 0..<3 { await h.model.refresh() }
        XCTAssertEqual(h.verifier?.calls, 1)
        XCTAssertFalse(h.model.sessionLost, "確認を出さない")

        // 数え直す: 次の 2 回では、まだたしかめない
        await h.model.refresh()
        await h.model.refresh()
        XCTAssertEqual(h.verifier?.calls, 1)
        await h.model.refresh()
        XCTAssertEqual(h.verifier?.calls, 2, "また 3 回続いたら、もう一度たしかめる")
        XCTAssertFalse(h.model.sessionLost)
    }

    func testInconclusiveVerificationKeepsSuspectingAndAsksAgainOnTheNextRejection() async throws {
        let h = try await makeHarness(server: .failure(SnapshotClientError.unauthorized), verifier: .unknown)
        defer { h.temp.cleanup() }

        for _ in 0..<3 { await h.model.refresh() }
        XCTAssertEqual(h.verifier?.calls, 1)
        XCTAssertFalse(h.model.sessionLost, "たしかめられないときは、確認を出さない")

        await h.model.refresh()
        XCTAssertEqual(h.verifier?.calls, 2, "拒否が続いているので、次の同期でまたたしかめる")
        XCTAssertFalse(h.model.sessionLost)

        h.verifier?.verdict = .rejected
        await h.model.refresh()
        XCTAssertTrue(h.model.sessionLost, "認証サーバーが確かに拒否したので、確認を出す")
    }

    // 認証 SDK がセッションを破棄したとき

    func testSessionDestroyedByTheSDKErasesTheDeviceAndReturnsToOnboarding() async throws {
        // アカウントがサーバーで消え、トークンの更新が拒否されると、SDK は端末のセッションを破棄する。
        // 古い snapshot を残したままオンボーディングへ落ちると、作り直した新しいアカウントの phase を古い記録が決めてしまう
        let h = try await makeHarness()
        defer { h.temp.cleanup() }
        XCTAssertEqual(h.model.phase, .paired)

        await h.auth.signOut() // SDK がセッションを消した(アプリは何もしていない)
        await h.model.refresh() // 次の同期のあと、phase を導き直すときに気づく
        await waitUntil { h.store.loadSnapshot() == nil }

        XCTAssertNil(h.auth.currentUserID)
        assertLocalDataIsErased(h)
        XCTAssertEqual(h.model.phase, .onboarding)
        XCTAssertEqual(h.registrar.clearCount, 0, "セッションはもう無いので、push の登録を外す通信はしない")
        XCTAssertEqual(h.account.deleteCount, 0)
        XCTAssertFalse(h.model.sessionLost, "確認は出さない(選べることがない)")
    }

    func testNewAccountAfterTheSDKDestroyedTheSessionDoesNotInheritTheOldSnapshot() async throws {
        let h = try await makeHarness(local: SnapshotFactory.paired())
        defer { h.temp.cleanup() }
        await h.auth.signOut()
        await h.model.refresh()
        await waitUntil { h.store.loadSnapshot() == nil }

        // 同じ端末で、新しい匿名アカウントを作る
        try await h.auth.signInAnonymously()
        h.sync.result = .success(SnapshotFactory.noPromise())
        await h.model.onboardingFinished()

        XCTAssertEqual(h.model.phase, .promiseSetup, "古いペアの記録が残っていれば、ここがホーム(.paired)になってしまう")
    }

    func testSessionThatComesBackBeforeTheRecheckIsNotErased() async throws {
        // Keychain の読み出しが一瞬失敗しただけ。少し待って読み直すと戻っているので、何も消さない
        let h = try await makeHarness(recheckInterval: 0.05)
        defer { h.temp.cleanup() }
        let signedInAs = try XCTUnwrap(h.auth.currentUserID)
        await h.auth.signOut()

        await h.model.refresh() // phase はいったんオンボーディングになる
        XCTAssertEqual(h.model.phase, .onboarding)
        _ = signedInAs
        try await h.auth.signInAnonymously() // 読めるようになった
        await waitUntil { h.model.phase != .onboarding }

        XCTAssertNotEqual(h.model.phase, .onboarding, "読み直しで戻る")
        XCTAssertNotNil(h.store.loadSnapshot(), "端末の記録は消さない")
        XCTAssertFalse(h.queue.isEmpty)
    }

    func testOnboardingFromTheStartIsNotTreatedAsALostSession() async throws {
        // 最初からセッションが無い(まだオンボーディング)なら、後始末は走らない
        let h = try await makeHarness(signedIn: false, local: SnapshotFactory.paired())
        defer { h.temp.cleanup() }
        XCTAssertEqual(h.model.phase, .onboarding)

        await h.model.sceneDidBecomeActive()
        try await Task.sleep(nanoseconds: 80_000_000)

        XCTAssertNotNil(h.store.loadSnapshot(), "オンボーディングで立ち上がっただけでは、記録を消さない")
    }

    // MARK: 設定画面を開く

    func testPresentSettingsOnTheHomeAndBeforeThePromiseButNotInOnboarding() async throws {
        let home = try await makeHarness()
        defer { home.temp.cleanup() }
        home.model.presentSettings()
        XCTAssertTrue(home.model.showsSettings)

        // 約束を決める前でも、サインアウト・アカウントの削除には入れる
        let beforePromise = try await makeHarness(local: SnapshotFactory.noPromise())
        defer { beforePromise.temp.cleanup() }
        XCTAssertEqual(beforePromise.model.phase, .promiseSetup)
        beforePromise.model.presentSettings()
        XCTAssertTrue(beforePromise.model.showsSettings)

        let onboarding = try await makeHarness(signedIn: false, local: nil)
        defer { onboarding.temp.cleanup() }
        onboarding.model.presentSettings()
        XCTAssertFalse(onboarding.model.showsSettings, "アカウントを作る前(オンボーディング)では開かない")
    }
}
