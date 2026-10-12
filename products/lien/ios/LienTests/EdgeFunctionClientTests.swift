// EdgeFunctionClientTests.swift — Live クライアントのリクエスト/応答/エラー(issue #55)
//
// URLProtocol スタブでネットワーク無しに検証する(StubURLProtocol — TestSupport.swift)。
// 対象: EdgeFunctionInviteClient / EdgeFunctionSnapshotClient / EdgeFunctionNudgeReactClient /
//       PostgRESTPartnerCheckinResolver / LiveNudgeReactService
//
// サーバー応答の「形」そのもの(products/lien/contracts/*.json)のデコードは ContractFixtureTests。
// ここでは URL・メソッド・認証ヘッダ・本文・エラー文字列のマップを固定する。

import XCTest
@testable import Lien

private let baseURL = URL(string: "https://example.supabase.co")!

private func makeSession() -> URLSession {
    StubURLProtocol.reset()
    return StubURLProtocol.makeSession()
}

private func json(_ text: String) -> Data { Data(text.utf8) }

private func reply(_ status: Int, _ body: String) {
    StubURLProtocol.handler = { _ in (status, json(body)) }
}

private let tokenProvider: () async throws -> String = { "test-token" }

private let snapshotJSON = """
{"schemaVersion":1,"pairId":null,"updatedAt":"2026-06-11T08:30:00.000Z","streakCurrent":0,"streakBest":0,
 "todayMeDone":false,"todayPartnerDone":false,"myPromiseTitle":"筋トレ","myPromiseEmoji":"💪",
 "partnerName":null,"partnerPromiseTitle":null,"partnerPromiseEmoji":null,"plantStage":0,
 "plantMood":"normal","plantName":null,"hasPartnerPhotoToday":false}
"""

// MARK: - 招待

final class EdgeFunctionInviteClientTests: XCTestCase {
    private func makeClient(
        tokenProvider: @escaping () async throws -> String = tokenProvider
    ) -> EdgeFunctionInviteClient {
        EdgeFunctionInviteClient(baseURL: baseURL, tokenProvider: tokenProvider, session: makeSession())
    }

    func testCreateInviteRequestAndResponse() async throws {
        let client = makeClient()
        reply(200, """
        {"token":"AbCd2345","appUrl":"lien://invite/AbCd2345",
         "webUrl":"https://ryoki63.github.io/Challenge/lien/i/?t=AbCd2345",
         "expiresAt":"2026-06-14T08:30:00.000Z"}
        """)

        let invite = try await client.createInvite()

        let request = try XCTUnwrap(StubURLProtocol.captured.first)
        XCTAssertEqual(request.url?.absoluteString, "https://example.supabase.co/functions/v1/invite-create")
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.header("Authorization"), "Bearer test-token")
        XCTAssertEqual(invite.token, "AbCd2345")
        XCTAssertEqual(invite.appUrl, "lien://invite/AbCd2345")
        XCTAssertTrue(invite.webUrl.hasSuffix("/lien/i/?t=AbCd2345"))
        XCTAssertEqual(invite.expiresAt, Date(timeIntervalSince1970: 1_781_425_800)) // 小数秒つき ISO8601
    }

    func testAcceptInviteSendsTokenAndDecodesSnapshot() async throws {
        let client = makeClient()
        reply(200, """
        {"pairId":"1f0c5a4e-9d3b-4c1a-8f2e-7b6d5a4c3b2a","snapshot":\(snapshotJSON)}
        """)

        let accepted = try await client.acceptInvite(token: "AbCd2345")

        let request = try XCTUnwrap(StubURLProtocol.captured.first)
        XCTAssertEqual(request.url?.absoluteString, "https://example.supabase.co/functions/v1/invite-accept")
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.header("Authorization"), "Bearer test-token")
        XCTAssertEqual(request.header("Content-Type"), "application/json")
        XCTAssertEqual(request.jsonObject?["token"] as? String, "AbCd2345")
        XCTAssertEqual(accepted.pairId, "1f0c5a4e-9d3b-4c1a-8f2e-7b6d5a4c3b2a")
        XCTAssertEqual(accepted.snapshot.myPromiseTitle, "筋トレ")
    }

    /// invite-create/core.ts・invite-accept/core.ts・各 index.ts の error 文字列 → InviteClientError
    func testServerErrorCodesMapToClientErrors() async throws {
        let table: [(status: Int, code: String, expected: InviteClientError)] = [
            (409, "already_paired", .alreadyPaired),
            (409, "partner_already_paired", .partnerAlreadyPaired),
            (404, "invite_not_found", .inviteNotFound),
            (410, "invite_expired", .inviteExpired),
            (410, "invite_already_used", .inviteAlreadyUsed),
            (400, "cannot_accept_own_invite", .cannotAcceptOwnInvite),
            (400, "invalid_token", .invalidToken),
            (404, "user_not_found", .userNotFound),
            (500, "token_generation_failed", .server(code: "token_generation_failed")),
            (500, "internal_error", .server(code: "internal_error")),
            (401, "unauthorized", .server(code: "unauthorized")),
            (400, "invalid_json", .server(code: "invalid_json")),
        ]
        for entry in table {
            let client = makeClient()
            reply(entry.status, #"{"error":"\#(entry.code)"}"#)
            do {
                _ = try await client.acceptInvite(token: "AbCd2345")
                XCTFail("\(entry.code) で成功してしまった")
            } catch {
                XCTAssertEqual(error as? InviteClientError, entry.expected, entry.code)
            }
        }
    }

    func testNetworkFailureMapsToNetworkError() async throws {
        let client = makeClient()
        StubURLProtocol.handler = { _ in throw URLError(.notConnectedToInternet) }
        do {
            _ = try await client.createInvite()
            XCTFail("オフラインで成功してしまった")
        } catch {
            XCTAssertEqual(error as? InviteClientError, .network)
        }
    }

    func testTokenProviderFailureIsNotReportedAsNetworkAndSendsNothing() async throws {
        let client = makeClient(tokenProvider: { throw AuthServiceError.notSignedIn })
        reply(200, "{}")
        do {
            _ = try await client.createInvite()
            XCTFail("トークンが取れないのに送信した")
        } catch {
            XCTAssertEqual(error as? AuthServiceError, .notSignedIn)
        }
        XCTAssertTrue(StubURLProtocol.captured.isEmpty, "トークンが無ければリクエストしない")
    }

    func testNonJSONFailureBodyFallsBackToHTTPStatusCode() async throws {
        let client = makeClient()
        reply(502, "<html>bad gateway</html>")
        do {
            _ = try await client.createInvite()
            XCTFail("502 で成功してしまった")
        } catch {
            XCTAssertEqual(error as? InviteClientError, .server(code: "http_502"))
        }
    }

    func testMalformedSuccessBodyIsInvalidResponse() async throws {
        let client = makeClient()
        reply(200, #"{"unexpected":true}"#)
        do {
            _ = try await client.createInvite()
            XCTFail("不正な本文で成功してしまった")
        } catch {
            XCTAssertEqual(error as? InviteClientError, .server(code: "invalid_response"))
        }
    }
}

// MARK: - snapshot

final class EdgeFunctionSnapshotClientTests: XCTestCase {
    private func makeClient() -> EdgeFunctionSnapshotClient {
        EdgeFunctionSnapshotClient(baseURL: baseURL, tokenProvider: tokenProvider, session: makeSession())
    }

    func testFetchSnapshotRequestAndEnvelopeDecoding() async throws {
        let client = makeClient()
        reply(200, #"{"snapshot":\#(snapshotJSON)}"#)

        let snapshot = try await client.fetchSnapshot()

        let request = try XCTUnwrap(StubURLProtocol.captured.first)
        XCTAssertEqual(request.url?.absoluteString, "https://example.supabase.co/functions/v1/snapshot")
        XCTAssertEqual(request.method, "GET")
        XCTAssertEqual(request.header("Authorization"), "Bearer test-token")
        XCTAssertNil(request.body)
        XCTAssertEqual(request.request.timeoutInterval, EdgeFunctionSnapshotClient.requestTimeout, "自己修復の取得は短く切り上げる")
        XCTAssertNil(snapshot.pairId)
        XCTAssertEqual(snapshot.myPromiseTitle, "筋トレ")
    }

    func testBareSnapshotWithoutEnvelopeIsRejected() async throws {
        // 応答は { "snapshot": {...} } の封筒つき(snapshot/core.ts)。素の PairSnapshot は契約違反
        let client = makeClient()
        reply(200, snapshotJSON)
        do {
            _ = try await client.fetchSnapshot()
            XCTFail("封筒なしを受理してしまった")
        } catch {
            XCTAssertEqual(error as? SnapshotClientError, .server(code: "invalid_response"))
        }
    }

    func testServerErrorCodes() async throws {
        let table: [(Int, String, SnapshotClientError)] = [
            (404, "user_not_found", .userNotFound),
            (401, "unauthorized", .unauthorized),
            (500, "internal_error", .server(code: "internal_error")),
            (405, "method_not_allowed", .server(code: "method_not_allowed")),
        ]
        for (status, code, expected) in table {
            let client = makeClient()
            reply(status, #"{"error":"\#(code)"}"#)
            do {
                _ = try await client.fetchSnapshot()
                XCTFail("\(code) で成功してしまった")
            } catch {
                XCTAssertEqual(error as? SnapshotClientError, expected, code)
            }
        }
    }

    func testNetworkFailure() async throws {
        let client = makeClient()
        StubURLProtocol.handler = { _ in throw URLError(.timedOut) }
        do {
            _ = try await client.fetchSnapshot()
            XCTFail("タイムアウトで成功してしまった")
        } catch {
            XCTAssertEqual(error as? SnapshotClientError, .network)
        }
    }
}

// MARK: - nudge / react

final class EdgeFunctionNudgeReactClientTests: XCTestCase {
    private func makeClient() -> EdgeFunctionNudgeReactClient {
        EdgeFunctionNudgeReactClient(baseURL: baseURL, tokenProvider: tokenProvider, session: makeSession())
    }

    func testNudgeRequestAndResponse() async throws {
        let client = makeClient()
        reply(200, #"{"remainingToday":2,"snapshot":\#(snapshotJSON)}"#)

        let response = try await client.nudge(stamp: "👋")

        let request = try XCTUnwrap(StubURLProtocol.captured.first)
        XCTAssertEqual(request.url?.absoluteString, "https://example.supabase.co/functions/v1/nudge")
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.header("Authorization"), "Bearer test-token")
        XCTAssertEqual(request.jsonObject?["stamp"] as? String, "👋")
        XCTAssertEqual(response.remainingToday, 2)
        XCTAssertNil(response.snapshot.pairId)
    }

    func testReactRequestAndResponse() async throws {
        let client = makeClient()
        reply(200, #"{"changed":true}"#)

        let response = try await client.react(checkinID: "8c2b7e5a-0d3f-4b61-9a47-2e1f5c6d7a80", stamp: "❤️")

        let request = try XCTUnwrap(StubURLProtocol.captured.first)
        XCTAssertEqual(request.url?.absoluteString, "https://example.supabase.co/functions/v1/react")
        XCTAssertEqual(request.method, "POST")
        // キー名は react/index.ts の payload(checkinId / stamp)
        XCTAssertEqual(request.jsonObject?["checkinId"] as? String, "8c2b7e5a-0d3f-4b61-9a47-2e1f5c6d7a80")
        XCTAssertEqual(request.jsonObject?["stamp"] as? String, "❤️")
        XCTAssertTrue(response.changed)
    }

    /// nudge/core.ts・react/core.ts・各 index.ts の error 文字列
    func testServerErrorCodesMapToClientErrors() async throws {
        let table: [(status: Int, code: String, expected: NudgeReactClientError)] = [
            (400, "invalid_stamp", .invalidStamp),
            (404, "user_not_found", .userNotFound),
            (409, "no_pair", .noPair),
            (409, "partner_already_done", .partnerAlreadyDone),
            (429, "nudge_limit_exceeded", .nudgeLimitExceeded),
            (404, "checkin_not_found", .checkinNotFound),
            (403, "not_partner", .notPartner),
            (401, "unauthorized", .unauthorized),
            (500, "internal_error", .server(code: "internal_error")),
            (400, "invalid_request", .server(code: "invalid_request")),
        ]
        for entry in table {
            let client = makeClient()
            reply(entry.status, #"{"error":"\#(entry.code)"}"#)
            do {
                _ = try await client.nudge(stamp: "👋")
                XCTFail("\(entry.code) で成功してしまった")
            } catch {
                XCTAssertEqual(error as? NudgeReactClientError, entry.expected, entry.code)
            }
        }
    }

    func testClientErrorsMapToHomeNudgeErrors() {
        XCTAssertEqual(NudgeReactClientError.nudgeLimitExceeded.asNudgeSendError, .limitReached)
        XCTAssertEqual(NudgeReactClientError.partnerAlreadyDone.asNudgeSendError, .partnerAlreadyDone)
        XCTAssertEqual(NudgeReactClientError.network.asNudgeSendError, .other)
        XCTAssertEqual(NudgeReactClientError.noPair.asNudgeSendError, .other)
    }

    func testNetworkFailure() async throws {
        let client = makeClient()
        StubURLProtocol.handler = { _ in throw URLError(.notConnectedToInternet) }
        do {
            _ = try await client.react(checkinID: "x", stamp: "🔥")
            XCTFail("オフラインで成功してしまった")
        } catch {
            XCTAssertEqual(error as? NudgeReactClientError, .network)
        }
    }
}

// MARK: - 相手のチェックイン行 id の解決(PostgREST)

final class PostgRESTPartnerCheckinResolverTests: XCTestCase {
    private let myID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!

    private func makeResolver() -> PostgRESTPartnerCheckinResolver {
        let me = myID
        return PostgRESTPartnerCheckinResolver(
            baseURL: baseURL,
            apiKey: "test-anon-key",
            tokenProvider: tokenProvider,
            currentUserID: { me },
            session: makeSession()
        )
    }

    func testRequestQueriesTodaysNonSelfRowWithApiKeyAndBearer() async throws {
        let resolver = makeResolver()
        reply(200, #"[{"id":"8c2b7e5a-0d3f-4b61-9a47-2e1f5c6d7a80"}]"#)

        let id = try await resolver.partnerCheckinID(dateLocal: "2026-06-11")

        XCTAssertEqual(id, "8c2b7e5a-0d3f-4b61-9a47-2e1f5c6d7a80")
        let request = try XCTUnwrap(StubURLProtocol.captured.first)
        XCTAssertEqual(request.method, "GET")
        XCTAssertEqual(request.header("apikey"), "test-anon-key", "PostgREST は apikey ヘッダが必須")
        XCTAssertEqual(request.header("Authorization"), "Bearer test-token")
        let components = URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)
        XCTAssertEqual(components?.path, "/rest/v1/checkins")
        let query = Dictionary(
            uniqueKeysWithValues: (components?.queryItems ?? []).map { ($0.name, $0.value ?? "") }
        )
        XCTAssertEqual(query["select"], "id")
        XCTAssertEqual(query["date_local"], "eq.2026-06-11")
        XCTAssertEqual(query["user_id"], "neq.11111111-2222-3333-4444-555555555555", "自分以外の行 = 相手")
        XCTAssertEqual(query["limit"], "1")
    }

    func testNoRowMeansPartnerHasNotCheckedIn() async throws {
        let resolver = makeResolver()
        reply(200, "[]")
        let id = try await resolver.partnerCheckinID(dateLocal: "2026-06-11")
        XCTAssertNil(id)
    }

    func testHTTPFailureIsServerError() async throws {
        let resolver = makeResolver()
        reply(401, #"{"message":"JWT expired"}"#)
        do {
            _ = try await resolver.partnerCheckinID(dateLocal: "2026-06-11")
            XCTFail("401 で成功してしまった")
        } catch {
            XCTAssertEqual(error as? NudgeReactClientError, .server(code: "http_401"))
        }
    }

    func testNetworkFailure() async throws {
        let resolver = makeResolver()
        StubURLProtocol.handler = { _ in throw URLError(.notConnectedToInternet) }
        do {
            _ = try await resolver.partnerCheckinID(dateLocal: "2026-06-11")
            XCTFail("オフラインで成功してしまった")
        } catch {
            XCTAssertEqual(error as? NudgeReactClientError, .network)
        }
    }

    func testNotSignedInThrowsWithoutRequest() async throws {
        let resolver = PostgRESTPartnerCheckinResolver(
            baseURL: baseURL,
            apiKey: "k",
            tokenProvider: tokenProvider,
            currentUserID: { nil },
            session: makeSession()
        )
        do {
            _ = try await resolver.partnerCheckinID(dateLocal: "2026-06-11")
            XCTFail("未サインインで成功してしまった")
        } catch {
            XCTAssertEqual(error as? AuthServiceError, .notSignedIn)
        }
        XCTAssertTrue(StubURLProtocol.captured.isEmpty)
    }
}

// MARK: - LiveNudgeReactService(ホームの NudgeSending / Reacting)

private final class MockNudgeReactAPI: NudgeReactAPIClient {
    private(set) var nudgeStamps: [String] = []
    private(set) var reactCalls: [(checkinID: String, stamp: String)] = []
    var nudgeError: Error?
    var reactError: Error?

    func nudge(stamp: String) async throws -> NudgeResponse {
        nudgeStamps.append(stamp)
        if let nudgeError { throw nudgeError }
        return NudgeResponse(remainingToday: 2, snapshot: SnapshotFactory.paired())
    }

    func react(checkinID: String, stamp: String) async throws -> ReactResponse {
        reactCalls.append((checkinID, stamp))
        if let reactError { throw reactError }
        return ReactResponse(changed: true)
    }
}

private final class MockResolver: PartnerCheckinResolving {
    var checkinID: String?
    var error: Error?
    private(set) var requestedDates: [String] = []

    func partnerCheckinID(dateLocal: String) async throws -> String? {
        requestedDates.append(dateLocal)
        if let error { throw error }
        return checkinID
    }
}

final class LiveNudgeReactServiceTests: XCTestCase {
    /// 2026-06-11T08:30:00Z = 日本時間 2026-06-11 17:30、UTC 2026-06-11
    private let fixedNow = Date(timeIntervalSince1970: 1_781_166_600)

    private func makeService(
        api: MockNudgeReactAPI,
        resolver: MockResolver,
        timeZone: String = "Asia/Tokyo"
    ) -> LiveNudgeReactService {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: timeZone) ?? .current
        return LiveNudgeReactService(
            api: api,
            partnerCheckins: resolver,
            now: { [fixedNow] in fixedNow },
            calendar: calendar
        )
    }

    func testSendNudgePassesStampRawValue() async throws {
        let api = MockNudgeReactAPI()
        let service = makeService(api: api, resolver: MockResolver())
        try await service.sendNudge(stamp: .clock)
        XCTAssertEqual(api.nudgeStamps, ["⏰"])
    }

    func testNudgeLimitMapsToLimitReached() async throws {
        let api = MockNudgeReactAPI()
        api.nudgeError = NudgeReactClientError.nudgeLimitExceeded
        let service = makeService(api: api, resolver: MockResolver())
        do {
            try await service.sendNudge(stamp: .wave)
            XCTFail("上限超過で成功してしまった")
        } catch {
            XCTAssertEqual(error as? NudgeSendError, .limitReached)
        }
    }

    func testOtherNudgeFailuresMapToOther() async throws {
        let api = MockNudgeReactAPI()
        api.nudgeError = NudgeReactClientError.network
        let service = makeService(api: api, resolver: MockResolver())
        do {
            try await service.sendNudge(stamp: .wave)
            XCTFail("失敗で成功してしまった")
        } catch {
            XCTAssertEqual(error as? NudgeSendError, .other)
        }

        api.nudgeError = AuthServiceError.notSignedIn // トークン取得の失敗なども一般失敗
        do {
            try await service.sendNudge(stamp: .wave)
            XCTFail("失敗で成功してしまった")
        } catch {
            XCTAssertEqual(error as? NudgeSendError, .other)
        }
    }

    func testReactionResolvesPartnersCheckinForTodayInDeviceTimeZone() async throws {
        let api = MockNudgeReactAPI()
        let resolver = MockResolver()
        resolver.checkinID = "8c2b7e5a-0d3f-4b61-9a47-2e1f5c6d7a80"
        let service = makeService(api: api, resolver: resolver, timeZone: "Asia/Tokyo")

        try await service.sendReaction(stamp: .fire)

        XCTAssertEqual(resolver.requestedDates, ["2026-06-11"])
        XCTAssertEqual(api.reactCalls.count, 1)
        XCTAssertEqual(api.reactCalls.first?.checkinID, "8c2b7e5a-0d3f-4b61-9a47-2e1f5c6d7a80")
        XCTAssertEqual(api.reactCalls.first?.stamp, "🔥")
    }

    func testReactionUsesLocalDateAcrossMidnight() async throws {
        // UTC では 6/11 でも、ホノルル(UTC-10)では 6/10 22:30 → 端末ローカルの「今日」は 6/10
        let api = MockNudgeReactAPI()
        let resolver = MockResolver()
        resolver.checkinID = "x"
        let service = makeService(api: api, resolver: resolver, timeZone: "Pacific/Honolulu")
        try await service.sendReaction(stamp: .heart)
        XCTAssertEqual(resolver.requestedDates, ["2026-06-10"])
    }

    func testReactionWithoutPartnerCheckinFailsWithoutCallingReact() async throws {
        let api = MockNudgeReactAPI()
        let resolver = MockResolver()
        resolver.checkinID = nil
        let service = makeService(api: api, resolver: resolver)
        do {
            try await service.sendReaction(stamp: .clap)
            XCTFail("対象が無いのに成功してしまった")
        } catch {
            XCTAssertEqual(error as? NudgeReactClientError, .checkinNotFound)
        }
        XCTAssertTrue(api.reactCalls.isEmpty)
    }

    // MARK: HomeViewModel への明示注入(Live 構成)

    private final class PlainCheckinService: CheckinPerforming {
        func performCheckin(current: PairSnapshot) async throws -> PairSnapshot { current }
    }

    @MainActor
    func testHomeViewModelUsesInjectedLiveServicesEvenWhenCheckinServiceHasNoCapability() async throws {
        let temp = TempStore()
        defer { temp.cleanup() }
        try temp.store.saveSnapshot(SnapshotFactory.paired(todayPartnerDone: false))
        let api = MockNudgeReactAPI()
        api.nudgeError = NudgeReactClientError.nudgeLimitExceeded
        let live = makeService(api: api, resolver: MockResolver())
        let vm = HomeViewModel(
            store: temp.store,
            checkinService: PlainCheckinService(),
            nudgeService: live,
            reactionService: live,
            reloadWidgets: {}
        )
        vm.load()

        XCTAssertTrue(vm.canNudge, "明示注入した Live サービスで能力が有効になる")
        await vm.sendNudge(stamp: .wave)
        XCTAssertEqual(vm.nudgeErrorMessage, Strings.Nudge.limitReachedMessage, "上限超過は専用文言")
    }
}
