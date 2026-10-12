// PushTokenSyncTests.swift — push_token / push_env の自動保存(issue #55 / REVIEW-2026-10-12 §2 M5)
//
// 検証対象(PushTokenSync.swift):
//   - 未サインイン中は保留し、セッション確立で送る(トークン→セッションの順)
//   - セッションが先でも、トークン取得で送る(セッション→トークンの順)
//   - 変化時だけ送る(同じ内容は再送しない / トークン変更・ユーザー変更では再送する)
//   - 送信失敗は保留のまま、次のトリガーで再送する
//   - push_env は注入した環境(DEBUG ビルドの既定は sandbox)

import XCTest
@testable import Lien

// MARK: - モック(トップレベル: テストクラスの隔離を継承させない)

private final class MockRegistrar: PushRegistrationUpdating {
    private(set) var calls: [(token: String, environment: PushEnvironment)] = []
    /// 先頭から数えてこの回数だけ失敗する(オフライン)
    var failuresRemaining = 0

    private struct Offline: Error {}

    func updatePushRegistration(token: String, environment: PushEnvironment) async throws {
        calls.append((token, environment))
        if failuresRemaining > 0 {
            failuresRemaining -= 1
            throw Offline()
        }
    }
}

/// セッションの有無を切り替えるための箱
private final class SessionBox {
    var userID: UUID?
}

final class PushTokenSyncTests: XCTestCase {
    private func makeSync(
        registrar: MockRegistrar,
        session: SessionBox,
        environment: PushEnvironment = .sandbox,
        ledger: PushRegistrationLedger = InMemoryPushRegistrationLedger()
    ) -> PushTokenSync {
        PushTokenSync(
            registrar: registrar,
            currentUserID: { session.userID },
            environment: environment,
            ledger: ledger
        )
    }

    // MARK: 保留(トークンとセッションの両方がそろうまで送らない)

    func testTokenReceivedBeforeSignInIsHeldUntilSessionIsEstablished() async {
        let registrar = MockRegistrar()
        let session = SessionBox()
        let sync = makeSync(registrar: registrar, session: session)

        await sync.receive(token: "aabbcc")
        XCTAssertEqual(registrar.calls.count, 0, "未サインイン中は送らない(保留)")

        session.userID = UUID() // 匿名サインイン完了
        await sync.sessionDidChange()
        XCTAssertEqual(registrar.calls.count, 1, "セッション確立で保留分を送る")
        XCTAssertEqual(registrar.calls.first?.token, "aabbcc")
        XCTAssertEqual(registrar.calls.first?.environment, .sandbox)
    }

    func testSessionEstablishedBeforeTokenSendsWhenTokenArrives() async {
        let registrar = MockRegistrar()
        let session = SessionBox()
        session.userID = UUID()
        let sync = makeSync(registrar: registrar, session: session)

        await sync.sessionDidChange()
        XCTAssertEqual(registrar.calls.count, 0, "トークン未取得では送らない")

        await sync.receive(token: "112233")
        XCTAssertEqual(registrar.calls.count, 1)
        XCTAssertEqual(registrar.calls.first?.token, "112233")
    }

    // MARK: 変化時だけ送る

    func testUnchangedRegistrationIsNotResent() async {
        let registrar = MockRegistrar()
        let session = SessionBox()
        session.userID = UUID()
        let sync = makeSync(registrar: registrar, session: session)

        await sync.receive(token: "aabbcc")
        await sync.receive(token: "aabbcc") // 起動ごとに同じトークンが届く
        await sync.sessionDidChange()
        await sync.flush() // 前面復帰
        XCTAssertEqual(registrar.calls.count, 1, "同じ (ユーザー, トークン, 環境) は再送しない")
    }

    func testChangedTokenIsResent() async {
        let registrar = MockRegistrar()
        let session = SessionBox()
        session.userID = UUID()
        let sync = makeSync(registrar: registrar, session: session)

        await sync.receive(token: "aabbcc")
        await sync.receive(token: "ddeeff") // APNs がトークンを更新した
        XCTAssertEqual(registrar.calls.map(\.token), ["aabbcc", "ddeeff"])
    }

    func testNewUserWithSameTokenIsResent() async {
        // 再インストール等で匿名ユーザーが作り直された: 同じトークンでも新しい users 行へ保存が必要
        let registrar = MockRegistrar()
        let session = SessionBox()
        session.userID = UUID()
        let ledger = InMemoryPushRegistrationLedger()
        let sync = makeSync(registrar: registrar, session: session, ledger: ledger)

        await sync.receive(token: "aabbcc")
        session.userID = UUID()
        await sync.sessionDidChange()
        XCTAssertEqual(registrar.calls.count, 2)
        XCTAssertEqual(registrar.calls.map(\.token), ["aabbcc", "aabbcc"])
    }

    func testChangedEnvironmentIsResent() async {
        // 同じ端末・同じユーザーで sandbox ビルド → production ビルドに入れ替えた場合
        let registrar = MockRegistrar()
        let session = SessionBox()
        session.userID = UUID()
        let ledger = InMemoryPushRegistrationLedger()

        let debugSync = makeSync(registrar: registrar, session: session, environment: .sandbox, ledger: ledger)
        await debugSync.receive(token: "aabbcc")
        let releaseSync = makeSync(registrar: registrar, session: session, environment: .production, ledger: ledger)
        await releaseSync.receive(token: "aabbcc")

        XCTAssertEqual(registrar.calls.map(\.environment), [.sandbox, .production])
    }

    // MARK: 失敗は保留のまま、次のトリガーで再送

    func testFailedSendStaysPendingAndIsRetriedOnNextFlush() async {
        let registrar = MockRegistrar()
        registrar.failuresRemaining = 1 // 最初の1回だけ失敗
        let session = SessionBox()
        session.userID = UUID()
        let ledger = InMemoryPushRegistrationLedger()
        let sync = makeSync(registrar: registrar, session: session, ledger: ledger)

        await sync.receive(token: "aabbcc")
        XCTAssertEqual(registrar.calls.count, 1)
        XCTAssertNil(ledger.lastSynced, "失敗したら記録しない(= 変化なし扱いにならない)")

        await sync.flush() // 前面復帰
        XCTAssertEqual(registrar.calls.count, 2, "次のトリガーで再送する")
        XCTAssertNotNil(ledger.lastSynced)

        await sync.flush()
        XCTAssertEqual(registrar.calls.count, 2, "成功後は再送しない")
    }

    // MARK: 記録の永続(UserDefaults)

    func testUserDefaultsLedgerSurvivesNewSyncInstance() async throws {
        let suite = "PushTokenSyncTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let registrar = MockRegistrar()
        let session = SessionBox()
        session.userID = UUID()

        let first = makeSync(
            registrar: registrar,
            session: session,
            ledger: UserDefaultsPushRegistrationLedger(defaults: defaults)
        )
        await first.receive(token: "aabbcc")
        XCTAssertEqual(registrar.calls.count, 1)

        // アプリ再起動を模して新しいインスタンス(同じ記録)でトークンを受け取る
        let second = makeSync(
            registrar: registrar,
            session: session,
            ledger: UserDefaultsPushRegistrationLedger(defaults: defaults)
        )
        await second.receive(token: "aabbcc")
        XCTAssertEqual(registrar.calls.count, 1, "再起動しても同じ内容は再送しない")
    }

    func testUserDefaultsLedgerRoundTripAndClear() throws {
        let suite = "PushTokenSyncTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let ledger = UserDefaultsPushRegistrationLedger(defaults: defaults)

        XCTAssertNil(ledger.lastSynced)
        let registration = PushRegistration(userID: "u1", token: "aabbcc", environment: .production)
        ledger.lastSynced = registration
        XCTAssertEqual(ledger.lastSynced, registration)
        ledger.lastSynced = nil
        XCTAssertNil(ledger.lastSynced)
    }

    // MARK: 環境(DEBUG = sandbox / それ以外 = production)

    func testPushEnvironmentRawValuesMatchServerCheckConstraint() {
        // users.push_env の check(push_env in ('sandbox','production')) — migration 0005 / issue #53
        XCTAssertEqual(PushEnvironment.sandbox.rawValue, "sandbox")
        XCTAssertEqual(PushEnvironment.production.rawValue, "production")
    }

    func testCurrentEnvironmentFollowsBuildConfiguration() {
        #if DEBUG
        XCTAssertEqual(PushEnvironment.current, .sandbox, "DEBUG ビルド(Xcode 直インストール)は sandbox")
        #else
        XCTAssertEqual(PushEnvironment.current, .production, "Release(TestFlight / App Store)は production")
        #endif
    }
}
