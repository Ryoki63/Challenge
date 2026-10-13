// ContractFixtureTests.swift — サーバー応答の契約フィクスチャ(products/lien/contracts/*.json)のデコード(issue #55)
//
// フィクスチャはサーバーの実ハンドラ(supabase/functions/**/core.ts)を固定入力で走らせて作った
// 応答 JSON そのもの(contracts/tools/generate.ts)。ここでは、アプリが本番で使うデコーダ・モデル・
// エラーマップで、それらを**そのまま**復元できることを固定する。
// サーバーの応答形が変わったら contracts を再生成する → このテストが落ちる → iOS 側を追従させる、の順で気づける。
//
// 検証する契約:
//   - 2xx 応答の形(snapshot / checkin / checkin-cancel / promise-set / invite-create / invite-accept / nudge / react)
//   - push ペイロード(NSE が lien.snapshot を App Group に書く形)
//   - スタンプの語彙と順序(NudgeStamp / ReactionStamp ⇔ messages.ts)
//   - エラー文字列(各クライアントのエラーマップ ⇔ 各 function の core.ts / index.ts)
//   - 前方互換(サーバーが snapshot に未知のキーを足しても壊れない)
//   - 成長ルール v2 の新キー3つ(plantGrownDays / plantStageFloor / plantNextStageAt)の値まで(PB #57)と、plant-name の応答

import XCTest
@testable import Lien

final class ContractFixtureTests: XCTestCase {
    /// フィクスチャ生成時の固定時刻 2026-06-11T08:30:00Z
    private let fixedDate = Date(timeIntervalSince1970: 1_781_166_600)
    private let pairID = "1f0c5a4e-9d3b-4c1a-8f2e-7b6d5a4c3b2a"
    private let myUserID = "a1111111-1111-4111-8111-111111111111"

    // MARK: GET /snapshot

    func testSnapshotPairedDecodes() throws {
        let snapshot = try ContractFixtures.decode(SnapshotResponse.self, from: "snapshot.paired").snapshot
        XCTAssertEqual(snapshot.schemaVersion, PairSnapshot.currentSchemaVersion)
        XCTAssertEqual(snapshot.pairId, pairID)
        XCTAssertEqual(snapshot.updatedAt, fixedDate, "小数秒つき ISO8601 (…:00.000Z) を復元できる")
        XCTAssertEqual(snapshot.streakCurrent, 6)
        XCTAssertEqual(snapshot.streakBest, 6)
        XCTAssertFalse(snapshot.todayMeDone)
        XCTAssertTrue(snapshot.todayPartnerDone)
        XCTAssertEqual(snapshot.myPromiseTitle, "筋トレ")
        XCTAssertEqual(snapshot.myPromiseEmoji, "💪")
        XCTAssertEqual(snapshot.partnerName, "ゆうき")
        XCTAssertEqual(snapshot.partnerPromiseTitle, "ランニング")
        XCTAssertEqual(snapshot.plantStage, 2)
        // 成長ルール v2 の新キー(サーバーの閾値 [0,1,3,7,…] で、段階2 = 下限3・次の段階7)
        XCTAssertEqual(snapshot.plantGrownDays, 6)
        XCTAssertEqual(snapshot.plantStageFloor, 3)
        XCTAssertEqual(snapshot.plantNextStageAt, 7)
        XCTAssertEqual(GrowthGauge.text(for: snapshot), "ふたりそろって あと1回で わかば", "実ハンドラの出力から、ゲージの文が作れる")
        XCTAssertEqual(snapshot.plantMood, .fidget)
        XCTAssertEqual(snapshot.plantName, "みどり")
        XCTAssertTrue(snapshot.hasPartnerPhotoToday)
        XCTAssertEqual(AppRouter.phase(hasSession: true, snapshot: snapshot), .paired)
    }

    func testSnapshotSoloDecodes() throws {
        let snapshot = try ContractFixtures.decode(SnapshotResponse.self, from: "snapshot.solo").snapshot
        XCTAssertNil(snapshot.pairId, "ソロ状態は pairId = null")
        XCTAssertEqual(snapshot.plantStage, 0)
        // ソロの植物の成長は 0 / 0 / null(キーは省略されない — DESIGN §3.4)。ソロにゲージは出さない
        XCTAssertEqual(snapshot.plantGrownDays, 0)
        XCTAssertEqual(snapshot.plantStageFloor, 0)
        XCTAssertNil(snapshot.plantNextStageAt)
        XCTAssertNil(PlantProgress(snapshot: snapshot))
        XCTAssertNil(GrowthGauge.text(for: snapshot))
        XCTAssertNil(snapshot.partnerName)
        XCTAssertEqual(snapshot.myPromiseTitle, "筋トレ")
        XCTAssertEqual(AppRouter.phase(hasSession: true, snapshot: snapshot), .solo)
    }

    func testSnapshotEmptyRoutesToPromiseSetup() throws {
        // オンボ直後にサーバーが返す「約束もペアもない」snapshot
        let snapshot = try ContractFixtures.decode(SnapshotResponse.self, from: "snapshot.empty").snapshot
        XCTAssertNil(snapshot.pairId)
        XCTAssertNil(snapshot.myPromiseTitle)
        XCTAssertEqual(AppRouter.phase(hasSession: true, snapshot: snapshot), .promiseSetup)
        XCTAssertEqual(snapshot, PairSnapshot.emptySolo(updatedAt: fixedDate), "スタブ構成の空 snapshot と同じ形")
    }

    func testSnapshotDecodingToleratesUnknownServerKeys() throws {
        // サーバーが将来 snapshot に足すキー(1.0.1 の花壇・おきゃくさんなど)。今のアプリは無視して動く
        var object = try ContractFixtures.object("snapshot.paired")
        var inner = try XCTUnwrap(object["snapshot"] as? [String: Any])
        inner["plantVisitorId"] = "ladybug"
        inner["someFutureKey"] = ["a": 1]
        object["snapshot"] = inner
        let data = try JSONSerialization.data(withJSONObject: object)

        let decoded = try PairSnapshot.makeJSONDecoder().decode(SnapshotResponse.self, from: data)
        XCTAssertEqual(decoded.snapshot.pairId, pairID)
        XCTAssertEqual(decoded.snapshot.plantStage, 2)
        XCTAssertEqual(decoded.snapshot.plantGrownDays, 6, "既知のキーはそのまま読める")
    }

    func testEverySnapshotFixtureCarriesTheGrowthKeysTheAppReads() throws {
        // サーバーの実ハンドラの出力は、どの応答の snapshot にも新キー3つを載せる(省略しない)。アプリはその値まで読める
        let fixtures: [(name: String, grown: Int, floor: Int, next: Int?)] = [
            ("snapshot.paired", 6, 3, 7),
            ("snapshot.solo", 0, 0, nil),
            ("snapshot.empty", 0, 0, nil),
        ]
        for fixture in fixtures {
            let snapshot = try ContractFixtures.decode(SnapshotResponse.self, from: fixture.name).snapshot
            XCTAssertEqual(snapshot.plantGrownDays, fixture.grown, fixture.name)
            XCTAssertEqual(snapshot.plantStageFloor, fixture.floor, fixture.name)
            XCTAssertEqual(snapshot.plantNextStageAt, fixture.next, fixture.name)
        }
        // ペア成立の直後(invite-accept)は 段階0・成長 0 回・次の段階は 1 回
        let accepted = try ContractFixtures.decode(InviteAcceptResponse.self, from: "invite-accept.ok").snapshot
        XCTAssertEqual(accepted.plantGrownDays, 0)
        XCTAssertEqual(accepted.plantStageFloor, 0)
        XCTAssertEqual(accepted.plantNextStageAt, 1)
        XCTAssertEqual(GrowthGauge.text(for: accepted), "ふたりそろって あと1回で ふたば")
        // ふたり達成(checkin): 7回で「わかば」に入った
        let both = try ContractFixtures.decode(CheckinResponse.self, from: "checkin.paired").snapshot
        XCTAssertEqual(both.plantStage, 3)
        XCTAssertEqual(both.plantGrownDays, 7)
        XCTAssertEqual(both.plantStageFloor, 7)
        XCTAssertEqual(both.plantNextStageAt, 14)
        XCTAssertEqual(GrowthGauge.text(for: both), "ふたりそろって あと7回で よりそい", "段階に入った直後(0回)は『0回そろったよ』と言わない")
    }

    // MARK: POST /plant-name

    func testPlantNameFixturesDecode() throws {
        let ok = try ContractFixtures.decode(PlantNameResponse.self, from: "plant-name.ok")
        XCTAssertEqual(ok.name, "みどり")
        XCTAssertEqual(ok.snapshot.pairId, pairID)
        XCTAssertEqual(ok.snapshot.plantName, "みどり", "呼び出し本人視点の snapshot に名前が入る")

        let conflict = try ContractFixtures.decode(PlantNameConflictResponse.self, from: "plant-name.already-named")
        XCTAssertEqual(conflict.error, "already_named")
        XCTAssertEqual(conflict.name, "みどり")
    }

    func testPlantNameFixturesAreReadByTheClientTheWayThePlanSays() throws {
        // 200 → 保存された名前 / 409 → 自分が送った名前と同じなら成功・違えば相手の名前を採用
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
            try EdgeFunctionPlantNaming.interpret(status: 409, data: conflict, sent: "あおば", mode: .first),
            .adopted(name: "みどり")
        )
    }

    // MARK: POST /checkin, /checkin-cancel

    func testCheckinPairedDecodes() throws {
        let response = try ContractFixtures.decode(CheckinResponse.self, from: "checkin.paired")
        XCTAssertFalse(response.alreadyCheckedIn)
        XCTAssertTrue(response.snapshot.todayMeDone)
        XCTAssertTrue(response.snapshot.todayPartnerDone)
        XCTAssertEqual(response.snapshot.plantMood, .happy, "両者完了は happy(ふたり達成)")
        XCTAssertEqual(response.snapshot.streakCurrent, 7, "確定 6 + 今日のプレビュー 1")
        XCTAssertNil(response.photoUpload, "requestPhotoUpload を付けなければ photoUpload は無い")
    }

    func testCheckinSoloDecodes() throws {
        // ソロでも写真なしのチェックインはサーバーが受け付ける(checkins に pair_id は無い)
        let response = try ContractFixtures.decode(CheckinResponse.self, from: "checkin.solo")
        XCTAssertFalse(response.alreadyCheckedIn)
        XCTAssertNil(response.snapshot.pairId)
        XCTAssertTrue(response.snapshot.todayMeDone)
        XCTAssertNil(response.photoUpload)
        XCTAssertEqual(AppRouter.phase(hasSession: true, snapshot: response.snapshot), .solo)
    }

    func testCheckinPhotoUploadDecodesAndMatchesPathConvention() throws {
        let response = try ContractFixtures.decode(CheckinResponse.self, from: "checkin.photo-upload")
        let upload = try XCTUnwrap(response.photoUpload)

        // 'pairs/<pair_id>/<date_local>/<user_id>/photo.jpg' (#52: 本人単位)。サムネは photo_thumb.jpg
        XCTAssertEqual(upload.photo.path, "pairs/\(pairID)/2026-06-11/\(myUserID)/photo.jpg")
        XCTAssertEqual(upload.thumb.path, "pairs/\(pairID)/2026-06-11/\(myUserID)/photo_thumb.jpg")
        XCTAssertFalse(upload.photo.token.isEmpty)
        XCTAssertFalse(upload.thumb.token.isEmpty)
        XCTAssertNotEqual(upload.photo.token, upload.thumb.token)

        // アップロード先 URL が組み立てられる(Storage 署名付きアップロード)
        let base = URL(string: "https://example.supabase.co")!
        let url = try XCTUnwrap(EdgeFunctionCheckinClient.signedUploadURL(baseURL: base, target: upload.photo))
        XCTAssertTrue(url.absoluteString.hasPrefix("https://example.supabase.co/storage/v1/object/upload/sign/photos/pairs/"))
        XCTAssertTrue(url.absoluteString.contains("token=\(upload.photo.token)"))
    }

    func testStubCheckinAPIClientUsesTheSamePhotoPathShapeAsTheServer() async throws {
        // スタブ(プレビュー・テスト用)のパスの形がサーバーの規約とずれていないこと
        let server = try ContractFixtures.decode(CheckinResponse.self, from: "checkin.photo-upload")
        let serverPath = try XCTUnwrap(server.photoUpload?.photo.path)

        let stub = StubCheckinAPIClient(snapshot: SnapshotFactory.paired(), now: { self.fixedDate })
        let stubbed = try await stub.checkin(dateLocal: "2026-06-11", photoPath: nil, requestPhotoUpload: true)
        let stubPath = try XCTUnwrap(stubbed.photoUpload?.photo.path)

        XCTAssertEqual(stubPath.split(separator: "/").count, serverPath.split(separator: "/").count)
        XCTAssertTrue(stubPath.hasPrefix("pairs/"))
        XCTAssertTrue(stubPath.hasSuffix("/photo.jpg"))
        XCTAssertEqual(
            stubPath.split(separator: "/").dropLast().dropLast().last.map(String.init),
            "2026-06-11",
            "日付の区画の位置が同じ"
        )
    }

    func testCheckinCancelDecodes() throws {
        let response = try ContractFixtures.decode(CheckinCancelResponse.self, from: "checkin-cancel.ok")
        XCTAssertFalse(response.alreadyCanceled)
        XCTAssertFalse(response.snapshot.todayMeDone)
        XCTAssertTrue(response.snapshot.todayPartnerDone)
    }

    // MARK: POST /promise-set

    func testPromiseSetDecodes() throws {
        let response = try ContractFixtures.decode(PromiseSetResponse.self, from: "promise-set.ok")
        XCTAssertTrue(response.created)
        XCTAssertEqual(response.promise.title, "筋トレ")
        XCTAssertEqual(response.promise.emoji, "💪")
        XCTAssertEqual(response.promise.remindAt, "20:00")
        XCTAssertFalse(response.promise.id.isEmpty)
    }

    // MARK: POST /invite-create, /invite-accept

    func testInviteCreateDecodesAndLinksResolveToTheSameToken() throws {
        let invite = try ContractFixtures.decode(InviteCreateResponse.self, from: "invite-create.ok")
        XCTAssertTrue(InviteToken.isValidFormat(invite.token), "8文字英数")
        XCTAssertEqual(invite.appUrl, "lien://invite/\(invite.token)")
        XCTAssertTrue(invite.webUrl.hasSuffix("/lien/i/?t=\(invite.token)"))
        XCTAssertEqual(invite.expiresAt, fixedDate.addingTimeInterval(72 * 60 * 60), "発行時刻 + 72時間")

        // 共有した2形式のリンクを、アプリの DeepLinkHandler が同じ token として受け取れる
        XCTAssertEqual(DeepLinkHandler.inviteToken(from: try XCTUnwrap(invite.appURL)), invite.token)
        XCTAssertEqual(DeepLinkHandler.inviteToken(from: try XCTUnwrap(invite.webURL)), invite.token)
    }

    func testInviteAcceptDecodes() throws {
        let accepted = try ContractFixtures.decode(InviteAcceptResponse.self, from: "invite-accept.ok")
        XCTAssertEqual(accepted.pairId, pairID)
        XCTAssertEqual(accepted.snapshot.pairId, pairID, "受諾者視点の snapshot はペア成立後の形")
        XCTAssertEqual(accepted.snapshot.partnerName, "ゆうき")
        XCTAssertEqual(accepted.snapshot.myPromiseTitle, "筋トレ", "自分の約束は引き継がれる")
        XCTAssertEqual(accepted.snapshot.plantStage, 0, "ペア成立で種が植わる(土の見た目)")
        XCTAssertEqual(AppRouter.phase(hasSession: true, snapshot: accepted.snapshot), .paired)
    }

    // MARK: POST /nudge, /react

    func testNudgeDecodes() throws {
        let response = try ContractFixtures.decode(NudgeResponse.self, from: "nudge.ok")
        XCTAssertEqual(response.remainingToday, 2, "1日3回のうち1回使った")
        XCTAssertEqual(response.snapshot.pairId, pairID)
        XCTAssertFalse(response.snapshot.todayPartnerDone)
    }

    func testReactDecodes() throws {
        let response = try ContractFixtures.decode(ReactResponse.self, from: "react.ok")
        XCTAssertTrue(response.changed)
    }

    // MARK: push ペイロード(NSE / サイレント push が App Group に書く形)

    /// NSE(NotificationService.updateSharedSnapshot)と同じ手順で userInfo["lien"]["snapshot"] を取り出す
    private func embeddedSnapshotData(in fixture: String) throws -> Data {
        let userInfo = try ContractFixtures.object(fixture)
        let lien = try XCTUnwrap(userInfo["lien"] as? [String: Any])
        let snapshotObject = try XCTUnwrap(lien["snapshot"])
        XCTAssertTrue(JSONSerialization.isValidJSONObject(snapshotObject))
        return try JSONSerialization.data(withJSONObject: snapshotObject)
    }

    func testVisiblePushPayloadFeedsTheNotificationServiceExtension() throws {
        let userInfo = try ContractFixtures.object("push.visible")
        let aps = try XCTUnwrap(userInfo["aps"] as? [String: Any])
        XCTAssertEqual(aps["mutable-content"] as? Int, 1, "NSE が起動する条件(DESIGN §4)")
        let alert = try XCTUnwrap(aps["alert"] as? [String: Any])
        XCTAssertEqual(alert["title"] as? String, "あきら", "相手起点の通知は相手の名前名義")
        let lien = try XCTUnwrap(userInfo["lien"] as? [String: Any])
        XCTAssertEqual(lien["type"] as? String, "partner_checkin")

        let temp = TempStore()
        defer { temp.cleanup() }
        let saved = try temp.store.saveSnapshotData(embeddedSnapshotData(in: "push.visible"))
        XCTAssertEqual(saved.partnerName, "あきら", "同梱 snapshot は受信者(相手)視点")
        XCTAssertEqual(saved.myPromiseTitle, "ランニング")
        XCTAssertEqual(temp.store.loadSnapshot(), saved)
    }

    func testSilentPushPayloadHasNoAlertAndCarriesSnapshot() throws {
        let userInfo = try ContractFixtures.object("push.silent")
        let aps = try XCTUnwrap(userInfo["aps"] as? [String: Any])
        XCTAssertEqual(aps["content-available"] as? Int, 1)
        XCTAssertNil(aps["alert"], "サイレント push に通知 UI は無い")
        let lien = try XCTUnwrap(userInfo["lien"] as? [String: Any])
        XCTAssertEqual(lien["type"] as? String, "pair_update")

        let temp = TempStore()
        defer { temp.cleanup() }
        let saved = try temp.store.saveSnapshotData(embeddedSnapshotData(in: "push.silent"))
        XCTAssertTrue(saved.todayMeDone)
        XCTAssertFalse(saved.todayPartnerDone)
    }

    // MARK: スタンプの語彙(messages.ts ⇔ NudgeReactService.swift)

    func testStampVocabularyAndOrderMatchTheServer() throws {
        let stamps = try ContractFixtures.object("stamps")
        XCTAssertEqual(NudgeStamp.allCases.map(\.rawValue), stamps["nudge"] as? [String], "NUDGE_STAMPS")
        XCTAssertEqual(ReactionStamp.allCases.map(\.rawValue), stamps["reaction"] as? [String], "REACTION_STAMPS")
    }

    // MARK: エラー文字列(クライアントのエラーマップ ⇔ 各 function)

    /// サーバーが返しうるエラーコード(functions → code)。contracts/errors.json
    private func serverErrorCodes(_ functions: [String]) throws -> Set<String> {
        let errors = try ContractFixtures.object("errors")
        var codes = Set<String>()
        for function in functions {
            let perFunction = try XCTUnwrap(errors[function] as? [String: Any], function)
            codes.formUnion(perFunction.keys)
        }
        return codes
    }

    /// クライアントが専用の case にマップしているコードは、サーバーに実在する(typo・サーバー側の改名を検知)。
    /// 逆に、サーバーにあるコードは専用 case にマップ済みか、意図して一般エラー扱いにするコード(generic)のどちらか
    /// (サーバーにコードが増えたのにクライアントが取りこぼすのを検知)
    private func assertErrorMap(
        label: String,
        functions: [String],
        mapped: [String],
        generic: Set<String>,
        isMapped: (String) -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let server = try serverErrorCodes(functions)
        for code in mapped {
            XCTAssertTrue(server.contains(code), "\(label): クライアントがマップする \(code) がサーバーに無い", file: file, line: line)
            XCTAssertTrue(isMapped(code), "\(label): \(code) が専用の case にマップされていない", file: file, line: line)
        }
        for code in server.subtracting(mapped) {
            XCTAssertTrue(generic.contains(code), "\(label): サーバーのコード \(code) がマップも generic 指定もされていない", file: file, line: line)
            XCTAssertFalse(isMapped(code), "\(label): generic のはずの \(code) が専用 case にマップされている", file: file, line: line)
        }
    }

    func testInviteErrorCodesMatchTheServer() throws {
        try assertErrorMap(
            label: "invite",
            functions: ["invite-create", "invite-accept"],
            mapped: [
                "already_paired", "partner_already_paired", "invite_not_found", "invite_expired",
                "invite_already_used", "cannot_accept_own_invite", "invalid_token", "user_not_found",
            ],
            generic: ["unauthorized", "internal_error", "method_not_allowed", "invalid_json", "token_generation_failed"],
            isMapped: { InviteClientError(serverCode: $0) != .server(code: $0) }
        )
    }

    func testSnapshotErrorCodesMatchTheServer() throws {
        try assertErrorMap(
            label: "snapshot",
            functions: ["snapshot"],
            mapped: ["user_not_found", "unauthorized"],
            // auth_unavailable(503): 認証サーバーの不調。「ログインが無効」ではないので専用 case にせず、一般のサーバー失敗として
            // 扱う(SessionHealthMonitor は .failed(.server) を数えも消しもしない)
            generic: ["internal_error", "method_not_allowed", "auth_unavailable"],
            isMapped: { SnapshotClientError(serverCode: $0) != .server(code: $0) }
        )
    }

    func testNudgeReactErrorCodesMatchTheServer() throws {
        try assertErrorMap(
            label: "nudge/react",
            functions: ["nudge", "react"],
            mapped: [
                "invalid_stamp", "user_not_found", "no_pair", "partner_already_done",
                "nudge_limit_exceeded", "checkin_not_found", "not_partner", "unauthorized",
            ],
            generic: ["internal_error", "method_not_allowed", "invalid_json", "invalid_request"],
            isMapped: { NudgeReactClientError(serverCode: $0) != .server(code: $0) }
        )
    }

    func testPlantNameErrorCodesMatchTheServer() throws {
        // already_named(409)は、エラーでなく結果として読む(本文の name を使う)ので、専用 case にはしない(generic)。
        // 本文の name つきの読み方は PlantNameFixtures と EdgeFunctionPlantNamingTests が検査する
        try assertErrorMap(
            label: "plant-name",
            functions: ["plant-name"],
            mapped: ["invalid_name", "no_pair", "plant_not_found", "user_not_found", "unauthorized"],
            generic: ["already_named", "invalid_mode", "invalid_json", "internal_error", "method_not_allowed"],
            isMapped: { PlantNameClientError(serverCode: $0) != .server(code: $0) }
        )
    }

    func testCheckinErrorCodesMatchTheServer() throws {
        try assertErrorMap(
            label: "checkin",
            functions: ["checkin", "checkin-cancel"],
            mapped: [
                "invalid_date_local", "date_local_out_of_range", "date_local_not_today", "no_promise",
                "no_pair", "invalid_photo_path", "user_not_found", "unauthorized",
            ],
            generic: ["internal_error", "method_not_allowed", "invalid_json", "invalid_request_photo_upload"],
            isMapped: { CheckinClientError(serverCode: $0) != .server(code: $0) }
        )
    }

    func testPromiseErrorCodesMatchTheServer() throws {
        try assertErrorMap(
            label: "promise-set",
            functions: ["promise-set"],
            mapped: ["invalid_title", "invalid_emoji", "invalid_remind_at", "user_not_found", "unauthorized"],
            generic: ["internal_error", "method_not_allowed", "invalid_json"],
            isMapped: { PromiseClientError(serverCode: $0) != .server(code: $0) }
        )
    }

    func testAccountErrorCodesMatchTheServer() throws {
        // ペア解消(pair-dissolve)とアカウント削除(delete-account)— T23 #23
        try assertErrorMap(
            label: "account",
            functions: ["pair-dissolve", "delete-account"],
            mapped: ["user_not_found", "unauthorized"],
            generic: ["internal_error", "method_not_allowed", "auth_unavailable"],
            isMapped: { AccountClientError(serverCode: $0) != .server(code: $0) }
        )
    }

    func testPairDissolveAndDeleteAccountFixturesDecode() throws {
        let dissolved = try ContractFixtures.decode(PairDissolveResponse.self, from: "pair-dissolve.ok")
        XCTAssertTrue(dissolved.dissolved)
        XCTAssertNil(dissolved.snapshot.pairId)
        XCTAssertEqual(AppRouter.phase(hasSession: true, snapshot: dissolved.snapshot), .solo, "解消後はソロのホーム")
        let already = try ContractFixtures.decode(PairDissolveResponse.self, from: "pair-dissolve.already")
        XCTAssertFalse(already.dissolved)
        XCTAssertEqual(try ContractFixtures.decode(AccountDeleteResponse.self, from: "delete-account.ok").deleted, true)
    }

    func testNudgeLimitIsTheOnlyNudgeErrorWithItsOwnHomeMessage() {
        // サーバーの 429 nudge_limit_exceeded だけが専用文言(責めない — §3.5)。他は一般失敗
        XCTAssertEqual(NudgeReactClientError(serverCode: "nudge_limit_exceeded").asNudgeSendError, .limitReached)
        XCTAssertEqual(NudgeReactClientError(serverCode: "partner_already_done").asNudgeSendError, .partnerAlreadyDone)
        XCTAssertEqual(NudgeReactClientError(serverCode: "no_pair").asNudgeSendError, .other)
    }
}
