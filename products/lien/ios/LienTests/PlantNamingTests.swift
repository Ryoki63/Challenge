// PlantNamingTests.swift — 植物の名前付け(issue #57 / docs/GROWTH.md §5.3 / DESIGN §5.3 plant-name)
//
// 検証対象:
//   - 入力の検査(PlantNameRules): サーバーの normalizePlantName と同じ規則。NFC に正規化して Unicode コードポイントで 1〜8字
//     (`String.count` ではない)/ ZWJ だけ許す書式文字 / 制御文字・ゼロ幅・双方向制御・見える文字が無い名前は不可
//   - Live クライアント(EdgeFunctionPlantNaming): リクエストの形・契約フィクスチャの応答・エラー文字列のマップ・
//     first の 409 の扱い(**自分が送った名前と同じなら成功 / 違えば相手が先に付けたその名前を採用**)
//   - スタブ(Config 未設定のアプリ実行)がサーバーと同じ規則で動く
//   - フォームの状態(PlantNamingModel): 検査の表示・保存・相手が先だったとき・失敗しても下書きが残る

import XCTest
@testable import Lien

// MARK: - 入力の検査

final class PlantNameRulesTests: XCTestCase {
    func testPlainNamesAreAccepted() {
        for name in ["みどり", "ゆうき", "Aki", "🌱", "🌱はな", "あお ば", "ふたりのタネ!", "あ"] {
            XCTAssertNil(PlantNameRules.validate(name), name)
        }
    }

    func testEmptyAndWhitespaceOnlyNamesAreEmpty() {
        for name in ["", " ", "   ", "\n", "\t \n", "\u{3000}"] {
            XCTAssertEqual(PlantNameRules.validate(name), .empty, "\(name.unicodeScalars.map(\.value))")
        }
    }

    func testTrimsTheEdgesAndKeepsInnerSpaces() {
        XCTAssertEqual(PlantNameRules.normalized("  みどり  "), "みどり")
        XCTAssertEqual(PlantNameRules.normalized("\nみどり\n"), "みどり", "前後の改行は除く")
        XCTAssertNil(PlantNameRules.validate("\nみどり\n"), "前後の改行を除けば使える")
        XCTAssertEqual(PlantNameRules.normalized("あお ば"), "あお ば", "途中の空白は残す")
    }

    // MARK: 長さ(Unicode コードポイント数。String.count ではない)

    func testLimitIsEightUnicodeScalars() {
        XCTAssertEqual(PlantNameRules.maxLength, 8)
        XCTAssertNil(PlantNameRules.validate("あいうえおかきく"), "8字")
        XCTAssertEqual(PlantNameRules.validate("あいうえおかきくけ"), .tooLong, "9字")
    }

    func testLengthIsCountedAfterNFCNormalization() {
        // 「が」の分解形(か + 濁点 U+3099)は2コードポイントだが、NFC で1つ。8個並べても 8字(分解のままなら 16字)
        let decomposed = String(repeating: "か\u{3099}", count: 8)
        XCTAssertEqual(decomposed.unicodeScalars.count, 16)
        XCTAssertNil(PlantNameRules.validate(decomposed))
        // Swift の String の == は正準等価を同じとみなすので、コードポイントの並びで確かめる
        XCTAssertEqual(
            PlantNameRules.normalized(decomposed).unicodeScalars.map(\.value),
            Array(repeating: 0x304C, count: 8),
            "送る名前は NFC(「が」は1コードポイント)"
        )
        XCTAssertEqual(PlantNameRules.validate(String(repeating: "か\u{3099}", count: 9)), .tooLong)
    }

    func testLengthIsNotTheGraphemeClusterCount() {
        // 虹の旗「🏳️‍🌈」は String.count = 1 だが、サーバーは 4 コードポイント(🏳 + VS16 + ZWJ + 🌈)と数える
        let rainbow = "🏳️‍🌈"
        XCTAssertEqual(rainbow.count, 1)
        XCTAssertEqual(rainbow.unicodeScalars.count, 4)
        XCTAssertNil(PlantNameRules.validate(rainbow))
        XCTAssertNil(PlantNameRules.validate(rainbow + rainbow), "8コードポイント")
        XCTAssertEqual(PlantNameRules.validate(rainbow + rainbow + rainbow), .tooLong, "count は 3 だが、12コードポイント")

        // 家族の絵文字(👨‍👩‍👧‍👦 = 4つの絵文字 + ZWJ 3つ = 7コードポイント)
        let family = "👨‍👩‍👧‍👦"
        XCTAssertEqual(family.count, 1)
        XCTAssertEqual(family.unicodeScalars.count, 7)
        XCTAssertNil(PlantNameRules.validate(family))
        XCTAssertEqual(PlantNameRules.validate(family + "あい"), .tooLong, "9コードポイント")
    }

    func testEmojiVariationSelectorIsAllowedAndCounts() {
        // 「❤️」は ❤ + VS16(U+FE0F)の2コードポイント。VS16 は書式文字でなく結合記号なので通る
        let heart = "❤️"
        XCTAssertEqual(heart.unicodeScalars.count, 2)
        XCTAssertNil(PlantNameRules.validate(heart))
        XCTAssertNil(PlantNameRules.validate(String(repeating: heart, count: 4)), "8コードポイント")
        XCTAssertEqual(PlantNameRules.validate(String(repeating: heart, count: 5)), .tooLong)
    }

    // MARK: 使えない文字

    func testControlAndSeparatorCharactersAreRejected() {
        let rejected: [(String, String)] = [
            ("あ\nい", "改行"),
            ("あ\r\nい", "CRLF"),
            ("あ\tい", "タブ"),
            ("あ\u{0}い", "NUL"),
            ("あ\u{7F}い", "DEL"),
            ("あ\u{85}い", "NEL(C1 制御)"),
            ("あ\u{2028}い", "行区切り"),
            ("あ\u{2029}い", "段落区切り"),
        ]
        for (name, label) in rejected {
            XCTAssertEqual(PlantNameRules.validate(name), .invalidCharacter, label)
        }
    }

    func testFormatCharactersExceptZWJAreRejected() {
        let rejected: [(String, String)] = [
            ("あ\u{202E}い", "右から左への上書き(U+202E)— 相手の画面で別の名前に見せかけられる"),
            ("あ\u{202A}い", "U+202A"),
            ("あ\u{2066}い", "U+2066(分離)"),
            ("あ\u{200B}い", "ゼロ幅スペース"),
            ("あ\u{200C}い", "ZWNJ"),
            ("あ\u{200E}い", "LRM"),
            ("あ\u{2060}い", "語結合子"),
            ("あ\u{FEFF}い", "BOM(途中)"),
            ("あ\u{00AD}い", "ソフトハイフン"),
        ]
        for (name, label) in rejected {
            XCTAssertEqual(PlantNameRules.validate(name), .invalidCharacter, label)
        }
    }

    func testNamesWithoutAVisibleCharacterAreRejected() {
        // 空白・ZWJ だけの名前は、見える文字が1つも無い
        XCTAssertEqual(PlantNameRules.validate("\u{200D}"), .invalidCharacter)
        XCTAssertEqual(PlantNameRules.validate("\u{200D}\u{200D}"), .invalidCharacter)
        XCTAssertEqual(PlantNameRules.validate(" \u{200D} "), .invalidCharacter, "前後の空白を除いても ZWJ だけ")
    }

    func testTooLongIsReportedBeforeInvalidCharacters() {
        // サーバーも、長さを先に見る(どちらも 400 invalid_name)
        XCTAssertEqual(PlantNameRules.validate("あいうえおかきくけ\n"), .tooLong)
    }
}

// MARK: - 409 の読み方

final class PlantNameConflictTests: XCTestCase {
    func testSameNameMeansMyOwnResend() {
        XCTAssertEqual(PlantNameConflict.resolveFirst(sent: "みどり", current: "みどり"), .saved(name: "みどり"))
    }

    func testDifferentNameMeansThePartnerNamedItFirst() {
        XCTAssertEqual(PlantNameConflict.resolveFirst(sent: "あおば", current: "みどり"), .adopted(name: "みどり"))
    }

    func testComparisonUsesTheNormalizedForms() {
        // 自分が送った名前は NFC に整えてから送るので、整える前の違い(分解形・前後の空白)で別の名前と見ない
        XCTAssertEqual(
            PlantNameConflict.resolveFirst(sent: " か\u{3099}き ", current: "\u{304C}き"),
            .saved(name: "\u{304C}き")
        )
    }
}

// MARK: - Live クライアント

final class EdgeFunctionPlantNamingTests: XCTestCase {
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
    ) -> EdgeFunctionPlantNaming {
        EdgeFunctionPlantNaming(baseURL: baseURL, tokenProvider: token, session: StubURLProtocol.makeSession())
    }

    private func respond(status: Int, fixture: String) throws {
        let body = try ContractFixtures.data(fixture)
        StubURLProtocol.handler = { _ in (status, body) }
    }

    private func respond(status: Int, json: String) {
        StubURLProtocol.handler = { _ in (status, Data(json.utf8)) }
    }

    // MARK: リクエストの形と成功

    func testFirstPostsTheNameAndModeAndReturnsTheSavedName() async throws {
        try respond(status: 200, fixture: "plant-name.ok")

        let outcome = try await makeClient().setName("みどり", mode: .first)

        XCTAssertEqual(outcome, .saved(name: "みどり"))
        let request = try XCTUnwrap(StubURLProtocol.captured.first)
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.url?.absoluteString, "https://example.supabase.co/functions/v1/plant-name")
        XCTAssertEqual(request.header("Authorization"), "Bearer jwt-123")
        XCTAssertEqual(request.header("Content-Type"), "application/json")
        XCTAssertEqual(request.jsonObject?["name"] as? String, "みどり")
        XCTAssertEqual(request.jsonObject?["mode"] as? String, "first")
        XCTAssertEqual(request.jsonObject?.count, 2, "pairId は入力に取らない(JWT から引く)")
        XCTAssertEqual(request.request.timeoutInterval, EdgeFunctionPlantNaming.requestTimeout)
    }

    func testRenameSendsRenameMode() async throws {
        try respond(status: 200, fixture: "plant-name.ok")
        _ = try await makeClient().setName("みどり", mode: .rename)
        let request = try XCTUnwrap(StubURLProtocol.captured.first)
        XCTAssertEqual(request.jsonObject?["mode"] as? String, "rename")
    }

    func testTheNameIsSentTrimmedAndNFCNormalized() async throws {
        try respond(status: 200, fixture: "plant-name.ok")

        _ = try await makeClient().setName("  か\u{3099}き  ", mode: .first)

        let request = try XCTUnwrap(StubURLProtocol.captured.first)
        let sent = try XCTUnwrap(request.jsonObject?["name"] as? String)
        // String の == は正準等価を同じとみなすので、コードポイントの並び(NFC の「が」「き」= 2つ)で確かめる
        XCTAssertEqual(sent.unicodeScalars.map(\.value), [0x304C, 0x304D], "サーバーと同じ整え方で送る(字数の数え違いを作らない)")
    }

    func testInvalidNamesAreRejectedWithoutTouchingTheNetwork() async {
        let client = makeClient()
        for name in ["", "あいうえおかきくけ", "あ\nい", "あ\u{200B}い"] {
            do {
                _ = try await client.setName(name, mode: .first)
                XCTFail("使えない名前で成功してしまった: \(name.debugDescription)")
            } catch {
                XCTAssertEqual(error as? PlantNameClientError, .invalidName)
            }
        }
        XCTAssertEqual(StubURLProtocol.captured.count, 0, "通信の前に弾く")
    }

    // MARK: 409 already_named(first)

    func testAlreadyNamedWithTheSameNameIsMyOwnResendAndSucceeds() async throws {
        // 通信失敗のあとの再試行: すでに自分の名前が入っているので 409 が返る(契約フィクスチャ = 名前は「みどり」)
        try respond(status: 409, fixture: "plant-name.already-named")

        let outcome = try await makeClient().setName("みどり", mode: .first)

        XCTAssertEqual(outcome, .saved(name: "みどり"), "409 の name が自分の送った名前と同じなら、成功として扱う")
    }

    func testAlreadyNamedWithADifferentNameMeansThePartnerWasFirst() async throws {
        try respond(status: 409, fixture: "plant-name.already-named")

        let outcome = try await makeClient().setName("あおば", mode: .first)

        XCTAssertEqual(outcome, .adopted(name: "みどり"), "違えば相手が先に付けた: その名前に決まる")
    }

    func testAlreadyNamedIsAnErrorForRenameOrWithoutAName() async {
        let client = makeClient()
        respond(status: 409, json: #"{"error":"already_named","name":"みどり"}"#)
        do {
            _ = try await client.setName("みどり", mode: .rename) // rename は 409 already_named にならない(サーバーの仕様外)
            XCTFail("成功してしまった")
        } catch {
            XCTAssertEqual(error as? PlantNameClientError, .server(code: "already_named"))
        }

        respond(status: 409, json: #"{"error":"already_named"}"#) // 名前が無い本文(仕様外)
        do {
            _ = try await client.setName("みどり", mode: .first)
            XCTFail("成功してしまった")
        } catch {
            XCTAssertEqual(error as? PlantNameClientError, .server(code: "already_named"))
        }
    }

    // MARK: エラー文字列

    func testServerErrorCodesMapToClientErrors() async {
        let table: [(status: Int, code: String, expected: PlantNameClientError)] = [
            (400, "invalid_name", .invalidName),
            (409, "no_pair", .noPair),
            (404, "plant_not_found", .plantNotFound),
            (404, "user_not_found", .userNotFound),
            (401, "unauthorized", .unauthorized),
            (400, "invalid_mode", .server(code: "invalid_mode")),
            (400, "invalid_json", .server(code: "invalid_json")),
            (405, "method_not_allowed", .server(code: "method_not_allowed")),
            (500, "internal_error", .server(code: "internal_error")),
        ]
        for entry in table {
            let client = makeClient()
            respond(status: entry.status, json: #"{"error":"\#(entry.code)"}"#)
            do {
                _ = try await client.setName("みどり", mode: .first)
                XCTFail("\(entry.code) で成功してしまった")
            } catch {
                XCTAssertEqual(error as? PlantNameClientError, entry.expected, entry.code)
            }
        }
    }

    func testNonJSONErrorBodyIsAGenericServerError() async {
        respond(status: 502, json: "<html>Bad Gateway</html>")
        do {
            _ = try await makeClient().setName("みどり", mode: .first)
            XCTFail("成功してしまった")
        } catch {
            XCTAssertEqual(error as? PlantNameClientError, .server(code: "http_502"))
        }
    }

    func testBrokenSuccessBodyIsAnInvalidResponseError() async {
        respond(status: 200, json: #"{"name":"みどり"}"#) // snapshot が無い
        do {
            _ = try await makeClient().setName("みどり", mode: .first)
            XCTFail("成功してしまった")
        } catch {
            XCTAssertEqual(error as? PlantNameClientError, .server(code: "invalid_response"))
        }
    }

    func testNetworkFailureMapsToNetworkError() async {
        StubURLProtocol.handler = { _ in throw URLError(.notConnectedToInternet) }
        do {
            _ = try await makeClient().setName("みどり", mode: .first)
            XCTFail("オフラインで成功してしまった")
        } catch {
            XCTAssertEqual(error as? PlantNameClientError, .network)
        }
    }

    func testTokenFailureIsNotMistakenForANetworkFailure() async {
        let client = makeClient(token: { throw AuthServiceError.notSignedIn })
        do {
            _ = try await client.setName("みどり", mode: .first)
            XCTFail("未サインインで成功してしまった")
        } catch {
            XCTAssertEqual(error as? AuthServiceError, .notSignedIn, "トークン取得の失敗は、そのまま投げる(通信エラーにしない)")
        }
        XCTAssertEqual(StubURLProtocol.captured.count, 0)
    }

    // MARK: 契約フィクスチャ

    func testContractFixturesDecode() throws {
        let ok = try ContractFixtures.decode(PlantNameResponse.self, from: "plant-name.ok")
        XCTAssertEqual(ok.name, "みどり")
        XCTAssertEqual(ok.snapshot.plantName, "みどり", "応答の snapshot は呼び出し本人視点(plantName が入る)")
        XCTAssertNotNil(ok.snapshot.pairId)

        let conflict = try ContractFixtures.decode(PlantNameConflictResponse.self, from: "plant-name.already-named")
        XCTAssertEqual(conflict.error, "already_named")
        XCTAssertEqual(conflict.name, "みどり", "409 の本文には今の名前が入っている(誰が付けたかは入っていない)")
    }

    func testInterpretReadsTheFixturesWithoutTheNetwork() throws {
        let ok = try ContractFixtures.data("plant-name.ok")
        XCTAssertEqual(
            try EdgeFunctionPlantNaming.interpret(status: 200, data: ok, sent: "みどり", mode: .first),
            .saved(name: "みどり")
        )
        let conflict = try ContractFixtures.data("plant-name.already-named")
        XCTAssertEqual(
            try EdgeFunctionPlantNaming.interpret(status: 409, data: conflict, sent: "みどり", mode: .first),
            .saved(name: "みどり")
        )
        XCTAssertEqual(
            try EdgeFunctionPlantNaming.interpret(status: 409, data: conflict, sent: "ほかの名前", mode: .first),
            .adopted(name: "みどり")
        )
    }
}

// MARK: - スタブ

final class StubPlantNamingTests: XCTestCase {
    private func makeStore(_ snapshot: PairSnapshot?) -> TempStore {
        let temp = TempStore()
        if let snapshot { try? temp.store.saveSnapshot(snapshot) }
        return temp
    }

    func testStubFollowsTheServerRules() async throws {
        // ペアが無い(ソロ・snapshot なし)→ no_pair
        for snapshot in [SnapshotFactory.solo(), nil] {
            let temp = makeStore(snapshot)
            defer { temp.cleanup() }
            do {
                _ = try await StubPlantNaming(store: temp.store).setName("みどり", mode: .first)
                XCTFail("ペアが無いのに成功してしまった")
            } catch {
                XCTAssertEqual(error as? PlantNameClientError, .noPair)
            }
        }

        // 名前がまだ無い: first は保存できる
        var paired = SnapshotFactory.paired()
        paired.plantName = nil
        let temp = makeStore(paired)
        defer { temp.cleanup() }
        let stub = StubPlantNaming(store: temp.store)
        let trimmed = try await stub.setName(" みどり ", mode: .first)
        XCTAssertEqual(trimmed, .saved(name: "みどり"), "整えた名前が返る")
        let renamed = try await stub.setName("あおば", mode: .rename)
        XCTAssertEqual(renamed, .saved(name: "あおば"), "rename は上書き")
    }

    func testStubFirstWithAnExistingNameResolvesLikeTheServer() async throws {
        let temp = makeStore(SnapshotFactory.paired()) // 名前は「みどり」
        defer { temp.cleanup() }
        let stub = StubPlantNaming(store: temp.store)

        let resent = try await stub.setName("みどり", mode: .first)

        XCTAssertEqual(resent, .saved(name: "みどり"), "同じ名前 = 自分の再送")
        let adoptedOutcome = try await stub.setName("あおば", mode: .first)
        XCTAssertEqual(adoptedOutcome, .adopted(name: "みどり"), "違えば、すでにある名前に決まる")
    }

    func testStubRejectsInvalidNames() async throws {
        let temp = makeStore(SnapshotFactory.paired())
        defer { temp.cleanup() }
        do {
            _ = try await StubPlantNaming(store: temp.store).setName("あいうえおかきくけ", mode: .rename)
            XCTFail("9字で成功してしまった")
        } catch {
            XCTAssertEqual(error as? PlantNameClientError, .invalidName)
        }
    }
}

// MARK: - フォームの状態

private final class MockPlantNaming: PlantNaming {
    private(set) var calls: [(name: String, mode: PlantNameMode)] = []
    var result: Result<PlantNameOutcome, Error> = .success(.saved(name: "みどり"))
    /// 設定すると、結果を返す前に待つ(保存中の状態を観測する)
    var gate: AsyncGate?

    func setName(_ name: String, mode: PlantNameMode) async throws -> PlantNameOutcome {
        calls.append((name, mode))
        if let gate { await gate.wait() }
        return try result.get()
    }
}

@MainActor
final class PlantNamingModelTests: XCTestCase {
    private func makeModel(_ naming: MockPlantNaming = MockPlantNaming()) -> (
        model: PlantNamingModel, naming: MockPlantNaming, applied: () -> [PlantNameApplication]
    ) {
        var applied: [PlantNameApplication] = []
        let model = PlantNamingModel(naming: naming)
        model.onApply = { applied.append($0) }
        return (model, naming, { applied })
    }

    // MARK: 検査の表示

    func testValidationMessagesAppearOnlyAfterTyping() {
        let (model, _, _) = makeModel()
        model.begin(mode: .first, currentName: nil)

        XCTAssertNil(model.validationMessage, "空のままは、エラーでなく、ボタンが押せないだけ")
        XCTAssertFalse(model.canSubmit)

        model.draft = "あいうえおかきくけ"
        XCTAssertEqual(model.validationMessage, Strings.Plant.nameTooLongError)
        XCTAssertFalse(model.canSubmit)

        model.draft = "あ\nい"
        XCTAssertEqual(model.validationMessage, Strings.Plant.nameInvalidError)
        XCTAssertFalse(model.canSubmit)

        model.draft = "   "
        XCTAssertEqual(model.validationMessage, Strings.Plant.nameEmptyError, "空白だけは、打ち始めたあとなら空と同じに知らせる")

        model.draft = "みどり"
        XCTAssertNil(model.validationMessage)
        XCTAssertTrue(model.canSubmit)
    }

    // MARK: 開く

    func testBeginResetsTheStateAndPrefillsTheCurrentNameOnRename() {
        let (model, _, _) = makeModel()
        model.draft = "ごみ"
        model.begin(mode: .rename, currentName: "みどり")
        XCTAssertEqual(model.mode, .rename)
        XCTAssertEqual(model.draft, "みどり", "変えるときは、今の名前から始める")
        XCTAssertNil(model.errorMessage)
        XCTAssertNil(model.resultNote)
        XCTAssertFalse(model.didSave)

        model.begin(mode: .first, currentName: "みどり")
        XCTAssertEqual(model.draft, "", "最初に付けるときは、空から")

        model.presentSheet(mode: .rename, currentName: "あおば")
        XCTAssertTrue(model.isSheetPresented)
        XCTAssertEqual(model.draft, "あおば")
    }

    // MARK: 送る

    func testSubmitSavesAndAppliesTheName() async {
        let (model, naming, applied) = makeModel()
        model.presentSheet(mode: .first, currentName: nil)
        model.draft = "みどり"

        let saved = await model.submit()

        XCTAssertTrue(saved)
        XCTAssertEqual(naming.calls.count, 1)
        XCTAssertEqual(naming.calls.first?.name, "みどり")
        XCTAssertEqual(naming.calls.first?.mode, .first)
        XCTAssertEqual(applied(), [.saved(name: "みどり")])
        XCTAssertEqual(model.resultNote, "『みどり』と名づけたよ")
        XCTAssertTrue(model.didSave)
        XCTAssertFalse(model.isSaving)
        XCTAssertFalse(model.isSheetPresented, "保存できたらシートを閉じる")
        XCTAssertNil(model.errorMessage)
    }

    func testSubmitInRenameModeSendsRename() async {
        let (model, naming, applied) = makeModel()
        model.begin(mode: .rename, currentName: "みどり")
        model.draft = "あおば"
        naming.result = .success(.saved(name: "あおば"))

        let saved = await model.submit()

        XCTAssertTrue(saved)

        XCTAssertEqual(naming.calls.first?.mode, .rename)
        XCTAssertEqual(applied(), [.saved(name: "あおば")])
    }

    func testPartnerNamedFirstAdoptsTheirNameAndTellsMe() async {
        // 先に付けた人の名前に決まる: 自分の入力は使われず、決まった名前を知らせる
        let (model, naming, applied) = makeModel()
        naming.result = .success(.adopted(name: "きいろ"))
        model.begin(mode: .first, currentName: nil)
        model.draft = "みどり"

        let saved = await model.submit()

        XCTAssertTrue(saved)

        XCTAssertEqual(applied(), [.adopted(name: "きいろ")])
        XCTAssertEqual(model.resultNote, "名前は『きいろ』になったよ")
        XCTAssertTrue(model.didSave)
    }

    func testFailureKeepsTheDraftAndAllowsRetry() async {
        let (model, naming, applied) = makeModel()
        naming.result = .failure(PlantNameClientError.network)
        model.begin(mode: .first, currentName: nil)
        model.draft = "みどり"

        let didSave = await model.submit()

        XCTAssertFalse(didSave)

        XCTAssertEqual(model.errorMessage, Strings.Plant.nameSaveError, "責めない文言")
        XCTAssertEqual(model.draft, "みどり", "下書きは残る")
        XCTAssertFalse(model.didSave)
        XCTAssertNil(model.resultNote)
        XCTAssertTrue(applied().isEmpty)
        XCTAssertTrue(model.canSubmit, "やり直せる")

        naming.result = .success(.saved(name: "みどり"))
        let retried = await model.submit()
        XCTAssertTrue(retried)
        XCTAssertNil(model.errorMessage, "成功したら、前のエラーは消える")
        XCTAssertEqual(applied(), [.saved(name: "みどり")])
    }

    func testErrorMessagesAreMappedGently() {
        XCTAssertEqual(PlantNamingModel.message(for: PlantNameClientError.invalidName), Strings.Plant.nameInvalidError)
        XCTAssertEqual(PlantNamingModel.message(for: PlantNameClientError.noPair), Strings.Plant.nameNoPairError)
        let others: [Error] = [
            PlantNameClientError.network, PlantNameClientError.unauthorized, PlantNameClientError.userNotFound,
            PlantNameClientError.plantNotFound, PlantNameClientError.server(code: "internal_error"),
            AuthServiceError.notSignedIn,
        ]
        for error in others {
            XCTAssertEqual(PlantNamingModel.message(for: error), Strings.Plant.nameSaveError)
        }
    }

    func testSubmitDoesNothingWhenTheDraftIsInvalidOrAlreadySaving() async {
        let (model, naming, _) = makeModel()
        model.begin(mode: .first, currentName: nil)
        let emptyResult = await model.submit()
        XCTAssertFalse(emptyResult, "空では送らない")
        model.draft = "あいうえおかきくけ"
        let tooLongResult = await model.submit()
        XCTAssertFalse(tooLongResult, "9字では送らない")
        XCTAssertTrue(naming.calls.isEmpty)

        // 保存中の二重送信
        let gate = AsyncGate()
        naming.gate = gate
        model.draft = "みどり"
        let first = Task { await model.submit() }
        await waitUntil { naming.calls.count == 1 }
        XCTAssertTrue(model.isSaving)
        XCTAssertFalse(model.canSubmit, "保存中は押せない")
        let secondResult = await model.submit()
        XCTAssertFalse(secondResult)
        gate.open()
        let firstResult = await first.value
        XCTAssertTrue(firstResult)
        XCTAssertEqual(naming.calls.count, 1)
    }
}
