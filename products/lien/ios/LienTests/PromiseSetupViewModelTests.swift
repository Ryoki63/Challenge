// PromiseSetupViewModelTests.swift — 約束設定 VM の主要パス(T12。モック注入で CI 完結)
//
// 実 promise-set との疎通は Functions デプロイ(G0)後+T20 の実機 E2E で検証する。
// ここではバリデーション(DB の char_length と同じコードポイント数え)・保存成功の
// snapshot 反映・失敗時の責めない文言・エラーコードのマッピング
// (promise-set/core.ts / index.ts の error 文字列と一致)を固定する。

import XCTest
@testable import Lien

// MARK: - モック
// トップレベルに置き、テストクラスの @MainActor 隔離を継承させない(PromiseAPIClient は非隔離)

private final class MockPromiseAPIClient: PromiseAPIClient {
    var callCount = 0
    var result: Result<Promise, Error> = .failure(PromiseClientError.network)
    private(set) var lastTitle: String?
    private(set) var lastEmoji: String?
    private(set) var lastRemindAt: String??

    func setPromise(title: String, emoji: String, remindAt: String?) async throws -> Promise {
        callCount += 1
        lastTitle = title
        lastEmoji = emoji
        lastRemindAt = remindAt
        return try result.get()
    }
}

// MARK: - テスト本体

@MainActor
final class PromiseSetupViewModelTests: XCTestCase {
    private func makeViewModel(
        client: MockPromiseAPIClient,
        store: AppGroupStore? = nil,
        existing: Promise? = nil,
        onSaved: @escaping (Promise) -> Void = { _ in }
    ) -> PromiseSetupViewModel {
        PromiseSetupViewModel(
            client: client,
            store: store,
            existing: existing,
            onSaved: onSaved
        )
    }

    private func makePromise(
        id: String = "prom-1",
        title: String = "まいにち散歩",
        emoji: String = "🚶",
        remindAt: String? = "20:00"
    ) -> Promise {
        Promise(id: id, title: title, emoji: emoji, remindAt: remindAt)
    }

    private func makeTempStore() -> (AppGroupStore, URL) {
        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("PromiseSetupVMTests-\(UUID().uuidString)", isDirectory: true)
        return (AppGroupStore(containerURL: tempDir), tempDir)
    }

    private func makeSnapshot(pairId: String?) -> PairSnapshot {
        PairSnapshot(
            schemaVersion: PairSnapshot.currentSchemaVersion,
            pairId: pairId,
            updatedAt: Date(timeIntervalSince1970: 1_781_166_600), // 2026-06-11T08:30:00Z
            streakCurrent: 5,
            streakBest: 8,
            todayMeDone: false,
            todayPartnerDone: true,
            myPromiseTitle: nil,
            myPromiseEmoji: nil,
            partnerName: "ゆうき",
            partnerPromiseTitle: "ランニング",
            partnerPromiseEmoji: "🏃",
            plantStage: 2,
            plantMood: .fidget,
            plantName: nil,
            hasPartnerPhotoToday: false
        )
    }

    // MARK: デフォルト値

    func testDefaultsRemindEnabledAtTwenty() {
        let vm = makeViewModel(client: MockPromiseAPIClient())

        XCTAssertTrue(vm.remindEnabled)
        XCTAssertEqual(vm.remindAtToSend, "20:00", "リマインドのデフォルトは 20:00")
        XCTAssertEqual(vm.emoji, Strings.PromiseSetup.emojiPalette.first)
        XCTAssertEqual(vm.titleError, .empty) // 未入力では送信不可
        XCTAssertFalse(vm.canSave)
    }

    // MARK: バリデーション(DB の char_length と同じコードポイント数え — §3.3 20字)

    func testTitleValidationCountsUnicodeScalars() async {
        let client = MockPromiseAPIClient()
        let vm = makeViewModel(client: client)

        vm.title = "   \n"
        XCTAssertEqual(vm.titleError, .empty)
        XCTAssertFalse(vm.canSave)
        await vm.save() // canSave ガードでサーバーへ送らない

        vm.title = String(repeating: "あ", count: 21)
        XCTAssertEqual(vm.titleError, .tooLong)
        XCTAssertFalse(vm.canSave)
        await vm.save()

        XCTAssertEqual(client.callCount, 0, "不正入力はサーバーへ送らない")

        // サロゲートペア絵文字 20 個 = UTF-16 では 40 だがコードポイントでは 20 → OK
        vm.title = String(repeating: "💪", count: 20)
        XCTAssertNil(vm.titleError)
        XCTAssertTrue(vm.canSave)

        // 前後空白は字数に入れない(trim 後で判定)
        vm.title = "  " + String(repeating: "あ", count: 20) + "  "
        XCTAssertNil(vm.titleError)
    }

    // MARK: 保存成功

    func testSaveSuccessTrimsTitleUpdatesSnapshotAndCallsOnSavedOnce() async {
        let client = MockPromiseAPIClient()
        let promise = makePromise(title: "まいにち散歩", emoji: "🚶", remindAt: "20:00")
        client.result = .success(promise)

        let (store, tempDir) = makeTempStore()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        try? store.saveSnapshot(makeSnapshot(pairId: "pair-1"))

        var saved: [Promise] = []
        let vm = makeViewModel(client: client, store: store) { saved.append($0) }
        vm.title = "  まいにち散歩\n"
        vm.emoji = "🚶"

        await vm.save()

        XCTAssertEqual(client.callCount, 1)
        XCTAssertEqual(client.lastTitle, "まいにち散歩", "trim してから送る")
        XCTAssertEqual(client.lastEmoji, "🚶")
        XCTAssertEqual(client.lastRemindAt, "20:00")
        XCTAssertEqual(saved, [promise])
        XCTAssertNil(vm.saveErrorMessage)

        // snapshot の自分の約束だけが更新され、ほかのフィールドは保たれる
        let snapshot = store.loadSnapshot()
        XCTAssertEqual(snapshot?.myPromiseTitle, "まいにち散歩")
        XCTAssertEqual(snapshot?.myPromiseEmoji, "🚶")
        XCTAssertEqual(snapshot?.pairId, "pair-1")
        XCTAssertEqual(snapshot?.streakCurrent, 5)
        XCTAssertEqual(snapshot?.partnerPromiseTitle, "ランニング")
    }

    func testSaveSuccessWithoutSnapshotCreatesSoloSnapshot() async {
        // オンボ直後(snapshot 未作成)でも約束がウィジェットに出せる状態を作る
        let client = MockPromiseAPIClient()
        client.result = .success(makePromise(title: "よる読書", emoji: "📚", remindAt: nil))

        let (store, tempDir) = makeTempStore()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        XCTAssertNil(store.loadSnapshot())

        let vm = makeViewModel(client: client, store: store)
        vm.title = "よる読書"
        vm.emoji = "📚"
        vm.remindEnabled = false

        await vm.save()

        let snapshot = store.loadSnapshot()
        XCTAssertEqual(snapshot?.myPromiseTitle, "よる読書")
        XCTAssertEqual(snapshot?.myPromiseEmoji, "📚")
        XCTAssertNil(snapshot?.pairId, "ソロ snapshot(pairId なし)")
        XCTAssertEqual(snapshot?.plantStage, 0)
    }

    // MARK: リマインド

    func testRemindDisabledSendsNil() async {
        let client = MockPromiseAPIClient()
        client.result = .success(makePromise(remindAt: nil))
        let vm = makeViewModel(client: client)
        vm.title = "まいにち散歩"
        vm.remindEnabled = false

        XCTAssertNil(vm.remindAtToSend)
        await vm.save()
        XCTAssertEqual(client.lastRemindAt, .some(nil), "toggle オフは remindAt: null")
    }

    // MARK: 保存失敗(責めない文言 — REQUIREMENTS §3.5)

    func testSaveFailureShowsGentleMessageAndRetryRecovers() async {
        let client = MockPromiseAPIClient()
        client.result = .failure(PromiseClientError.network)
        var savedCount = 0
        let vm = makeViewModel(client: client) { _ in savedCount += 1 }
        vm.title = "まいにち散歩"

        await vm.save()

        XCTAssertEqual(vm.saveErrorMessage, Strings.PromiseSetup.saveErrorMessage)
        XCTAssertEqual(savedCount, 0)
        XCTAssertTrue(vm.canSave, "失敗後もリトライできる")

        client.result = .success(makePromise())
        await vm.save()
        XCTAssertNil(vm.saveErrorMessage)
        XCTAssertEqual(savedCount, 1)
    }

    // MARK: 編集(プリフィル)

    func testExistingPromisePrefillsFields() {
        let existing = makePromise(title: "あさストレッチ", emoji: "🧘", remindAt: "07:30")
        let vm = makeViewModel(client: MockPromiseAPIClient(), existing: existing)

        XCTAssertEqual(vm.title, "あさストレッチ")
        XCTAssertEqual(vm.emoji, "🧘")
        XCTAssertTrue(vm.remindEnabled)
        XCTAssertEqual(vm.remindAtToSend, "07:30")

        let noRemind = makePromise(remindAt: nil)
        let vm2 = makeViewModel(client: MockPromiseAPIClient(), existing: noRemind)
        XCTAssertFalse(vm2.remindEnabled, "リマインドなしの約束は toggle オフで開く")
    }

    // MARK: 契約整合(サーバー実装との突き合わせ)

    func testServerErrorCodeMapping() {
        // 文字列はサーバー実装からコピー(promise-set/core.ts / index.ts)
        XCTAssertEqual(PromiseClientError(serverCode: "invalid_title"), .invalidTitle)
        XCTAssertEqual(PromiseClientError(serverCode: "invalid_emoji"), .invalidEmoji)
        XCTAssertEqual(PromiseClientError(serverCode: "invalid_remind_at"), .invalidRemindAt)
        XCTAssertEqual(PromiseClientError(serverCode: "user_not_found"), .userNotFound)
        XCTAssertEqual(PromiseClientError(serverCode: "unauthorized"), .unauthorized)
        // 未知のコードは .server に落ちる(将来サーバーがコードを足しても壊れない)
        XCTAssertEqual(
            PromiseClientError(serverCode: "internal_error"),
            .server(code: "internal_error")
        )
    }

    func testPromiseSetResponseDecodesServerShapedJSON() throws {
        // promise-set/core.ts の 200 body と同形
        let json = """
        {
          "promise": {
            "id": "1f0c5a4e-9d3b-4c1a-8f2e-7b6d5a4c3b2a",
            "title": "まいにち散歩",
            "emoji": "🚶",
            "remindAt": "20:00"
          },
          "created": true
        }
        """
        let response = try PairSnapshot.makeJSONDecoder()
            .decode(PromiseSetResponse.self, from: Data(json.utf8))
        XCTAssertEqual(response.promise.id, "1f0c5a4e-9d3b-4c1a-8f2e-7b6d5a4c3b2a")
        XCTAssertEqual(response.promise.title, "まいにち散歩")
        XCTAssertEqual(response.promise.remindAt, "20:00")
        XCTAssertTrue(response.created)

        // remindAt: null も受ける(promise-set/core.ts PromiseRow)
        let jsonNoRemind = """
        {"promise":{"id":"p-2","title":"よる読書","emoji":"📚","remindAt":null},"created":false}
        """
        let response2 = try PairSnapshot.makeJSONDecoder()
            .decode(PromiseSetResponse.self, from: Data(jsonNoRemind.utf8))
        XCTAssertNil(response2.promise.remindAt)
        XCTAssertFalse(response2.created)
    }

    // MARK: スタブ(アプリ実行用)も契約の不変条件を守ること

    func testStubKeepsPromiseIDStableAcrossEdits() async throws {
        // サーバーの「編集は同一 promise_id への UPDATE(id 不変)」をスタブも再現する
        let stub = StubPromiseAPIClient()
        let first = try await stub.setPromise(title: "筋トレ", emoji: "💪", remindAt: nil)
        let second = try await stub.setPromise(title: "朝ストレッチ", emoji: "🧘", remindAt: "07:00")
        XCTAssertEqual(first.id, second.id, "編集で id が変わらない(ストリーク非影響 — §3.3)")
        XCTAssertEqual(second.title, "朝ストレッチ")
        XCTAssertEqual(second.remindAt, "07:00")
    }
}
