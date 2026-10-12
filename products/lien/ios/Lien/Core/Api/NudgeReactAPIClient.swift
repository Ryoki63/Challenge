// NudgeReactAPIClient.swift — つつく(nudge)/ リアクション(react)の Live クライアント(issue #55)
//
// NudgeReactService.swift の抽象(NudgeSending / Reacting)を、実 Edge Functions に結線するための
// 下回り。ホーム画面は NudgeSending / Reacting しか知らない(LiveNudgeReactService が橋渡し)。
//
// 正本(契約テストで検証する):
//   nudge/core.ts : POST {stamp} → 200 { remainingToday, snapshot }
//                   400 invalid_stamp / 404 user_not_found / 409 no_pair / 409 partner_already_done /
//                   429 nudge_limit_exceeded
//   react/core.ts : POST {checkinId, stamp} → 200 { changed }
//                   400 invalid_stamp / 404 user_not_found / 404 checkin_not_found / 409 no_pair /
//                   403 not_partner
//   各 index.ts   : 401 unauthorized / 400 invalid_json・invalid_request / 405 / 500 internal_error
//
// react は相手のチェックイン行の id(checkinId)を要求するが、snapshot は id を持たない。
// 相手の「今日の」チェックイン行は RLS(checkins_select_pair)で現役ペアのメンバーに読めるため、
// PostgREST で自分以外の行を引いて解決する(PartnerCheckinResolving)。
// 同じ行の photo_path は、ホームに出す「相手の今日の写真」(PV #59 — PartnerPhotoService)が使う。

import Foundation

// MARK: - 応答モデル(契約の正本はサーバー実装。デコードは PairSnapshot.makeJSONDecoder())

/// POST /nudge の 200 応答(nudge/core.ts NudgeResult.body)
struct NudgeResponse: Equatable, Sendable, Codable {
    /// 今日あと何回つつけるか(サーバー正本。1日3回まで — REQUIREMENTS §3.7)
    let remainingToday: Int
    /// 送信後の自分視点 snapshot(nudge は snapshot の内容を変えないが、応答形を揃えるため同梱される)
    let snapshot: PairSnapshot
}

/// POST /react の 200 応答(react/core.ts ReactResult.body)
struct ReactResponse: Equatable, Sendable, Codable {
    /// 新規 or スタンプ変更で push を送った場合 true。同一スタンプの再送(無変更)は false
    let changed: Bool
}

// MARK: - エラー

/// サーバーの error 文字列 → クライアントのエラー型(変更時はサーバー実装と両方を直す)
enum NudgeReactClientError: Error, Equatable {
    /// "invalid_stamp" — 400(語彙外)
    case invalidStamp
    /// "user_not_found" — 404
    case userNotFound
    /// "no_pair" — 409(ソロにはつつく・リアクションする相手がいない)
    case noPair
    /// "partner_already_done" — 409(nudge: 相手が既に完了済み)
    case partnerAlreadyDone
    /// "nudge_limit_exceeded" — 429(nudge: 1日3回まで)
    case nudgeLimitExceeded
    /// "checkin_not_found" — 404(react: 対象のチェックインが無い)
    case checkinNotFound
    /// "not_partner" — 403(react: 現役パートナーのチェックインではない)
    case notPartner
    /// "unauthorized" — 401(トークン失効等)
    case unauthorized
    /// 上記以外のサーバーエラー("internal_error" / "invalid_json" / "invalid_request" 等)
    case server(code: String)
    /// 通信エラー(オフライン・タイムアウト等)
    case network

    init(serverCode: String) {
        switch serverCode {
        case "invalid_stamp": self = .invalidStamp
        case "user_not_found": self = .userNotFound
        case "no_pair": self = .noPair
        case "partner_already_done": self = .partnerAlreadyDone
        case "nudge_limit_exceeded": self = .nudgeLimitExceeded
        case "checkin_not_found": self = .checkinNotFound
        case "not_partner": self = .notPartner
        case "unauthorized": self = .unauthorized
        default: self = .server(code: serverCode)
        }
    }

    /// ホームのつつき送信失敗理由へ(上限超過だけ専用文言 — NudgeSendError)
    var asNudgeSendError: NudgeSendError {
        switch self {
        case .nudgeLimitExceeded: return .limitReached
        case .partnerAlreadyDone: return .partnerAlreadyDone
        default: return .other
        }
    }
}

// MARK: - プロトコル

protocol NudgeReactAPIClient: AnyObject {
    /// POST /nudge — 相手へスタンプでつつく(NudgeStamp.rawValue)
    func nudge(stamp: String) async throws -> NudgeResponse

    /// POST /react — 相手のチェックイン(行 id)へスタンプでリアクション(ReactionStamp.rawValue)
    func react(checkinID: String, stamp: String) async throws -> ReactResponse
}

// MARK: - live 実装(URLSession。supabase-swift 非依存)

final class EdgeFunctionNudgeReactClient: NudgeReactAPIClient {
    private struct NudgeRequestBody: Encodable {
        let stamp: String
    }

    /// キー名は react/index.ts の payload と一致
    private struct ReactRequestBody: Encodable {
        let checkinId: String
        let stamp: String
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

    func nudge(stamp: String) async throws -> NudgeResponse {
        let body = try JSONEncoder().encode(NudgeRequestBody(stamp: stamp))
        let request = try await transport.functionRequest("nudge", method: "POST", jsonBody: body)
        return try await perform(request)
    }

    func react(checkinID: String, stamp: String) async throws -> ReactResponse {
        let body = try JSONEncoder().encode(ReactRequestBody(checkinId: checkinID, stamp: stamp))
        let request = try await transport.functionRequest("react", method: "POST", jsonBody: body)
        return try await perform(request)
    }

    private func perform<Response: Decodable>(_ request: URLRequest) async throws -> Response {
        let result: (data: Data, status: Int)
        do {
            result = try await transport.send(request)
        } catch {
            throw NudgeReactClientError.network
        }
        guard result.status == 200 else {
            if let code = EdgeFunctionTransport.errorCode(in: result.data) {
                throw NudgeReactClientError(serverCode: code)
            }
            throw NudgeReactClientError.server(code: "http_\(result.status)")
        }
        do {
            return try PairSnapshot.makeJSONDecoder().decode(Response.self, from: result.data)
        } catch {
            throw NudgeReactClientError.server(code: "invalid_response")
        }
    }
}

// MARK: - 相手のチェックイン行の解決(react の対象 / 相手の今日の写真)

/// 相手の当日のチェックイン行(PostgREST の checkins から読む列だけ)
struct PartnerCheckin: Equatable, Sendable {
    let id: String
    /// 添えた写真の原寸のパス('pairs/<pair_id>/<date_local>/<user_id>/photo.jpg')。写真が無ければ nil
    let photoPath: String?
}

/// PostgREST `GET /rest/v1/checkins?select=id,photo_path&…` が返す行
/// (契約フィクスチャ: contracts/partner-checkin.*.json。列名は DB のまま)
struct PartnerCheckinRow: Decodable, Equatable, Sendable {
    let id: String
    let photoPath: String?

    private enum CodingKeys: String, CodingKey {
        case id
        case photoPath = "photo_path"
    }
}

protocol PartnerCheckinResolving: AnyObject {
    /// 相手の `dateLocal` のチェックイン行(まだ無ければ nil)。photo_path つき。
    /// 実装が持つのはこれだけ(下の `partnerCheckinID` は、これから作る拡張メソッドで、実装側では上書きしない)
    func partnerCheckin(dateLocal: String) async throws -> PartnerCheckin?
}

extension PartnerCheckinResolving {
    /// 相手の `dateLocal` のチェックイン行 id(react の対象。まだ無ければ nil)
    func partnerCheckinID(dateLocal: String) async throws -> String? {
        try await partnerCheckin(dateLocal: dateLocal)?.id
    }
}

/// PostgREST(`/rest/v1/checkins`)で自分以外の当日の行を引く。
/// RLS(checkins_select_pair)により、読めるのは自分と「現役ペアの相手」の行だけ
/// (解消後・成立前の行は読めない)ので、自分以外の1行 = 現在のパートナーの行になる。
/// PostgREST は `apikey` ヘッダ(anon / publishable key)が必須で、Edge Functions とは認証の要件が違う
final class PostgRESTPartnerCheckinResolver: PartnerCheckinResolving {
    /// 通信が不安定でも、ホームの読み込み表示(相手の写真)やリアクションを長く待たせない
    static let requestTimeout: TimeInterval = 15

    private let baseURL: URL
    private let apiKey: String
    private let tokenProvider: () async throws -> String
    private let currentUserID: () -> UUID?
    private let session: URLSession

    init(
        baseURL: URL,
        apiKey: String,
        tokenProvider: @escaping () async throws -> String,
        currentUserID: @escaping () -> UUID?,
        session: URLSession = .shared
    ) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.tokenProvider = tokenProvider
        self.currentUserID = currentUserID
        self.session = session
    }

    func partnerCheckin(dateLocal: String) async throws -> PartnerCheckin? {
        guard let myID = currentUserID() else { throw AuthServiceError.notSignedIn }
        var components = URLComponents(
            url: baseURL.appendingPathComponent("rest/v1/checkins"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [
            URLQueryItem(name: "select", value: "id,photo_path"),
            URLQueryItem(name: "date_local", value: "eq.\(dateLocal)"),
            URLQueryItem(name: "user_id", value: "neq.\(myID.uuidString.lowercased())"),
            URLQueryItem(name: "limit", value: "1"),
        ]
        guard let url = components?.url else {
            throw NudgeReactClientError.server(code: "invalid_url")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = Self.requestTimeout
        request.setValue(apiKey, forHTTPHeaderField: "apikey")
        let token = try await tokenProvider()
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw NudgeReactClientError.network
        }
        guard let http = response as? HTTPURLResponse else {
            throw NudgeReactClientError.network
        }
        guard http.statusCode == 200 else {
            throw NudgeReactClientError.server(code: "http_\(http.statusCode)")
        }
        guard let rows = try? JSONDecoder().decode([PartnerCheckinRow].self, from: data) else {
            throw NudgeReactClientError.server(code: "invalid_response")
        }
        return rows.first.map { PartnerCheckin(id: $0.id, photoPath: $0.photoPath) }
    }
}
