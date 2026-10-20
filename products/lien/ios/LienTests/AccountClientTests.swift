// AccountClientTests.swift — ペア解消(pair-dissolve)とアカウント削除(delete-account)のクライアント(T23 #23)
//
// 検証対象(AccountAPIClient.swift):
//   - リクエストの形(POST /functions/v1/<name>・Bearer・本文なし・待ち時間)
//   - 契約フィクスチャ(サーバーの実ハンドラ出力)のデコード / エラー文字列のマップ
//   - 通信エラー・壊れた応答・deleted:false の扱い
//   - スタブ(Config 未設定の構成)が、サーバーの解消後と同じソロの形を返す

import XCTest
@testable import Lien

final class AccountClientTests: XCTestCase {
    private let baseURL = URL(string: "https://example.supabase.co")!

    override func setUp() {
        super.setUp()
        StubURLProtocol.reset()
    }

    override func tearDown() {
        StubURLProtocol.reset()
        super.tearDown()
    }

    private func makeClient(
        token: @escaping () async throws -> String = { "jwt-123" }
    ) -> EdgeFunctionAccountClient {
        EdgeFunctionAccountClient(baseURL: baseURL, tokenProvider: token, session: StubURLProtocol.makeSession())
    }

    private func respond(status: Int, fixture: String) throws {
        let body = try ContractFixtures.data(fixture)
        StubURLProtocol.handler = { _ in (status, body) }
    }

    private func respond(status: Int, json: String) {
        StubURLProtocol.handler = { _ in (status, Data(json.utf8)) }
    }

    // MARK: pair-dissolve

    func testDissolvePairPostsToTheFunctionAndReturnsTheSoloSnapshot() async throws {
        try respond(status: 200, fixture: "pair-dissolve.ok")

        let snapshot = try await makeClient().dissolvePair()

        let request = try XCTUnwrap(StubURLProtocol.captured.first)
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.url?.absoluteString, "https://example.supabase.co/functions/v1/pair-dissolve")
        XCTAssertEqual(request.header("Authorization"), "Bearer jwt-123")
        XCTAssertNil(request.body, "本文は読まない(解消するペアは JWT から決まる)")
        XCTAssertEqual(request.request.timeoutInterval, EdgeFunctionAccountClient.dissolveTimeout)

        XCTAssertNil(snapshot.pairId, "解消後はソロの形")
        XCTAssertNil(snapshot.partnerName)
        XCTAssertEqual(snapshot.myPromiseTitle, "筋トレ", "自分の約束は残る")
        XCTAssertTrue(snapshot.todayMeDone, "今日の自分のチェックインも残る")
        XCTAssertEqual(AppRouter.phase(hasSession: true, snapshot: snapshot), .solo)
    }

    func testDissolveAlreadySoloIsAlsoSuccess() async throws {
        // 冪等: すでにペアが無くても 200 { dissolved: false, snapshot }。クライアントは同じに扱える
        try respond(status: 200, fixture: "pair-dissolve.already")

        let snapshot = try await makeClient().dissolvePair()

        XCTAssertNil(snapshot.pairId)
        XCTAssertEqual(snapshot.myPromiseTitle, "筋トレ")
    }

    func testDissolveResponsesDecodeWithTheDissolvedFlag() throws {
        let done = try ContractFixtures.decode(PairDissolveResponse.self, from: "pair-dissolve.ok")
        XCTAssertTrue(done.dissolved)
        let already = try ContractFixtures.decode(PairDissolveResponse.self, from: "pair-dissolve.already")
        XCTAssertFalse(already.dissolved)
    }

    func testDissolveErrorsAreMappedFromTheServerCodes() async throws {
        let cases: [(status: Int, json: String, expected: AccountClientError)] = [
            (401, #"{"error":"unauthorized"}"#, .unauthorized),
            (404, #"{"error":"user_not_found"}"#, .userNotFound),
            (500, #"{"error":"internal_error"}"#, .server(code: "internal_error")),
            (405, #"{"error":"method_not_allowed"}"#, .server(code: "method_not_allowed")),
            (502, "<html>Bad Gateway</html>", .server(code: "http_502")),
        ]
        for item in cases {
            respond(status: item.status, json: item.json)
            do {
                _ = try await makeClient().dissolvePair()
                XCTFail("失敗するはず: \(item.status)")
            } catch let error as AccountClientError {
                XCTAssertEqual(error, item.expected, "\(item.status)")
            }
        }
    }

    func testDissolveNetworkFailureIsReportedAsNetwork() async {
        StubURLProtocol.handler = { _ in throw URLError(.notConnectedToInternet) }
        do {
            _ = try await makeClient().dissolvePair()
            XCTFail()
        } catch {
            XCTAssertEqual(error as? AccountClientError, .network)
        }
    }

    func testDissolveWithABrokenBodyIsAServerError() async {
        respond(status: 200, json: #"{"unexpected":true}"#)
        do {
            _ = try await makeClient().dissolvePair()
            XCTFail()
        } catch {
            XCTAssertEqual(error as? AccountClientError, .server(code: "invalid_response"))
        }
    }

    func testTokenFailureIsPropagatedAndNothingIsSent() async {
        let client = makeClient(token: { throw AuthServiceError.notSignedIn })
        do {
            _ = try await client.dissolvePair()
            XCTFail()
        } catch {
            XCTAssertEqual(error as? AuthServiceError, .notSignedIn)
        }
        XCTAssertTrue(StubURLProtocol.captured.isEmpty, "トークンが取れなければ何も送らない")
    }

    // MARK: delete-account

    func testDeleteAccountPostsToTheFunction() async throws {
        try respond(status: 200, fixture: "delete-account.ok")

        try await makeClient().deleteAccount()

        let request = try XCTUnwrap(StubURLProtocol.captured.first)
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.url?.absoluteString, "https://example.supabase.co/functions/v1/delete-account")
        XCTAssertEqual(request.header("Authorization"), "Bearer jwt-123")
        XCTAssertNil(request.body)
        XCTAssertEqual(
            request.request.timeoutInterval,
            EdgeFunctionAccountClient.deleteTimeout,
            "写真の回収を含むので、解消より長く待つ"
        )
        XCTAssertGreaterThan(EdgeFunctionAccountClient.deleteTimeout, EdgeFunctionAccountClient.dissolveTimeout)
    }

    func testDeleteAccountResponseDecodes() throws {
        let response = try ContractFixtures.decode(AccountDeleteResponse.self, from: "delete-account.ok")
        XCTAssertTrue(response.deleted)
    }

    func testDeleteAccountErrorsAreMappedAndRetryable() async {
        let cases: [(status: Int, json: String, expected: AccountClientError)] = [
            (401, #"{"error":"unauthorized"}"#, .unauthorized),
            (500, #"{"error":"internal_error"}"#, .server(code: "internal_error")),
        ]
        for item in cases {
            respond(status: item.status, json: item.json)
            do {
                try await makeClient().deleteAccount()
                XCTFail("失敗するはず")
            } catch {
                XCTAssertEqual(error as? AccountClientError, item.expected)
            }
        }
    }

    func testDeletedFalseIsNotTreatedAsSuccess() async {
        respond(status: 200, json: #"{"deleted":false}"#)
        do {
            try await makeClient().deleteAccount()
            XCTFail()
        } catch {
            XCTAssertEqual(error as? AccountClientError, .server(code: "not_deleted"))
        }
    }

    func testDeleteNetworkFailureIsReportedAsNetwork() async {
        StubURLProtocol.handler = { _ in throw URLError(.timedOut) }
        do {
            try await makeClient().deleteAccount()
            XCTFail()
        } catch {
            XCTAssertEqual(error as? AccountClientError, .network)
        }
    }

    // MARK: スタブ(Config 未設定の構成)

    func testStubDissolveReturnsTheSameShapeAsTheServerAfterDissolving() async throws {
        let temp = TempStore()
        defer { temp.cleanup() }
        try temp.store.saveSnapshot(SnapshotFactory.paired(todayMeDone: true))
        let stub = StubAccountClient(store: temp.store, now: { SnapshotFactory.fixedDate })

        let snapshot = try await stub.dissolvePair()

        var server = try ContractFixtures.decode(PairDissolveResponse.self, from: "pair-dissolve.ok").snapshot
        // スタブは端末で組み立てるので、サーバーが載せる「組み立てに使った今日」(dateLocal。issue #72)は持たない
        // (アプリは時刻から保守的に判定する)。それ以外の形はサーバーと同じ
        XCTAssertEqual(server.dateLocal, "2026-06-11", "サーバーは dateLocal を載せる")
        XCTAssertNil(snapshot.dateLocal)
        server.dateLocal = nil
        XCTAssertEqual(snapshot, server, "スタブの解消後の形は、サーバーの実ハンドラの出力と同じ")
    }

    func testStubDissolveWithoutALocalSnapshotReturnsAnEmptySolo() async throws {
        let stub = StubAccountClient(store: nil, now: { SnapshotFactory.fixedDate })
        let snapshot = try await stub.dissolvePair()
        XCTAssertEqual(snapshot, PairSnapshot.emptySolo(updatedAt: SnapshotFactory.fixedDate))
    }

    func testStubDeleteDoesNothing() async throws {
        let stub = StubAccountClient(store: nil)
        try await stub.deleteAccount()
    }

    func testDissolvedSnapshotKeepsPromiseAndTodayCheckinButDropsThePair() {
        let paired = SnapshotFactory.paired(todayMeDone: true, todayPartnerDone: true)
        let solo = paired.dissolved(updatedAt: SnapshotFactory.fixedDate)

        XCTAssertNil(solo.pairId)
        XCTAssertNil(solo.partnerName)
        XCTAssertNil(solo.partnerPromiseTitle)
        XCTAssertFalse(solo.todayPartnerDone)
        XCTAssertEqual(solo.streakCurrent, 0)
        XCTAssertNil(solo.plantName)
        XCTAssertEqual(solo.plantStage, 0)
        XCTAssertEqual(solo.myPromiseTitle, "筋トレ")
        XCTAssertTrue(solo.todayMeDone)
    }

    // MARK: 契約: 解消された相手に届くサイレント push

    func testPairDissolvedPushFeedsTheAppAsSolo() throws {
        let userInfo = try ContractFixtures.object("push.pair-dissolved")
        let aps = try XCTUnwrap(userInfo["aps"] as? [String: Any])
        XCTAssertEqual(aps["content-available"] as? Int, 1)
        XCTAssertNil(aps["alert"], "通知 UI は出さない(罰・恥の演出を作らない)")
        let lien = try XCTUnwrap(userInfo["lien"] as? [String: Any])
        XCTAssertEqual(lien["type"] as? String, "pair_update")

        let temp = TempStore()
        defer { temp.cleanup() }
        let data = try JSONSerialization.data(withJSONObject: try XCTUnwrap(lien["snapshot"]))
        let saved = try temp.store.saveSnapshotData(data)

        XCTAssertNil(saved.pairId, "解消された相手の snapshot はソロの形")
        XCTAssertEqual(saved.myPromiseTitle, "ランニング", "受信者(相手)視点")
        XCTAssertEqual(AppRouter.phase(hasSession: true, snapshot: saved), .solo)
    }
}
