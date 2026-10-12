// PushTokenSyncTests.swift — push_token / push_env の自動保存(issue #55 / REVIEW-2026-10-12 §2 M5)
//
// 検証対象(PushTokenSync.swift):
//   - 未サインイン中は保留し、セッション確立で送る(トークン→セッションの順)
//   - セッションが先でも、トークン取得で送る(セッション→トークンの順)
//   - 変化時だけ送る(同じ内容は再送しない / トークン変更・ユーザー変更では再送する)
//   - 送信失敗は保留のまま、次のトリガーで再送する
//   - push_env は注入した環境(このビルドの環境を署名から決める判定は PushEnvironmentTests)
//   - サーバー側のずれの検知(issue #62): サーバーが 410 / BadDeviceToken で push_token を null にした後でも、
//     コールドスタート時と(間隔をあけた)前面復帰時に自分の users 行を読んで、ずれていれば送り直す

import XCTest
@testable import Lien

// MARK: - モック(トップレベル: テストクラスの隔離を継承させない)

private final class MockRegistrar: PushRegistrationUpdating {
    private(set) var calls: [(token: String, environment: PushEnvironment)] = []
    /// サーバーの登録を読みに行った回数
    private(set) var fetchCount = 0
    /// 先頭から数えてこの回数だけ失敗する(オフライン)
    var failuresRemaining = 0
    /// 同じく、サーバーの登録を読むときの失敗
    var fetchFailuresRemaining = 0
    /// サーバーの users 行の代わり。更新が成功すると書き換わる。
    /// テストが直接書き換えれば「サーバー側が 410 で push_token を null にした」状況も作れる
    var serverRegistration = ServerPushRegistration(token: nil, environment: nil)

    private struct Offline: Error {}

    func updatePushRegistration(token: String, environment: PushEnvironment) async throws {
        calls.append((token, environment))
        if failuresRemaining > 0 {
            failuresRemaining -= 1
            throw Offline()
        }
        serverRegistration = ServerPushRegistration(token: token, environment: environment)
    }

    func fetchPushRegistration() async throws -> ServerPushRegistration {
        fetchCount += 1
        if fetchFailuresRemaining > 0 {
            fetchFailuresRemaining -= 1
            throw Offline()
        }
        return serverRegistration
    }
}

/// セッションの有無を切り替えるための箱
private final class SessionBox {
    var userID: UUID?
}

/// 時刻を進められる時計(サーバーの登録を読み直す間隔の検証用)
private final class VerifyClock {
    var now = Date(timeIntervalSince1970: 1_781_166_600)
    func advance(_ seconds: TimeInterval) { now = now.addingTimeInterval(seconds) }
}

final class PushTokenSyncTests: XCTestCase {
    private func makeSync(
        registrar: MockRegistrar,
        session: SessionBox,
        environment: PushEnvironment = .sandbox,
        ledger: PushRegistrationLedger = InMemoryPushRegistrationLedger(),
        clock: VerifyClock = VerifyClock()
    ) -> PushTokenSync {
        PushTokenSync(
            registrar: registrar,
            currentUserID: { session.userID },
            environment: environment,
            ledger: ledger,
            now: { clock.now }
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

    // MARK: サーバー側のずれの検知と回復(issue #62)

    /// 前回の起動で送信済み(記録あり)の状態を作る。次に作る PushTokenSync は「再起動したアプリ」になる
    private func syncedBefore(
        registrar: MockRegistrar,
        session: SessionBox,
        ledger: PushRegistrationLedger,
        token: String = "aabbcc"
    ) async {
        let previousLaunch = makeSync(registrar: registrar, session: session, ledger: ledger)
        await previousLaunch.receive(token: token)
        XCTAssertEqual(registrar.calls.count, 1, "前提: 前回の起動で送信済み")
        XCTAssertEqual(registrar.fetchCount, 0, "前提: 初回の登録は、サーバーを読む前にそのまま送る")
    }

    func testTokenNulledByServerIsRestoredAtColdStart() async {
        // サーバーは APNs の 410 / BadDeviceToken で users.push_token を null にする(push_env は残る)。
        // 端末の記録は「送信済み」のままなので、読み戻して確かめないと二度と戻らない
        let registrar = MockRegistrar()
        let session = SessionBox()
        session.userID = UUID()
        let ledger = InMemoryPushRegistrationLedger()
        await syncedBefore(registrar: registrar, session: session, ledger: ledger)
        registrar.serverRegistration = ServerPushRegistration(token: nil, environment: .sandbox)

        let relaunched = makeSync(registrar: registrar, session: session, ledger: ledger)
        await relaunched.receive(token: "aabbcc") // 起動ごとに同じトークンが届く

        XCTAssertEqual(registrar.fetchCount, 1, "コールドスタートの最初に、自分の登録を読む")
        XCTAssertEqual(registrar.calls.count, 2, "null になっていたので送り直す")
        XCTAssertEqual(registrar.serverRegistration, ServerPushRegistration(token: "aabbcc", environment: .sandbox))
    }

    func testRegistrationInSyncWithServerIsReadOnceAndNotResent() async {
        let registrar = MockRegistrar()
        let session = SessionBox()
        session.userID = UUID()
        let ledger = InMemoryPushRegistrationLedger()
        await syncedBefore(registrar: registrar, session: session, ledger: ledger)

        let relaunched = makeSync(registrar: registrar, session: session, ledger: ledger)
        await relaunched.receive(token: "aabbcc")
        await relaunched.sessionDidChange()
        await relaunched.flush() // 前面復帰

        XCTAssertEqual(registrar.fetchCount, 1, "読むのはプロセスの最初の1回だけ(直後の前面復帰では読み直さない)")
        XCTAssertEqual(registrar.calls.count, 1, "ずれていなければ送らない")
    }

    func testForegroundWithinIntervalDoesNotReadServerAgain() async {
        let registrar = MockRegistrar()
        let session = SessionBox()
        session.userID = UUID()
        let ledger = InMemoryPushRegistrationLedger()
        let clock = VerifyClock()
        await syncedBefore(registrar: registrar, session: session, ledger: ledger)
        let relaunched = makeSync(registrar: registrar, session: session, ledger: ledger, clock: clock)
        await relaunched.receive(token: "aabbcc")
        XCTAssertEqual(registrar.fetchCount, 1)

        clock.advance(PushTokenSync.minVerifyInterval - 1)
        registrar.serverRegistration = ServerPushRegistration(token: nil, environment: .sandbox) // 間隔の途中で無効化
        await relaunched.flush() // 前面復帰(間隔がまだあいていない)

        XCTAssertEqual(registrar.fetchCount, 1, "間隔があくまで読み直さない")
        XCTAssertEqual(registrar.calls.count, 1)
    }

    func testForegroundAfterIntervalReadsServerAgainAndRestoresNulledToken() async {
        let registrar = MockRegistrar()
        let session = SessionBox()
        session.userID = UUID()
        let ledger = InMemoryPushRegistrationLedger()
        let clock = VerifyClock()
        await syncedBefore(registrar: registrar, session: session, ledger: ledger)
        let relaunched = makeSync(registrar: registrar, session: session, ledger: ledger, clock: clock)
        await relaunched.receive(token: "aabbcc")
        XCTAssertEqual(registrar.fetchCount, 1)

        // 使っている間にサーバーが 410 を受けてトークンを無効にした。間隔があいた後の前面復帰で拾う
        registrar.serverRegistration = ServerPushRegistration(token: nil, environment: .sandbox)
        clock.advance(PushTokenSync.minVerifyInterval + 1)
        await relaunched.flush()

        XCTAssertEqual(registrar.fetchCount, 2)
        XCTAssertEqual(registrar.calls.count, 2, "null になっていたので送り直す")
        XCTAssertEqual(registrar.serverRegistration.token, "aabbcc")

        // 直したあとは、また間隔があくまで読まない
        await relaunched.flush()
        XCTAssertEqual(registrar.fetchCount, 2)
    }

    func testServerWithDifferentTokenOrUnsetEnvironmentIsOverwritten() async {
        let drifted: [(label: String, server: ServerPushRegistration)] = [
            ("別のトークンが入っている", ServerPushRegistration(token: "ffffff", environment: .sandbox)),
            ("push_env が未設定(従来の行)", ServerPushRegistration(token: "aabbcc", environment: nil)),
            ("push_env が違う", ServerPushRegistration(token: "aabbcc", environment: .production)),
            ("どちらも未設定", ServerPushRegistration(token: nil, environment: nil)),
        ]
        for (label, server) in drifted {
            let registrar = MockRegistrar()
            let session = SessionBox()
            session.userID = UUID()
            let ledger = InMemoryPushRegistrationLedger()
            await syncedBefore(registrar: registrar, session: session, ledger: ledger)
            registrar.serverRegistration = server

            await makeSync(registrar: registrar, session: session, ledger: ledger).receive(token: "aabbcc")

            XCTAssertEqual(registrar.calls.count, 2, label)
            XCTAssertEqual(
                registrar.serverRegistration,
                ServerPushRegistration(token: "aabbcc", environment: .sandbox),
                label
            )
        }
    }

    func testFirstRegistrationIsSentWithoutReadingServerFirst() async {
        // 記録が無い(= どのみち送る)ときは、読んで確かめる必要がない
        let registrar = MockRegistrar()
        let session = SessionBox()
        session.userID = UUID()
        let sync = makeSync(registrar: registrar, session: session)

        await sync.receive(token: "aabbcc")

        XCTAssertEqual(registrar.calls.count, 1)
        XCTAssertEqual(registrar.fetchCount, 0)
    }

    func testServerIsNotReadWithoutTokenOrSession() async {
        // 比べる相手(送りたい内容)が無い間は、サーバーを読まない
        let registrar = MockRegistrar()
        let session = SessionBox()
        let userID = UUID()
        session.userID = userID
        let ledger = InMemoryPushRegistrationLedger()
        await syncedBefore(registrar: registrar, session: session, ledger: ledger)
        session.userID = nil // 再起動直後でまだセッションが復元されていない

        let relaunched = makeSync(registrar: registrar, session: session, ledger: ledger)
        await relaunched.flush() // トークン未取得
        await relaunched.receive(token: "aabbcc") // セッション未確立
        XCTAssertEqual(registrar.fetchCount, 0)
        XCTAssertEqual(registrar.calls.count, 1)

        // セッションが戻った(同じユーザー)→ このときに読む
        session.userID = userID
        await relaunched.sessionDidChange()
        XCTAssertEqual(registrar.fetchCount, 1)
        XCTAssertEqual(registrar.calls.count, 1, "ずれていなければ送らない")
    }

    func testReadFailureKeepsRecordAndIsRetriedAtNextTrigger() async {
        let registrar = MockRegistrar()
        let session = SessionBox()
        session.userID = UUID()
        let ledger = InMemoryPushRegistrationLedger()
        await syncedBefore(registrar: registrar, session: session, ledger: ledger)
        registrar.serverRegistration = ServerPushRegistration(token: nil, environment: .sandbox)
        registrar.fetchFailuresRemaining = 1 // オフライン

        let relaunched = makeSync(registrar: registrar, session: session, ledger: ledger)
        await relaunched.receive(token: "aabbcc")
        XCTAssertEqual(registrar.fetchCount, 1)
        XCTAssertEqual(registrar.calls.count, 1, "読めなかったときは何も送らない(記録も壊さない)")
        XCTAssertNotNil(ledger.lastSynced)

        // 読めなかった確認は「確認済み」にしない: 次のトリガーでもう一度読み、今度はずれを直す
        await relaunched.flush()
        XCTAssertEqual(registrar.fetchCount, 2)
        XCTAssertEqual(registrar.calls.count, 2)
        XCTAssertEqual(registrar.serverRegistration.token, "aabbcc")
    }

    func testFailedResendAfterDriftIsRetriedWithoutReadingAgain() async {
        let registrar = MockRegistrar()
        let session = SessionBox()
        session.userID = UUID()
        let ledger = InMemoryPushRegistrationLedger()
        await syncedBefore(registrar: registrar, session: session, ledger: ledger)
        registrar.serverRegistration = ServerPushRegistration(token: nil, environment: .sandbox)
        registrar.failuresRemaining = 1 // 送り直しの1回目が失敗する

        let relaunched = makeSync(registrar: registrar, session: session, ledger: ledger)
        await relaunched.receive(token: "aabbcc")
        XCTAssertEqual(registrar.calls.count, 2, "ずれを見つけて送り直そうとした(失敗)")
        XCTAssertNil(ledger.lastSynced, "送れていないので記録は空のまま(= 保留)")

        await relaunched.flush()
        XCTAssertEqual(registrar.calls.count, 3, "次のトリガーで再送する")
        XCTAssertEqual(registrar.serverRegistration.token, "aabbcc")
        XCTAssertEqual(registrar.fetchCount, 1, "再送のために読み直す必要はない")
    }

    func testClockMovedBackwardDoesNotStallVerification() async {
        let registrar = MockRegistrar()
        let session = SessionBox()
        session.userID = UUID()
        let ledger = InMemoryPushRegistrationLedger()
        let clock = VerifyClock()
        await syncedBefore(registrar: registrar, session: session, ledger: ledger)
        let relaunched = makeSync(registrar: registrar, session: session, ledger: ledger, clock: clock)
        await relaunched.receive(token: "aabbcc")
        XCTAssertEqual(registrar.fetchCount, 1)

        clock.advance(-3600) // 端末の時計が過去に戻った
        await relaunched.flush()
        XCTAssertEqual(registrar.fetchCount, 2, "時計が戻っても確認が止まり続けない")
    }

    // MARK: 環境の語彙(判定そのものは PushEnvironmentTests)

    func testPushEnvironmentRawValuesMatchServerCheckConstraint() {
        // users.push_env の check(push_env in ('sandbox','production')) — migration 0005 / issue #53
        XCTAssertEqual(PushEnvironment.sandbox.rawValue, "sandbox")
        XCTAssertEqual(PushEnvironment.production.rawValue, "production")
    }
}
