// EdgeFunctionInviteClient.swift — 招待 API(invite-create / invite-accept)の Live クライアント(issue #55)
//
// InviteClient プロトコル(InviteClient.swift)の本実装。URLSession ベースで supabase-swift に依存しない
// (baseURL と JWT プロバイダを注入 — 他の Edge Function クライアントと同じイディオム)。
//
// エラー文字列の正本(InviteClientError.init(serverCode:) と一致させる。契約テストで検証):
//   invite-create/core.ts : 404 user_not_found / 409 already_paired / 500 token_generation_failed
//   invite-accept/core.ts : 400 invalid_token / 400 cannot_accept_own_invite / 404 user_not_found /
//                           404 invite_not_found / 410 invite_already_used / 410 invite_expired /
//                           409 already_paired / 409 partner_already_paired
//   各 index.ts           : 401 unauthorized / 400 invalid_json / 405 method_not_allowed / 500 internal_error

import Foundation

final class EdgeFunctionInviteClient: InviteClient {
    /// POST /invite-accept の本文(キー名は invite-accept/index.ts の payload と一致)
    private struct AcceptRequestBody: Encodable {
        let token: String
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

    func createInvite() async throws -> InviteCreateResponse {
        // invite-create は本文を読まない(発行者は JWT から決まる)
        let request = try await transport.functionRequest("invite-create", method: "POST")
        return try await perform(request)
    }

    func acceptInvite(token: String) async throws -> InviteAcceptResponse {
        let body = try JSONEncoder().encode(AcceptRequestBody(token: token))
        let request = try await transport.functionRequest(
            "invite-accept",
            method: "POST",
            jsonBody: body
        )
        return try await perform(request)
    }

    private func perform<Response: Decodable>(_ request: URLRequest) async throws -> Response {
        let result: (data: Data, status: Int)
        do {
            result = try await transport.send(request)
        } catch {
            throw InviteClientError.network
        }
        guard result.status == 200 else {
            if let code = EdgeFunctionTransport.errorCode(in: result.data) {
                throw InviteClientError(serverCode: code)
            }
            throw InviteClientError.server(code: "http_\(result.status)")
        }
        do {
            return try PairSnapshot.makeJSONDecoder().decode(Response.self, from: result.data)
        } catch {
            throw InviteClientError.server(code: "invalid_response")
        }
    }
}
