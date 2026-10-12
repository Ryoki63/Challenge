// AppServicesTests.swift — Live / Stub 構成の切替と、Stub 構成での通し(issue #55)
//
// 検証対象(AppServices.swift / Config.swift):
//   - Config(Supabase URL / anon key)が無い環境(CI・Secrets なし)では Stub 構成になる
//   - Stub 構成はネットワークを使わず、オンボ → 約束設定 → ソロのホーム(チェックイン)→ ペア成立 まで
//     実際の ViewModel と AppModel の組み合わせで通る
//   - 端末の App Group が使えないときの代替保存先

import XCTest
@testable import Lien

private final class GrantingPushAuthorizer: PushAuthorizing {
    @discardableResult
    func requestAuthorization() async -> Bool { true }
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
