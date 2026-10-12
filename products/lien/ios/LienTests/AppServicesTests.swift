// AppServicesTests.swift — Live / Stub 構成の切替と、Stub 構成での通し(issue #55)
//
// 検証対象(AppServices.swift / Config.swift):
//   - Config(Supabase URL / anon key)が無い環境(CI・Secrets なし)では Stub 構成になる
//   - Stub 構成はネットワークを使わず、オンボ → 約束設定 → ソロのホーム(チェックイン)→ ペア成立 まで
//     実際の ViewModel と AppModel の組み合わせで通る
//   - 端末の App Group が使えないときの代替保存先
//   - Live 構成の組み立て(issue #62): 各スロットが Live の実装になっていて、未サインインのうちは通信せず、
//     チェックインのキューと未送信キュー(同期の巻き戻し判定)が同じものを指している

import XCTest
@testable import Lien

private final class GrantingPushAuthorizer: PushAuthorizing {
    @discardableResult
    func requestAuthorization() async -> Bool { true }
}

/// Supabase の接続情報だけを返す Bundle(AppServices.make を Live で組み立てさせる)
private final class ConfiguredBundle: Bundle, @unchecked Sendable {
    override func object(forInfoDictionaryKey key: String) -> Any? {
        switch key {
        case Config.supabaseURLInfoPlistKey: return "https://example.supabase.co"
        case Config.supabaseAnonKeyInfoPlistKey: return "anon-key"
        default: return nil
        }
    }
}

@MainActor
final class AppServicesTests: XCTestCase {
    // MARK: Config の有無 → Live / Stub

    func testConfigIsNilWhenSecretsAreMissing() {
        // テストバンドル(= CI と同じく Secrets.xcconfig 無し)の Info.plist には接続情報が入っていない
        // (入っている環境で実行された場合は Live 構成になるだけなので、ここでは「空文字なら nil」を直接確かめる)
        final class EmptyKeysBundle: Bundle, @unchecked Sendable {
            override func object(forInfoDictionaryKey key: String) -> Any? { "" }
        }
        XCTAssertNil(Config.load(bundle: EmptyKeysBundle()))
    }

    func testConfigLoadsWhenBothValuesAreSet() {
        final class FilledBundle: Bundle, @unchecked Sendable {
            override func object(forInfoDictionaryKey key: String) -> Any? {
                switch key {
                case Config.supabaseURLInfoPlistKey: return "https://example.supabase.co"
                case Config.supabaseAnonKeyInfoPlistKey: return "anon-key"
                default: return nil
                }
            }
        }
        let config = Config.load(bundle: FilledBundle())
        XCTAssertEqual(config?.supabaseURL.absoluteString, "https://example.supabase.co")
        XCTAssertEqual(config?.supabaseAnonKey, "anon-key")
    }

    func testStubServicesAreOffline() {
        let temp = TempStore()
        defer { temp.cleanup() }
        let services = AppServices.stub(store: temp.store, pushAuthorizer: GrantingPushAuthorizer())
        XCTAssertFalse(services.isLive)
        XCTAssertTrue(services.auth is StubAuthService)
        XCTAssertTrue(services.inviteClient is StubInviteClient)
        XCTAssertTrue(services.promiseClient is StubPromiseAPIClient)
        XCTAssertTrue(services.snapshotClient is StubSnapshotClient)
        XCTAssertTrue(services.checkinService is LocalEchoCheckinService)
        XCTAssertNil(services.pendingOps, "スタブ構成にオフラインキューは無い")
    }

    func testLocalFallbackStoreLivesInApplicationSupport() {
        // App Group が解決できないとき(署名なしビルドなど)の代替。実ファイルは触らず、置き場所だけ確かめる
        let store = AppGroupStore.localFallback()
        XCTAssertEqual(store.containerURL.lastPathComponent, "LienLocal")
        XCTAssertTrue(store.containerURL.path.contains("Application Support"))
    }

    // MARK: Live 構成の組み立て(ネットワークなし — issue #62)

    /// Live 構成を組み立てる。URLSession は記録用のスタブ(組み立てただけで通信が起きないことを確かめる)
    private func makeLiveServices(store: AppGroupStore) -> AppServices {
        StubURLProtocol.reset()
        return AppServices.live(
            config: Config(supabaseURL: URL(string: "https://example.supabase.co")!, supabaseAnonKey: "anon-key"),
            store: store,
            pushAuthorizer: GrantingPushAuthorizer(),
            session: StubURLProtocol.makeSession(),
            reloadWidgets: {}
        )
    }

    func testLiveServicesUseLiveImplementationsInEverySlot() {
        let temp = TempStore()
        defer { temp.cleanup() }
        let services = makeLiveServices(store: temp.store)
        defer { StubURLProtocol.reset() }

        XCTAssertTrue(services.isLive)
        XCTAssertTrue(services.auth is SupabaseService)
        XCTAssertTrue(services.inviteClient is EdgeFunctionInviteClient)
        XCTAssertTrue(services.promiseClient is EdgeFunctionPromiseClient)
        XCTAssertTrue(services.snapshotClient is EdgeFunctionSnapshotClient)
        XCTAssertTrue(services.checkinService is CheckinService)
        XCTAssertTrue(services.nudgeService is LiveNudgeReactService)
        XCTAssertTrue(services.reactionService is LiveNudgeReactService)
        XCTAssertNotNil(services.pendingOps)
        XCTAssertEqual(services.store?.containerURL, temp.store.containerURL)
        XCTAssertTrue(
            (services.nudgeService as AnyObject) === (services.reactionService as AnyObject),
            "つつくとリアクションは同じ Live サービスが担う"
        )
        XCTAssertEqual(StubURLProtocol.captured.count, 0, "組み立てただけでは通信しない")
    }

    func testLiveServicesDoNotTouchTheNetworkBeforeSignIn() async {
        let temp = TempStore()
        defer { temp.cleanup() }
        let services = makeLiveServices(store: temp.store)
        defer { StubURLProtocol.reset() }

        // 未サインインではユーザー JWT が取れない。どのクライアントも、リクエストを送らずに失敗する
        await assertFails("招待の発行") { _ = try await services.inviteClient.createInvite() }
        await assertFails("約束の保存") {
            _ = try await services.promiseClient.setPromise(title: "筋トレ", emoji: "💪", remindAt: nil)
        }
        await assertFails("snapshot の取得") { _ = try await services.snapshotClient.fetchSnapshot() }
        await assertFails("つつく") { try await services.nudgeService?.sendNudge(stamp: .wave) }
        XCTAssertEqual(StubURLProtocol.captured.count, 0, "トークンが無い間は Edge Function を呼ばない")
    }

    func testLiveCheckinQueueIsTheOneTheSynchronizerGuards() async throws {
        // チェックインを積むキューと、snapshot 同期が「端末の方が新しい」を判定するキューは同じもの。
        // 別物になると、未送信のチェックインがあるのに同期が楽観状態を巻き戻してしまう
        let temp = TempStore()
        defer { temp.cleanup() }
        let services = makeLiveServices(store: temp.store)
        defer { StubURLProtocol.reset() }
        let queue = try XCTUnwrap(services.pendingOps)
        XCTAssertTrue(queue.isEmpty)

        // 未サインイン(送信できない)でのチェックイン = オフラインと同じ: 楽観値を返し、キューに残す
        let result = try await services.checkinService.performCheckin(current: SnapshotFactory.solo())

        XCTAssertTrue(result.todayMeDone)
        XCTAssertEqual(queue.load().count, 1)
        XCTAssertEqual(
            PendingOpsQueue(store: temp.store).load(),
            queue.load(),
            "キューは AppServices.live に渡したストアの上にある"
        )
        XCTAssertEqual(StubURLProtocol.captured.count, 0)
    }

    func testAppModelOnLiveServicesStartsInOnboardingWithoutSession() async {
        let temp = TempStore()
        defer { temp.cleanup() }
        let services = makeLiveServices(store: temp.store)
        defer { StubURLProtocol.reset() }

        let model = AppModel(services: services)
        XCTAssertEqual(model.phase, .onboarding)
        await model.start()
        await model.sceneDidBecomeActive()

        XCTAssertEqual(model.phase, .onboarding, "セッションが無ければ、同期もせずオンボのまま")
        XCTAssertEqual(StubURLProtocol.captured.count, 0)
    }

    func testMakeBuildsLiveServicesWhenConfigIsPresent() {
        // 接続情報があれば、ポリシー(Release の致命 / Debug の Stub)に関係なく Live
        for policy in [Config.MissingPolicy.fallBackToStub, .fatal] {
            let services = AppServices.make(bundle: ConfiguredBundle(), whenConfigMissing: policy)
            XCTAssertTrue(services.isLive)
            XCTAssertTrue(services.auth is SupabaseService)
        }
    }

    func testMakeFallsBackToStubServicesWhenConfigIsMissing() {
        final class EmptyKeysBundle: Bundle, @unchecked Sendable {
            override func object(forInfoDictionaryKey key: String) -> Any? { "" }
        }
        // ビルド構成の既定(Release は致命)に左右されないよう、ポリシーを明示する(致命側は ConfigTests)
        let services = AppServices.make(bundle: EmptyKeysBundle(), whenConfigMissing: .fallBackToStub)
        XCTAssertFalse(services.isLive)
        XCTAssertTrue(services.auth is StubAuthService)
    }

    private func assertFails(
        _ label: String,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ operation: () async throws -> Void
    ) async {
        do {
            try await operation()
            XCTFail("\(label): 未サインインなのに成功した", file: file, line: line)
        } catch {
            // 失敗すればよい(エラーの型は各クライアントのエラーマップに依る)
        }
    }

    // MARK: Stub 構成の通し(実 ViewModel + AppModel)

    func testStubConfigurationWalksThroughOnboardingToPairedHome() async throws {
        let temp = TempStore()
        defer { temp.cleanup() }
        let services = AppServices.stub(store: temp.store, pushAuthorizer: GrantingPushAuthorizer())
        let model = AppModel(services: services)
        XCTAssertEqual(model.phase, .onboarding)

        // 1. オンボーディング(匿名サインイン → プロフィール → 通知)
        var onboardingFinished = false
        let onboarding = OnboardingViewModel(
            authService: services.auth,
            pushAuthorizer: services.pushAuthorizer,
            onFinished: { onboardingFinished = true }
        )
        onboarding.advanceFromConcept()
        onboarding.nickname = "あきら"
        await onboarding.submitProfile()
        await onboarding.requestNotifications()
        XCTAssertTrue(onboardingFinished)
        await model.onboardingFinished()
        XCTAssertEqual(model.phase, .promiseSetup, "約束がまだ無い → 約束設定が本番導線")

        // 2. 約束設定(保存 → ホームへ)
        let promise = PromiseSetupViewModel(
            client: services.promiseClient,
            store: services.store,
            onSaved: { _ in model.promiseSaved() }
        )
        promise.title = "筋トレ"
        await promise.save()
        XCTAssertEqual(model.phase, .solo, "ペア前でもホームに入れる(ソロモード — §3.2)")

        // 3. ソロのままチェックイン
        let home = HomeViewModel(
            store: services.store,
            checkinService: services.checkinService,
            nudgeService: services.nudgeService,
            reactionService: services.reactionService,
            reloadWidgets: {}
        )
        home.load()
        XCTAssertTrue(home.isSolo)
        XCTAssertTrue(home.canCheckin)
        await home.performCheckin()
        XCTAssertEqual(home.snapshot?.todayMeDone, true)

        // 4. 同期してもスタブ構成は端末内の状態を巻き戻さない
        await model.refresh()
        XCTAssertEqual(model.phase, .solo)
        XCTAssertEqual(services.store?.loadSnapshot()?.todayMeDone, true)

        // 5. 招待コードでペア成立(約束とチェックイン状態を引き継ぐ → 約束設定へ戻らない)
        let pairing = PairingViewModel(
            inviteClient: services.inviteClient,
            store: services.store,
            onPaired: { model.pairingSucceeded() }
        )
        pairing.codeInput = "AbCd2345"
        await pairing.acceptInvite()
        XCTAssertEqual(model.phase, .paired)
        XCTAssertEqual(services.store?.loadSnapshot()?.myPromiseTitle, "筋トレ")
        XCTAssertEqual(services.store?.loadSnapshot()?.todayMeDone, true)
        await waitUntil { model.snapshotRevision > 0 }
    }
}
