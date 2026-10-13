// AppModelAccountTests.swift — アカウント・ペアの操作と端末の後始末(AppModel / issue #23)
//
// 検証対象(AppModel.swift の AccountOperating):
//   - ペアの解消: サーバーがソロの形の snapshot を返し、端末の snapshot・ウィジェット・phase を即座にソロへ。失敗では何も変えない
//   - アカウントの削除 / サインアウト / セッション無効のあと: サインアウトし、端末の記録(snapshot・未送信キュー・
//     相手の写真のサムネ)を消し、ウィジェットを更新し、オンボーディングへ戻る。push の登録は適切に外す
//   - 削除はサーバーの成功を待ち、401 などを成功とみなさない(アカウントが残るのに端末だけ消さない)
//   - 走っている同期が、消したあとに古い snapshot を書き戻さない
//   - セッション無効(401 / user_not_found の連続)の確認

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

        var store: AppGroupStore { temp.store }
    }

    private func makeHarness(
        signedIn: Bool = true,
        local: PairSnapshot? = SnapshotFactory.paired(),
        server: Result<PairSnapshot, Error> = .success(SnapshotFactory.paired()),
        withAccountClient: Bool = true
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
            accountClient: withAccountClient ? account : nil
        )
        // 相手の写真のサムネ(NSE が置く)も端末に残っている状況
        try Data("jpeg".utf8).write(to: temp.store.photoThumbFileURL)
        return Harness(
            model: AppModel(services: services),
            auth: auth,
            sync: sync,
            account: account,
            registrar: registrar,
            temp: temp,
            reloads: reloads,
            queue: queue
        )
    }

    private func assertLocalDataIsErased(_ h: Harness, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertNil(h.store.loadSnapshot(), "snapshot が消えている", file: file, line: line)
        XCTAssertTrue(h.queue.isEmpty, "未送信のチェックインのキューが消えている", file: file, line: line)
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

    // MARK: アカウントの削除

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
