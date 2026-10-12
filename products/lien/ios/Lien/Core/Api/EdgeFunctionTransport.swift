// EdgeFunctionTransport.swift — Edge Functions を叩く共通の HTTP 下回り(issue #55)
//
// invite / snapshot / nudge / react の Live クライアントが共有する。
// (promise / checkin の既存クライアントは自前実装のまま — 完了条件にないリファクタをしない)
//
// - URL は `<baseURL>/functions/v1/<name>`、認証は `Authorization: Bearer <ユーザー JWT>` のみ
//   (全関数 verify_jwt = false で、関数内の adminClient.auth.getUser が自己認証する — supabase/config.toml)
// - トークン取得の失敗(未サインイン・更新失敗)は通信エラーとは区別してそのまま throw する
//   (呼び出し側 = ViewModel / CheckinService が「再送可能な一時エラー」として扱う)
// - 応答が返らない失敗(オフライン・タイムアウト等)だけを TransportError.network にする
// - 失敗応答の本文は `{ "error": "<code>" }`(各 function の index.ts json())

import Foundation

struct EdgeFunctionTransport {
    enum TransportError: Error, Equatable {
        /// 応答が返らない(オフライン・タイムアウト等)
        case network
    }

    let baseURL: URL
    /// 現在のユーザー JWT を返す(失効時の更新は提供側の責務 — AuthServicing.accessToken)
    let tokenProvider: () async throws -> String
    let session: URLSession

    init(
        baseURL: URL,
        tokenProvider: @escaping () async throws -> String,
        session: URLSession = .shared
    ) {
        self.baseURL = baseURL
        self.tokenProvider = tokenProvider
        self.session = session
    }

    /// 認証付きの Edge Function リクエストを組み立てる。
    /// jsonBody があれば Content-Type: application/json で載せる(GET / 本文なしの POST は nil)
    func functionRequest(
        _ name: String,
        method: String,
        jsonBody: Data? = nil
    ) async throws -> URLRequest {
        var request = URLRequest(url: baseURL.appendingPathComponent("functions/v1/\(name)"))
        request.httpMethod = method
        let token = try await tokenProvider()
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let jsonBody {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = jsonBody
        }
        return request
    }

    /// 送信して (本文, HTTP ステータス) を返す。応答が返らない失敗は TransportError.network
    func send(_ request: URLRequest) async throws -> (data: Data, status: Int) {
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw TransportError.network
            }
            return (data, http.statusCode)
        } catch {
            throw TransportError.network
        }
    }

    /// 失敗応答 `{ "error": "<code>" }` の code。JSON でない・error が無い場合は nil
    static func errorCode(in data: Data) -> String? {
        struct ErrorBody: Decodable { let error: String }
        return (try? JSONDecoder().decode(ErrorBody.self, from: data))?.error
    }
}
