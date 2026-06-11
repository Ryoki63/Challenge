// PairingViewModelTests.swift — 招待画面 VM の主要パス(T11。モック注入で CI 完結)
//
// 実 invite-create / invite-accept との疎通は Functions デプロイ(G0)後+T20 の実機 E2E で
// 検証する。ここではエラーコードのマッピング(invite-create/core.ts・invite-accept/core.ts の
// error 文字列と一致)とレスポンス JSON の契約整合を固定する。

import XCTest
@testable import Lien

// MARK: - モック
// トップレベルに置き、テストクラスの @MainActor 隔離を継承させない(InviteClient は非隔離)

private final class MockInviteClient: InviteClient {
    var createCallCount = 0
    var acceptCallCount = 0
    var createResult: Result<InviteCreateResponse, Error> =
        .failure(InviteClientError.network)
    var acceptResult: Result<InviteAcceptResponse, Error> =
        .failure(InviteClientError.network)
    private(set) var lastAcceptedToken: String?

    func createInvite() async throws -> InviteCreateResponse {
        createCallCount += 1
        return try createResult.get()
    }

    func acceptInvite(token: String) async throws -> InviteAcceptResponse {
        acceptCallCount += 1
        lastAcceptedToken = token
        return try acceptResult.get()
    }
}

// MARK: - テスト本体

@MainActor
final class PairingViewModelTests: XCTestCase {
    private func makeViewModel(
        client: MockInviteClient,
        store: AppGroupStore? = nil,
        onPaired: @escaping () -> Void = {}
    ) -> PairingViewModel {
        PairingViewModel(inviteClient: client, store: store, onPaired: onPaired)
    }

    private func makeInvite(token: String = "AbCd2345") -> InviteCreateResponse {
        InviteCreateResponse(
            token: token,
            appUrl: "lien://invite/\(token)",
            webUrl: "https://ryoki63.github.io/Challenge/lien/i/?t=\(token)",
            expiresAt: Date(timeIntervalSince1970: 1_781_425_800) // 2026-06-14T08:30:00Z
        )
    }

    private func makeAcceptResponse(pairId: String) -> InviteAcceptResponse {
        InviteAcceptResponse(pairId: pairId, snapshot: makeSnapshot(pairId: pairId))
    }

    private func makeSnapshot(pairId: String?) -> PairSnapshot {
        PairSnapshot(
            schemaVersion: PairSnapshot.currentSchemaVersion,
            pairId: pairId,
            updatedAt: Date(timeIntervalSince1970: 1_781_166_600), // 2026-06-11T08:30:00Z
            streakCurrent: 0,
            streakBest: 0,
            todayMeDone: false,
            todayPartnerDone: false,
            myPromiseTitle: nil,
            myPromiseEmoji: nil,
            partnerName: "ゆうき",
            partnerPromiseTitle: nil,
            partnerPromiseEmoji: nil,
            plantStage: 0,
            plantMood: .normal,
            plantName: nil,
            hasPartnerPhotoToday: false
        )
    }

    // MARK: 発行

    func testIssueInviteSuccessHoldsResponse() async {
        let client = MockInviteClient()
        let invite = makeInvite()
        client.createResult = .success(invite)
        let vm = makeViewModel(client: client)

        await vm.issueInvite()

        XCTAssertEqual(client.createCallCount, 1)
        XCTAssertEqual(vm.issuedInvite, invite)
        XCTAssertEqual(vm.issuedInvite?.appUrl, "lien://invite/AbCd2345")
        XCTAssertEqual(
            vm.issuedInvite?.webUrl,
            "https://ryoki63.github.io/Challenge/lien/i/?t=AbCd2345"
        )
        XCTAssertNil(vm.issueErrorMessage)
    }

    func testIssueInviteAlreadyPairedShowsMappedMessage() async {
        let client = MockInviteClient()
        client.createResult = .failure(InviteClientError.alreadyPaired)
        let vm = makeViewModel(client: client)

        await vm.issueInvite()

        XCTAssertNil(vm.issuedInvite)
        XCTAssertEqual(vm.issueState, .idle) // リトライ可能な状態に戻る
        XCTAssertEqual(vm.issueErrorMessage, Strings.Pairing.errorAlreadyPaired)
    }

    func testIssueInviteRetryAfterErrorRecovers() async {
        let client = MockInviteClient()
        client.createResult = .failure(InviteClientError.network)
        let vm = makeViewModel(client: client)

        await vm.issueInvite()
        XCTAssertEqual(vm.issueErrorMessage, Strings.Pairing.errorNetwork)

        client.createResult = .success(makeInvite())
        await vm.issueInvite()
        XCTAssertNotNil(vm.issuedInvite)
        XCTAssertNil(vm.issueErrorMessage)
    }

    // MARK: 受諾(コード入力)

    func testAcceptRejectsInvalidFormatWithoutCallingServer() async {
        let client = MockInviteClient()
        let vm = makeViewModel(client: client)

        for invalid in ["", "AbCd234", "AbCd23456", "AbCd234-", "AbCd 234"] {
            vm.codeInput = invalid
            XCTAssertFalse(vm.canAccept, "形式不正でも canAccept: \(invalid)")
            await vm.acceptInvite()
        }

        XCTAssertEqual(client.acceptCallCount, 0) // サーバーへ送らない
        XCTAssertEqual(vm.acceptErrorMessage, Strings.Pairing.errorInvalidTokenFormat)
    }

    func testAcceptTrimsWhitespaceBeforeSending() async {
        let client = MockInviteClient()
        client.acceptResult = .success(makeAcceptResponse(pairId: "p-1"))
        let vm = makeViewModel(client: client)

        vm.codeInput = "  AbCd2345\n"
        XCTAssertTrue(vm.canAccept)
        await vm.acceptInvite()

        XCTAssertEqual(client.lastAcceptedToken, "AbCd2345")
    }

    func testAcceptSuccessSavesSnapshotAndFinishesOnce() async throws {
        let pairId = "1f0c5a4e-9d3b-4c1a-8f2e-7b6d5a4c3b2a"
        let client = MockInviteClient()
        client.acceptResult = .success(makeAcceptResponse(pairId: pairId))

        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("PairingVMTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let store = AppGroupStore(containerURL: tempDir)

        var pairedCount = 0
        let vm = makeViewModel(client: client, store: store) { pairedCount += 1 }
        vm.codeInput = "AbCd2345"

        await vm.acceptInvite()

        XCTAssertEqual(pairedCount, 1)
        XCTAssertNil(vm.acceptErrorMessage)
        // snapshot が App Group(テストでは temp dir)へ保存されている
        XCTAssertEqual(store.loadSnapshot()?.pairId, pairId)

        // 2回目の受諾は何もしない(二重ペア成立防止)
        await vm.acceptInvite()
        XCTAssertEqual(pairedCount, 1)
        XCTAssertEqual(client.acceptCallCount, 1)
    }

    func testAcceptErrorMapsToUserMessage() async {
        // サーバーの error 文字列 → InviteClientError → 文言(出典: invite-accept/core.ts)
        let cases: [(InviteClientError, String)] = [
            (.inviteExpired, Strings.Pairing.errorInviteExpired),          // 410 invite_expired
            (.inviteAlreadyUsed, Strings.Pairing.errorInviteAlreadyUsed),  // 410 invite_already_used
            (.inviteNotFound, Strings.Pairing.errorInviteNotFound),        // 404 invite_not_found
            (.cannotAcceptOwnInvite, Strings.Pairing.errorCannotAcceptOwnInvite), // 400
            (.alreadyPaired, Strings.Pairing.errorAlreadyPaired),          // 409 already_paired
            (.partnerAlreadyPaired, Strings.Pairing.errorPartnerAlreadyPaired),   // 409
            (.invalidToken, Strings.Pairing.errorInvalidTokenFormat),      // 400 invalid_token
            (.userNotFound, Strings.Pairing.errorNetwork),                 // 404 user_not_found
            (.server(code: "internal_error"), Strings.Pairing.errorNetwork),
            (.network, Strings.Pairing.errorNetwork),
        ]
        for (error, expected) in cases {
            let client = MockInviteClient()
            client.acceptResult = .failure(error)
            var pairedCount = 0
            let vm = makeViewModel(client: client) { pairedCount += 1 }
            vm.codeInput = "AbCd2345"

            await vm.acceptInvite()

            XCTAssertEqual(vm.acceptErrorMessage, expected, "エラー: \(error)")
            XCTAssertEqual(pairedCount, 0)
        }
    }

    func testPrefillSetsCodeInputAndClearsError() async {
        let client = MockInviteClient()
        let vm = makeViewModel(client: client)
        vm.codeInput = "bad"
        await vm.acceptInvite() // 形式エラーを立てる
        XCTAssertNotNil(vm.acceptErrorMessage)

        vm.prefill(token: "AbCd2345")
        XCTAssertEqual(vm.codeInput, "AbCd2345")
        XCTAssertNil(vm.acceptErrorMessage)
        XCTAssertTrue(vm.canAccept)
    }

    // MARK: 契約整合(サーバー実装との突き合わせ)

    func testServerErrorCodeMapping() {
        // 文字列はサーバー実装からコピー(invite-create/core.ts / invite-accept/core.ts)
        XCTAssertEqual(InviteClientError(serverCode: "already_paired"), .alreadyPaired)
        XCTAssertEqual(InviteClientError(serverCode: "partner_already_paired"), .partnerAlreadyPaired)
        XCTAssertEqual(InviteClientError(serverCode: "invite_not_found"), .inviteNotFound)
        XCTAssertEqual(InviteClientError(serverCode: "invite_expired"), .inviteExpired)
        XCTAssertEqual(InviteClientError(serverCode: "invite_already_used"), .inviteAlreadyUsed)
        XCTAssertEqual(InviteClientError(serverCode: "cannot_accept_own_invite"), .cannotAcceptOwnInvite)
        XCTAssertEqual(InviteClientError(serverCode: "invalid_token"), .invalidToken)
        XCTAssertEqual(InviteClientError(serverCode: "user_not_found"), .userNotFound)
        // 未知のコードは .server に落ちる(将来サーバーがコードを足しても壊れない)
        XCTAssertEqual(
            InviteClientError(serverCode: "token_generation_failed"),
            .server(code: "token_generation_failed")
        )
    }

    func testInviteCreateResponseDecodesServerShapedJSON() throws {
        // invite-create/core.ts の 200 body と同形(expiresAt は Date.toISOString() の小数秒つき)
        let json = """
        {
          "token": "AbCd2345",
          "appUrl": "lien://invite/AbCd2345",
          "webUrl": "https://ryoki63.github.io/Challenge/lien/i/?t=AbCd2345",
          "expiresAt": "2026-06-14T08:30:00.000Z"
        }
        """
        let response = try PairSnapshot.makeJSONDecoder()
            .decode(InviteCreateResponse.self, from: Data(json.utf8))
        XCTAssertEqual(response.token, "AbCd2345")
        XCTAssertEqual(response.appUrl, "lien://invite/AbCd2345")
        XCTAssertEqual(response.webURL?.absoluteString, response.webUrl)
        XCTAssertEqual(response.expiresAt, Date(timeIntervalSince1970: 1_781_425_800))
    }

    func testInviteAcceptResponseDecodesServerShapedJSON() throws {
        // invite-accept/core.ts の 200 body と同形(snapshot は _shared/snapshot.ts の PairSnapshot)
        let json = """
        {
          "pairId": "1f0c5a4e-9d3b-4c1a-8f2e-7b6d5a4c3b2a",
          "snapshot": {
            "schemaVersion": 1,
            "pairId": "1f0c5a4e-9d3b-4c1a-8f2e-7b6d5a4c3b2a",
            "updatedAt": "2026-06-11T08:30:00.000Z",
            "streakCurrent": 0,
            "streakBest": 0,
            "todayMeDone": false,
            "todayPartnerDone": false,
            "myPromiseTitle": null,
            "myPromiseEmoji": null,
            "partnerName": "ゆうき",
            "partnerPromiseTitle": null,
            "partnerPromiseEmoji": null,
            "plantStage": 0,
            "plantMood": "normal",
            "plantName": null,
            "hasPartnerPhotoToday": false
          }
        }
        """
        let response = try PairSnapshot.makeJSONDecoder()
            .decode(InviteAcceptResponse.self, from: Data(json.utf8))
        XCTAssertEqual(response.pairId, "1f0c5a4e-9d3b-4c1a-8f2e-7b6d5a4c3b2a")
        XCTAssertEqual(response.snapshot.pairId, response.pairId)
        XCTAssertEqual(response.snapshot.partnerName, "ゆうき")
    }

    // MARK: スタブ(アプリ実行用)も契約形式を守ること

    func testStubInviteClientProducesValidInvite() async throws {
        let stub = StubInviteClient()
        let invite = try await stub.createInvite()
        XCTAssertTrue(InviteToken.isValidFormat(invite.token))
        XCTAssertEqual(invite.appUrl, "lien://invite/\(invite.token)")
        XCTAssertTrue(invite.webUrl.hasSuffix("/lien/i/?t=\(invite.token)"))
        XCTAssertGreaterThan(invite.expiresAt, Date())

        let accepted = try await stub.acceptInvite(token: invite.token)
        XCTAssertEqual(accepted.snapshot.pairId, accepted.pairId)

        do {
            _ = try await stub.acceptInvite(token: "bad")
            XCTFail("形式不正の token を受理してしまった")
        } catch {
            XCTAssertEqual(error as? InviteClientError, .invalidToken)
        }
    }
}
