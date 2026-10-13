// SessionVerifierTests.swift — 認証サーバーへの、ログイン状態の直接のたしかめ(T23 #23)
//
// 検証対象(SessionVerifier.swift):
//   - リクエストの形(GET /auth/v1/user・apikey と Bearer)
//   - 応答の判定: 200 = 有効 / 403・404 の user_not_found・session_not_found = 確かに使えない / それ以外 = たしかめられない
//     (401 の期限切れなどは、端末の時計のずれでも出るので、使えないとは決めない)
//   - トークンを用意できない・通信の失敗は、投げずに「たしかめられない」

import XCTest
@testable import Lien

final class SessionVerifierTests: XCTestCase {
    private let baseURL = URL(string: "https://example.supabase.co")!

    override func setUp() {
        super.setUp()
        StubURLProtocol.reset()
    }

    override func tearDown() {
        StubURLProtocol.reset()
        super.tearDown()
    }

    private func makeVerifier(
        token: @escaping () async throws -> String = { "jwt-123" }
    ) -> GoTrueSessionVerifier {
        GoTrueSessionVerifier(
            baseURL: baseURL,
            apiKey: "anon-key",
            tokenProvider: token,
            session: StubURLProtocol.makeSession()
        )
    }

    private func respond(status: Int, json: String) {
        StubURLProtocol.handler = { _ in (status, Data(json.utf8)) }
    }

    private struct NoSession: Error {}

    // MARK: リクエスト

    func testAsksTheAuthServerWithTheUsersOwnToken() async throws {
        respond(status: 200, json: #"{"id":"u1"}"#)

        let verdict = await makeVerifier().verify()

        XCTAssertEqual(verdict, .valid)
        let request = try XCTUnwrap(StubURLProtocol.captured.first)
        XCTAssertEqual(request.method, "GET")
        XCTAssertEqual(request.url?.absoluteString, "https://example.supabase.co/auth/v1/user")
        XCTAssertEqual(request.header("apikey"), "anon-key", "公開キー(サービスキーではない)")
        XCTAssertEqual(request.header("Authorization"), "Bearer jwt-123", "利用者自身のトークン")
        XCTAssertEqual(request.request.timeoutInterval, GoTrueSessionVerifier.requestTimeout)
    }

    // MARK: 判定

    func testUserOrSessionNotFoundIsRejected() async {
        respond(status: 403, json: #"{"code":403,"error_code":"user_not_found","msg":"User from sub claim in JWT does not exist"}"#)
        let userGone = await makeVerifier().verify()
        XCTAssertEqual(userGone, .rejected)

        respond(status: 403, json: #"{"code":403,"error_code":"session_not_found","msg":"Session from session_id claim in JWT does not exist"}"#)
        let sessionGone = await makeVerifier().verify()
        XCTAssertEqual(sessionGone, .rejected)

        respond(status: 404, json: #"{"code":404,"error_code":"user_not_found","msg":"User not found"}"#)
        let notFound = await makeVerifier().verify()
        XCTAssertEqual(notFound, .rejected)
    }

    func testOtherFailuresAreNotConclusive() async {
        let cases: [(status: Int, json: String)] = [
            // 期限切れ・署名の不正: 端末の時計のずれでも出る。使えないとは決めない
            (401, #"{"code":401,"error_code":"bad_jwt","msg":"invalid JWT: token is expired"}"#),
            (401, #"{"code":401,"error_code":"no_authorization","msg":"This endpoint requires a Bearer token"}"#),
            // 認証サーバーの不調
            (500, #"{"code":500,"error_code":"unexpected_failure","msg":"boom"}"#),
            (503, "<html>Service Unavailable</html>"),
            (502, ""),
            // 403 でも別の理由
            (403, #"{"code":403,"error_code":"not_admin","msg":"nope"}"#),
            // error_code の無い応答は、断定しない
            (404, #"{"msg":"User not found"}"#),
            (403, "not json"),
        ]
        for item in cases {
            respond(status: item.status, json: item.json)
            let verdict = await makeVerifier().verify()
            XCTAssertEqual(verdict, .unknown, "\(item.status) \(item.json)")
        }
    }

    func testVerdictFunctionIsPure() {
        XCTAssertEqual(GoTrueSessionVerifier.verdict(status: 200, body: Data()), .valid)
        XCTAssertEqual(
            GoTrueSessionVerifier.verdict(status: 403, body: Data(#"{"error_code":"user_not_found"}"#.utf8)),
            .rejected
        )
        XCTAssertEqual(GoTrueSessionVerifier.verdict(status: 401, body: Data(#"{"error_code":"user_not_found"}"#.utf8)), .unknown)
    }

    // MARK: たしかめられないとき

    func testNoTokenIsInconclusiveAndSendsNothing() async {
        let verdict = await makeVerifier(token: { throw NoSession() }).verify()

        XCTAssertEqual(verdict, .unknown)
        XCTAssertTrue(StubURLProtocol.captured.isEmpty, "トークンが無ければ、認証サーバーにも問い合わせない")
    }

    func testNetworkFailureIsInconclusive() async {
        StubURLProtocol.handler = { _ in throw URLError(.notConnectedToInternet) }

        let verdict = await makeVerifier().verify()

        XCTAssertEqual(verdict, .unknown, "通信の失敗は、使えないとは決めない")
    }
}
