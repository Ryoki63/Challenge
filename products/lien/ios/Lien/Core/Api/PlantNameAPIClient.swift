// PlantNameAPIClient.swift — plant-name(植物の名前を付ける・変える)の Live クライアント(issue #57)
//
// PlantNaming.swift の抽象(PlantNaming)を、実 Edge Function に結線する。View / ViewModel は PlantNaming しか知らない。
//
// 正本(契約テストで検証する — contracts/plant-name.ok.json・plant-name.already-named.json・errors.json):
//   plant-name/core.ts : POST { name, mode: "first" | "rename" } →
//       200 { name, snapshot }(snapshot は呼び出し本人視点。plantName が入る)
//       409 { error: "already_named", name }(first で、すでに名前があった。**name は今の名前**)
//       400 invalid_mode・invalid_name / 404 user_not_found・plant_not_found / 409 no_pair
//   index.ts           : 401 unauthorized / 400 invalid_json / 405 / 500 internal_error
//
// first の 409 は**エラーにせず**、結果として読む(PlantNameConflict): 名前を付けた本人の再送でも 409 になる(サーバーは
// 誰が付けたかを返さない)ので、本文の name が自分の送った名前と同じなら成功、違えば相手が先に付けたその名前を採用する。
// 送る名前は、検査(PlantNameRules)を通して NFC に整えたもの(通らないときは通信せずに invalidName)。

import Foundation

/// POST /plant-name の 200 応答(plant-name/core.ts)
struct PlantNameResponse: Equatable, Sendable, Codable {
    /// 保存された名前(サーバーが NFC に整えたあと)
    let name: String
    /// 呼び出し本人視点の snapshot(plantName が入る)。端末へはこの全体を上書きせず、名前だけを反映する
    /// (未送信のチェックインが残っているとき、サーバーの「今日は未完」で楽観の状態を巻き戻さないため — 次の同期で揃う)
    let snapshot: PairSnapshot
}

/// 409 already_named の本文 { error, name }
struct PlantNameConflictResponse: Equatable, Sendable, Decodable {
    let error: String
    let name: String?
}

/// サーバーの error 文字列 → クライアントのエラー型(変更時はサーバー実装と両方を直す)。
/// first の 409 already_named は、エラーでなく結果として読む(本文の name があるとき)ので、ここには無い
enum PlantNameClientError: Error, Equatable {
    /// 入力が使えない(通信の前の検査、またはサーバーの 400 "invalid_name")
    case invalidName
    /// "no_pair" — 409(ソロ・ペア解消後には鉢が無い)
    case noPair
    /// "plant_not_found" — 404(ペアの鉢の行が無い。データ不整合)
    case plantNotFound
    /// "user_not_found" — 404
    case userNotFound
    /// "unauthorized" — 401(トークン失効等)
    case unauthorized
    /// 上記以外のサーバーエラー("internal_error" / "invalid_json" / "invalid_mode" / "already_named"(name なし)等)
    case server(code: String)
    /// 通信エラー(オフライン・タイムアウト等)
    case network

    init(serverCode: String) {
        switch serverCode {
        case "invalid_name": self = .invalidName
        case "no_pair": self = .noPair
        case "plant_not_found": self = .plantNotFound
        case "user_not_found": self = .userNotFound
        case "unauthorized": self = .unauthorized
        default: self = .server(code: serverCode)
        }
    }
}

// MARK: - live 実装(URLSession。supabase-swift 非依存)

final class EdgeFunctionPlantNaming: PlantNaming {
    /// 名前の保存は短い DB 更新だけ
    static let requestTimeout: TimeInterval = 30

    /// キー名は plant-name/index.ts の payload と一致
    private struct RequestBody: Encodable {
        let name: String
        let mode: String
    }

    private let transport: EdgeFunctionTransport

    init(
        baseURL: URL,
        tokenProvider: @escaping () async throws -> String,
        session: URLSession = .shared
    ) {
        transport = EdgeFunctionTransport(
            baseURL: baseURL,
            tokenProvider: tokenProvider,
            session: session
        )
    }

    func setName(_ name: String, mode: PlantNameMode) async throws -> PlantNameOutcome {
        // 使えない名前は、通信せずに弾く(サーバーも DB を引く前に同じ規則で弾く)
        guard PlantNameRules.validate(name) == nil else { throw PlantNameClientError.invalidName }
        let sent = PlantNameRules.normalized(name)
        let body = try JSONEncoder().encode(RequestBody(name: sent, mode: mode.rawValue))
        var request = try await transport.functionRequest("plant-name", method: "POST", jsonBody: body)
        request.timeoutInterval = Self.requestTimeout
        let result: (data: Data, status: Int)
        do {
            result = try await transport.send(request)
        } catch {
            throw PlantNameClientError.network
        }
        return try Self.interpret(status: result.status, data: result.data, sent: sent, mode: mode)
    }

    /// 応答を結果に読む(通信なしで契約フィクスチャを検査できるよう、static にしてある)。
    /// - 200: 保存された名前
    /// - 409 already_named(first): 本文の name が sent と同じなら成功(自分の再送)・違えば相手が先に付けた(PlantNameConflict)
    /// - それ以外: PlantNameClientError
    static func interpret(
        status: Int,
        data: Data,
        sent: String,
        mode: PlantNameMode
    ) throws -> PlantNameOutcome {
        if status == 200 {
            guard let response = try? PairSnapshot.makeJSONDecoder().decode(PlantNameResponse.self, from: data) else {
                throw PlantNameClientError.server(code: "invalid_response")
            }
            return .saved(name: response.name)
        }
        guard let code = EdgeFunctionTransport.errorCode(in: data) else {
            throw PlantNameClientError.server(code: "http_\(status)")
        }
        if code == "already_named", mode == .first,
           let conflict = try? JSONDecoder().decode(PlantNameConflictResponse.self, from: data),
           let current = conflict.name, !current.isEmpty {
            return PlantNameConflict.resolveFirst(sent: sent, current: current)
        }
        throw PlantNameClientError(serverCode: code)
    }
}
