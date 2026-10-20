// HistoryRepositoryTests.swift — Live の HistoryRepository(PostgREST)の検証(T18 #18)
//
// URLProtocol スタブ(TestSupport.swift)でネットワーク無しに確かめる:
//   - pairs → checkins → streak_days の順と、クエリ(月の範囲・pair_id・select)・認証ヘッダ
//   - 自分/相手のチェックインの振り分けと、streak_days の kind の読み取り
//   - ペアが無いときは追加の問い合わせをしない
//   - 401/403/5xx/通信断/壊れた JSON のマッピング
// 本番の RLS の範囲(現役ペアの相手だけ読める)は、クエリを増やさず既存のポリシーに任せる。

import XCTest
@testable import Lien

private let historyBaseURL = URL(string: "https://example.supabase.co")!
private let historyMyID = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
private let historyPartnerID = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!

private func historyJSON(_ text: String) -> Data { Data(text.utf8) }

private func historyQuery(_ request: URLRequest, named name: String) -> [String] {
    URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?
        .queryItems?
        .filter { $0.name == name }
        .compactMap(\.value) ?? []
}

private func historyQuery(_ captured: CapturedRequest, named name: String) -> [String] {
    historyQuery(captured.request, named: name)
}

private func historyPath(_ request: URLRequest) -> String {
    request.url?.path ?? ""
}

private func historyPath(_ captured: CapturedRequest) -> String {
    historyPath(captured.request)
}

private final class HistoryRepositoryTestSupport {
    let repository: PostgRESTHistoryRepository

    init(
        calendar: Calendar = .lienHistory,
        currentUserID: @escaping () -> UUID? = { historyMyID },
        tokenProvider: @escaping () async throws -> String = { "test-token" }
    ) {
        StubURLProtocol.reset()
        repository = PostgRESTHistoryRepository(
            baseURL: historyBaseURL,
            apiKey: "test-anon-key",
            tokenProvider: tokenProvider,
            currentUserID: currentUserID,
            session: StubURLProtocol.makeSession(),
            calendar: calendar
        )
    }

    /// 3つのテーブルの応答を返す。省略したテーブルは空配列
    func serve(
        pairs: String = "[]",
        checkins: String = "[]",
        streakDays: String = "[]"
    ) {
        StubURLProtocol.handler = { request in
            switch historyPath(request) {
            case "/rest/v1/pairs":
                return (200, historyJSON(pairs))
            case "/rest/v1/checkins":
                return (200, historyJSON(checkins))
            case "/rest/v1/streak_days":
                return (200, historyJSON(streakDays))
            default:
                return (404, historyJSON("{}"))
            }
        }
    }
}

final class HistoryRepositoryTests: XCTestCase {
    private let pairJSON = """
    [{"id":"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa","started_on":"2026-06-10","status":"active"}]
    """

    override func tearDown() {
        StubURLProtocol.reset()
        super.tearDown()
    }

    // MARK: 正常系

    func testFetchesTheMonthWithTheExpectedQueriesAndDecodesRows() async throws {
        let support = HistoryRepositoryTestSupport()
        support.serve(
            pairs: pairJSON,
            checkins: """
            [
              {"user_id":"11111111-1111-4111-8111-111111111111","date_local":"2026-06-10"},
              {"user_id":"22222222-2222-4222-8222-222222222222","date_local":"2026-06-10"},
              {"user_id":"11111111-1111-4111-8111-111111111111","date_local":"2026-06-11"}
            ]
            """,
            streakDays: """
            [
              {"date_local":"2026-06-10","kind":"both"},
              {"date_local":"2026-06-11","kind":"ticket"},
              {"date_local":"2026-06-12","kind":"future_kind"}
            ]
            """
        )

        let data = try await support.repository.fetchMonth(HistoryMonth(year: 2026, month: 6))

        XCTAssertEqual(data.pairStartedOn, "2026-06-10")
        XCTAssertEqual(data.myCheckinDays, ["2026-06-10", "2026-06-11"])
        XCTAssertEqual(data.partnerCheckinDays, ["2026-06-10"])
        XCTAssertEqual(data.streakDays, [
            "2026-06-10": .both,
            "2026-06-11": .ticket,
        ], "未知の kind は無視する")

        let requests = StubURLProtocol.captured
        XCTAssertEqual(requests.map(historyPath), [
            "/rest/v1/pairs",
            "/rest/v1/checkins",
            "/rest/v1/streak_days",
        ])

        let pairs = requests[0]
        XCTAssertEqual(pairs.method, "GET")
        XCTAssertEqual(pairs.header("apikey"), "test-anon-key")
        XCTAssertEqual(pairs.header("Authorization"), "Bearer test-token")
        XCTAssertEqual(historyQuery(pairs, named: "select"), ["id,started_on,status"])
        XCTAssertEqual(historyQuery(pairs, named: "order"), ["created_at.desc"])

        let checkins = requests[1]
        XCTAssertEqual(historyQuery(checkins, named: "select"), ["user_id,date_local"])
        XCTAssertEqual(historyQuery(checkins, named: "date_local"), ["gte.2026-06-01", "lte.2026-06-30"])
        XCTAssertEqual(historyQuery(checkins, named: "order"), ["date_local.asc"])

        let streak = requests[2]
        XCTAssertEqual(historyQuery(streak, named: "select"), ["date_local,kind"])
        XCTAssertEqual(
            historyQuery(streak, named: "pair_id"),
            ["eq.aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"]
        )
        XCTAssertEqual(historyQuery(streak, named: "date_local"), ["gte.2026-06-01", "lte.2026-06-30"])
    }

    func testLeapFebruaryUsesTheCorrectLastDay() async throws {
        let support = HistoryRepositoryTestSupport()
        support.serve(pairs: pairJSON)

        _ = try await support.repository.fetchMonth(HistoryMonth(year: 2024, month: 2))

        let checkins = try XCTUnwrap(StubURLProtocol.captured.first { historyPath($0) == "/rest/v1/checkins" })
        XCTAssertEqual(historyQuery(checkins, named: "date_local"), ["gte.2024-02-01", "lte.2024-02-29"])
    }

    func testActivePairIsPreferredOverADissolvedPair() async throws {
        let support = HistoryRepositoryTestSupport()
        support.serve(pairs: """
        [
          {"id":"dddddddd-dddd-4ddd-8ddd-dddddddddddd","started_on":"2026-01-01","status":"dissolved"},
          {"id":"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa","started_on":"2026-06-10","status":"active"}
        ]
        """)

        let data = try await support.repository.fetchMonth(HistoryMonth(year: 2026, month: 6))

        XCTAssertEqual(data.pairStartedOn, "2026-06-10")
        let streak = try XCTUnwrap(StubURLProtocol.captured.first { historyPath($0) == "/rest/v1/streak_days" })
        XCTAssertEqual(
            historyQuery(streak, named: "pair_id"),
            ["eq.aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"]
        )
    }

    // MARK: ペアが無い

    func testNoPairReturnsEmptyWithoutQueryingHistory() async throws {
        let support = HistoryRepositoryTestSupport()
        support.serve(pairs: "[]")

        let data = try await support.repository.fetchMonth(HistoryMonth(year: 2026, month: 6))

        XCTAssertEqual(data, .empty)
        XCTAssertEqual(StubURLProtocol.captured.map(historyPath), ["/rest/v1/pairs"])
    }

    // MARK: エラー

    func testStatusCodesMapToTheErrors() async throws {
        let cases: [(status: Int, expected: HistoryRepositoryError)] = [
            (401, .unauthorized),
            (403, .unauthorized),
            (500, .server(500)),
            (503, .server(503)),
        ]
        for entry in cases {
            let support = HistoryRepositoryTestSupport()
            StubURLProtocol.handler = { _ in (entry.status, historyJSON(#"{"message":"x"}"#)) }
            do {
                _ = try await support.repository.fetchMonth(HistoryMonth(year: 2026, month: 6))
                XCTFail("\(entry.status) で成功してしまった")
            } catch {
                XCTAssertEqual(error as? HistoryRepositoryError, entry.expected, "\(entry.status)")
            }
        }
    }

    func testNetworkFailureIsMapped() async throws {
        let support = HistoryRepositoryTestSupport()
        StubURLProtocol.handler = { _ in throw URLError(.notConnectedToInternet) }

        do {
            _ = try await support.repository.fetchMonth(HistoryMonth(year: 2026, month: 6))
            XCTFail("オフラインで成功してしまった")
        } catch {
            XCTAssertEqual(error as? HistoryRepositoryError, .network)
        }
    }

    func testUnreadableJSONIsAnInvalidResponse() async throws {
        let support = HistoryRepositoryTestSupport()
        StubURLProtocol.handler = { _ in (200, historyJSON("not json")) }

        do {
            _ = try await support.repository.fetchMonth(HistoryMonth(year: 2026, month: 6))
            XCTFail("壊れた JSON で成功してしまった")
        } catch {
            XCTAssertEqual(error as? HistoryRepositoryError, .invalidResponse)
        }
    }

    func testNotSignedInDoesNotSendARequest() async throws {
        let support = HistoryRepositoryTestSupport(currentUserID: { nil })

        do {
            _ = try await support.repository.fetchMonth(HistoryMonth(year: 2026, month: 6))
            XCTFail("未サインインで成功してしまった")
        } catch {
            XCTAssertEqual(error as? HistoryRepositoryError, .notSignedIn)
        }
        XCTAssertTrue(StubURLProtocol.captured.isEmpty)
    }

    func testTokenFailureDoesNotSendARequest() async throws {
        let support = HistoryRepositoryTestSupport(tokenProvider: { throw AuthServiceError.notSignedIn })

        do {
            _ = try await support.repository.fetchMonth(HistoryMonth(year: 2026, month: 6))
            XCTFail("トークンが取れないのに成功してしまった")
        } catch {
            XCTAssertEqual(error as? AuthServiceError, .notSignedIn)
        }
        XCTAssertTrue(StubURLProtocol.captured.isEmpty)
    }
}
